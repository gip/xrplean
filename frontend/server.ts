import http from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadEnv, type ViteDevServer } from "vite";

const root = dirname(fileURLToPath(import.meta.url));
const MAX_BODY = 64 * 1024 * 1024;
export function upstreamURL(value: string) {
  const url = new URL(value);
  if (
    url.protocol !== "http:" ||
    !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) ||
    url.username ||
    url.password ||
    url.pathname !== "/" ||
    url.search ||
    url.hash
  )
    throw new Error(
      "Backend must be an HTTP loopback origin without credentials, path or query",
    );
  return url;
}
export function allowedRoute(method: string, path: string) {
  if (
    method === "GET" &&
    (/^\/batches(?:\/policy|\/[1-9]\d*)?$/.test(path) ||
      /^\/batches\/[1-9]\d*\/artifacts\/(?:request\.json|transaction\.json|unsigned\.hex|policy\.json|Certificate\.lean|BatchPolicy\.lean|lean-toolchain|kernel\.log(?:\.stderr)?|binding\.json|report\.json|manifest\.json)$/.test(
        path,
      ))
  )
    return true;
  if (method === "POST" && path === "/batches/prepare") return true;
  if (method === "GET" && /^\/(health|status|bundles)$/.test(path)) return true;
  const route = path.replace(/^\/bundles\/[A-Za-z0-9_-]{1,64}(?=\/)/, "");
  return method === "GET"
    ? /^\/proofs\/(merkle|payments)$/.test(route) ||
        /^\/jobs\/[1-9]\d*\/verifications\/[1-9]\d*\/proof(?:\/(?:generated|definition)_[A-Za-z0-9_]+\/\d+)?$/.test(
          route,
        ) ||
        /^\/(ledgers|exports|tasks|jobs|state\/info)$/.test(route) ||
        /^\/(tasks|jobs)\/[1-9]\d*$/.test(route)
    : method === "POST" &&
        (/^\/(tasks|jobs|trust)$/.test(route) ||
          /^\/tasks\/[1-9]\d*\/(stream|retry|cancel)$/.test(route) ||
          /^\/jobs\/[1-9]\d*\/cancel$/.test(route));
}
export async function createUiServer(options: {
  backend: string;
  dev?: boolean;
  port?: number;
  dist?: string;
  speculos?: string;
}) {
  if (options.speculos && !options.dev)
    throw new Error(
      "Speculos requires --dev; production never exposes the emulator bridge",
    );
  const bridge = options.speculos
    ? await import("./dev/speculos-bridge.ts").then(
        ({ createSpeculosBridge, speculosOrigin }) =>
          createSpeculosBridge(speculosOrigin(options.speculos!)),
      )
    : undefined;
  const upstream = upstreamURL(options.backend);
  let vite: ViteDevServer | undefined;
  const dist = options.dist ?? resolve(root, "dist");
  const server = http.createServer(async (req, res) => {
    const port = (server.address() as import("node:net").AddressInfo).port;
    const hosts = new Set([`localhost:${port}`, `127.0.0.1:${port}`]);
    const fail = (code: number, error: string) => {
      if (!res.headersSent) {
        res.writeHead(code, {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
        });
        res.end(JSON.stringify({ error }));
      } else res.destroy();
    };
    if (
      !hosts.has(req.headers.host ?? "") ||
      (req.headers.origin &&
        req.headers.origin !== `http://${req.headers.host}`) ||
      (req.headers["sec-fetch-site"] === "cross-site" &&
        !(
          req.method === "GET" &&
          req.headers["sec-fetch-mode"] === "navigate" &&
          !req.url?.startsWith("/api") &&
          !req.url?.startsWith("/dev/speculos")
        ))
    ) {
      fail(403, "Local same-origin requests only");
      return;
    }
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("Cross-Origin-Opener-Policy", "same-origin-allow-popups");
    res.setHeader(
      "Content-Security-Policy",
      "frame-ancestors 'none'; object-src 'none'; base-uri 'self'",
    );
    try {
      const raw = req.url ?? "/";
      if (raw.startsWith("/dev/speculos")) {
        if (!bridge) {
          fail(404, "Speculos is not enabled");
          return;
        }
        if (raw === "/dev/speculos" && req.method === "GET") {
          res.writeHead(200, {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
          });
          res.end(JSON.stringify(bridge.info()));
          return;
        }
        if (raw !== "/dev/speculos/apdu" || req.method !== "POST") {
          fail(404, "Unsupported Speculos route");
          return;
        }
        if (
          !String(req.headers["content-type"])
            .toLowerCase()
            .startsWith("application/json")
        ) {
          fail(415, "application/json required");
          return;
        }
        const chunks: Buffer[] = [];
        let size = 0;
        req.setTimeout(5000, () => req.destroy());
        for await (const chunk of req) {
          size += chunk.length;
          if (size > 1024) {
            fail(413, "Speculos request exceeds 1 KiB");
            return;
          }
          chunks.push(Buffer.from(chunk));
        }
        let body: unknown;
        try {
          body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        } catch {
          fail(400, "Invalid JSON");
          return;
        }
        const controller = new AbortController();
        res.on("close", () => controller.abort());
        try {
          const result = await bridge.exchange(body, controller.signal);
          res.writeHead(200, {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
          });
          res.end(JSON.stringify(result));
        } catch (error) {
          const { SpeculosBridgeError } =
            await import("./dev/speculos-bridge.ts");
          fail(
            error instanceof SpeculosBridgeError ? error.status : 502,
            error instanceof Error ? error.message : "Speculos unavailable",
          );
        }
      } else if (raw.startsWith("/api")) {
        const path = raw.slice(4);
        if (!allowedRoute(req.method ?? "", path)) {
          fail(404, "Unsupported API route");
          return;
        }
        let size = 0;
        const chunks: Buffer[] = [];
        req.setTimeout(30000, () => req.destroy());
        for await (const chunk of req) {
          size += chunk.length;
          if (size > MAX_BODY) {
            fail(413, "Body exceeds 64 MiB");
            return;
          }
          chunks.push(Buffer.from(chunk));
        }
        const body = Buffer.concat(chunks);
        if (req.method === "POST") {
          if (
            !String(req.headers["content-type"])
              .toLowerCase()
              .startsWith("application/json")
          ) {
            fail(415, "application/json required");
            return;
          }
          try {
            JSON.parse(body.toString("utf8"));
          } catch {
            fail(400, "Invalid JSON");
            return;
          }
        } else if (body.length) {
          fail(400, "GET bodies are unsupported");
          return;
        }
        const outgoing = http.request(
          new URL(path, upstream),
          {
            method: req.method,
            headers: {
              "Content-Type": "application/json",
              "Content-Length": body.length,
              Connection: "close",
            },
          },
          (incoming) => {
            res.writeHead(incoming.statusCode ?? 502, {
              "Content-Type":
                incoming.headers["content-type"] ?? "application/json",
              "Cache-Control": "no-store",
            });
            res.flushHeaders();
            incoming.on("error", () => res.destroy());
            incoming.pipe(res);
          },
        );
        let timedOut = false;
        // Observe streams without a timeout; disconnect only detaches the observer.
        if (!path.endsWith("/stream"))
          outgoing.setTimeout(10000, () => {
            timedOut = true;
            outgoing.destroy(new Error("Backend request timed out"));
          });
        outgoing.on("error", (error: NodeJS.ErrnoException) => {
          const message = timedOut
            ? "XLB did not respond within 10 seconds; it may still be running and busy."
            : error.code === "ECONNREFUSED"
              ? "Cannot connect to XLB; check ./xl status and start it with ./xl start if stopped."
              : "Connection to XLB was interrupted; check ./xl status.";
          fail(
            timedOut ? 504 : 502,
            message +
              (req.method === "POST"
                ? " A submitted operation may already be durable; inspect task/job history before submitting again."
                : " Inventory will refresh automatically."),
          );
        });
        res.on("close", () => outgoing.destroy());
        outgoing.end(body);
      } else if (vite) {
        vite.middlewares(req, res, () => fail(404, "Not found"));
      } else {
        if (req.method !== "GET" && req.method !== "HEAD") {
          fail(405, "GET required");
          return;
        }
        const pathname = new URL(raw, "http://localhost").pathname;
        const file =
          pathname === "/"
            ? resolve(dist, "index.html")
            : resolve(dist, "." + decodeURIComponent(pathname));
        if (!file.startsWith(dist + sep)) {
          fail(404, "Not found");
          return;
        }
        const info = await stat(file).catch(() => undefined);
        if (!info?.isFile()) {
          fail(404, "Build the frontend with pnpm --dir frontend run build");
          return;
        }
        const mime: Record<string, string> = {
          ".html": "text/html; charset=utf-8",
          ".js": "text/javascript; charset=utf-8",
          ".css": "text/css; charset=utf-8",
          ".svg": "image/svg+xml",
          ".woff2": "font/woff2",
        };
        res.writeHead(200, {
          "Content-Type": mime[extname(file)] ?? "application/octet-stream",
          "Cache-Control": "no-cache",
          "Content-Length": info.size,
        });
        if (req.method === "HEAD") res.end();
        else
          createReadStream(file)
            .on("error", () => res.destroy())
            .pipe(res);
      }
    } catch {
      fail(500, "UI request failed");
    }
  });
  if (options.dev)
    vite = await (
      await import("vite")
    ).createServer({
      root,
      cacheDir: resolve(
        root,
        "node_modules/.vite",
        String(options.port ?? 4173),
        options.speculos ? "speculos" : "standard",
      ),
      define: { __XL_SPECULOS__: JSON.stringify(!!options.speculos) },
      server: {
        middlewareMode: true,
        host: "127.0.0.1",
        hmr: { server },
        fs: { strict: true, allow: [root] },
      },
      appType: "spa",
    });
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  await new Promise<void>((done, reject) => {
    server.once("error", reject);
    server.listen(options.port ?? 4173, "127.0.0.1", done);
  });
  return {
    server,
    close: async () => {
      await vite?.close();
      server.closeAllConnections();
      await new Promise<void>((done, reject) =>
        server.close((e) => (e ? reject(e) : done())),
      );
    },
  };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  const args = process.argv.slice(2),
    env = loadEnv("", root, "");
  let backend =
      process.env.XL_UI_BACKEND ?? env.XL_UI_BACKEND ?? "http://127.0.0.1:4001",
    port = 4173,
    dev = false,
    speculos: string | undefined;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--help") {
      console.log(
        "./xl ui [--port 4173] [--backend http://127.0.0.1:4001] [--dev [--speculos http://127.0.0.1:5000]]",
      );
      process.exit(0);
    } else if (args[i] === "--dev") dev = true;
    else if (args[i] === "--speculos" && args[i + 1]) speculos = args[++i];
    else if (args[i] === "--backend" && args[i + 1]) backend = args[++i];
    else if (args[i] === "--port" && /^\d+$/.test(args[i + 1] ?? ""))
      port = Number(args[++i]);
    else throw new Error(`Unknown or incomplete option: ${args[i]}`);
  }
  if (port < 1 || port > 65535) throw new Error("Port must be 1–65535");
  const ui = await createUiServer({ backend, port, dev, speculos });
  console.log(`XL workspace: http://localhost:${port} · XLB: ${backend}`);
  for (const signal of ["SIGINT", "SIGTERM"] as const)
    process.once(signal, () => {
      void ui.close().then(() => process.exit(0));
    });
}
