import { useEffect, useRef, useState } from "react";
import type { z } from "zod";
import { api } from "./api.ts";
export function refresh() {
  window.dispatchEvent(new Event("xl-refresh"));
}
export function usePoll<T>(
  path: string | null,
  schema: z.ZodType<T>,
  milliseconds = 5000,
  activeOnly = false,
) {
  const schemaRef = useRef(schema);
  schemaRef.current = schema;
  const [state, setState] = useState<{
    data?: T;
    updated?: number;
    error?: string;
  }>({});
  useEffect(() => {
    setState({});
    if (!path) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>,
      busy = false,
      terminal = false;
    async function read() {
      if (busy || controller.signal.aborted) return;
      busy = true;
      clearTimeout(timer);
      try {
        const data = await api(path!, schemaRef.current, controller.signal);
        terminal =
          activeOnly &&
          typeof data === "object" &&
          data !== null &&
          "status" in data &&
          data.status !== "queued" &&
          data.status !== "running";
        if (!controller.signal.aborted) setState({ data, updated: Date.now() });
      } catch (error) {
        if (!controller.signal.aborted)
          setState((old) => ({
            ...old,
            error: String(error instanceof Error ? error.message : error),
          }));
      } finally {
        busy = false;
        if (!controller.signal.aborted)
          timer = setTimeout(read, terminal ? 5000 : milliseconds);
      }
    }
    void read();
    window.addEventListener("xl-refresh", read);
    return () => {
      controller.abort();
      clearTimeout(timer);
      window.removeEventListener("xl-refresh", read);
    };
  }, [path, milliseconds, activeOnly]);
  return state;
}
