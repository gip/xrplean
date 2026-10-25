// Development-only browser fixture. Not imported by the production entry or build.
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { App } from "../src/App.tsx";
import { IdentityContext } from "../src/identity.ts";
import "../src/styles.css";
function Harness() {
  const [connected, setConnected] = useState(false);
  return (
    <IdentityContext.Provider
      value={{
        connected,
        address: connected
          ? new URLSearchParams(location.search).get("batchFixture") === "1"
            ? "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
            : "rTESTbrowserFixture"
          : undefined,
        provider: "Test fixture",
        network: "mainnet",
        connecting: false,
        connect: () => setConnected(true),
        disconnect: () => setConnected(false),
      }}
    >
      <App />
    </IdentityContext.Provider>
  );
}
createRoot(document.getElementById("root")!).render(<Harness />);
