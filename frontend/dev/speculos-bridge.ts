import { z } from "zod";

// Only the XRP app's silent default-account read and version request are exposed.
// Transaction signing, arbitrary derivation, seeds, and emulator controls are not proxied.
export const XRP_ADDRESS_APDU =
  "e002004015058000002c80000090800000000000000000000000";
export const XRP_VERSION_APDU = "e006000000";
const requestSchema = z
  .object({
    data: z
      .string()
      .transform((v) => v.toLowerCase())
      .refine(
        (v) => v === XRP_ADDRESS_APDU || v === XRP_VERSION_APDU,
        "Only XRP default-account identity reads are allowed",
      ),
  })
  .strict();
const responseSchema = z.object({
  data: z.string().regex(/^(?:[a-fA-F0-9]{2}){2,256}$/),
});
export class SpeculosBridgeError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}
export function speculosOrigin(value: string): URL {
  const url = new URL(value);
  if (
    url.protocol !== "http:" ||
    !["127.0.0.1", "[::1]"].includes(url.hostname) ||
    url.username ||
    url.password ||
    url.pathname !== "/" ||
    url.search ||
    url.hash
  )
    throw new Error(
      "Speculos must be a numeric HTTP loopback origin without credentials, path or query",
    );
  return url;
}
export function createSpeculosBridge(origin: URL, timeoutMs = 3000) {
  let busy = false;
  return {
    info: () => ({
      enabled: true,
      wallet: "speculos",
      label: "Ledger (Speculos · development)",
      emulator_url: origin.origin,
      derivation_path: "44'/144'/0'/0/0",
    }),
    exchange: async (raw: unknown, signal?: AbortSignal) => {
      const parsed = requestSchema.safeParse(raw);
      if (!parsed.success)
        throw new SpeculosBridgeError(
          400,
          "Only XRP app version and silent default-account address reads are allowed",
        );
      if (busy)
        throw new SpeculosBridgeError(
          409,
          "Speculos is busy; wait for the current identity read",
        );
      busy = true;
      try {
        const response = await fetch(new URL("/apdu", origin), {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(parsed.data),
          redirect: "error",
          signal: signal
            ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)])
            : AbortSignal.timeout(timeoutMs),
        });
        if (!response.ok)
          throw new SpeculosBridgeError(
            502,
            `Speculos returned HTTP ${response.status}`,
          );
        // Bound both the wait for headers and the response body, including stalled chunked replies.
        const reader = response.body?.getReader();
        if (!reader) throw new Error("Missing Speculos response");
        const chunks: Uint8Array[] = [];
        let size = 0;
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.length;
            if (size > 4096) throw new Error("Speculos response exceeds 4 KiB");
            chunks.push(value);
          }
        } finally {
          await reader.cancel().catch(() => {});
          reader.releaseLock();
        }
        const data = responseSchema.parse(
          JSON.parse(Buffer.concat(chunks).toString("utf8")),
        );
        return { data: data.data.toLowerCase() };
      } catch (e) {
        if (e instanceof SpeculosBridgeError) throw e;
        throw new SpeculosBridgeError(
          502,
          "Speculos identity read failed or timed out. Start the pinned XRP app and reconnect.",
        );
      } finally {
        busy = false;
      }
    },
  };
}
