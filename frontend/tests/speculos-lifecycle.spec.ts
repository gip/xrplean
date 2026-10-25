import { test, expect } from "@playwright/test";
import type { SpeculosAdapter } from "../src/SpeculosAdapter.ts";
const ACCOUNT =
  "21038368b6f1151e0cd559126ae13910b8b8d790652eb5cc0b5019a63d2e60792961227261375a723864647939744238385261584c38423837596b7168454a4732766b414a9000";
type AdapterWindow = Window & {
  adapter: SpeculosAdapter;
  pending?: Promise<string>;
};
async function load(page: import("@playwright/test").Page) {
  await page.goto("/tests/harness.html");
  await page.evaluate(async () => {
    const path = "/src/SpeculosAdapter.ts";
    const { SpeculosAdapter } = await import(/* @vite-ignore */ path);
    (window as unknown as AdapterWindow).adapter = new SpeculosAdapter();
  });
}
test("emulator adapter validates identity and declares signing unsupported", async ({
  page,
}) => {
  await page.route("**/dev/speculos/apdu", (route) =>
    route.fulfill({
      json: {
        data: route.request().postDataJSON().data.startsWith("e006")
          ? "000208029000"
          : ACCOUNT,
      },
    }),
  );
  await load(page);
  const account = await page.evaluate(() =>
    (window as unknown as AdapterWindow).adapter.connect({
      network: "mainnet",
    }),
  );
  expect(account.address).toBe("ra7Zr8ddy9tB88RaXL8B87YkqhEJG2vkAJ");
  const signing = await page.evaluate(async () => {
    const adapter = (window as unknown as AdapterWindow).adapter;
    const results = [];
    for (const method of ["sign", "signAndSubmit", "signMessage"] as const) {
      try {
        await adapter[method]();
      } catch (error) {
        results.push((error as { code: string }).code);
      }
    }
    return { capabilities: adapter.capabilities, results };
  });
  expect(signing).toEqual({
    capabilities: { sign: false, signAndSubmit: false, signMessage: false },
    results: ["UNSUPPORTED_METHOD", "UNSUPPORTED_METHOD", "UNSUPPORTED_METHOD"],
  });
  await page.evaluate(() =>
    (window as unknown as AdapterWindow).adapter.disconnect(),
  );
  expect(
    await page.evaluate(() =>
      (window as unknown as AdapterWindow).adapter.getAccount(),
    ),
  ).toBeNull();
});
test("disconnect during an address read cannot restore a stale identity", async ({
  page,
}) => {
  let entered!: () => void, release!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const resume = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/dev/speculos/apdu", async (route) => {
    if (route.request().postDataJSON().data.startsWith("e006")) {
      await route.fulfill({ json: { data: "000208029000" } });
      return;
    }
    entered();
    await resume;
    await route.fulfill({ json: { data: ACCOUNT } }).catch(() => {});
  });
  await load(page);
  await page.evaluate(() => {
    const state = window as unknown as AdapterWindow;
    state.pending = state.adapter.connect().then(
      () => "connected",
      () => "cancelled",
    );
  });
  await started;
  await page.evaluate(() =>
    (window as unknown as AdapterWindow).adapter.disconnect(),
  );
  release();
  expect(
    await page.evaluate(() => (window as unknown as AdapterWindow).pending),
  ).toBe("cancelled");
  expect(
    await page.evaluate(() =>
      (window as unknown as AdapterWindow).adapter.getAccount(),
    ),
  ).toBeNull();
});
test("malformed or mismatched emulator addresses never become connected identities", async ({
  page,
}) => {
  await load(page);
  for (const data of [
    "9000",
    ACCOUNT.slice(0, 72) + "00" + ACCOUNT.slice(74),
  ]) {
    await page.route("**/dev/speculos/apdu", (route) =>
      route.fulfill({
        json: {
          data: route.request().postDataJSON().data.startsWith("e006")
            ? "000208029000"
            : data,
        },
      }),
    );
    const result = await page.evaluate(async () => {
      const adapter = (window as unknown as AdapterWindow).adapter;
      try {
        await adapter.connect();
        return "connected";
      } catch {
        return await adapter.getAccount();
      }
    });
    expect(result).toBeNull();
  }
});
