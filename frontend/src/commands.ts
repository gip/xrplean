import { z } from "zod";
import type { Export } from "./contracts.ts";
const bundle = z
  .string()
  .regex(
    /^[A-Za-z0-9_-]{1,64}$/,
    "Bundle names use 1–64 ASCII letters, digits, underscores or hyphens",
  );
const index = z.number().int().min(1).max(4294967295);
const hash = z
  .string()
  .regex(/^[a-fA-F0-9]{64}$/, "Expected a 64-character hexadecimal hash")
  .transform((v) => v.toUpperCase());
const identifier = z.string().regex(/^[1-9]\d*$/, "Expected a positive ID");
const selector = z.string().min(1);
const transport = z.enum(["auto", "peer", "rpc"]);
export const commandSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("fetch"),
    bundle,
    selector,
    state: z.boolean(),
    transport,
    hash: hash.optional(),
  }),
  z.object({
    kind: z.enum(["state_new", "state_update"]),
    bundle,
    selector,
    transport,
    hash: hash.optional(),
  }),
  z.object({
    kind: z.literal("verify"),
    bundle,
    selector,
    checks: z.array(z.enum(["merkle", "payments"])).min(1),
    hash: hash.optional(),
    exportId: identifier.optional(),
  }),
  z.object({
    kind: z.literal("trust"),
    bundle,
    index,
    hash,
    reason: z.string().trim().min(1, "Enter a reason for the trust anchor"),
  }),
  z.object({
    kind: z.enum(["retry", "cancel", "cancel_job"]),
    bundle,
    id: identifier,
  }),
  z.object({
    kind: z.literal("inspect"),
    bundle,
    resource: z.enum([
      "health",
      "ledgers",
      "exports",
      "bundles",
      "tasks",
      "jobs",
    ]),
    id: identifier.optional(),
    index: index.optional(),
    hash: hash.optional(),
  }),
]);
export type Command = z.infer<typeof commandSchema>;
export function interval(
  value: string,
  latest = false,
  open = false,
): { from: number | "latest"; to?: number } {
  if (latest && value === "latest") return { from: "latest" };
  const parts = value.split(":");
  if (
    parts.length > 2 ||
    parts.some(
      (v, i) =>
        !/^\d+$/.test(v) &&
        !(open && i === 0 && v === "" && parts.length === 2),
    )
  )
    throw new Error("Use INDEX or START:END" + (latest ? ", or latest" : ""));
  const from = parts[0] === "" ? 1 : index.parse(Number(parts[0]));
  const to = index.parse(Number(parts[1] ?? parts[0]));
  if (to < from || (parts[0] !== "" && to - from >= 10000))
    throw new Error("Select an inclusive range of 1–10000 ledgers");
  return { from, to };
}
export function validateCommand(raw: unknown): Command {
  const c = commandSchema.parse(raw);
  if (
    c.kind === "fetch" ||
    c.kind === "verify" ||
    c.kind === "state_new" ||
    c.kind === "state_update"
  ) {
    const range = interval(
      c.selector,
      c.kind !== "verify",
      c.kind === "state_update",
    );
    if (c.hash && range.to !== undefined && range.from !== range.to)
      throw new Error("Hash selection requires a single ledger");
    if (
      c.kind === "verify" &&
      c.exportId &&
      (range.from !== range.to || c.hash)
    )
      throw new Error("Select an export ID or a hash for one ledger");
  }
  return c;
}
export function parseCommand(text: string, selectedBundle: string): Command {
  // Deliberately small tokenizer: quoted arguments, no expansion, pipes, or shell execution.
  if (/[;|`$<>\n\r]/.test(text))
    throw new Error("Shell operators and expansion are not supported");
  const matcher = /\s*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\s"']+))/y;
  const words: string[] = [];
  let position = 0;
  while (text.slice(position).trim()) {
    matcher.lastIndex = position;
    const match = matcher.exec(text);
    if (
      !match ||
      (text[matcher.lastIndex] && !/\s/.test(text[matcher.lastIndex]))
    )
      throw new Error("Use matching quotes around a complete argument");
    words.push(match[1] ?? match[2] ?? match[3]);
    position = matcher.lastIndex;
  }
  if (words[0] === "xl" || words[0] === "./xl") words.shift();
  const positional: string[] = [],
    options = new Map<string, string | boolean>();
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (!word.startsWith("-")) {
      positional.push(word);
      continue;
    }
    const key = word === "-b" ? "--bundle" : word === "-i" ? "--index" : word;
    if (options.has(key)) throw new Error(`Duplicate option: ${key}`);
    if (key === "--state") {
      options.set(key, true);
      continue;
    }
    const value = words[++i];
    if (!value || value.startsWith("-"))
      throw new Error(`Missing value for ${key}`);
    options.set(key, value);
  }
  const [noun, verb] = positional;
  if (positional.length !== (noun === "health" ? 1 : 2))
    throw new Error("Use a supported resource/action command");
  const take = (key: string, fallback?: string) => {
    const v = options.get(key);
    options.delete(key);
    return typeof v === "string" ? v : fallback;
  };
  const need = (key: string) => {
    const v = take(key);
    if (!v) throw new Error(`Missing ${key}`);
    return v;
  };
  const b = take("--bundle", selectedBundle)!;
  let command: unknown;
  if (noun === "ledger" && verb === "get") {
    const state = options.get("--state") === true;
    options.delete("--state");
    command = {
      kind: "fetch",
      bundle: b,
      selector: need("--index"),
      state,
      transport: take("--transport", "auto"),
      hash: take("--hash"),
    };
  } else if (noun === "bundle" && (verb === "new" || verb === "update")) {
    command = {
      kind: verb === "new" ? "state_new" : "state_update",
      bundle: b,
      selector: need("--index"),
      transport: take("--transport", "auto"),
      hash: take("--hash"),
    };
  } else if (noun === "ledger" && verb === "verify") {
    command = {
      kind: "verify",
      bundle: b,
      selector: need("--index"),
      checks: need("--checks").split(","),
      hash: take("--hash"),
      exportId: take("--export-id"),
    };
  } else if (noun === "ledger" && verb === "trust") {
    command = {
      kind: "trust",
      bundle: b,
      index: Number(need("--index")),
      hash: need("--hash"),
      reason: need("--reason"),
    };
  } else if (noun === "task" && (verb === "retry" || verb === "cancel")) {
    command = { kind: verb, bundle: b, id: need("--id") };
  } else if (noun === "job" && verb === "cancel") {
    command = { kind: "cancel_job", bundle: b, id: need("--id") };
  } else if (noun === "health" || ["show", "list"].includes(verb)) {
    const resources: Record<string, string> = {
      health: "health",
      ledger: "ledgers",
      export: "exports",
      bundle: "bundles",
      task: "tasks",
      job: "jobs",
    };
    if (!resources[noun]) throw new Error("Unsupported resource");
    const id = noun === "job" || noun === "task" ? take("--id") : undefined;
    const idx = noun === "ledger" ? take("--index") : undefined;
    command = {
      kind: "inspect",
      bundle: b,
      resource: resources[noun],
      id,
      index: idx ? Number(idx) : undefined,
      hash: noun === "ledger" ? take("--hash") : undefined,
    };
  } else
    throw new Error(
      "Supported commands: ledger get/show/verify/trust, bundle new/update/show, task show/retry/cancel, job show/cancel, export show, health",
    );
  if (options.size)
    throw new Error(`Unsupported option: ${[...options.keys()][0]}`);
  return validateCommand(command);
}
export function requestFor(command: Command, exports: Export[] = []) {
  const c = validateCommand(command),
    base = `/bundles/${c.bundle}`;
  const method = c.kind === "inspect" ? "GET" : "POST";
  let path: string, body: unknown;
  switch (c.kind) {
    case "fetch":
      path = `${base}/tasks`;
      body = {
        kind: "fetch",
        request: {
          ...interval(c.selector, true),
          state: c.state,
          transport: c.transport,
          ...(c.hash && { ledger_hash: c.hash }),
        },
      };
      break;
    case "state_new":
    case "state_update":
      path = `${base}/tasks`;
      body = {
        kind: c.kind,
        request: {
          index: c.selector,
          transport: c.transport,
          ...(c.hash && { ledger_hash: c.hash }),
        },
      };
      break;
    case "verify": {
      const range = interval(c.selector),
        candidates = exports.filter(
          (e) =>
            Number(e.ledger_index) >= Number(range.from) &&
            Number(e.ledger_index) <= Number(range.to) &&
            (!c.hash || e.ledger_hash.toUpperCase() === c.hash),
        );
      if (
        !c.exportId &&
        candidates.some(
          (e) =>
            candidates.filter((v) => v.ledger_index === e.ledger_index).length >
            1,
        )
      )
        throw new Error(
          "Multiple export variants: select one exact export ID and digest",
        );
      const selected = c.exportId
        ? exports.find(
            (e) =>
              e.export_id === c.exportId &&
              Number(e.ledger_index) === range.from,
          )
        : range.from === range.to
          ? candidates[0]
          : undefined;
      if (c.exportId && !selected)
        throw new Error("Export ID does not match the selected ledger");
      if (selected && !Number.isSafeInteger(Number(selected.export_id)))
        throw new Error("Export ID exceeds the safe JSON integer range");
      path = `${base}/jobs`;
      body = {
        ...range,
        checks: [...new Set(c.checks)],
        ...(selected
          ? { export_id: Number(selected.export_id) }
          : c.hash
            ? { ledger_hash: c.hash }
            : {}),
      };
      break;
    }
    case "trust":
      path = `${base}/trust`;
      body = { ledger_index: c.index, ledger_hash: c.hash, reason: c.reason };
      break;
    case "retry":
    case "cancel":
      path = `${base}/tasks/${c.id}/${c.kind}`;
      body = {};
      break;
    case "cancel_job":
      path = `${base}/jobs/${c.id}/cancel`;
      body = {};
      break;
    case "inspect":
      path =
        c.resource === "health" || c.resource === "bundles"
          ? `/${c.resource}`
          : `${base}/${c.resource}${c.id ? "/" + c.id : ""}`;
      break;
  }
  return { method, path, body };
}
