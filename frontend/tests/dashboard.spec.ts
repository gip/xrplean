import { test, expect, type Page } from "@playwright/test";
const A = "A".repeat(64),
  B = "B".repeat(64),
  C = "C".repeat(64),
  D = "D".repeat(64);
const progress = {
  ledger_index: 204,
  phase: "receiving_state",
  transport: "peer",
  pages: 0,
  entries: 0,
  state_bytes: 512,
  elapsed_ms: 1000,
  keyspace_permille: 0,
  nodes: 120,
  pending: 30,
  resumed: true,
  retry_attempt: 0,
  retry_delay_ms: 0,
  last_error: "",
};
const bundle = (name: string) => ({
  bundle: name,
  network_id: 0,
  path: "/tmp/test",
  status: "complete",
  ledger_count: 3,
  snapshot_count: 4,
  ledger_intervals: [
    { first: 200, last: 201 },
    { first: 204, last: 204 },
  ],
  has_gaps: true,
  first_ledger: 200,
  last_ledger: 204,
  ledger_hash: C,
  state_root: D,
  pending: [{ ledger_index: "204", ledger_hash: C }],
});
const ledger = (index: string, hash: string, changes = {}) => ({
  ledger_index: index,
  ledger_hash: hash,
  parent_hash: A,
  state_root: D,
  trust: "untrusted",
  export_variants: "1",
  state: "peer_snapshot",
  header_json: "{}",
  merkle: "not_checked",
  payments: "not_checked",
  ...changes,
});
const variant = (id: string, hash = B) => ({
  export_id: id,
  ledger_index: "201",
  ledger_hash: hash,
  payload_sha256: D,
  received_at: "",
  merkle: "not_checked",
  payments: "not_checked",
});
const task = {
  task_id: "42",
  bundle: "main",
  kind: "fetch",
  status: "running",
  progress,
  error: "",
  retry_of: "40",
  created_at: "2026-10-24 00:00:00",
  started_at: "2026-10-24 00:01:00",
  finished_at: "",
  updated_at: "2026-10-24 00:02:00",
  request: { from: "latest" },
  resolved_request: { from: 204, to: 204 },
  result: null,
};
const job = {
  job_id: "18",
  from: "201",
  to: "204",
  checks: '["merkle","payments"]',
  status: "unsupported",
  error: "Payment coverage did not pass completely",
  created_at: "",
  updated_at: "",
};
async function setup(page: Page, running = false) {
  const calls: { path: string; body: Record<string, unknown> }[] = [];
  let nodeOverrides: Record<string, unknown> = {};
  let streaming = 0,
    failed = false;
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.route("https://fonts.googleapis.com/**", (r) => r.abort());
  await page.route("**/api/**", async (route) => {
    const req = route.request(),
      path = new URL(req.url()).pathname.slice(4),
      body = req.postDataJSON() as Record<string, unknown> | null;
    let data: unknown;
    if (path === "/health")
      data = { service: "XLB", network_id: 0, pid: 123, state_backend: "nudb" };
    else if (path === "/status")
      data = {
        service: "XLB",
        network_id: 0,
        xrpld: {
          reachable: true,
          server_state: "full",
          build_version: "xrpld-fixture",
          complete_ledgers: "200-204",
          validated_ledger: { seq: 204, hash: C },
          network_id: null,
          network_compatible: true,
          latency_ms: 12,
          observed_at_unix: String(Math.floor(Date.now() / 1000)),
          error: null,
          ...nodeOverrides,
        },
      };
    else if (path === "/bundles")
      data = [bundle("default"), bundle("main"), bundle("archive")];
    else if (path.endsWith("/ledgers"))
      data = [
        ledger("200", A, { trust: "operator_trusted" }),
        ledger("201", B, {
          merkle: "kernel_checked",
          payments: "unsupported",
          export_variants: "2",
        }),
        ledger("201", C),
        ledger("204", C, { export_variants: "0" }),
        ledger("204", D, { state: "missing" }),
      ];
    else if (path.endsWith("/exports"))
      data = [variant("7"), variant("8"), variant("9", C)];
    else if (path.endsWith("/tasks/42/stream")) {
      calls.push({ path, body: body ?? {} });
      streaming++;
      if (streaming > 1) running = false;
      const event =
        streaming === 1
          ? { ...progress, event: "progress", task_id: "42", event_seq: 1 }
          : { event: "result", task_id: "42", event_seq: 2, data: [] };
      await route.fulfill({
        contentType: "application/x-ndjson",
        body: JSON.stringify(event) + "\n",
      });
      return;
    } else if (path.endsWith("/tasks/42"))
      data = {
        ...task,
        status: failed
          ? "interrupted"
          : streaming > 1
            ? "succeeded"
            : "running",
        error: failed ? "backend stopped" : "",
      };
    else if (path.endsWith("/tasks") && req.method() === "GET")
      data = [
        {
          ...task,
          status: failed ? "interrupted" : running ? "running" : "succeeded",
          error: failed ? "backend stopped" : "",
        },
      ];
    else if (path.endsWith("/jobs/18"))
      data = {
        job_id: "18",
        status: "unsupported",
        error: job.error,
        items: [
          {
            ledger_index: "201",
            export_id: "8",
            status: "unsupported",
            error: "Unsupported Payment",
          },
          { ledger_index: "204", export_id: "", status: "pending", error: "" },
        ],
        verifications: [
          {
            verification_id: "22",
            export_id: "8",
            kind: "payments",
            status: "unsupported",
            report_json: '{"payments_unsupported":1,"other_transactions":2}',
            artifacts_json: '[{"path":"proof.lean","sha256":"digest"}]',
            attempt_dir: "/tmp/immutable-attempt",
          },
        ],
      };
    else if (path.endsWith("/jobs") && req.method() === "GET") data = [job];
    else if (req.method() === "POST") {
      calls.push({ path, body: body ?? {} });
      if (path.endsWith("/tasks")) running = true;
      data = path.endsWith("/trust")
        ? {
            ledger_hash: A,
            trust: "operator_trusted",
            verification: "unchanged",
          }
        : path.endsWith("/jobs")
          ? { job_id: "18", status: "queued" }
          : task;
    } else throw new Error(`Unhandled fixture ${req.method()} ${path}`);
    await route.fulfill({ json: data });
  });
  await page.goto("/tests/harness.html?bundle=main");
  await expect(page.getByText("XLB online", { exact: true })).toBeVisible();
  return {
    calls,
    errors,
    setNode: (values: Record<string, unknown>) => {
      nodeOverrides = values;
    },
    failTask: () => {
      failed = true;
    },
  };
}
const row = (page: Page, index: string, fork = 0) =>
  page
    .locator(".ledger-row")
    .filter({ has: page.getByRole("button", { name: index, exact: true }) })
    .nth(fork);
