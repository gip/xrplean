import { useEffect, useState } from "react";
import { api } from "./api.ts";
import { jobDetailSchema, type JobDetail } from "./contracts.ts";

// Job summaries describe ranges. Read running items to identify the exact export.
export function useRunningJobs(base: string, ids: string) {
  const [state, setState] = useState<{
    base: string;
    details: JobDetail[];
    error?: string;
  }>({ base, details: [] });
  useEffect(() => {
    setState({ base, details: [] });
    if (!ids) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>,
      busy = false;
    async function read() {
      if (busy || controller.signal.aborted) return;
      busy = true;
      clearTimeout(timer);
      const results = await Promise.allSettled(
        ids
          .split(",")
          .map((id) =>
            api(`${base}/jobs/${id}`, jobDetailSchema, controller.signal),
          ),
      );
      if (!controller.signal.aborted) {
        const details: JobDetail[] = [];
        const errors: string[] = [];
        for (const result of results) {
          if (result.status === "fulfilled") details.push(result.value);
          else
            errors.push(
              String(
                result.reason instanceof Error
                  ? result.reason.message
                  : result.reason,
              ),
            );
        }
        setState({
          base,
          details,
          error: errors.length ? errors.join("; ") : undefined,
        });
        timer = setTimeout(read, 2000);
      }
      busy = false;
    }
    void read();
    window.addEventListener("xl-refresh", read);
    return () => {
      controller.abort();
      clearTimeout(timer);
      window.removeEventListener("xl-refresh", read);
    };
  }, [base, ids]);
  return state.base === base ? state : { base, details: [] };
}
