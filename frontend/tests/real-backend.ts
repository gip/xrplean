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
