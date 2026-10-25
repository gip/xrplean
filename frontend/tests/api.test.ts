import { test } from "node:test";
import assert from "node:assert/strict";
import { z } from "zod";
import { api, streamTask } from "../src/api.ts";

test("a mutation waiting for an HTTP slot rechecks wallet identity before sending", async () => {
  const original = globalThis.fetch;
  let count = 0,
    connected = true;
  const release: (() => void)[] = [];
  globalThis.fetch = async () => {
    count++;
    await new Promise<void>((done) => release.push(done));
    return new Response('{"ok":true}', {
      headers: { "Content-Type": "application/json" },
    });
  };
  try {
    const schema = z.object({ ok: z.boolean() });
    const readers = [
      api("/health", schema),
      api("/health", schema),
      api("/health", schema),
    ];
    await new Promise((done) => setTimeout(done, 0));
    assert.equal(count, 3);
    const mutation = api("/tasks", schema, undefined, {}, () => {
      if (!connected) throw new Error("Wallet disconnected");
    });
    const rejected = assert.rejects(mutation, /Wallet disconnected/);
    connected = false;
    release.shift()!();
    await rejected;
    assert.equal(count, 3);
    for (const done of release) done();
    await Promise.all(readers);
  } finally {
    globalThis.fetch = original;
  }
});

test("a malformed progress stream cancels its underlying observer before reconnect", async () => {
  const original = globalThis.fetch;
  let cancelled = false;
  globalThis.fetch = async () =>
    new Response(
      new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode("{bad}\n"));
        },
        cancel() {
          cancelled = true;
        },
      }),
    );
  try {
    await assert.rejects(
      streamTask("main", "1", 0, new AbortController().signal, () => {}),
    );
    assert.equal(cancelled, true);
  } finally {
    globalThis.fetch = original;
  }
});
