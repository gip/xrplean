import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { z } from "zod";
import { api } from "./api.ts";
import { tokenizeLean } from "./leanSyntax.ts";

export type ProofKind = "merkle" | "payments";
const definitionsSchema = z.object({
  kind: z.enum(["merkle", "payments"]),
  files: z.array(z.object({ name: z.string(), source: z.string() })),
});
const listingSchema = z.object({
  kind: z.enum(["merkle", "payments"]),
  status: z.string(),
  entry: z.string(),
  files: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      role: z.enum(["generated", "definition"]),
      recorded: z.boolean(),
    }),
  ),
});
const pageSchema = z.object({
  file_id: z.string(),
  page: z.number().int().nonnegative(),
  pages: z.number().int().positive(),
  source: z.string(),
  recorded: z.boolean(),
});
const descriptions = {
  merkle:
    "Authenticates both state roots and checks every exported state change in order. Transaction semantics and network consensus are separate.",
  payments:
    "Checks normalized facts and accounting for supported Payments. Skipped Payments, blob authentication, signatures, other transaction semantics and network consensus remain outside this proof.",
};
const primary = {
  merkle: ["LedgerTransition", "certify"],
  payments: ["Valid", "Common", "Rules", "payment_accounting"],
};
// Select exact declarations from the source returned by XLB, including their
// proof bodies. Never maintain a second handwritten version of a Lean theorem.
export function declaration(source: string, name: string): string {
  const lines = source.split("\n");
  const start = lines.findIndex((line) =>
    new RegExp(`^(?:def|theorem|inductive|structure) ${name}(?:[ {(:]|$)`).test(
      line,
    ),
  );
  if (start < 0) return "";
  let end = start + 1;
  while (
    end < lines.length &&
    !/^(?:def |theorem |inductive |structure |instance |end\b|\/--)/.test(
      lines[end],
    )
  )
    end++;
  return lines.slice(start, end).join("\n").trimEnd();
}
function useSource<T>(
  path: string | undefined,
  schema: z.ZodType<T>,
  pollMs?: number,
) {
  const [state, setState] = useState<{
    path?: string;
    data?: T;
    error?: string;
  }>({});
  useEffect(() => {
    if (!path) return;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    setState({ path });
    async function read() {
      try {
        const data = await api(path!, schema, controller.signal);
        if (!controller.signal.aborted) setState({ path, data });
      } catch (error) {
        if (!controller.signal.aborted)
          setState({
            path,
            error: error instanceof Error ? error.message : String(error),
          });
      } finally {
        if (pollMs && !controller.signal.aborted)
          timer = setTimeout(read, pollMs);
      }
    }
    void read();
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [path, schema, pollMs]);
  return state.path === path ? state : {};
}

function LeanSource({ source }: { source: string }) {
  const tokens = useMemo(() => tokenizeLean(source), [source]);
  return (
    <pre className="lean-source" tabIndex={0}>
      <code className="language-lean">
        {tokens.map((token, index) =>
          token.kind === "plain" ? (
            token.text
          ) : (
            <span key={index} className={`lean-${token.kind}`}>
              {token.text}
            </span>
          ),
        )}
      </code>
    </pre>
  );
}
function CertificateFile({ path }: { path: string }) {
  const [page, setPage] = useState(0);
  const result = useSource(`${path}/${page}`, pageSchema);
  return (
    <>
      {result.error && (
        <p role="alert" className="error-text">
          Source unavailable: {result.error}
        </p>
      )}
      {!result.data && !result.error && (
        <p className="muted">Loading Lean source…</p>
      )}
      {result.data && (
        <>
          <p className="source-origin">
            {result.data.recorded
              ? "Receipt-bound source · recorded digest matched"
              : "Unchecked generated source · no recorded receipt"}
          </p>
          <LeanSource source={result.data.source} />
          {result.data.pages > 1 && (
            <nav className="source-pages" aria-label="Lean source pages">
              <button disabled={page === 0} onClick={() => setPage(page - 1)}>
                Previous source page
              </button>
              <span>
                {page + 1} / {result.data.pages}
              </span>
              <button
                disabled={page + 1 === result.data.pages}
                onClick={() => setPage(page + 1)}
              >
                Next source page
              </button>
            </nav>
          )}
        </>
      )}
    </>
  );
}
function Certificate({ path, watch }: { path: string; watch: boolean }) {
  const result = useSource(path, listingSchema, watch ? 2000 : undefined);
  const [chosen, setChosen] = useState("");
  const files = result.data?.files ?? [];
  const selected =
    files.find((file) => file.id === chosen) ??
    files.find((file) => file.id === result.data?.entry);
  return (
    <section className="certificate-view">
      <h4>Generated certificate</h4>
      {result.error && (
        <p role="alert" className="error-text">
          Source unavailable: {result.error}
        </p>
      )}
      {!result.data && !result.error && (
        <p className="muted">Loading certificate files…</p>
      )}
      {result.data && !files.length && (
        <p>No generated Lean source is available for this attempt yet.</p>
      )}
      {files.length > 0 && (
        <>
          <label className="source-picker">
            Lean source file
            <select
              value={selected?.id ?? ""}
              onChange={(event) => setChosen(event.target.value)}
            >
              {!selected && (
                <option value="">
                  Certificate entry file unavailable — choose supporting source
                </option>
              )}
              {files.map((file) => (
                <option key={file.id} value={file.id}>
                  {file.name}
                  {file.role === "definition" ? " · receipt definition" : ""}
                </option>
              ))}
            </select>
          </label>
          {selected && (
            <CertificateFile
              key={`${path}/${selected.id}`}
              path={`${path}/${selected.id}`}
            />
          )}
        </>
      )}
    </section>
  );
}
export function ProofViewer({
  kind,
  base,
  attempt,
  status,
}: {
  kind: ProofKind;
  base: string;
  attempt?: { job: string; verification: string };
  status?: string;
}) {
  const definitions = useSource(`${base}/proofs/${kind}`, definitionsSchema);
  const snippets =
    definitions.data &&
    primary[kind].map(
      (name) =>
        definitions
          .data!.files.map((file) => declaration(file.source, name))
          .find(Boolean) ?? "",
    );
  return (
    <section
      className="proof-viewer"
      aria-label={`${kind === "merkle" ? "Tree" : "Payment"} Lean proof`}
    >
      <p className="proof-description">{descriptions[kind]}</p>
      {status && (
        <p className="muted">
          Verification status: {status.replaceAll("_", " ")}
        </p>
      )}
      <h4>{attempt ? "Current Lean definitions" : "What Lean will check"}</h4>
      {attempt && (
        <p className="source-origin">
          Current project source. Receipt-bound definitions are available in the
          certificate file selector.
        </p>
      )}
      {definitions.error && (
        <p role="alert" className="error-text">
          Definitions unavailable: {definitions.error}
        </p>
      )}
      {!definitions.data && !definitions.error && (
        <p className="muted">Loading Lean definitions…</p>
      )}
      {snippets && (
        <>
          <LeanSource source={snippets.filter(Boolean).join("\n\n")} />
          {snippets.some((text) => !text) && (
            <p role="alert">
              Some expected declarations are unavailable; inspect the full
              modules below.
            </p>
          )}
          <details className="supporting-definitions">
            <summary>Supporting definitions · current project source</summary>
            {definitions.data!.files.map((file) => (
              <details key={file.name}>
                <summary>{file.name}</summary>
                <LeanSource source={file.source} />
              </details>
            ))}
          </details>
        </>
      )}
      {attempt && (
        <Certificate
          key={`${base}/${attempt.job}/${attempt.verification}/${status}`}
          watch={status === "running" || status === "queued"}
          path={`${base}/jobs/${attempt.job}/verifications/${attempt.verification}/proof`}
        />
      )}
    </section>
  );
}

/** Read-only preview. Clicking the existing action opens its persistent review
 * or result containing this same viewer; hover/focus never dispatch a command. */
export function ProofPreview({
  children,
  kind,
  base,
  status,
  resolveAttempt,
}: {
  children: ReactNode;
  kind: "trust" | ProofKind;
  base: string;
  status: string;
  resolveAttempt?: (
    signal: AbortSignal,
  ) => Promise<
    { job: string; verification: string; status: string } | undefined
  >;
}) {
  const anchor = useRef<HTMLSpanElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [position, setPosition] = useState<{
    top: number;
    left: number;
    maxHeight: number;
  }>();
  const pointerFocus = useRef(0);
  const [pinned, setPinned] = useState(false);
  const resolver = useRef(resolveAttempt);
  resolver.current = resolveAttempt;
  const [receipt, setReceipt] = useState<{
    job: string;
    verification: string;
    status: string;
  }>();
  const [receiptError, setReceiptError] = useState("");
  useEffect(() => {
    setReceipt(undefined);
    setReceiptError("");
    if (!position || !resolver.current) return;
    const controller = new AbortController();
    void resolver.current(controller.signal).then(
      (value) => {
        if (!controller.signal.aborted) setReceipt(value);
      },
      (error: unknown) => {
        if (!controller.signal.aborted)
          setReceiptError(
            error instanceof Error ? error.message : String(error),
          );
      },
    );
    return () => controller.abort();
  }, [!!position, base, kind, status]);
  const hide = () => {
    clearTimeout(timer.current);
    setPosition(undefined);
    setPinned(false);
  };
  const open = () => {
    clearTimeout(timer.current);
    const rect = anchor.current?.getBoundingClientRect();
    if (rect) {
      const below = innerHeight - rect.bottom - 16;
      const above = rect.top - 16;
      const placeBelow = below >= Math.min(420, above);
      const height = Math.min(650, Math.max(120, placeBelow ? below : above));
      setPosition({
        top: placeBelow ? rect.bottom + 8 : Math.max(8, rect.top - height - 8),
        left: Math.max(
          8,
          Math.min(
            rect.right - 600,
            innerWidth - Math.min(600, innerWidth - 16) - 8,
          ),
        ),
        maxHeight: height,
      });
    }
  };
  const leave = () => {
    if (!pinned) timer.current = setTimeout(hide, 200);
  };
  useEffect(() => {
    if (!position) return;
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        hide();
      }
    };
    const outside = (event: PointerEvent) => {
      if (
        !anchor.current?.contains(event.target as Node) &&
        !panel.current?.contains(event.target as Node)
      )
        hide();
    };
    document.addEventListener("keydown", key, true);
    document.addEventListener("pointerdown", outside);
    const scroll = (event: Event) => {
      if (!panel.current?.contains(event.target as Node)) hide();
    };
    window.addEventListener("scroll", scroll, true);
    return () => {
      document.removeEventListener("keydown", key, true);
      document.removeEventListener("pointerdown", outside);
      window.removeEventListener("scroll", scroll, true);
    };
  }, [!!position]);
  useEffect(() => () => clearTimeout(timer.current), []);
  const blur = (target: EventTarget | null) => {
    if (
      !anchor.current?.contains(target as Node) &&
      !panel.current?.contains(target as Node)
    )
      leave();
  };
  return (
    <span
      ref={anchor}
      className="proof-preview-anchor"
      tabIndex={0}
      aria-label={`${kind === "merkle" ? "Tree" : kind === "payments" ? "Payment" : "Trust"} proof preview`}
      onPointerEnter={(event) => {
        if (event.pointerType !== "touch") open();
      }}
      onPointerLeave={leave}
      onPointerDownCapture={() => {
        pointerFocus.current = Date.now();
      }}
      onFocus={() => {
        if (Date.now() - pointerFocus.current > 600) open();
      }}
      onKeyDown={(event) => {
        pointerFocus.current = 0;
        if (
          event.target === anchor.current &&
          ["Enter", " "].includes(event.key)
        ) {
          event.preventDefault();
          open();
          setPinned(true);
        }
      }}
      onBlur={(event) => blur(event.relatedTarget)}
      onClickCapture={(event) => {
        if (anchor.current?.contains(event.target as Node)) hide();
      }}
    >
      {children}
      {position &&
        createPortal(
          <div
            ref={panel}
            role="dialog"
            aria-label="Proof preview"
            className="proof-preview"
            style={position}
            onPointerEnter={() => clearTimeout(timer.current)}
            onPointerLeave={leave}
            onFocus={() => clearTimeout(timer.current)}
            onBlur={(event) => blur(event.relatedTarget)}
          >
            <header>
              <strong>
                {kind === "merkle"
                  ? "Tree consistency"
                  : kind === "payments"
                    ? "Payment coverage"
                    : "Operator trust"}
              </strong>
              <div className="preview-actions">
                <button onClick={() => setPinned(true)} disabled={pinned}>
                  {pinned ? "Kept open" : "Keep open"}
                </button>
                <button onClick={hide} aria-label="Close proof preview">
                  ×
                </button>
              </div>
            </header>
            {kind === "trust" ? (
              <p>
                {status === "verified_trusted"
                  ? "Tree and Payment checks passed for the same export. Skipped Payments remain outside verification; this does not establish network consensus or create an operator anchor."
                  : "Operator trust anchors an exact stored ledger commitment. This is an operator decision and creates no Lean proof or consensus certificate."}
              </p>
            ) : (
              <>
                <ProofViewer
                  kind={kind}
                  base={base}
                  status={receipt?.status ?? status}
                  attempt={receipt}
                />
                {receiptError && (
                  <p role="alert" className="error-text">
                    Attempt source unavailable: {receiptError}
                  </p>
                )}
              </>
            )}
          </div>,
          document.body,
        )}
    </span>
  );
}
