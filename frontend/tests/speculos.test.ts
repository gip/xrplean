import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { once } from "node:events";
import { readFile, readdir } from "node:fs/promises";
import {
  createSpeculosBridge,
  speculosOrigin,
  XRP_ADDRESS_APDU,
  XRP_VERSION_APDU,
  SpeculosBridgeError,
} from "../dev/speculos-bridge.ts";
import { createUiServer } from "../server.ts";

test("Speculos endpoint accepts only a numeric HTTP loopback origin", () => {
  for (const value of [
    "http://example.com",
    "http://localhost:5000",
    "https://127.0.0.1:5000",
    "http://user:pass@127.0.0.1:5000",
    "http://127.0.0.1:5000/path",
    "http://127.0.0.1:5000/?url=evil",
  ])
    assert.throws(() => speculosOrigin(value));
  assert.equal(speculosOrigin("http://127.0.0.1:5000").port, "5000");
});
test("bridge limits APDUs, response size, timeouts and concurrent identity reads", async () => {
  let body: unknown,
    mode = "ok",
    count = 0;
  let release: (() => void) | undefined;
  const emulator = http
    .createServer(async (req, res) => {
      count++;
      assert.equal(req.url, "/apdu");
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(chunk);
      body = JSON.parse(Buffer.concat(chunks).toString());
      if (mode === "paused")
        await new Promise<void>((done) => {
          release = done;
        });
      if (mode === "timeout") {
        res.writeHead(200);
        res.write("{");
        return;
      }
      if (mode === "large") {
        res.end(JSON.stringify({ data: "aa".repeat(3000) }));
        return;
      }
      if (mode === "redirect") {
        res.writeHead(302, { Location: "http://example.com" });
        res.end();
        return;
      }
      res.setHeader("Content-Type", "application/json");
      res.end(mode === "malformed" ? "{bad" : '{"data":"000208029000"}');
    })
    .listen(0, "127.0.0.1");
  await once(emulator, "listening");
  const origin = speculosOrigin(
    `http://127.0.0.1:${(emulator.address() as import("node:net").AddressInfo).port}`,
  );
  const bridge = createSpeculosBridge(origin, 150);
  try {
    assert.deepEqual(await bridge.exchange({ data: XRP_VERSION_APDU }), {
      data: "000208029000",
    });
    assert.deepEqual(body, { data: XRP_VERSION_APDU });
    const before = count;
    for (const data of [
      "e004000000",
      "e002014015058000002c80000090800000000000000000000000",
      "e002004015058000002c80000000800000000000000000000000",
      "00",
    ])
      await assert.rejects(
        bridge.exchange({ data }),
        (e) => e instanceof SpeculosBridgeError && e.status === 400,
      );
    await assert.rejects(
      bridge.exchange({ data: XRP_VERSION_APDU, target: "http://evil" }),
    );
    assert.equal(count, before);
    mode = "paused";
    const pending = bridge.exchange({ data: XRP_ADDRESS_APDU });
    while (!release) await new Promise((done) => setTimeout(done, 1));
    await assert.rejects(
      bridge.exchange({ data: XRP_VERSION_APDU }),
      (e) => e instanceof SpeculosBridgeError && e.status === 409,
    );
    mode = "ok";
    release();
    await pending;
    for (const failure of ["malformed", "large", "redirect", "timeout"]) {
      mode = failure;
      await assert.rejects(
        bridge.exchange({ data: XRP_VERSION_APDU }),
        (e) => e instanceof SpeculosBridgeError && e.status === 502,
      );
    }
    mode = "ok";
    await bridge.exchange({ data: XRP_VERSION_APDU });
  } finally {
    emulator.closeAllConnections();
    await new Promise<void>((done) => emulator.close(() => done()));
  }
});
test("production rejects Speculos even if explicitly configured; routes are absent by default", async () => {
  await assert.rejects(
    createUiServer({
      backend: "http://127.0.0.1:4001",
      speculos: "http://127.0.0.1:5000",
      port: 0,
    }),
    /requires --dev/,
  );
  const ui = await createUiServer({
    backend: "http://127.0.0.1:4001",
    port: 0,
  });
  const origin = `http://127.0.0.1:${(ui.server.address() as import("node:net").AddressInfo).port}`;
  try {
    assert.equal((await fetch(origin + "/dev/speculos")).status, 404);
    assert.equal(
      (
        await fetch(origin + "/dev/speculos/apdu", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ data: XRP_VERSION_APDU }),
        })
      ).status,
      404,
    );
  } finally {
    await ui.close();
  }
});
test("production assets exclude the Speculos adapter and emulator endpoints", async () => {
  const directory = new URL("../dist/assets/", import.meta.url);
  const names = (await readdir(directory)).filter((n) => n.endsWith(".js"));
  for (const name of names) {
    const source = await readFile(new URL(name, directory), "utf8");
    assert.doesNotMatch(
      source,
      /SpeculosTransport|\/dev\/speculos|Ledger \(Speculos/,
    );
  }
});

test("opted-in development bridge retains local origin and payload restrictions", async () => {
  let count = 0;
  const emulator = http
    .createServer(async (req, res) => {
      for await (const _ of req) {
        /* drain */
      }
      count++;
      res.setHeader("Content-Type", "application/json");
      res.end('{"data":"000208029000"}');
    })
    .listen(0, "127.0.0.1");
  await once(emulator, "listening");
  const endpoint = `http://127.0.0.1:${(emulator.address() as import("node:net").AddressInfo).port}`;
  const ui = await createUiServer({
    backend: "http://127.0.0.1:4001",
    dev: true,
    speculos: endpoint,
    port: 0,
  });
  const origin = `http://127.0.0.1:${(ui.server.address() as import("node:net").AddressInfo).port}`;
  const post = (body: unknown, headers: Record<string, string> = {}) =>
    fetch(origin + "/dev/speculos/apdu", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
    });
  try {
    assert.equal(
      (await (await fetch(origin + "/dev/speculos")).json()).enabled,
      true,
    );
    assert.equal((await post({ data: XRP_VERSION_APDU })).status, 200);
    assert.equal(count, 1);
    assert.equal((await post({ data: "e004000000" })).status, 400);
    assert.equal(
      (await post({ data: XRP_VERSION_APDU, target: endpoint })).status,
      400,
    );
    assert.equal(
      (
        await post(
          { data: XRP_VERSION_APDU },
          { Origin: "http://evil.example" },
        )
      ).status,
      403,
    );
    assert.equal(
      (
        await post(
          { data: XRP_VERSION_APDU },
          { "Sec-Fetch-Site": "cross-site" },
        )
      ).status,
      403,
    );
    assert.equal(
      (await fetch(origin + "/dev/speculos/screenshot")).status,
      404,
    );
    assert.equal(count, 1);
  } finally {
    await ui.close();
    emulator.closeAllConnections();
    await new Promise<void>((done) => emulator.close(() => done()));
  }
});
