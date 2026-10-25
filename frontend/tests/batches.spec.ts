import { test, expect, type Page } from "@playwright/test";
import { createHash } from "node:crypto";

const SERVICE = "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe";
const policy = {
  version: 1,
  network_id: 0,
  service_address: SERVICE,
  service_fee_drops: "1000",
};
async function setup(page: Page) {
  let submissions = 0,
    complete = false;
  const attempts = new Map<string, Record<string, unknown>>();
  await page.route("**/api/**", async (route) => {
    const path = new URL(route.request().url()).pathname.slice(4);
    let value: unknown = [];
    let status = 200;
    if (path === "/health")
      value = { service: "XLB", network_id: 0, pid: 1, state_backend: "nudb" };
    else if (path === "/status")
      value = {
        service: "XLB",
        network_id: 0,
        xrpld: {
          reachable: false,
          server_state: null,
          build_version: null,
          complete_ledgers: null,
          validated_ledger: null,
          network_id: null,
          network_compatible: null,
          latency_ms: 0,
          observed_at_unix: "0",
          error: null,
        },
      };
    else if (path === "/batches/policy")
      value = { enabled: true, policy, policy_digest: "A".repeat(64) };
    else if (path === "/batches/prepare") {
      submissions++;
      const body = route.request().postDataJSON();
      expect(body.policy_digest).toBe("A".repeat(64));
      expect(body.account).toBe("rTESTbrowserFixture");
      const id = String(submissions);
      value = {
        attempt_id: id,
        status: "queued",
        error: "",
        created_at: "2026-10-25 12:00:00",
        report: null,
        prepared: {
          transaction: {
            TransactionType: "Batch",
            Flags: 65536,
            Sequence: body.sequence,
            LastLedgerSequence: body.last_ledger_sequence,
            SigningPubKey: body.public_key,
            Account: body.account,
            Fee: body.network_fee_drops,
            RawTransactions: [
              ...body.payments.map(
                (p: {
                  destination: string;
                  amount_drops: string;
                  sequence: number;
                }) => ({
                  RawTransaction: {
                    TransactionType: "Payment",
                    Flags: 1073741824,
                    Account: body.account,
                    Destination: p.destination,
                    Amount: p.amount_drops,
                    Sequence: p.sequence,
                    Fee: "0",
                    SigningPubKey: "",
                  },
                }),
              ),
              {
                RawTransaction: {
                  TransactionType: "Payment",
                  Flags: 1073741824,
                  Account: body.account,
                  Destination: SERVICE,
                  Amount: "1000",
                  Sequence: body.service_sequence,
                  Fee: "0",
                  SigningPubKey: "",
                },
              },
            ],
          },
          unsigned_bytes: "120047",
          signing_digest: "B".repeat(64),
          policy,
          policy_digest: "A".repeat(64),
          total_debit_drops: "1101",
          certificate_source: "theorem example : True := True.intro",
        },
      };
      attempts.set(id, value as Record<string, unknown>);
      status = 202;
    } else if (path === "/batches")
      value = Array.from(attempts.values(), (a) => ({
        attempt_id: a.attempt_id,
        status: a.status,
        created_at: a.created_at,
      }));
    else if (/^\/batches\/\d+$/.test(path)) {
      const attempt = attempts.get(path.split("/")[2]);
      value = attempt
        ? {
            ...attempt,
            status: complete ? "kernel_checked" : "running",
            report: complete
              ? {
                  artifacts: [
                    "transaction.json",
                    "Certificate.lean",
                    "kernel.log",
                  ],
                }
              : null,
          }
        : null;
    } else if (path.endsWith("/artifacts/transaction.json")) {
      const content = JSON.stringify(
        attempts.get(path.split("/")[2])?.prepared,
      );
      value = {
        name: "transaction.json",
        content,
        sha256: createHash("sha256")
          .update(content)
          .digest("hex")
          .toUpperCase(),
      };
    }
    await route.fulfill({ status, json: value });
  });
  await page.goto("/tests/harness.html?view=batch");
  return {
    count: () => submissions,
    complete: () => {
      complete = true;
    },
  };
}
async function fill(page: Page) {
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await page
    .getByLabel("Destination", { exact: true })
    .fill("rPEPPER7kfTD9w2To4CQk6UCfuHM9c6GDY");
  await page.getByLabel("Amount (drops)", { exact: true }).fill("1");
  await page.getByLabel("Sequence", { exact: true }).fill("101");
  await page
    .getByLabel("Compressed secp256k1 public key")
    .fill("0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020");
  await page.getByLabel("Outer sequence", { exact: true }).fill("100");
  await page.getByLabel("Service Payment sequence").fill("102");
  await page.getByLabel("Last ledger sequence").fill("200");
  await page.getByLabel("Network fee (drops)").fill("100");
}

test("Batch fee is reviewed before preparation; edited drafts never inherit a certificate", async ({
  page,
}) => {
  const control = await setup(page);
  const prepare = page.getByRole("button", {
    name: "Prepare and check in Lean",
  });
  await expect(prepare).toBeDisabled();
  await expect(
    page.getByRole("region", { name: "Service fee policy" }),
  ).toContainText(SERVICE);
  await fill(page);
  await prepare.click();
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Prepared for the current draft.");
  await page.getByLabel("Amount (drops)", { exact: true }).fill("2");
  control.complete();
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Kernel checked");
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("does not certify the current draft");
  expect(control.count()).toBe(1);
  await prepare.click();
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Attempt #2");
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Prepared for the current draft.");
  const downloaded = page.waitForEvent("download");
  await page
    .getByRole("button", { name: "Download transaction.json", exact: true })
    .click();
  expect((await downloaded).suggestedFilename()).toBe(
    "batch-2-transaction.json",
  );
  await page.screenshot({
    path: "/private/tmp/xl-batch-preview.png",
    fullPage: true,
  });
  await page.reload();
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Attempt #2");
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Previous preparation");
  expect(control.count()).toBe(2);
});

test("disconnect detaches identity but retains the accepted attempt without another submission", async ({
  page,
}) => {
  const control = await setup(page);
  await fill(page);
  await page.getByRole("button", { name: "Prepare and check in Lean" }).click();
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Attempt #1");
  await page.getByRole("button", { name: /Disconnect/ }).click();
  control.complete();
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Kernel checked");
  await expect(
    page.getByRole("region", { name: "Batch preparation result" }),
  ).toContainText("Previous preparation");
  await expect(
    page.getByRole("button", { name: "Prepare and check in Lean" }),
  ).toBeDisabled();
  expect(control.count()).toBe(1);
});
