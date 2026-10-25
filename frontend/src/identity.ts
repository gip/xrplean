import { createContext, useContext } from "react";
export interface Identity {
  connected: boolean;
  address?: string;
  provider?: string;
  network?: string;
  connecting: boolean;
  error?: string;
  connect: () => void;
  disconnect: () => void;
}
export const IdentityContext = createContext<Identity>({
  connected: false,
  connecting: false,
  connect: () => {},
  disconnect: () => {},
});
export const useIdentity = () => useContext(IdentityContext);
