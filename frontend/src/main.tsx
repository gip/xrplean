import { createRoot } from "react-dom/client";
import { Wallet, walletConfiguration } from "./Wallet.tsx";
import { App } from "./App.tsx";
import "./styles.css";
const root = createRoot(document.getElementById("root")!);
void walletConfiguration()
  .then((config) =>
    root.render(
      <Wallet config={config}>
        <App />
      </Wallet>,
    ),
  )
  .catch((error) =>
    root.render(
      <p role="alert">Wallet configuration failed: {String(error)}</p>,
    ),
  );
