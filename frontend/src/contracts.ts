import { z } from "zod";

export const id = z.string().regex(/^\d+$/);
const nullableText = z.string().nullable();
export const healthSchema = z.object({
  service: z.literal("XLB"),
  network_id: z.number().int().nonnegative(),
  pid: z.number(),
  state_backend: z.string(),
});
export const statusSchema = z.object({
  service: z.literal("XLB"),
  network_id: z.number(),
  xrpld: z.object({
    reachable: z.boolean(),
    server_state: nullableText,
    build_version: nullableText,
    complete_ledgers: nullableText,
    validated_ledger: z
      .object({ seq: z.number().int(), hash: nullableText })
      .nullable(),
    network_id: z.number().nullable(),
    network_compatible: z.boolean().nullable(),
    latency_ms: z.number(),
    observed_at_unix: z.string().regex(/^\d+$/),
    error: nullableText,
  }),
});
export const bundleSchema = z.object({
  bundle: z.string(),
  network_id: z.number(),
  status: z.string(),
  path: z.string(),
  ledger_count: z.number(),
  snapshot_count: z.number(),
  ledger_intervals: z.array(z.object({ first: z.number(), last: z.number() })),
  has_gaps: z.boolean(),
  first_ledger: z.number().nullable(),
  last_ledger: z.number().nullable(),
  ledger_hash: nullableText,
  state_root: nullableText,
  pending: z.array(z.object({ ledger_index: id, ledger_hash: z.string() })),
});
export const ledgerSchema = z.object({
  ledger_index: id,
  ledger_hash: z.string(),
  parent_hash: z.string(),
  state_root: z.string(),
  trust: z.string(),
  export_variants: id,
  state: z.string(),
  header_json: z.string(),
  merkle: z.string(),
  payments: z.string(),
});
export const exportSchema = z.object({
  export_id: id,
  ledger_index: id,
  ledger_hash: z.string(),
  payload_sha256: z.string(),
  received_at: z.string(),
  merkle: z.string(),
  payments: z.string(),
});
export const progressSchema = z
  .object({
    ledger_index: z.number(),
    phase: z.string(),
    transport: z.string(),
    pages: z.number(),
    entries: z.number(),
    state_bytes: z.number(),
    elapsed_ms: z.number(),
    keyspace_permille: z.number(),
    nodes: z.number(),
    pending: z.number(),
    resumed: z.boolean(),
    incremental: z.boolean().default(false),
    base_ledger_hash: z.string().default(""),
    reused_subtrees: z.number().default(0),
    retry_attempt: z.number(),
    retry_delay_ms: z.number(),
    last_error: z.string(),
  })
  .passthrough();
export const taskSchema = z.object({
  task_id: id,
  bundle: z.string(),
  kind: z.string(),
  status: z.enum([
    "queued",
    "running",
    "succeeded",
    "failed",
    "interrupted",
    "cancelled",
  ]),
  progress: progressSchema.nullable(),
  error: z.string(),
  retry_of: id.nullable(),
  cancel_requested: z.boolean().default(false),
  created_at: z.string(),
  started_at: z.string(),
  finished_at: z.string(),
  updated_at: z.string(),
  request: z.unknown().optional(),
  resolved_request: z.unknown().optional(),
  result: z.unknown().optional(),
});
const encodedJson = z.string().transform((text, ctx): unknown => {
  try {
    return JSON.parse(text);
  } catch {
    ctx.addIssue({
      code: "custom",
      message: "Malformed JSON in backend report",
    });
    return z.NEVER;
  }
});
export const jobSchema = z.object({
  cancel_requested: z.boolean().default(false),
  job_id: id,
  from: id,
  to: id,
  checks: encodedJson.pipe(z.array(z.enum(["merkle", "payments"]))),
  status: z.string(),
  error: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
});
export const jobDetailSchema = z.object({
  cancel_requested: z.boolean().default(false),
  job_id: id,
  status: z.string(),
  error: z.string(),
  items: z.array(
    z.object({
      ledger_index: id,
      export_id: z.string(),
      status: z.string(),
      error: z.string(),
    }),
  ),
  verifications: z.array(
    z.object({
      verification_id: id,
      export_id: id,
      kind: z.string(),
      status: z.string(),
      report_json: encodedJson,
      artifacts_json: encodedJson,
      attempt_dir: z.string(),
    }),
  ),
});
export const eventSchema = z.discriminatedUnion("event", [
  progressSchema.extend({
    event: z.literal("progress"),
    task_id: id,
    event_seq: z.number().int().nonnegative(),
  }),
  z.object({
    event: z.literal("result"),
    task_id: id,
    event_seq: z.number().int().nonnegative(),
    data: z.unknown(),
  }),
  z.object({
    event: z.literal("error"),
    task_id: id,
    event_seq: z.number().int().nonnegative(),
    error: z.string(),
  }),
]);
export type Health = z.infer<typeof healthSchema>;
export type Status = z.infer<typeof statusSchema>;
export type Bundle = z.infer<typeof bundleSchema>;
export type Ledger = z.infer<typeof ledgerSchema>;
export type Export = z.infer<typeof exportSchema>;
export type Task = z.infer<typeof taskSchema>;
export type Job = z.infer<typeof jobSchema>;
export type JobDetail = z.infer<typeof jobDetailSchema>;
export type Progress = z.infer<typeof progressSchema>;
export const active = (status: string) =>
  status === "queued" || status === "running";
