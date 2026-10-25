import { useEffect, useState, type ReactNode } from "react";
import {
  LedgerAdapter,
  XamanAdapter,
  type WalletManagerOptions,
} from "xrpl-connect";
import {
  XrplConnectProvider,
  useWallet,
  useWalletModal,
  WalletConnector,
} from "@xrpl-commons/xrpl-connect-react";
import { IdentityContext } from "./identity.ts";

const apiKey = import.meta.env.VITE_XAMAN_API_KEY?.trim();
const networkSetting = import.meta.env.VITE_WALLET_NETWORK ?? "mainnet";
const network: "mainnet" | "testnet" | "devnet" =
  networkSetting === "testnet" || networkSetting === "devnet"
    ? networkSetting
    : "mainnet";
const baseConfig: WalletManagerOptions = {
  adapters: [
    new LedgerAdapter(),
    new XamanAdapter({
      apiKey,
      returnUrl: {
        web:
          import.meta.env.VITE_XAMAN_RETURN_URL || window.location.origin + "/",
      },
    }),
  ],
  network,
  autoConnect: true,
};
export async function walletConfiguration(): Promise<WalletManagerOptions> {
  const adapters = [...baseConfig.adapters];
  if (import.meta.env.DEV && __XL_SPECULOS__) {
    const { SpeculosAdapter } = await import("./SpeculosAdapter.ts");
    adapters.push(new SpeculosAdapter());
  }
  return { ...baseConfig, adapters };
}
function Identity({ children }: { children: ReactNode }) {
  const wallet = useWallet(),
    modal = useWalletModal();
  const [error, setError] = useState<string>();
  useEffect(() => {
    if (
      !import.meta.env.DEV ||
      !__XL_SPECULOS__ ||
      !wallet.connected ||
      wallet.manager.wallet?.id !== "speculos"
    )
      return;
    let busy = false;
    const timer = setInterval(() => {
      if (busy) return;
      busy = true;
      void wallet.manager
        .fetchAccount()
        .catch((e) => setError(String(e)))
        .finally(() => {
          busy = false;
        });
    }, 5000);
    return () => clearInterval(timer);
  }, [wallet.connected, wallet.manager]);
  return (
    <IdentityContext.Provider
      value={{
        connected: wallet.connected,
        address: wallet.account?.address,
        provider: wallet.manager.wallet?.name,
        network: wallet.network?.name ?? network,
        connecting: wallet.connecting,
        error: error ?? wallet.error?.message,
        connect: () => {
          setError(undefined);
          void modal.open().catch((e) => setError(String(e)));
        },
        disconnect: () => {
          void wallet.disconnect().catch((e) => setError(String(e)));
        },
      }}
    >
      {children}
      <WalletConnector
        className="wallet-modal-only"
        wallets={wallet.manager.wallets.map((adapter) => adapter.id)}
        showUnavailable
        theme="light"
        cssVars={{
          "--xc-font-family": '"Geist Variable", sans-serif',
          "--xc-primary-color": "#171717",
          "--xc-background-color": "#ffffff",
          "--xc-text-color": "#171717",
          "--xc-text-muted-color": "#888888",
          "--xc-background-secondary": "#fafafa",
          "--xc-background-tertiary": "#f5f5f5",
          "--xc-primary-button-background": "#171717",
          "--xc-primary-button-color": "#ffffff",
          "--xc-primary-button-hover-background": "#333333",
          "--xc-focus-color": "#999999",
          "--xc-danger-color": "#333333",
          "--xc-modal-border-radius": "10px",
        }}
        onError={(e) => setError(`${e.code}: ${e.message}`)}
      />
    </IdentityContext.Provider>
  );
}
export function Wallet({
  children,
  config,
}: {
  children: ReactNode;
  config: WalletManagerOptions;
}) {
  return (
    <XrplConnectProvider config={config}>
      <Identity>{children}</Identity>
    </XrplConnectProvider>
  );
}
