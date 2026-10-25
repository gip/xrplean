/** Run against the dev UI and an actual Speculos XRP app, never a mock identity. */
import { chromium, expect } from "@playwright/test";
const origin = process.argv[2] ?? "http://localhost:4173";
const browser = await chromium.launch();
try {
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  });
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  // Wallet transport is real; isolate the smoke test from any local XLB databases.
  await page.route("**/api/**", (route) =>
    route.fulfill({
      status: 503,
      json: {
        error: "XLB is intentionally isolated for this wallet transport test",
      },
    }),
  );
  await page.goto(origin);
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await expect(page.getByText("Ledger", { exact: true }).first()).toBeVisible();
  const xaman = page.getByText("Xaman", { exact: true }).first();
  if (await xaman.count()) await expect(xaman).toBeVisible();
  else
    await expect(
      page.getByText("Xaman is not configured.", { exact: false }),
    ).toBeVisible();
  await page
    .getByText("Ledger (Speculos · development)", { exact: true })
    .first()
    .click();
  await expect(
    page.getByRole("button", { name: /Ledger \(Speculos.*Disconnect/ }),
  ).toBeVisible({ timeout: 15000 });
  await expect(page.locator(".connection-hint")).toContainText(
    "ra7Zr8ddy9tB88RaXL8B87YkqhEJG2vkAJ",
  );
  // Refresh restores the same account through the real emulator, without opening a picker.
  await page.reload();
  await expect(
    page.getByRole("button", { name: /Ledger \(Speculos.*Disconnect/ }),
  ).toBeVisible({ timeout: 15000 });
  await expect(page.locator(".connection-hint")).toContainText(
    "ra7Zr8ddy9tB88RaXL8B87YkqhEJG2vkAJ",
  );
  await expect(
    page.getByRole("dialog", { name: "Connect Wallet", exact: true }),
  ).not.toBeVisible();
  await page
    .getByRole("button", { name: /Ledger \(Speculos.*Disconnect/ })
    .click();
  await expect(
    page.getByRole("button", { name: "Connect wallet", exact: true }),
  ).toBeVisible();
  // Explicit Disconnect clears the remembered wallet, including across refresh.
  expect(
    await page.evaluate(() =>
      localStorage.getItem("xrpl-connect:wallet-state"),
    ),
  ).toBeNull();
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Connect wallet", exact: true }),
  ).toBeEnabled();
  await expect(
    page.getByRole("button", { name: /Ledger \(Speculos.*Disconnect/ }),
  ).not.toBeVisible();
  // Reconnect using the real emulator, then simulate a lost bridge during live refresh.
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await page
    .getByText("Ledger (Speculos · development)", { exact: true })
    .first()
    .click();
  await expect(
    page.getByRole("button", { name: /Ledger \(Speculos.*Disconnect/ }),
  ).toBeVisible({ timeout: 15000 });
  let failedReads = 0;
  await page.route("**/dev/speculos/apdu", (route) => {
    failedReads++;
    return route.fulfill({ status: 502, json: { error: "Emulator stopped" } });
  });
  await expect(
    page.getByRole("button", { name: "Connect wallet", exact: true }),
  ).toBeVisible({ timeout: 12000 });
  expect(failedReads).toBe(1);
  // A failed automatic restore must never display the cached address as connected.
  await page.unroute("**/dev/speculos/apdu");
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await page
    .getByText("Ledger (Speculos · development)", { exact: true })
    .first()
    .click();
  await expect(
    page.getByRole("button", { name: /Ledger \(Speculos.*Disconnect/ }),
  ).toBeVisible({ timeout: 15000 });
  await page.route("**/dev/speculos/apdu", (route) =>
    route.fulfill({
      status: 502,
      json: { error: "Emulator unavailable on restore" },
    }),
  );
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Connect wallet", exact: true }),
  ).toBeEnabled({ timeout: 15000 });
  await expect(
    page.getByRole("button", { name: /Ledger \(Speculos.*Disconnect/ }),
  ).not.toBeVisible();
  expect(
    await page.evaluate(() =>
      localStorage.getItem("xrpl-connect:wallet-state"),
    ),
  ).toBeNull();

  expect(errors).toEqual([]);
  console.log(
    "PASS actual XRP app → Speculos → local identity bridge → XRPL Connect → dashboard connect/refresh restore/disconnect and unavailable-provider recovery",
  );
} catch (e) {
  throw e;
} finally {
  await browser.close();
}