async function connect(page: Page) {
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
}

test("one compact ordered list shows only complete state and preserves forks", async ({
  page,
}) => {
  const { calls, errors } = await setup(page);
  await expect(page.locator(".ledger-row")).toHaveCount(4);
  expect(await page.locator(".ledger-number").allTextContents()).toEqual([
    "200",
    "201",
    "201",
    "204",
  ]);
  await expect(page.getByRole("navigation")).toHaveCount(0);
  await expect(row(page, "200")).toHaveClass(/connected/);
  await expect(row(page, "201", 1)).toHaveClass(/gap/);
  await expect(row(page, "201", 1).locator(".gap-label")).toHaveText(
    "2 missing",
  );
  await expect(page.locator(".next-index")).toHaveText("205");
  await expect(
    page
      .locator(".next-ledger")
      .getByRole("button", { name: "Fetch next ledger 205" }),
  ).toBeDisabled();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify payment" }),
  ).toBeDisabled();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify payment" }),
  ).toHaveAttribute("title", /Unsupported/);
  expect(calls.filter((call) => call.path.endsWith("/tasks"))).toHaveLength(0);
  await page.getByRole("combobox", { name: "Bundle" }).selectOption("archive");
  await page.reload();
  await expect(page.getByRole("combobox", { name: "Bundle" })).toHaveValue(
    "archive",
  );
  expect(errors).toEqual([]);
});
test("number and checkmark open a details popover; theme persists", async ({
  page,
}) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await setup(page);
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await row(page, "200")
    .getByRole("button", { name: "Trust ledger result" })
    .click();
  await expect(page.locator(".ledger-popover:popover-open")).toContainText(A);
  await page.getByRole("button", { name: "Close ledger details" }).click();
  await row(page, "201")
    .getByRole("button", { name: "201", exact: true })
    .click();
  await expect(page.locator(".ledger-popover:popover-open")).toContainText(
    "Unsupported",
  );
  await page.getByRole("button", { name: "Close ledger details" }).click();
  await page.getByRole("button", { name: "Switch to light mode" }).click();
  await page.reload();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
});
test("fetch by index always acquires full state and follows durable progress", async ({
  page,
}) => {
  const { calls } = await setup(page);
  await connect(page);
  await page.getByLabel("Fetch by index").fill("107,883,772");
  await page.getByRole("button", { name: "Fetch ledger", exact: true }).click();
  await expect
    .poll(() => calls.filter((call) => call.path.endsWith("/tasks")).length)
    .toBe(1);
  expect(calls.find((call) => call.path.endsWith("/tasks"))?.body).toEqual({
    kind: "fetch",
    request: { from: 107883772, to: 107883772, state: true, transport: "auto" },
  });
  await expect(page.locator(".task-result")).toContainText("Succeeded", {
    timeout: 10000,
  });
});
test("next fetch extends the retained tip", async ({ page }) => {
  const { calls } = await setup(page);
  await connect(page);
  await page.getByRole("button", { name: "Fetch next ledger 205" }).click();
  await expect
    .poll(() => calls.some((call) => call.path.endsWith("/tasks")))
    .toBe(true);
  expect(calls.find((call) => call.path.endsWith("/tasks"))?.body).toEqual({
    kind: "state_update",
    request: { index: "205", transport: "auto" },
  });
});
test("a gap after the retained tip offers its immediate next state", async ({
  page,
}, info) => {
  const { calls, setNode, errors } = await setup(page);
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({ json: [ledger("107891325", C)] }),
  );
  setNode({ validated_ledger: { seq: 107891501, hash: D } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  const tip = row(page, "107,891,325");
  const next = tip.getByRole("button", {
    name: "Fetch next ledger 107,891,326",
  });
  await expect(tip.locator(".gap-count")).toHaveText("175 missing");
  await expect(next).toHaveText("Fetch 107,891,326");
  await expect(next).toBeDisabled();
  await expect(page.locator(".next-ledger")).toHaveCount(0);
  await connect(page);
  await expect(next).toBeEnabled();
  await page.screenshot({ path: info.outputPath("next-state-light.png") });
  await page.getByRole("button", { name: "Switch to dark mode" }).click();
  await page.screenshot({ path: info.outputPath("next-state-dark.png") });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(next).toBeInViewport();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({ path: info.outputPath("next-state-mobile.png") });
  await next.click();
  await expect
    .poll(() => calls.filter((call) => call.path.endsWith("/tasks")))
    .toEqual([
      {
        path: "/bundles/main/tasks",
        body: {
          kind: "state_update",
          request: { index: "107891326", transport: "auto" },
        },
      },
    ]);
  await expect(next).toBeDisabled();
  expect(errors).toEqual([]);
});
test("the next-state gap action stays disabled for an ambiguous tip", async ({
  page,
}) => {
  const { calls, setNode } = await setup(page);
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({ json: [ledger("204", C), ledger("204", D)] }),
  );
  setNode({ validated_ledger: { seq: 208, hash: A } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await connect(page);
  const next = page.getByRole("button", { name: "Fetch next ledger 205" });
  await expect(next).toBeDisabled();
  await expect(next).toHaveAttribute("title", /multiple forks/);
  expect(calls.filter((call) => call.path.endsWith("/tasks"))).toHaveLength(0);
});
test("the next-state gap action remains available across a page boundary", async ({
  page,
}) => {
  const { setNode } = await setup(page);
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({
      json: Array.from({ length: 50 }, (_, i) => ledger(String(200 + i), C)),
    }),
  );
  setNode({ validated_ledger: { seq: 425, hash: D } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(row(page, "249").locator(".gap-count")).toHaveText(
    "175 missing",
  );
  await connect(page);
  await expect(
    row(page, "249").getByRole("button", { name: "Fetch next ledger 250" }),
  ).toBeEnabled();
  await page.getByRole("button", { name: "Next", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Fetch latest ledger 425" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Fetch next ledger 250" }),
  ).toHaveCount(0);
});
test("latest validated index follows polling and fetches the displayed exact ledger", async ({
  page,
}) => {
  const { calls, setNode } = await setup(page);
  const latest = page.locator(".latest-ledger");
  await expect(
    row(page, "204").getByLabel("Latest validated ledger", { exact: true }),
  ).toBeVisible();
  await expect(latest).toHaveCount(0);
  setNode({ validated_ledger: { seq: 205, hash: D } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(latest.locator(".latest-index")).toHaveText("205");
  await expect(row(page, "204")).toHaveClass(/connected/);
  await expect(row(page, "204").locator(".gap-label")).toHaveCount(0);
  await expect(latest.locator(".ledger-checks")).toHaveCount(0);
  setNode({ validated_ledger: { seq: 208, hash: D } });
  await expect(latest.locator(".latest-index")).toHaveText("208", {
    timeout: 10000,
  });
  await expect(page.locator(".ledger-list > .ledger-row").last()).toHaveClass(
    /latest-ledger/,
  );
  await expect(row(page, "204")).toHaveClass(/gap/);
  await expect(row(page, "204").locator(".gap-count")).toHaveText("3 missing");
  await expect(page.locator(".next-ledger")).toHaveCount(0);
  await expect(latest.getByRole("button")).toBeDisabled();
  await connect(page);
  await page.getByRole("button", { name: "Fetch latest ledger 208" }).click();
  await expect
    .poll(() => calls.find((call) => call.path.endsWith("/tasks"))?.body)
    .toEqual({
      kind: "fetch",
      request: {
        from: 208,
        to: 208,
        ledger_hash: D,
        state: true,
        transport: "auto",
      },
    });
});
test("latest fetch is available for empty bundles and preserves fork identity", async ({
  page,
}) => {
  const { calls, setNode } = await setup(page);
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({ json: [] }),
  );
  setNode({ validated_ledger: { seq: 204, hash: D } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await connect(page);
  const latest = page.getByLabel("Latest validated ledger", { exact: true });
  await expect(page.locator(".next-ledger")).toHaveCount(0);
  await expect(page.locator(".ledger-row")).toHaveCount(1);
  await expect(latest).toHaveClass(/ledger-row/);
  await expect(latest.getByRole("button")).toBeEnabled();
  await latest.getByRole("button").click();
  await expect
    .poll(() => calls.find((call) => call.path.endsWith("/tasks"))?.body)
    .toEqual({
      kind: "fetch",
      request: {
        from: 204,
        to: 204,
        ledger_hash: D,
        state: true,
        transport: "auto",
      },
    });
});
test("latest fetch requires current compatible node status and exact stored hash", async ({
  page,
}) => {
  const { setNode } = await setup(page);
  await connect(page);
  const latest = page.getByLabel("Latest validated ledger", { exact: true });
  // A different fork at a retained index still needs acquisition.
  setNode({ validated_ledger: { seq: 204, hash: D } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(latest.getByRole("button")).toBeEnabled();
  for (const unavailable of [
    { validated_ledger: null },
    { reachable: false },
    { network_compatible: false },
    { error: "node error" },
    { observed_at_unix: "1" },
  ]) {
    setNode({ validated_ledger: { seq: 208, hash: D }, ...unavailable });
    await page.getByRole("button", { name: "↻ Refresh" }).click();
    if ("validated_ledger" in unavailable) {
      await expect(latest).toHaveCount(0);
    } else {
      await expect(latest).toContainText("Status unavailable");
      await expect(latest.getByRole("button")).toBeDisabled();
    }
    setNode({ validated_ledger: { seq: 208, hash: D } });
    await page.getByRole("button", { name: "↻ Refresh" }).click();
    await expect(latest.getByRole("button")).toBeEnabled();
  }
});
test("trust needs one exact confirmation and displays the result in a popover", async ({
  page,
}) => {
  const { calls } = await setup(page);
  await connect(page);
  await page.route("**/api/bundles/main/trust", async (route) => {
    calls.push({
      path: "/bundles/main/trust",
      body: route.request().postDataJSON(),
    });
    await route.fulfill({
      json: {
        ledger_hash: B,
        trust: "operator_trusted",
        verification: "unchanged",
      },
    });
  });
  await row(page, "201")
    .getByRole("button", { name: "Trust ledger", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText(B);
  await expect(dialog).toContainText(D);
  await dialog.getByRole("button", { name: "Cancel" }).click();
  expect(calls.filter((call) => call.path.endsWith("/trust"))).toHaveLength(0);
  await row(page, "201")
    .getByRole("button", { name: "Trust ledger", exact: true })
    .click();
  await dialog.getByRole("button", { name: "Confirm trust ledger" }).click();
  await expect(dialog).not.toBeVisible();
  await expect(
    page.locator(".ledger-popover:popover-open").getByRole("status"),
  ).toContainText("Ledger trusted");
  await expect(
    row(page, "201").getByRole("button", { name: "Trust ledger result" }),
  ).toBeEnabled();
});
test("Payment confirmation pins an export and shows unsupported reports in the result popover", async ({
  page,
}) => {
  const { calls } = await setup(page);
  await connect(page);
  await row(page, "201")
    .getByRole("button", { name: "Verify payment", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByRole("button", { name: "Confirm verify payment" }),
  ).toBeDisabled();
  await dialog.getByLabel("Exact export").selectOption("8");
  await expect(
    dialog.getByText(/This export needs a tree check first/),
  ).toHaveCount(0);
  // A missing parent snapshot must not block the freshly reviewed Payment submission.
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({ json: [ledger("201", B, { export_variants: "2" })] }),
  );
  await dialog.getByRole("button", { name: "Confirm verify payment" }).click();
  await expect
    .poll(() => calls.some((call) => call.path.endsWith("/jobs")))
    .toBe(true);
  expect(calls.find((call) => call.path.endsWith("/jobs"))?.body).toEqual({
    from: 201,
    to: 201,
    checks: ["payments"],
    export_id: 8,
  });
  const popover = page.locator(".ledger-popover:popover-open");
  await expect(popover.locator(".inline-result")).toContainText("Unsupported");
  await popover.getByText("Payment result").click();
  await expect(popover.locator(".attempt")).toContainText(
    "payments_unsupported",
  );
  await page.reload();
  await expect(
    page.locator(".ledger-popover:popover-open .inline-result"),
  ).toContainText("Unsupported");
});
test("supported Payment results succeed and keep skipped counts visible", async ({
  page,
}) => {
  const { calls } = await setup(page);
  await connect(page);
  await page.route("**/api/bundles/main/jobs/18", (route) =>
    route.fulfill({
      json: {
        job_id: "18",
        status: "succeeded",
        error: "",
        items: [
          {
            ledger_index: "201",
            export_id: "8",
            status: "succeeded",
            error: "",
          },
        ],
        verifications: [
          {
            verification_id: "23",
            export_id: "8",
            kind: "payments",
            status: "supported_checked",
            report_json: JSON.stringify({
              payments_verified: 5,
              payments_skipped: 3,
              payments_unsupported: 3,
              payments_failed: 0,
              coverage: "supported_payments_only",
              transactions: [
                { status: "unsupported", reason: "failure result not modeled" },
              ],
            }),
            artifacts_json: "[]",
            attempt_dir: "/tmp/supported-attempt",
          },
        ],
      },
    }),
  );
  await row(page, "201")
    .getByRole("button", { name: "Verify payment", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("Exact export").selectOption("8");
  await dialog.getByRole("button", { name: "Confirm verify payment" }).click();
  const popover = page.locator(".ledger-popover:popover-open");
  await expect(popover.locator(".inline-result")).toContainText("Succeeded");
  await expect(popover).toContainText(
    "5 Payments checked · 3 skipped · 0 failed",
  );
  await expect(popover).toContainText("Supported Payments checked");
  await popover.getByText("Payment result").click();
  await expect(popover.locator(".attempt")).toContainText(
    "failure result not modeled",
  );
  expect(
    calls.find((call) => call.path.endsWith("/jobs"))?.body.checks,
  ).toEqual(["payments"]);
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({
      json: [
        ledger("200", A),
        ledger("201", B, { payments: "supported_checked" }),
      ],
    }),
  );
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify payment result" }),
  ).toBeEnabled();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify tree", exact: true }),
  ).toBeEnabled();
});
test("changed reviewed digest blocks verification submission", async ({
  page,
}) => {
  const { calls } = await setup(page);
  await connect(page);
  await row(page, "201", 1)
    .getByRole("button", { name: "Verify tree", exact: true })
    .click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Export #9");
  await page.route("**/api/bundles/main/exports", (route) =>
    route.fulfill({ json: [{ ...variant("9", C), payload_sha256: A }] }),
  );
  await dialog.getByRole("button", { name: "Confirm verify tree" }).click();
  await expect(dialog.getByRole("alert")).toContainText(
    "reviewed export changed",
  );
  expect(calls.filter((call) => call.path.endsWith("/jobs"))).toHaveLength(0);
});
test("active observers reconnect with cursor and interrupted fetches can be retried", async ({
  page,
}) => {
  const { calls, failTask } = await setup(page, true);
  await expect
    .poll(() => calls.filter((call) => call.path.endsWith("/stream")).length)
    .toBeGreaterThan(1);
  expect(calls.filter((call) => call.path.endsWith("/stream"))[1].body).toEqual(
    { after_seq: 1 },
  );
  failTask();
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await connect(page);
  await page.getByRole("tab", { name: /^Jobs/ }).click();
  await page.getByRole("button", { name: /^Fetch #42/ }).click();
  await page.getByRole("button", { name: "Retry fetch" }).click();
  await expect
    .poll(
      () =>
        calls.filter((call) => call.path.endsWith("/tasks/42/retry")).length,
    )
    .toBe(1);
});
test("ambiguous submissions are never retried automatically", async ({
  page,
}) => {
  await setup(page);
  await connect(page);
  let submissions = 0;
  await page.route("**/api/bundles/main/tasks", (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    submissions++;
    return route.abort("connectionreset");
  });
  await page.getByLabel("Fetch by index").fill("123");
  await page.getByRole("button", { name: "Fetch ledger", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("No automatic retry");
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  expect(submissions).toBe(1);
});
test("production starts disconnected; inventories are numerically ordered and paginated", async ({
  page,
}) => {
  const { errors, setNode } = await setup(page);
  await page.goto("/?bundle=main");
  await expect(
    page.getByRole("heading", { name: "Ledgers", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Connect wallet", exact: true }),
  ).toBeVisible();
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({
      json: [
        ledger("9999", A, { state: "witness" }),
        ...Array.from({ length: 125 }, (_, i) =>
          ledger(String(1124 - i), i.toString(16).padStart(64, "0")),
        ),
      ],
    }),
  );
  setNode({ validated_ledger: { seq: 1124, hash: "0".repeat(64) } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(page.getByText("Showing 1–50 of 125")).toBeVisible();
  await expect(page.locator(".ledger-row")).toHaveCount(50);
  await expect(page.locator(".ledger-number").first()).toHaveText("1,000");
  await page.getByRole("button", { name: "Next", exact: true }).click();
  await expect(page.getByText("Showing 51–100 of 125")).toBeVisible();
  expect(errors).toEqual([]);
});
test("the header is the only wallet connection control and opens the wallet picker", async ({
  page,
}) => {
  await setup(page);
  await page.goto("/?bundle=main");
  const connect = page.getByRole("button", { name: /^connect wallet$/i });
  await expect(connect).toHaveCount(1);
  await expect(
    page
      .locator(".masthead")
      .getByRole("button", { name: /^connect wallet$/i }),
  ).toBeVisible();
  await connect.click();
  await expect(
    page.getByRole("region", { name: "Wallet options" }),
  ).toBeVisible();
  await expect(page.locator(".wallet-help")).toHaveCount(0);
  await expect(
    page.getByText("Xaman is not configured.", { exact: false }),
  ).toHaveCount(0);
});
test("compact list fits mobile and captures both themes", async ({
  page,
}, info) => {
  const { setNode } = await setup(page);
  setNode({ validated_ledger: { seq: 208, hash: D } });
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(page.locator(".latest-index")).toHaveText("208");
  await page.evaluate(() => document.fonts.ready);
  const centered = await page.locator(".bundle-select").evaluate((control) => {
    const select = control.querySelector("select")!.getBoundingClientRect();
    const arrow = control.querySelector("svg")!.getBoundingClientRect();
    return (
      Math.abs(select.top + select.height / 2 - arrow.top - arrow.height / 2) <
      1
    );
  });
  expect(centered).toBe(true);
  await page.getByRole("tab", { name: /^Jobs/ }).click();
  await page.screenshot({
    path: info.outputPath("jobs-light.png"),
    fullPage: true,
  });
  await page.getByRole("tab", { name: "Ledgers", exact: true }).click();
  await page.screenshot({
    path: info.outputPath("ledgers-light.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Switch to dark mode" }).click();
  await page.screenshot({
    path: info.outputPath("ledgers-dark.png"),
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(
    row(page, "201").getByRole("button", { name: "Verify payment" }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({
    path: info.outputPath("ledgers-mobile.png"),
    fullPage: true,
  });
});
test("Jobs tab retains fetch and verification history and survives reload", async ({
  page,
}) => {
  await setup(page);
  await expect(
    page.getByRole("tab", { name: "Ledgers", exact: true }),
  ).toHaveAttribute("aria-selected", "true");
  await page.getByRole("tab", { name: /^Jobs/ }).click();
  await expect(page.getByRole("tabpanel", { name: /^Jobs/ })).toBeVisible();
  await expect(page.locator(".job-row")).toHaveCount(2);
  await expect(
    page.locator(".job-row").filter({ hasText: "Fetch #42" }),
  ).toContainText("Succeeded");
  await expect(
    page.locator(".job-row").filter({ hasText: "Tree + Payment #18" }),
  ).toContainText("Unsupported");
  await expect(page.getByLabel("Fetch by index")).toHaveCount(0);
  await expect(
    page.getByText(
      "Full state, operator trust, tree consistency, and Payment coverage are separate.",
      { exact: false },
    ),
  ).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("tab", { name: /^Jobs/ })).toHaveAttribute(
    "aria-selected",
    "true",
  );
  await page
    .locator(".job-row")
    .filter({ hasText: "Tree + Payment #18" })
    .click();
  await expect(page.locator("#history-result:popover-open")).toContainText(
    "Unsupported",
  );
  await page.getByRole("button", { name: "Close verification result" }).click();
  await page
    .locator(".job-row")
    .filter({ hasText: "Tree + Payment #18" })
    .click();
  await expect(page.locator("#history-result:popover-open")).toBeVisible();
  await page.getByRole("button", { name: "Close verification result" }).click();
  await page.getByRole("tab", { name: "Ledgers", exact: true }).click();
  await expect(page.locator(".ledger-row")).toHaveCount(4);
});
test("running verification identifies only its current ledger and exact export fork", async ({
  page,
}) => {
  await setup(page);
  let finished = false;
  await page.route("**/api/bundles/main/jobs", (route) =>
    route.fulfill({
      json: [{ ...job, status: finished ? "succeeded" : "running", error: "" }],
    }),
  );
  await page.route("**/api/bundles/main/jobs/18", (route) =>
    route.fulfill({
      json: {
        job_id: "18",
        status: finished ? "succeeded" : "running",
        error: "",
        items: [
          {
            ledger_index: "201",
            export_id: "8",
            status: finished ? "succeeded" : "running",
            error: "",
          },
          { ledger_index: "204", export_id: "", status: "pending", error: "" },
        ],
        verifications: [
          {
            verification_id: "23",
            export_id: "8",
            kind: "merkle",
            status: finished ? "kernel_checked" : "running",
            report_json: "{}",
            artifacts_json: "[]",
            attempt_dir: "/tmp/running-attempt",
          },
        ],
      },
    }),
  );
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(row(page, "201").locator(".running-job")).toHaveText(
    "Tree #18 running",
  );
  await expect(row(page, "201", 1).locator(".running-job")).toHaveCount(0);
  await expect(row(page, "204").locator(".running-job")).toHaveCount(0);
  await row(page, "201").locator(".running-job").click();
  await expect(page.getByRole("tab", { name: /^Jobs/ })).toHaveAttribute(
    "aria-selected",
    "true",
  );
  await expect(page.locator("#history-result:popover-open")).toContainText(
    "Running",
  );
  await page.getByRole("button", { name: "Close verification result" }).click();
  await page.getByRole("tab", { name: "Ledgers", exact: true }).click();
  await expect(row(page, "201").locator(".running-job")).toBeVisible();
  finished = true;
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(row(page, "201").locator(".running-job")).toHaveCount(0);
});
test("a running fetch appears beside its pending ledger index", async ({
  page,
}) => {
  const { setNode } = await setup(page);
  setNode({ validated_ledger: { seq: 208, hash: D } });
  const current = { ...task, progress: { ...progress, ledger_index: 205 } };
  await page.route("**/api/bundles/main/tasks", (route) =>
    route.fulfill({ json: [current] }),
  );
  await page.route("**/api/bundles/main/tasks/42", (route) =>
    route.fulfill({ json: current }),
  );
  await page.route("**/api/bundles/main/tasks/42/stream", (route) =>
    route.fulfill({
      contentType: "application/x-ndjson",
      body:
        JSON.stringify({
          ...current.progress,
          task_id: "42",
          event: "progress",
          event_seq: 1,
        }) + "\n",
    }),
  );
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  const pending = page.locator(".pending-ledger");
  await expect(pending.locator(".next-index")).toHaveText("205");
  await expect(pending.locator(".running-job")).toHaveText("Fetch #42 running");
  await pending.locator(".running-job").click();
  await expect(page.locator("#task-result:popover-open")).toContainText(
    "Ledger 205",
  );
});
test("tree requires exact parent state while Payment only requires the current export", async ({
  page,
}) => {
  await setup(page);
  await connect(page);
  await expect(
    row(page, "201", 1).getByRole("button", {
      name: "Verify tree",
      exact: true,
    }),
  ).toBeVisible();
  // The parent hash matches, but witness paths are not a complete snapshot.
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({
      json: [ledger("200", A, { state: "witness" }), ledger("201", C)],
    }),
  );
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify tree", exact: true }),
  ).toHaveCount(0);
  await expect(
    row(page, "201").getByRole("button", {
      name: "Verify payment",
      exact: true,
    }),
  ).toBeEnabled();
  // A complete ledger at the preceding index must also have the exact parent hash.
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({ json: [ledger("200", D), ledger("201", C)] }),
  );
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(row(page, "200")).toBeVisible();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify tree", exact: true }),
  ).toHaveCount(0);
  await expect(
    row(page, "201").getByRole("button", {
      name: "Verify payment",
      exact: true,
    }),
  ).toBeEnabled();
  // With both states present the export is still required.
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({ json: [ledger("200", A), ledger("201", C)] }),
  );
  await page.route("**/api/bundles/main/exports", (route) =>
    route.fulfill({ json: [] }),
  );
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify tree", exact: true }),
  ).toHaveCount(0);
  await expect(
    row(page, "201").getByRole("button", {
      name: "Verify payment",
      exact: true,
    }),
  ).toHaveCount(0);
  await page.route("**/api/bundles/main/exports", (route) =>
    route.fulfill({ json: [variant("9", C)] }),
  );
  await page.getByRole("button", { name: "↻ Refresh" }).click();
  await expect(
    row(page, "201").getByRole("button", { name: "Verify tree", exact: true }),
  ).toBeEnabled();
  await expect(
    row(page, "201").getByRole("button", {
      name: "Verify payment",
      exact: true,
    }),
  ).toBeEnabled();
});
test("verification rechecks the parent snapshot after confirmation", async ({
  page,
}) => {
  const { calls } = await setup(page);
  await connect(page);
  await row(page, "201", 1)
    .getByRole("button", { name: "Verify tree", exact: true })
    .click();
  await page.route("**/api/bundles/main/ledgers", (route) =>
    route.fulfill({ json: [ledger("201", C)] }),
  );
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Confirm verify tree" })
    .click();
  await expect(page.getByRole("dialog").getByRole("alert")).toContainText(
    "exact previous ledger’s full state",
  );
  expect(calls.filter((call) => call.path.endsWith("/jobs"))).toHaveLength(0);
});

for (const status of ["running", "queued"]) {
  test(`${status} fetch can be cancelled from its details and retried from history`, async ({
    page,
  }) => {
    const { errors } = await setup(page);
    let current = { ...task, status, cancel_requested: false };
    let cancellations = 0;
    await page.route("**/api/bundles/main/tasks", (route) =>
      route.fulfill({ json: [current] }),
    );
    await page.route("**/api/bundles/main/tasks/42", (route) =>
      route.fulfill({ json: current }),
    );
    await page.route("**/api/bundles/main/tasks/42/stream", (route) =>
      route.fulfill({
        contentType: "application/x-ndjson",
        body:
          JSON.stringify({
            ...progress,
            event: "progress",
            task_id: "42",
            event_seq: 1,
          }) + "\n",
      }),
    );
    await page.route("**/api/bundles/main/tasks/42/cancel", async (route) => {
      expect(route.request().method()).toBe("POST");
      expect(route.request().postDataJSON()).toEqual({});
      cancellations++;
      current = { ...current, cancel_requested: true };
      await route.fulfill({ json: current });
    });
    await page.getByRole("button", { name: "↻ Refresh" }).click();
    await page.getByRole("tab", { name: /^Jobs/ }).click();
    await page.getByRole("button", { name: /^Fetch #42/ }).click();
    const details = page.locator("#task-result:popover-open");
    await expect(
      details.getByRole("button", { name: "Cancel task", exact: true }),
    ).toBeDisabled();
    await connect(page);
    // Connecting closes the popover; reopen the selected task.
    await page.getByRole("button", { name: /^Fetch #42/ }).click();
    await details
      .getByRole("button", { name: "Cancel task", exact: true })
      .click();
    await expect(
      details.getByRole("button", { name: "Cancelling…", exact: true }),
    ).toBeDisabled();
    expect(cancellations).toBe(1);
    current = {
      ...current,
      status: "cancelled",
      error: "acquisition cancelled; retry this task to resume",
    };
    await page.getByRole("button", { name: "↻ Refresh" }).click();
    await page.getByRole("button", { name: /^Fetch #42/ }).click();
    await expect(details).toContainText("Cancelled");
    await expect(
      details.getByRole("button", { name: "Cancel task", exact: true }),
    ).toHaveCount(0);
    await expect(
      details.getByRole("button", { name: "Retry fetch", exact: true }),
    ).toBeEnabled();
    expect(errors).toEqual([]);
  });
}

for (const check of ["merkle", "payments"]) {
  test(`Jobs tab exposes cancellation for a running ${check} verification`, async ({
    page,
  }) => {
    const { errors } = await setup(page);
    let current = {
      ...job,
      checks: JSON.stringify([check]),
      status: "running",
      error: "",
      cancel_requested: false,
    };
    const detail = () => ({
      job_id: "18",
      status: current.status,
      error: current.error,
      cancel_requested: current.cancel_requested,
      items: [],
      verifications: [],
    });
    await page.route("**/api/bundles/main/jobs", (route) =>
      route.fulfill({ json: [current] }),
    );
    await page.route("**/api/bundles/main/jobs/18", (route) =>
      route.fulfill({ json: detail() }),
    );
    let cancellations = 0;
    await page.route("**/api/bundles/main/jobs/18/cancel", async (route) => {
      expect(route.request().method()).toBe("POST");
      expect(route.request().postDataJSON()).toEqual({});
      cancellations++;
      current = { ...current, cancel_requested: true };
      await route.fulfill({ json: detail() });
    });
    await page.getByRole("button", { name: "↻ Refresh" }).click();
    await page.getByRole("tab", { name: /^Jobs/ }).click();
    const title = check === "merkle" ? "Tree" : "Payment";
    const cancel = page.getByRole("button", {
      name: `Cancel ${title} #18`,
      exact: true,
    });
    await expect(cancel).toBeVisible();
    await expect(cancel).toBeDisabled();
    await connect(page);
    await cancel.click();
    await expect(cancel).toHaveText("Cancelling…");
    await expect(cancel).toBeDisabled();
    expect(cancellations).toBe(1);
    current = {
      ...current,
      status: "cancelled",
      error: "verification cancelled",
    };
    await page.getByRole("button", { name: "↻ Refresh" }).click();
    await expect(cancel).toHaveCount(0);
    await page
      .getByRole("button", { name: new RegExp(`${title} #18`) })
      .click();
    await expect(page.locator("#history-result:popover-open")).toContainText(
      "Cancelled",
    );
    await expect(
      page.getByRole("button", { name: "Cancel job", exact: true }),
    ).toHaveCount(0);
    expect(errors).toEqual([]);
  });
}
