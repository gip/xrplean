// Imported only by an explicitly enabled Vite development server; removed from production.
import Transport from "@ledgerhq/hw-transport";
import Xrp from "@ledgerhq/hw-app-xrp";
import { Buffer } from "buffer";
import { deriveAddress } from "ripple-keypairs";
import { z } from "zod";
import {
  resolveNetwork,
  WalletError,
  WalletErrorCode,
  type WalletAdapter,
  type AccountInfo,
  type ConnectOptions,
  type NetworkInfo,
} from "xrpl-connect";

// LedgerJS expects Buffer in browsers. This polyfill exists only in this dev chunk.
if (!globalThis.Buffer)
  Object.defineProperty(globalThis, "Buffer", {
    value: Buffer,
    configurable: true,
  });
const PATH = "44'/144'/0'/0/0";
const responseSchema = z.object({
  data: z.string().regex(/^(?:[a-fA-F0-9]{2}){2,256}$/),
});
export class SpeculosTransport extends Transport {
  private controller = new AbortController();
  override async exchange(apdu: Buffer): Promise<Buffer> {
    const response = await fetch("/dev/speculos/apdu", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ data: apdu.toString("hex") }),
      signal: AbortSignal.any([
        this.controller.signal,
        AbortSignal.timeout(5000),
      ]),
    });
    if (!response.ok)
      throw new Error(
        `Speculos bridge HTTP ${response.status}. Check that the XRP app is running.`,
      );
    return Buffer.from(responseSchema.parse(await response.json()).data, "hex");
  }
  override async close() {
    this.controller.abort();
  }
}
export class SpeculosAdapter implements WalletAdapter {
  readonly id = "speculos";
  readonly name = "Ledger (Speculos · development)";
  readonly url = "https://speculos.ledger.com/";
  readonly capabilities = {
    sign: false,
    signAndSubmit: false,
    signMessage: false,
  };
  private account: AccountInfo | null = null;
  private transport: SpeculosTransport | null = null;
  private generation = 0;
  private listeners = new Map<string, Set<(data: unknown) => void>>();
  // Opt into the manager's saved-account comparison on reconnect. The only
  // supported path is fixed, so there are no caller-supplied options to restore.
  serializeReconnectOptions() {
    return {};
  }
  async isAvailable() {
    try {
      const r = await fetch("/dev/speculos", {
        signal: AbortSignal.timeout(800),
      });
      return r.ok && (await r.json()).enabled === true;
    } catch {
      return false;
    }
  }
  async connect(options?: ConnectOptions): Promise<AccountInfo> {
    const generation = ++this.generation;
    const previous = this.transport;
    this.transport = null;
    this.account = null;
    await previous?.close();
    if (generation !== this.generation)
      throw new WalletError(
        WalletErrorCode.CONNECTION_FAILED,
        "Speculos connection cancelled",
      );
    const transport = new SpeculosTransport();
    this.transport = transport;
    try {
      const app = new Xrp(transport);
      const { version } = await app.getAppConfiguration();
      if (!/^\d+\.\d+\.\d+$/.test(version))
        throw new Error("Invalid XRP app version");
      const account = await this.readAccount(
        app,
        resolveNetwork(options?.network),
      );
      if (generation !== this.generation)
        throw new Error("Speculos connection cancelled");
      this.account = account;
      return { ...account };
    } catch (error) {
      await transport.close();
      if (this.transport === transport) {
        this.transport = null;
        this.account = null;
      }
      throw new WalletError(
        WalletErrorCode.CONNECTION_FAILED,
        error instanceof Error ? error.message : String(error),
      );
    }
  }
  private async readAccount(
    app: Xrp,
    network: NetworkInfo,
  ): Promise<AccountInfo> {
    const result = await app.getAddress(PATH, false, false);
    const publicKey = result.publicKey.toUpperCase();
    if (
      !/^(02|03)[A-F0-9]{64}$/.test(publicKey) ||
      deriveAddress(publicKey) !== result.address
    )
      throw new Error("XRP address does not match the emulator public key");
    return { address: result.address, publicKey, network };
  }
  async disconnect() {
    this.generation++;
    const transport = this.transport;
    this.transport = null;
    this.account = null;
    await transport?.close();
  }
  async getAccount() {
    return this.account ? { ...this.account } : null;
  }
  async getNetwork() {
    if (!this.account)
      throw new WalletError(
        WalletErrorCode.NOT_CONNECTED,
        "Connect Speculos first",
      );
    return this.account.network;
  }
  async fetchAccount() {
    if (!this.account || !this.transport) return null;
    const generation = this.generation,
      transport = this.transport,
      previous = this.account;
    try {
      const next = await this.readAccount(new Xrp(transport), previous.network);
      if (generation !== this.generation)
        throw new Error("Speculos connection cancelled");
      this.account = next;
      if (next.address !== previous.address) this.emit("accountChanged", next);
      return { ...next };
    } catch (error) {
      if (generation === this.generation) {
        await this.disconnect();
        this.emit("disconnect", undefined);
      }
      throw new WalletError(
        WalletErrorCode.CONNECTION_FAILED,
        error instanceof Error ? error.message : String(error),
      );
    }
  }
  private unsupported(): never {
    throw new WalletError(
      WalletErrorCode.UNSUPPORTED_METHOD,
      "Speculos development identity adapter does not sign or submit transactions",
    );
  }
  async sign(): Promise<never> {
    return this.unsupported();
  }
  async signAndSubmit(): Promise<never> {
    return this.unsupported();
  }
  async signMessage(): Promise<never> {
    return this.unsupported();
  }
  on(event: string, callback: (data: unknown) => void) {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(callback);
  }
  off(event: string, callback: (data: unknown) => void) {
    this.listeners.get(event)?.delete(callback);
  }
  private emit(event: string, data: unknown) {
    for (const callback of this.listeners.get(event) ?? []) callback(data);
  }
}
