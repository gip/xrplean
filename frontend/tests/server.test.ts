import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { once } from "node:events";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { allowedRoute, upstreamURL, createUiServer } from "../server.ts";

test("proxy route and upstream policy cannot select arbitrary hosts or files", () => {
  for (const url of [
    "http://example.com",
    "https://localhost",
    "http://user:pass@localhost:4001",
    "http://localhost:4001/path",
    "http://localhost:4001/?x=1",
  ])
    assert.throws(() => upstreamURL(url));
  for (const path of [
    "/tasks/1/wait",
    "/fetch",
    "//evil",
    "/bundles/a/../../health",
    "/health?target=evil",
    "/bundles/%2e%2e/ledgers",
  ])
    assert.equal(allowedRoute("POST", path), false);
  assert.equal(allowedRoute("POST", "/bundles/main/tasks/1/stream"), true);
  assert.equal(allowedRoute("POST", "/bundles/main/tasks/1/cancel"), true);
  assert.equal(allowedRoute("GET", "/bundles/main/tasks/1/cancel"), false);
  assert.equal(allowedRoute("POST", "/bundles/main/jobs/1/cancel"), true);
  assert.equal(allowedRoute("GET", "/bundles/main/jobs/1/cancel"), false);
});
test("server enforces Host and Origin, forwards explicit lengths and streams without buffering", async () => {
  let seenLength: string | undefined,
    ended = false,
    mutations = 0;
  const backend = http
    .createServer(async (req, res) => {
      seenLength = req.headers["content-length"];
      const chunks = [];
      for await (const c of req) chunks.push(c);
      if (req.url?.endsWith("/stream")) {
        res.writeHead(200, { "Content-Type": "application/x-ndjson" });
        res.write('{"event":"progress"}\n');
        setTimeout(() => {
          ended = true;
          res.end('{"event":"result"}\n');
        }, 150);
      } else {
        if (req.method === "POST") mutations++;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ body: Buffer.concat(chunks).toString() }));
      }
    })
    .listen(0, "127.0.0.1");
  await once(backend, "listening");
  const dist = await mkdtemp(join(tmpdir(), "xl-ui-test-"));
  await writeFile(join(dist, "index.html"), "<h1>XL</h1>");
  const ui = await createUiServer({
    backend: `http://127.0.0.1:${(backend.address() as import("node:net").AddressInfo).port}`,
    port: 0,
    dist,
  });
  const origin = `http://127.0.0.1:${(ui.server.address() as import("node:net").AddressInfo).port}`;
  try {
    assert.equal((await fetch(origin)).status, 200);
    assert.equal((await fetch(origin + "/tests/harness.html")).status, 404);
    const navigate = (path: string) =>
      new Promise<number>((resolve) => {
        http.get(
          origin + path,
          {
            headers: {
              "Sec-Fetch-Site": "cross-site",
              "Sec-Fetch-Mode": "navigate",
            },
          },
          (r) => {
            r.resume();
            resolve(r.statusCode!);
          },
        );
      });
    assert.equal(await navigate("/?code=provider-return"), 200);
    assert.equal(await navigate("/api/health"), 403);
    const badHost = await new Promise<number>((resolve) => {
      http.get(origin, { headers: { Host: "evil.example" } }, (r) => {
        r.resume();
        resolve(r.statusCode!);
      });
    });
    assert.equal(badHost, 403);
    assert.equal(
      (
        await fetch(origin + "/api/health", {
          headers: { Origin: origin.replace("127.0.0.1", "localhost") },
        })
      ).status,
      403,
    );
    assert.equal(
      (
        await fetch(origin + "/api/tasks", {
          method: "POST",
          headers: {
            Origin: "https://evil.example",
            "Content-Type": "application/json",
          },
          body: "{}",
        })
      ).status,
      403,
    );
    assert.equal(
      (
        await fetch(origin + "/api/health", {
          headers: { "Sec-Fetch-Site": "cross-site" },
        })
      ).status,
      403,
    );
    assert.equal((await fetch(origin + "/api/health?target=evil")).status, 404);
    assert.equal(
      (
        await fetch(origin + "/api/tasks", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{bad",
        })
      ).status,
      400,
    );
    const payload = '{"kind":"fetch","request":{"from":200}}';
    const response = await fetch(origin + "/api/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: payload,
    });
    assert.equal(response.status, 200);
    assert.equal(seenLength, String(Buffer.byteLength(payload)));
    assert.equal(mutations, 1);
    const stream = await fetch(origin + "/api/tasks/1/stream", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const reader = stream.body!.getReader(),
      first = await reader.read();
    assert.match(new TextDecoder().decode(first.value), /progress/);
    assert.equal(ended, false);
    while (!(await reader.read()).done) {
      /* drain */
    }
    backend.closeAllConnections();
    await new Promise<void>((done) => backend.close(() => done()));
    const unavailable = await fetch(origin + "/api/health");
    assert.equal(unavailable.status, 502);
    assert.match((await unavailable.json()).error, /Cannot connect to XLB/);
  } finally {
    await ui.close();
    backend.closeAllConnections();
    backend.close();
    await rm(dist, { recursive: true });
  }
});

test("a busy backend reports a timeout and preserves mutation uncertainty without retrying", async () => {
  let submissions = 0;
  const backend = http
    .createServer((req, res) => {
      req.resume();
      if (req.method === "POST") submissions++;
      if (req.url === "/health") res.end('{"service":"XLB"}');
      // Other requests deliberately remain connected without a response.
    })
    .listen(0, "127.0.0.1");
  await once(backend, "listening");
  const ui = await createUiServer({
    backend: `http://127.0.0.1:${(backend.address() as import("node:net").AddressInfo).port}`,
    port: 0,
  });
  const origin = `http://127.0.0.1:${(ui.server.address() as import("node:net").AddressInfo).port}`;
  try {
    const pending = Promise.all([
      fetch(origin + "/api/exports"),
      fetch(origin + "/api/tasks", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      }),
    ]);
    assert.equal((await fetch(origin + "/api/health")).status, 200);
    const [inventory, mutation] = await pending;
    assert.equal(inventory.status, 504);
    assert.equal(mutation.status, 504);
    const readError = (await inventory.json()).error;
    assert.match(readError, /may still be running and busy/);
    assert.doesNotMatch(readError, /start it|submitted operation/);
    assert.match(
      (await mutation.json()).error,
      /already be durable; inspect task\/job history/,
    );
    assert.equal(submissions, 1);
  } finally {
    await ui.close();
    backend.closeAllConnections();
    await new Promise<void>((done) => backend.close(() => done()));
  }
});
