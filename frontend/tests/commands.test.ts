import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCommand, requestFor, validateCommand } from "../src/commands.ts";
import {
  jobDetailSchema,
  eventSchema,
  statusSchema,
  type Export,
} from "../src/contracts.ts";
const hash = "A".repeat(64),
  digest = "B".repeat(64);
const variant = (id: string): Export => ({
  export_id: id,
  ledger_index: "200",
  ledger_hash: hash,
  payload_sha256: digest,
  received_at: "",
  merkle: "not_checked",
  payments: "not_checked",
});

test("forms and command bar produce the same pinned API request", () => {
  const form = validateCommand({
    kind: "fetch",
    bundle: "main",
    selector: "200:202",
    state: true,
    transport: "peer",
  });
  const command = parseCommand(
    "xl ledger get --bundle main --index 200:202 --state --transport peer",
    "default",
  );
  assert.deepEqual(requestFor(form), requestFor(command));
  assert.deepEqual(requestFor(command), {
    method: "POST",
    path: "/bundles/main/tasks",
    body: {
      kind: "fetch",
      request: { from: 200, to: 202, state: true, transport: "peer" },
    },
  });
});
test("latest stays unresolved until XLB executes it; updates keep their selector", () => {
  assert.deepEqual(
    requestFor(parseCommand("ledger get --index latest", "main")).body,
    {
      kind: "fetch",
      request: { from: "latest", state: false, transport: "auto" },
    },
  );
  assert.deepEqual(
    requestFor(parseCommand("bundle update --index :220", "main")).body,
    { kind: "state_update", request: { index: ":220", transport: "auto" } },
  );
});
test("ambiguous exports require exact selection even when a hash matches", () => {
  const c = parseCommand(
    `ledger verify --index 200 --checks merkle --hash ${hash}`,
    "main",
  );
  assert.throws(
    () => requestFor(c, [variant("7"), variant("8")]),
    /Multiple export/,
  );
  const pinned = parseCommand(
    "ledger verify --index 200 --checks merkle,payments --export-id 8",
    "main",
  );
  assert.deepEqual(requestFor(pinned, [variant("7"), variant("8")]).body, {
    from: 200,
    to: 200,
    checks: ["merkle", "payments"],
    export_id: 8,
  });
  assert.throws(() => requestFor(pinned, [variant("7")]), /does not match/);
});
test("unsupported commands, malformed inputs, shell syntax and conflicts fail before HTTP", () => {
  for (const text of [
    "xl stop",
    "ledger get --index latest --backend http://evil",
    "ledger get --index 1;id",
    "ledger get --index 0",
    "ledger get --index 4:2",
    "ledger get --index 1:10001",
    "ledger get --index 1 --index 2",
    "ledger get --index 1 --unknown yes",
    "ledger verify --index 200 --checks consensus",
    `ledger verify --index 200 --checks merkle --hash ${hash} --export-id 7`,
    `ledger get --index 1:3 --hash ${hash}`,
  ])
    assert.throws(() => parseCommand(text, "main"), text);
});
test("trust reasons support quoted text and exact identity; inspections stay read-only", () => {
  const trust = parseCommand(
    `ledger trust --index 200 --hash ${hash} --reason "Independent checkpoint"`,
    "main",
  );
  assert.deepEqual(requestFor(trust).body, {
    ledger_index: 200,
    ledger_hash: hash,
    reason: "Independent checkpoint",
  });
  assert.equal(
    requestFor(parseCommand("task show --id 12", "main")).method,
    "GET",
  );
});

test("unmatched quotes and lossy export IDs fail before a request can be sent", () => {
  assert.throws(
    () =>
      parseCommand(
        `ledger trust --index 200 --hash ${hash} --reason "unclosed`,
        "main",
      ),
    /matching quotes/,
  );
  const c = parseCommand("ledger verify --index 200 --checks merkle", "main");
  assert.throws(
    () => requestFor(c, [variant("9007199254740993")]),
    /safe JSON integer/,
  );
});
test("wire decoding retains string IDs and parses proof reports without fabricating success", () => {
  const job = jobDetailSchema.parse({
    job_id: "1",
    status: "unsupported",
    error: "coverage",
    items: [],
    verifications: [
      {
        verification_id: "2",
        export_id: "7",
        kind: "payments",
        status: "unsupported",
        report_json: '{"payments_unsupported":1}',
        artifacts_json: "[]",
        attempt_dir: "/tmp/attempt",
      },
    ],
  });
  assert.deepEqual(job.verifications[0].report_json, {
    payments_unsupported: 1,
  });
  assert.equal(job.status, "unsupported");
  assert.throws(() =>
    jobDetailSchema.parse({
      ...job,
      verifications: [
        { ...job.verifications[0], report_json: "{bad", artifacts_json: "[]" },
      ],
    }),
  );
  assert.throws(() =>
    statusSchema.parse({
      service: "XLB",
      network_id: 0,
      xrpld: { reachable: "yes" },
    }),
  );
  assert.throws(() =>
    eventSchema.parse({ event: "result", task_id: "1", data: [] }),
  );
});

test("task cancellation maps to its scoped backend route", () => {
  assert.deepEqual(requestFor(parseCommand("task cancel --id 42", "main")), {
    method: "POST",
    path: "/bundles/main/tasks/42/cancel",
    body: {},
  });
  assert.throws(() => parseCommand("task cancel", "main"));
  assert.throws(() => parseCommand("task cancel --id 0", "main"));
});

test("verification cancellation maps to the job route", () => {
  assert.deepEqual(requestFor(parseCommand("job cancel --id 10", "main")), {
    method: "POST",
    path: "/bundles/main/jobs/10/cancel",
    body: {},
  });
  assert.throws(() => parseCommand("job cancel", "main"));
});
