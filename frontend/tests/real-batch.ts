/** Real browser → proxy → XLB → pinned Lean kernel, with public identity fixtures. */
import { chromium, expect } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { encode, encodeForSigning } from "xrpl";
import { createHash } from "node:crypto";
const origin = process.argv[2];
if (!origin) throw new Error("Pass the temporary UI origin");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1100 },
  });
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  let submissions = 0;
  page.on("request", (r) => {
    if (r.method() === "POST" && r.url().endsWith("/api/batches/prepare"))
      submissions++;
  });
  await page.goto(origin + "/tests/harness.html?view=batch&batchFixture=1");
  await expect(
    page.getByRole("region", { name: "Service fee policy" }),
  ).toContainText("1000 drops");
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  for (const [label, value] of [
    ["Destination", "rPEPPER7kfTD9w2To4CQk6UCfuHM9c6GDY"],
    ["Amount (drops)", "1"],
    ["Sequence", "101"],
    [
      "Compressed secp256k1 public key",
      "0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020",
    ],
    ["Outer sequence", "100"],
    ["Service Payment sequence", "102"],
    ["Last ledger sequence", "200"],
    ["Network fee (drops)", "100"],
  ])
    await page.getByLabel(label, { exact: true }).fill(value);
  await page.getByRole("button", { name: "Prepare and check in Lean" }).click();
  const result = page.getByRole("region", { name: "Batch preparation result" });
  await expect(result).toContainText("Kernel checked", { timeout: 30000 });
  await expect(result).toContainText("Prepared for the current draft.");
  const receipt = await (
    await page.request.get(origin + "/api/batches/1")
  ).json();
  expect(receipt.status).toBe("kernel_checked");
  expect(receipt.report.axiom_audit).not.toContain("sorryAx");
  expect(encode(receipt.prepared.transaction)).toBe(
    receipt.prepared.unsigned_bytes,
  );
  const signing = createHash("sha512")
    .update(Buffer.from(encodeForSigning(receipt.prepared.transaction), "hex"))
    .digest()
    .subarray(0, 32)
    .toString("hex")
    .toUpperCase();
  expect(signing).toBe(receipt.prepared.signing_digest);
  const pending = page.waitForEvent("download");
  await page
    .getByRole("button", { name: "Download Certificate.lean", exact: true })
    .click();
  const download = await pending;
  expect(await readFile((await download.path())!, "utf8")).toBe(
    receipt.prepared.certificate_source,
  );
  await page.getByLabel("Amount (drops)", { exact: true }).fill("2");
  await expect(result).toContainText("does not certify the current draft");
  expect(submissions).toBe(1);
  expect(errors).toEqual([]);
  console.log(
    "PASS real Batch form → restricted proxy → Lean XLB → actual kernel certificate, codec/digest binding, artifact download, and edited-draft isolation",
  );
} finally {
  await browser.close();
}
