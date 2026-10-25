import type { z } from "zod";
import { eventSchema } from "./contracts.ts";

// One stream and two short requests at most, below XLB's eight-request limit.
let inFlight = 0;
const waiting: (() => void)[] = [];
async function slot(signal?: AbortSignal) {
  if (signal?.aborted) throw new DOMException("Aborted", "AbortError");
  await new Promise<void>((resolve, reject) => {
    const enter = () => {
      signal?.removeEventListener("abort", abort);
      inFlight++;
      resolve();
    };
    const abort = () => {
      const i = waiting.indexOf(enter);
      if (i >= 0) waiting.splice(i, 1);
      reject(new DOMException("Aborted", "AbortError"));
    };
    if (inFlight < 3) enter();
    else {
      waiting.push(enter);
      signal?.addEventListener("abort", abort, { once: true });
    }
  });
  return () => {
    inFlight--;
    waiting.shift()?.();
  };
}
export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}
export async function api<T>(
  path: string,
  schema: z.ZodType<T>,
  signal?: AbortSignal,
  body?: unknown,
  beforeSend?: () => void,
): Promise<T> {
  const release = await slot(signal);
  try {
    beforeSend?.();
    const response = await fetch("/api" + path, {
      method: body === undefined ? "GET" : "POST",
      headers:
        body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: signal
        ? AbortSignal.any([signal, AbortSignal.timeout(12000)])
        : AbortSignal.timeout(12000),
    });
    const data: unknown = await response.json();
    if (!response.ok)
      throw new ApiError(
        response.status,
        typeof data === "object" && data && "error" in data
          ? String(data.error)
          : `HTTP ${response.status}`,
      );
    return schema.parse(data);
  } finally {
    release();
  }
}
export async function streamTask(
  bundle: string,
  id: string,
  after: number,
  signal: AbortSignal,
  onEvent: (event: z.infer<typeof eventSchema>) => void,
) {
  const release = await slot(signal);
  try {
    const response = await fetch(`/api/bundles/${bundle}/tasks/${id}/stream`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ after_seq: after }),
      signal,
    });
    if (!response.ok || !response.body)
      throw new ApiError(response.status, "Could not follow acquisition task");
    const reader = response.body.getReader(),
      decoder = new TextDecoder();
    let pending = "";
    try {
      while (true) {
        const { done, value } = await reader.read();
        pending += decoder.decode(value, { stream: !done });
        if (pending.length > 4 * 1024 * 1024)
          throw new Error("Progress event exceeds browser limit");
        const lines = pending.split("\n");
        pending = lines.pop()!;
        for (const line of lines) {
          if (!line.trim()) continue;
          const event = eventSchema.parse(JSON.parse(line));
          if (event.task_id !== id)
            throw new Error("Progress task identity mismatch");
          onEvent(event);
          if (event.event !== "progress") {
            await reader.cancel();
            return;
          }
        }
        if (done)
          throw new Error(
            "Progress stream disconnected; reconnecting to durable history",
          );
      }
    } finally {
      await reader.cancel().catch(() => {});
      reader.releaseLock();
    }
  } finally {
    release();
  }
}
