/** Browser integration against a temporary real XLB, launched by tests/frontend.py. */
import { chromium, expect } from "@playwright/test";
const origin = process.argv[2];
if (!origin) throw new Error("Pass the temporary UI origin");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(origin + "/tests/harness.html");
  await expect(page.getByText("XLB online", { exact: true })).toBeVisible();
  const row = (index: string) =>
    page
      .locator(".ledger-row")
      .filter({ has: page.getByRole("button", { name: index, exact: true }) });
  await expect(row("200")).toBeVisible();
  await expect(row("201")).toBeVisible();
  await expect(row("200")).toHaveClass(/connected/);
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await row("201")
    .getByRole("button", { name: "Verify payment", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Confirm verify payment" })
    .click();
  await expect(
    page.locator(".ledger-popover:popover-open .inline-result"),
  ).toContainText("Succeeded", { timeout: 180000 });
  await expect(
    page.locator(".ledger-popover:popover-open .attempt"),
  ).toHaveCount(1);
  const receipt = await (
    await page.request.get(origin + "/api/bundles/default/jobs/1")
  ).json();
  expect(receipt.status).toBe("succeeded");
  expect(
    receipt.verifications.map((attempt: { kind: string; status: string }) => [
      attempt.kind,
      attempt.status,
    ]),
  ).toEqual([["payments", "kernel_checked"]]);
  expect(
    JSON.parse(receipt.verifications[0].report_json).state_authentication,
  ).toBe("not_checked_by_payments");
  const paymentResult = page.locator(".ledger-popover:popover-open .attempt");
  await paymentResult.locator("summary").first().click();
  await expect(
    paymentResult.locator(".certificate-view .lean-source"),
  ).toContainText("theorem supported_xrp_accounting");
  await expect(paymentResult).toContainText("Receipt-bound source");
  const paymentSource = await (
    await page.request.get(
      origin +
        `/api/bundles/default/jobs/1/verifications/${receipt.verifications[0].verification_id}/proof/generated_Payments/0`,
    )
  ).json();
  await expect(
    paymentResult.locator(".certificate-view .lean-source"),
  ).toHaveText(paymentSource.source);
  const ledgers = await (
    await page.request.get(origin + "/api/bundles/default/ledgers")
  ).json();
  expect(
    ledgers.find(
      (ledger: { ledger_index: string }) => ledger.ledger_index === "201",
    ).merkle,
  ).toBe("not_checked");
  await page.getByRole("button", { name: "Close ledger details" }).click();
  await row("200")
    .getByRole("button", { name: "Trust ledger", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Confirm trust ledger" })
    .click();
  await expect(page.getByRole("dialog")).not.toBeVisible();
  await expect(
    row("200").getByRole("button", { name: "Trust ledger result" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Close ledger details" }).click();
  await row("201")
    .getByRole("button", { name: "Verify tree", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Confirm verify tree" })
    .click();
  await expect(
    page.locator(".ledger-popover:popover-open .inline-result"),
  ).toContainText("Succeeded", { timeout: 180000 });
  const treeReceipt = await (
    await page.request.get(origin + "/api/bundles/default/jobs/2")
  ).json();
  expect(
    treeReceipt.verifications.map(
      (attempt: { kind: string; status: string }) => [
        attempt.kind,
        attempt.status,
      ],
    ),
  ).toEqual([["merkle", "kernel_checked"]]);
  const treeResult = page.locator(".ledger-popover:popover-open .attempt");
  await treeResult.locator("summary").first().click();
  await expect(
    treeResult.locator(".certificate-view .lean-source"),
  ).toContainText("theorem full_ledger_certificate");
  await expect(treeResult).toContainText("Receipt-bound source");
  await treeResult
    .getByLabel("Lean source file")
    .selectOption("definition_KernelMerkle");
  await expect(
    treeResult.locator(".certificate-view .lean-source"),
  ).toContainText("def LedgerTransition");
  const checkedLedgers = await (
    await page.request.get(origin + "/api/bundles/default/ledgers")
  ).json();
  expect(
    checkedLedgers.find(
      (ledger: { ledger_index: string }) => ledger.ledger_index === "201",
    ).trust,
  ).toBe("verified_trusted");
  await expect(
    row("201").getByRole("button", { name: "Trust ledger result" }),
  ).toBeVisible();
  await expect(page.locator(".ledger-popover:popover-open")).toContainText(
    "Trusted · verified",
  );
  await page.getByRole("button", { name: "Close ledger details" }).click();
  await page.getByLabel("Fetch by index").fill("200");
  await page.getByRole("button", { name: "Fetch ledger", exact: true }).click();
  await expect(page.locator(".task-result")).toContainText("Succeeded", {
    timeout: 30000,
  });
  await expect(
    page.getByRole("button", { name: "Fetch next ledger 202" }),
  ).toBeVisible();
  expect(errors).toEqual([]);
  console.log(
    "PASS real browser → proxy → Lean XLB: standalone Payment then separate tree check, exact trust confirmation, result popover and acquisition",
  );
} finally {
  await browser.close();
}
