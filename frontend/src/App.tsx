import { Fragment, useEffect, useRef, useState, type ReactNode } from "react";
import { z } from "zod";
import { api, streamTask, ApiError } from "./api.ts";
import {
  active,
  healthSchema,
  statusSchema,
  bundleSchema,
  ledgerSchema,
  exportSchema,
  taskSchema,
  jobSchema,
  jobDetailSchema,
  type Ledger,
  type Export,
  type Task,
  type Job,
  type JobDetail,
} from "./contracts.ts";
import { requestFor, type Command } from "./commands.ts";
import { useIdentity } from "./identity.ts";
import { usePoll, refresh } from "./usePoll.ts";
import { useRunningJobs } from "./useRunningJobs.ts";
import { BatchComposer } from "./BatchComposer.tsx";
import { ProofViewer, ProofPreview, type ProofKind } from "./ProofViewer.tsx";

const short = (value: string) => `${value.slice(0, 10)}…${value.slice(-8)}`;
const label = (value: string) =>
  ({
    kernel_checked: "Kernel checked",
    supported_checked: "Supported Payments checked",
    no_supported_payments: "No supported Payments",
    operator_trusted: "Trusted",
    verified_trusted: "Trusted · verified",
    not_checked: "Not checked",
    untrusted: "Not trusted",
    merkle: "Tree",
    payments: "Payment",
  })[value] ?? value.replaceAll("_", " ").replace(/^./, (c) => c.toUpperCase());
const errorText = (error: unknown) =>
  error instanceof Error ? error.message : String(error);
const complete = (ledger: Ledger) =>
  ["rpc_snapshot", "peer_snapshot"].includes(ledger.state);
const hasVerificationState = (ledger: Ledger, inventory: Ledger[]) =>
  complete(ledger) &&
  inventory.some(
    (parent) =>
      complete(parent) &&
      Number(parent.ledger_index) + 1 === Number(ledger.ledger_index) &&
      parent.ledger_hash.toUpperCase() === ledger.parent_hash.toUpperCase(),
  );
const ledgerKey = (ledger: Ledger) =>
  `${ledger.ledger_index}:${ledger.ledger_hash}`;
function Icon({
  name,
}: {
  name:
    | "trust"
    | "payments"
    | "merkle"
    | "chevron"
    | "sun"
    | "moon"
    | "check"
    | "fetch";
}) {
  const paths = {
    fetch: (
      <>
        <path d="M12 3v12m-5-5 5 5 5-5" />
        <path d="M5 17v4h14v-4" />
      </>
    ),
    check: <path d="m5 12 4 4L19 6" />,
    trust: (
      <>
        <path d="M12 3 4.5 6v5c0 4.5 3.2 7.6 7.5 10 4.3-2.4 7.5-5.5 7.5-10V6L12 3Z" />
        <path d="m8.5 11.5 2.5 2.5 4.5-5" />
      </>
    ),
    payments: (
      <>
        <rect x="3" y="6" width="18" height="12" rx="2" />
        <circle cx="12" cy="12" r="3" />
        <path d="M6 12h.01M18 12h.01" />
      </>
    ),
    merkle: (
      <>
        <rect x="9" y="3" width="6" height="5" rx="1" />
        <rect x="2" y="16" width="6" height="5" rx="1" />
        <rect x="16" y="16" width="6" height="5" rx="1" />
        <path d="M12 8v4M5 16v-4h14v4" />
      </>
    ),
    chevron: <path d="m9 6 6 6-6 6" />,
    sun: (
      <>
        <circle cx="12" cy="12" r="4" />
        <path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" />
      </>
    ),
    moon: <path d="M20.5 13A8.6 8.6 0 0 1 11 3.5 8.6 8.6 0 1 0 20.5 13Z" />,
  };
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  );
}
function Badge({ value }: { value: string }) {
  const tone = [
    "succeeded",
    "kernel_checked",
    "supported_checked",
    "operator_trusted",
    "verified_trusted",
  ].includes(value)
    ? "good"
    : ["failed", "unsupported", "blocked", "interrupted", "invalid"].includes(
          value,
        )
      ? "bad"
      : active(value)
        ? "accent"
        : "";
  return <span className={`badge ${tone}`}>{label(value)}</span>;
}
function Json({ value }: { value: unknown }) {
  return <pre className="json">{JSON.stringify(value, null, 2)}</pre>;
}
function Dialog({
  title,
  close,
  children,
}: {
  title: string;
  close: () => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    ref.current?.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      onCancel={(event) => {
        event.preventDefault();
        close();
      }}
      aria-label={title}
    >
      <header>
        <h2>{title}</h2>
        <button onClick={close} aria-label="Close dialog">
          ×
        </button>
      </header>
      {children}
    </dialog>
  );
}
interface Selection {
  view: "ledgers" | "jobs" | "batch";
  batch?: string;
  bundle: string;
  ledger?: string;
  task?: string;
  job?: string;
}
function readSelection(): Selection {
  const params = new URLSearchParams(location.search);
  const number = (key: string) =>
    /^\d+$/.test(params.get(key) ?? "") ? params.get(key)! : undefined;
  return {
    view:
      params.get("view") === "batch"
        ? "batch"
        : params.get("view") === "jobs"
          ? "jobs"
          : "ledgers",
    batch: number("batch"),
    bundle: /^[A-Za-z0-9_-]{1,64}$/.test(params.get("bundle") ?? "")
      ? params.get("bundle")!
      : "default",
    ledger: params.get("ledger") ?? undefined,
    task: number("task"),
    job: number("job"),
  };
}
type Review = {
  kind: "trust" | "merkle" | "payments";
  ledger: Ledger;
  bundle: string;
};
export function App() {
  const identity = useIdentity();
  const identityRef = useRef(identity);
  identityRef.current = identity;
  const [selection, setSelection] = useState(readSelection);
  const [review, setReview] = useState<Review>();
  const [openLedger, setOpenLedger] = useState<string>();
  const [historyOpen, setHistoryOpen] = useState(false);
  const resultLookup = useRef<AbortController | undefined>(undefined);
  useEffect(() => () => resultLookup.current?.abort(), []);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [message, setMessage] = useState("");
  const [reviewError, setReviewError] = useState("");
  const [trusted, setTrusted] = useState<string>();
  const [index, setIndex] = useState("");
  const [page, setPage] = useState(1);
  const [now, setNow] = useState(Date.now());
  const [theme, setTheme] = useState<"light" | "dark">(() => {
    try {
      const saved = localStorage.getItem("xl:theme");
      if (saved === "light" || saved === "dark") return saved;
    } catch {
      /* storage is optional */
    }
    return matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "light";
  });
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      localStorage.setItem("xl:theme", theme);
    } catch {
      /* storage is optional */
    }
  }, [theme]);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    const pop = () => {
      setSelection(readSelection());
      setReview(undefined);
      setMessage("");
    };
    window.addEventListener("popstate", pop);
    return () => {
      clearInterval(timer);
      window.removeEventListener("popstate", pop);
    };
  }, []);
  function select(update: Partial<Selection>) {
    resultLookup.current?.abort();
    setSelection((current) => {
      const next = { ...current, ...update };
      const params = new URLSearchParams();
      Object.entries(next).forEach(([key, value]) => {
        if (value) params.set(key, value);
      });
      history.pushState(null, "", "?" + params);
      return next;
    });
  }
  function openTask(id: string) {
    select({ task: id, job: undefined, ledger: undefined });
    requestAnimationFrame(() =>
      document.getElementById("task-result")?.showPopover(),
    );
  }
  function openJob(id: string, navigate = false) {
    select({
      ...(navigate ? { view: "jobs" as const } : {}),
      job: id,
      task: undefined,
      ledger: undefined,
    });
    requestAnimationFrame(() =>
      document.getElementById("history-result")?.showPopover(),
    );
  }
  const base = `/bundles/${selection.bundle}`;
  const health = usePoll("/health", healthSchema);
  const status = usePoll("/status", statusSchema);
  const bundles = usePoll("/bundles", z.array(bundleSchema));
  const ledgers = usePoll(base + "/ledgers", z.array(ledgerSchema));
  const exports = usePoll(base + "/exports", z.array(exportSchema));
  const tasks = usePoll(base + "/tasks", z.array(taskSchema));
  const jobs = usePoll(base + "/jobs", z.array(jobSchema));
  const runningJobs = useRunningJobs(
    base,
    (jobs.data ?? [])
      .filter((job) => job.status === "running")
      .map((job) => job.job_id)
      .sort()
      .join(","),
  );
  const taskId =
    selection.task ?? tasks.data?.find((task) => active(task.status))?.task_id;
  const taskDetail = usePoll(
    taskId ? `${base}/tasks/${taskId}` : null,
    taskSchema,
    2000,
  );
  const jobDetail = usePoll(
    selection.job ? `${base}/jobs/${selection.job}` : null,
    jobDetailSchema,
    2000,
    true,
  );
  const [liveTask, setLiveTask] = useState<Task>();
  const [streamError, setStreamError] = useState("");
  useEffect(() => {
    setLiveTask(taskDetail.data);
  }, [taskDetail.data]);
  useEffect(() => {
    setStreamError("");
    if (!taskId || !taskDetail.data || !active(taskDetail.data.status)) return;
    const controller = new AbortController();
    const key = `xl:cursor:${selection.bundle}:${taskId}`;
    let cursor = 0;
    try {
      cursor = Number(sessionStorage.getItem(key) ?? 0) || 0;
    } catch {
      /* optional */
    }
    let timer: ReturnType<typeof setTimeout>;
    async function follow() {
      try {
        await streamTask(
          selection.bundle,
          taskId!,
          cursor,
          controller.signal,
          (event) => {
            if (event.event_seq <= cursor) {
              if (event.event !== "progress") refresh();
              return;
            }
            cursor = event.event_seq;
            try {
              sessionStorage.setItem(key, String(cursor));
            } catch {
              /* optional */
            }
            setStreamError("");
            if (event.event === "progress")
              setLiveTask((task) =>
                task ? { ...task, progress: event } : task,
              );
            else refresh();
          },
        );
      } catch (error) {
        if (!controller.signal.aborted) {
          setStreamError(errorText(error));
          timer = setTimeout(follow, 2000);
        }
      }
    }
    void follow();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [selection.bundle, taskId, taskDetail.data?.status]);

  const dataFresh =
    !!health.updated && !health.error && now - health.updated < 15000;
  const inventoryFresh =
    !!ledgers.updated && !ledgers.error && now - ledgers.updated < 15000;
  const enabled = identity.connected && dataFresh && inventoryFresh && !busy;
  const fullLedgers = (ledgers.data ?? [])
    .filter(complete)
    .sort(
      (a, b) =>
        Number(a.ledger_index) - Number(b.ledger_index) ||
        a.ledger_hash.localeCompare(b.ledger_hash),
    );
  const tip = fullLedgers.at(-1);
  const nextIndex = tip ? Number(tip.ledger_index) + 1 : undefined;
  const tipForked =
    tip &&
    fullLedgers.filter((ledger) => ledger.ledger_index === tip.ledger_index)
      .length > 1;
  const acquiring = tasks.data?.some((task) => active(task.status));
  const fetchEnabled = enabled && !!tasks.updated && !tasks.error && !acquiring;
  const node = status.data?.xrpld;
  const nodeFresh =
    !!status.updated &&
    !status.error &&
    node &&
    now - Number(node.observed_at_unix) * 1000 < 15000;
  const latest = node?.validated_ledger;
  const latestAvailable =
    !!nodeFresh &&
    !!node?.reachable &&
    !node.error &&
    node.network_compatible === true &&
    !!latest &&
    latest.seq >= 1 &&
    latest.seq <= 4294967295;
  const latestHash = latest?.hash;
  const latestStored =
    !!latestHash &&
    fullLedgers.some(
      (ledger) =>
        Number(ledger.ledger_index) === latest.seq &&
        ledger.ledger_hash.toUpperCase() === latestHash.toUpperCase(),
    );
  const showNextRow =
    !!tip &&
    (!latest || latestStored || latest.seq <= Number(tip.ledger_index));
  const listLedgers: (Ledger | { ledger_index: string; latest: true })[] = [
    ...fullLedgers,
    ...(latest && !latestStored
      ? [{ ledger_index: String(latest.seq), latest: true as const }]
      : []),
  ].sort((a, b) => Number(a.ledger_index) - Number(b.ledger_index));
  const pageCount = Math.max(1, Math.ceil(listLedgers.length / 50));
  const currentPage = Math.min(page, pageCount);
  const rows = listLedgers.slice((currentPage - 1) * 50, currentPage * 50);

  async function run(command: Command, reviewedExport?: Export) {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setMessage("");
    setReviewError("");
    const submittedBundle = selection.bundle;
    try {
      if (!identityRef.current.connected)
        throw new Error("Connect a wallet before submitting an action.");
      if (!dataFresh || !inventoryFresh || command.bundle !== submittedBundle)
        throw new Error("Refresh the backend before submitting.");
      if (command.kind === "trust" || command.kind === "verify") {
        const fresh = await api(base + "/ledgers", z.array(ledgerSchema));
        const target = review?.ledger;
        if (
          !target ||
          !fresh.some(
            (ledger) =>
              complete(ledger) &&
              ledgerKey(ledger) === ledgerKey(target) &&
              ledger.state_root === target.state_root &&
              ledger.parent_hash === target.parent_hash,
          )
        )
          throw new Error(
            "The reviewed full-state ledger is no longer available. Refresh and try again.",
          );
        if (
          command.kind === "verify" &&
          command.checks.includes("merkle") &&
          !hasVerificationState(target, fresh)
        )
          throw new Error(
            "Verification requires the exact previous ledger’s full state, the current state, and a transaction export.",
          );
      }
      const variants =
        command.kind === "verify"
          ? await api(base + "/exports", z.array(exportSchema))
          : [];
      if (
        command.kind === "verify" &&
        (!reviewedExport ||
          !variants.some(
            (variant) =>
              variant.export_id === reviewedExport.export_id &&
              variant.ledger_index === reviewedExport.ledger_index &&
              variant.ledger_hash === reviewedExport.ledger_hash &&
              variant.payload_sha256 === reviewedExport.payload_sha256,
          ))
      )
        throw new Error(
          "The reviewed export changed. Reopen the confirmation and select an exact export.",
        );
      const request = requestFor(command, variants);
      const beforeSend = () => {
        if (!identityRef.current.connected)
          throw new Error("Wallet disconnected before submission.");
      };
      if (command.kind === "trust") {
        const result = await api(
          request.path,
          z.object({
            ledger_hash: z.string(),
            trust: z.literal("operator_trusted"),
            verification: z.literal("unchanged"),
          }),
          undefined,
          request.body,
          beforeSend,
        );
        if (result.ledger_hash.toUpperCase() !== command.hash.toUpperCase())
          throw new Error("Trust response ledger mismatch.");
        setTrusted(`${submittedBundle}:${command.index}:${command.hash}`);
      } else if (command.kind === "verify") {
        const result = await api(
          request.path,
          z.object({ job_id: z.string(), status: z.string() }),
          undefined,
          request.body,
          beforeSend,
        );
        select({ ledger: ledgerKey(review!.ledger), job: result.job_id });
      } else if (command.kind === "cancel_job") {
        const result = await api(
          request.path,
          jobDetailSchema,
          undefined,
          request.body,
          beforeSend,
        );
        select({ job: result.job_id });
      } else {
        const result = await api(
          request.path,
          taskSchema,
          undefined,
          request.body,
          beforeSend,
        );
        select({ task: result.task_id });
        if (command.kind === "cancel") setLiveTask(result);
        else setIndex("");
      }
      setReview(undefined);
      refresh();
    } catch (error) {
      const definite =
        error instanceof ApiError && error.status >= 400 && error.status < 500;
      const text =
        errorText(error) +
        (!definite
          ? " No automatic retry was sent. Check the Jobs tab before resubmitting."
          : "");
      setMessage(text);
      setReviewError(text);
      refresh();
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }
  function openReview(kind: Review["kind"], ledger: Ledger) {
    resultLookup.current?.abort();
    setReviewError("");
    setMessage("");
    setReview({ kind, ledger, bundle: selection.bundle });
  }
  async function findProof(
    ledger: Ledger,
    kind: ProofKind,
    signal?: AbortSignal,
  ) {
    const candidates = (jobs.data ?? [])
      .filter(
        (job) =>
          job.checks.includes(kind) &&
          Number(job.from) <= Number(ledger.ledger_index) &&
          Number(job.to) >= Number(ledger.ledger_index),
      )
      .sort((a, b) => (BigInt(a.job_id) > BigInt(b.job_id) ? -1 : 1));
    for (const candidate of candidates) {
      const detail = await api(
        `${base}/jobs/${candidate.job_id}`,
        jobDetailSchema,
        signal,
      );
      const matchingExports = detail.items
        .filter(
          (item) =>
            item.ledger_index === ledger.ledger_index &&
            exports.data?.some(
              (variant) =>
                variant.export_id === item.export_id &&
                variant.ledger_hash === ledger.ledger_hash,
            ),
        )
        .map((item) => item.export_id);
      const attempt = detail.verifications.findLast(
        (attempt) =>
          attempt.kind === kind && matchingExports.includes(attempt.export_id),
      );
      if (attempt)
        return {
          job: candidate.job_id,
          verification: attempt.verification_id,
          status: attempt.status,
        };
    }
  }
  async function showResult(ledger: Ledger, kind: "trust" | ProofKind) {
    resultLookup.current?.abort();
    document.getElementById(`ledger-${ledger.ledger_hash}`)?.showPopover();
    if (kind === "trust") return;
    const controller = new AbortController();
    resultLookup.current = controller;
    try {
      const proof = await findProof(ledger, kind, controller.signal);
      if (
        !controller.signal.aborted &&
        proof &&
        readSelection().bundle === selection.bundle
      )
        select({ ledger: ledgerKey(ledger), job: proof.job });
    } catch (error) {
      if (!controller.signal.aborted) setMessage(errorText(error));
    }
  }
  function fetchIndex() {
    const value = index.trim();
    const normalized = value.replaceAll(",", "");
    if (
      !/^(?:\d+|\d{1,3}(?:,\d{3})+)$/.test(value) ||
      Number(normalized) < 1 ||
      Number(normalized) > 4294967295
    ) {
      setMessage("Enter a ledger index between 1 and 4294967295.");
      return;
    }
    void run({
      kind: "fetch",
      bundle: selection.bundle,
      selector: normalized,
      state: true,
      transport: "auto",
    });
  }
  function nextLedgerButton(inGap = false) {
    if (nextIndex === undefined) return null;
    return (
      <button
        className={inGap ? "gap-fetch" : "icon-button"}
        aria-label={`Fetch next ledger ${nextIndex.toLocaleString()}`}
        disabled={!fetchEnabled || !!tipForked || nextIndex > 4294967295}
        title={
          tipForked
            ? "The latest index has multiple forks. Fetch an explicit index instead."
            : `Fetch full state for ledger ${nextIndex.toLocaleString()}`
        }
        onClick={() =>
          void run({
            kind: "state_update",
            bundle: selection.bundle,
            selector: String(nextIndex),
            transport: "auto",
          })
        }
      >
        <Icon name="fetch" />
        {inGap && `Fetch ${nextIndex.toLocaleString()}`}
      </button>
    );
  }
  const runningDetails = [...runningJobs.details];
  if (
    jobDetail.data?.status === "running" &&
    !runningDetails.some((job) => job.job_id === jobDetail.data!.job_id)
  )
    runningDetails.push(jobDetail.data);
  function runningFor(ledger: Ledger) {
    return runningDetails.filter(
      (job) =>
        job.status === "running" &&
        job.items.some(
          (item) =>
            item.status === "running" &&
            item.ledger_index === ledger.ledger_index &&
            exports.data?.some(
              (variant) =>
                variant.export_id === item.export_id &&
                variant.ledger_hash === ledger.ledger_hash,
            ),
        ),
    );
  }
  const runningFetch = (tasks.data ?? [])
    .map((task) =>
      liveTask?.bundle === selection.bundle && liveTask.task_id === task.task_id
        ? liveTask
        : task,
    )
    .find((task) => task.status === "running");
  const fetchingIndex = runningFetch?.progress?.ledger_index;
  const fetchPending =
    !!fetchingIndex &&
    !fullLedgers.some(
      (ledger) => Number(ledger.ledger_index) === fetchingIndex,
    ) &&
    fetchingIndex !== latest?.seq;
  function fetchStatus() {
    return runningFetch ? (
      <button
        className="running-job"
        onClick={() => openTask(runningFetch.task_id)}
      >
        <span className="running-dot" />
        Fetch #{runningFetch.task_id} running
      </button>
    ) : null;
  }
  function pendingFetchRow() {
    return (
      <li className="pending-ledger ledger-main">
        <div className="ledger-index-group">
          <span className="next-index">{fetchingIndex?.toLocaleString()}</span>
          {fetchStatus()}
        </div>
      </li>
    );
  }
  const result = jobDetail.data;
  const selectedRow = fullLedgers.find(
    (ledger) => ledgerKey(ledger) === selection.ledger,
  );
  const resultMatchesRow =
    !!selectedRow &&
    result?.items.some(
      (item) =>
        item.ledger_index === selectedRow.ledger_index &&
        exports.data?.some(
          (variant) =>
            variant.export_id === item.export_id &&
            variant.ledger_hash === selectedRow.ledger_hash,
        ),
    );
  useEffect(() => {
    if (!selection.ledger) return;
    const index = fullLedgers.findIndex(
      (ledger) => ledgerKey(ledger) === selection.ledger,
    );
    if (index >= 0) setPage(Math.floor(index / 50) + 1);
  }, [selection.ledger, selection.bundle, !!ledgers.data]);
  useEffect(() => {
    if (!selection.job) return;
    if (selection.ledger && selectedRow) {
      const hash = selection.ledger.split(":")[1];
      document.getElementById(`ledger-${hash}`)?.showPopover();
    } else document.getElementById("history-result")?.showPopover();
  }, [
    selection.ledger,
    selection.job,
    !!ledgers.data,
    currentPage,
    !!selectedRow,
  ]);
  useEffect(() => {
    if (selection.task) document.getElementById("task-result")?.showPopover();
  }, [selection.task]);
  useEffect(() => {
    if (trusted)
      document.getElementById(`ledger-${trusted.split(":")[2]}`)?.showPopover();
  }, [trusted]);
  return (
    <div className="workspace">
      <header className="masthead">
        <a className="brand" href="/" aria-label="XL ledgers">
          <span>XL</span>
          <strong>xrplean</strong>
        </a>
        <div className="header-actions">
          <label className="bundle-control">
            Bundle{" "}
            <span className="bundle-select">
              <select
                aria-label="Bundle"
                value={selection.bundle}
                disabled={busy}
                onChange={(event) => {
                  select({
                    bundle: event.target.value,
                    ledger: undefined,
                    task: undefined,
                    job: undefined,
                  });
                  setPage(1);
                  setReview(undefined);
                  setMessage("");
                  setIndex("");
                }}
              >
                {!(bundles.data ?? []).some(
                  (bundle) => bundle.bundle === selection.bundle,
                ) && <option>{selection.bundle}</option>}
                {bundles.data?.map((bundle) => (
                  <option key={bundle.bundle}>{bundle.bundle}</option>
                ))}
              </select>
              <svg
                className="select-chevron"
                width="12"
                height="12"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.5"
                aria-hidden="true"
              >
                <path d="m4 6 4 4 4-4" />
              </svg>
            </span>
          </label>
          <button
            className="theme-toggle"
            aria-label={`Switch to ${theme === "light" ? "dark" : "light"} mode`}
            onClick={() => setTheme(theme === "light" ? "dark" : "light")}
          >
            <Icon name={theme === "light" ? "moon" : "sun"} />
          </button>
          {identity.connected ? (
            <button onClick={identity.disconnect} title={identity.address}>
              {short(identity.address ?? "")} · Disconnect
            </button>
          ) : (
            <button onClick={identity.connect} disabled={identity.connecting}>
              {identity.connecting ? "Connecting…" : "Connect wallet"}
            </button>
          )}
        </div>
      </header>
      <main>
        <div className="page-heading">
          <div>
            <p className="eyebrow">
              {health.data
                ? health.data.network_id === 0
                  ? "Mainnet"
                  : `Network ${health.data.network_id}`
                : "Local workspace"}
            </p>
            <h1>
              {selection.view === "batch"
                ? "Batch"
                : selection.view === "jobs"
                  ? "Jobs"
                  : "Ledgers"}
            </h1>
            <p className="muted">
              {selection.view === "batch"
                ? "Unsigned XRP Payments with a Lean certificate."
                : selection.view === "jobs"
                  ? "Fetches and verification checks."
                  : "Complete state. One ledger at a time."}
            </p>
          </div>
          <button className="quiet" onClick={refresh}>
            ↻ Refresh
          </button>
        </div>
        <div
          className="connection-line"
          role="region"
          aria-label="Service status"
        >
          <span className={`dot ${dataFresh ? "good" : "bad"}`} />
          <span
            title={
              health.error ??
              (health.data
                ? `Online · ${health.data.state_backend.toUpperCase()} · PID ${health.data.pid}`
                : "Run ./xl start")
            }
          >
            XLB{" "}
            {dataFresh ? "online" : health.error ? "unreachable" : "connecting"}
          </span>
          <span className="separator">/</span>
          <span title={node?.error ?? status.error ?? undefined}>
            Node{" "}
            {nodeFresh
              ? node?.reachable && !node.error
                ? "connected"
                : "unreachable"
              : "status unavailable"}
          </span>
          {nodeFresh && node?.validated_ledger && (
            <span className="muted">
              · latest {node.validated_ledger.seq.toLocaleString()}
            </span>
          )}
        </div>
        {identity.error && (
          <p className="notice error" role="alert">
            Wallet: {identity.error}
          </p>
        )}
        {message && (
          <p className="notice error" role="alert">
            {message}
          </p>
        )}
        {[
          bundles.error,
          ledgers.error,
          exports.error,
          tasks.error,
          jobs.error,
          runningJobs.error,
        ]
          .filter(Boolean)
          .map((error, i) => (
            <p className="notice error" role="alert" key={i}>
              {error}
            </p>
          ))}
        <div className="view-tabs" role="tablist" aria-label="Workspace">
          {(["ledgers", "jobs", "batch"] as const).map((view) => (
            <button
              key={view}
              role="tab"
              id={`tab-${view}`}
              aria-selected={selection.view === view}
              tabIndex={selection.view === view ? 0 : -1}
              aria-controls={`${view}-view`}
              onClick={() =>
                select({
                  view,
                  ledger: undefined,
                  job: undefined,
                  task: undefined,
                })
              }
              onKeyDown={(event) => {
                if (
                  ["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)
                ) {
                  event.preventDefault();
                  const views = ["ledgers", "jobs", "batch"] as const;
                  const direction = event.key === "ArrowLeft" ? -1 : 1;
                  const next =
                    event.key === "Home"
                      ? views[0]
                      : event.key === "End"
                        ? views[2]
                        : views[(views.indexOf(view) + direction + 3) % 3];
                  select({
                    view: next,
                    ledger: undefined,
                    job: undefined,
                    task: undefined,
                  });
                  document.getElementById(`tab-${next}`)?.focus();
                }
              }}
            >
              {view === "batch"
                ? "Batch"
                : view === "ledgers"
                  ? "Ledgers"
                  : "Jobs"}
              {view === "jobs" && (
                <span className="count">
                  {(tasks.data?.length ?? 0) + (jobs.data?.length ?? 0)}
                </span>
              )}
            </button>
          ))}
        </div>
        {selection.view === "batch" ? (
          <section id="batch-view" role="tabpanel" aria-labelledby="tab-batch">
            <BatchComposer
              attemptId={selection.batch}
              onSelect={(id) => select({ batch: id })}
            />
          </section>
        ) : selection.view === "ledgers" ? (
          <section
            id="ledgers-view"
            role="tabpanel"
            aria-labelledby="tab-ledgers"
          >
            <section className="fetch-bar" aria-label="Fetch ledgers">
              <form
                onSubmit={(event) => {
                  event.preventDefault();
                  fetchIndex();
                }}
              >
                <label htmlFor="ledger-index">Fetch by index</label>
                <input
                  id="ledger-index"
                  inputMode="numeric"
                  pattern="[0-9]+|[0-9]{1,3}(,[0-9]{3})+"
                  placeholder="Ledger index"
                  value={index}
                  onChange={(event) => setIndex(event.target.value)}
                  required
                  disabled={busy}
                />
                <button
                  className="icon-button"
                  disabled={!fetchEnabled}
                  aria-label="Fetch ledger"
                  title="Fetch ledger"
                >
                  <Icon name="fetch" />
                </button>
              </form>
            </section>
            {!identity.connected && (
              <p className="help">
                Connect a wallet to fetch, trust, or verify ledgers.
              </p>
            )}
            {tipForked && (
              <p className="help">
                Multiple forks at the latest index. Use an explicit index to
                fetch another ledger.
              </p>
            )}
            <section className="ledger-panel" aria-label="Complete ledgers">
              <div className="list-heading">
                <h2>
                  Full-state ledgers{" "}
                  <span className="count">
                    {fullLedgers.length.toLocaleString()}
                  </span>
                </h2>
                <span className="muted">Oldest first ↑</span>
              </div>
              <ol className="ledger-list">
                {rows.map((ledger, rowIndex) => {
                  const next =
                    listLedgers[(currentPage - 1) * 50 + rowIndex + 1];
                  const gap =
                    next &&
                    Number(next.ledger_index) - Number(ledger.ledger_index) > 1;
                  const connected =
                    next &&
                    Number(next.ledger_index) ===
                      Number(ledger.ledger_index) + 1;
                  const insertFetch =
                    fetchPending &&
                    (fetchingIndex !== nextIndex || !showNextRow) &&
                    fetchingIndex < Number(ledger.ledger_index) &&
                    (rowIndex === 0
                      ? currentPage === 1 ||
                        fetchingIndex >
                          Number(
                            listLedgers[(currentPage - 1) * 50 - 1]
                              ?.ledger_index,
                          )
                      : fetchingIndex >
                        Number(rows[rowIndex - 1].ledger_index));
                  const missing = next
                    ? Math.max(
                        0,
                        Number(next.ledger_index) -
                          Number(ledger.ledger_index) -
                          1,
                      )
                    : 0;
                  const extendTip =
                    tip &&
                    !("latest" in ledger) &&
                    ledgerKey(ledger) === ledgerKey(tip);
                  const gapLabel = gap && (
                    <div
                      className={`gap-label${extendTip ? " gap-with-action" : ""}`}
                    >
                      <span className="gap-count">
                        {missing.toLocaleString()} missing
                      </span>
                      {extendTip && nextLedgerButton(true)}
                    </div>
                  );
                  if ("latest" in ledger) {
                    if (!latest) return null;
                    return (
                      <Fragment
                        key={`latest:${ledger.ledger_index}:${latest.hash}`}
                      >
                        {insertFetch && pendingFetchRow()}
                        <li
                          className={`ledger-row latest-ledger ${connected ? "connected" : gap ? "gap" : ""}`}
                          aria-label="Latest validated ledger"
                          data-gap={missing || undefined}
                        >
                          <div className="ledger-main">
                            <div className="ledger-index-group">
                              <span className="ledger-number latest-index">
                                {latest.seq.toLocaleString()}
                              </span>
                              <span className="muted">Latest validated</span>
                              {fetchingIndex === latest.seq && fetchStatus()}
                              {!latestAvailable ? (
                                <span className="muted">
                                  Status unavailable
                                </span>
                              ) : null}
                            </div>
                            <button
                              className="icon-button"
                              aria-label={`Fetch latest ledger ${latest.seq.toLocaleString()}`}
                              disabled={!fetchEnabled || !latestAvailable}
                              title={
                                !latestAvailable
                                  ? "Waiting for a current validated ledger from the configured node"
                                  : `Fetch full state for ledger ${latest.seq.toLocaleString()}`
                              }
                              onClick={() => {
                                if (!latestAvailable) return;
                                void run({
                                  kind: "fetch",
                                  bundle: selection.bundle,
                                  selector: String(latest.seq),
                                  hash: latest.hash ?? undefined,
                                  state: true,
                                  transport: "auto",
                                });
                              }}
                            >
                              <Icon name="fetch" />
                            </button>
                          </div>
                          {gapLabel}
                        </li>
                      </Fragment>
                    );
                  }
                  const variants = (exports.data ?? []).filter(
                    (variant) =>
                      variant.ledger_index === ledger.ledger_index &&
                      variant.ledger_hash === ledger.ledger_hash,
                  );
                  const verificationReady =
                    hasVerificationState(ledger, ledgers.data ?? []) &&
                    variants.length > 0 &&
                    !exports.error;
                  const trustSucceeded =
                    trusted ===
                    `${selection.bundle}:${ledger.ledger_index}:${ledger.ledger_hash}`;
                  return (
                    <Fragment key={ledgerKey(ledger)}>
                      {insertFetch && pendingFetchRow()}
                      <li
                        className={`ledger-row ${connected ? "connected" : gap ? "gap" : ""}`}
                        key={ledgerKey(ledger)}
                        data-gap={
                          gap
                            ? Number(next.ledger_index) -
                              Number(ledger.ledger_index) -
                              1
                            : undefined
                        }
                      >
                        <div className="ledger-main">
                          <div className="ledger-index-group">
                            <button
                              className="ledger-number"
                              popoverTarget={`ledger-${ledger.ledger_hash}`}
                            >
                              {Number(ledger.ledger_index).toLocaleString()}
                            </button>
                            {latestStored &&
                              Number(ledger.ledger_index) === latest?.seq &&
                              ledger.ledger_hash.toUpperCase() ===
                                latestHash?.toUpperCase() && (
                                <span
                                  className="latest-label muted"
                                  aria-label="Latest validated ledger"
                                >
                                  Latest validated
                                </span>
                              )}
                            {fetchingIndex === Number(ledger.ledger_index) &&
                              fullLedgers.filter(
                                (stored) =>
                                  stored.ledger_index === ledger.ledger_index,
                              ).length === 1 &&
                              fetchStatus()}
                            {runningFor(ledger).map((job) => {
                              const kind = job.verifications.find(
                                (attempt) =>
                                  attempt.status === "running" &&
                                  variants.some(
                                    (variant) =>
                                      variant.export_id === attempt.export_id,
                                  ),
                              )?.kind;
                              return (
                                <button
                                  className="running-job"
                                  key={job.job_id}
                                  onClick={() => openJob(job.job_id, true)}
                                >
                                  <span className="running-dot" />
                                  {kind ? label(kind) : "Check"} #{job.job_id}{" "}
                                  running
                                </button>
                              );
                            })}
                          </div>
                          <div
                            className="ledger-checks"
                            aria-label={`Actions for ledger ${ledger.ledger_index}`}
                          >
                            {(["trust", "payments", "merkle"] as const).map(
                              (kind) => {
                                const value =
                                  kind === "trust"
                                    ? trustSucceeded
                                      ? "operator_trusted"
                                      : ledger.trust
                                    : ledger[kind];
                                const checked =
                                  value === "operator_trusted" ||
                                  value === "verified_trusted" ||
                                  value === "kernel_checked" ||
                                  value === "supported_checked";
                                if (
                                  kind !== "trust" &&
                                  !checked &&
                                  !(kind === "payments"
                                    ? variants.length && !exports.error
                                    : verificationReady)
                                )
                                  return null;
                                const title =
                                  kind === "trust"
                                    ? "Trust ledger"
                                    : kind === "payments"
                                      ? "Verify payment"
                                      : "Verify tree";
                                return (
                                  <ProofPreview
                                    key={kind}
                                    kind={kind}
                                    base={base}
                                    status={value}
                                    resolveAttempt={
                                      kind === "trust"
                                        ? undefined
                                        : (signal) =>
                                            findProof(ledger, kind, signal)
                                    }
                                  >
                                    <button
                                      data-check={kind}
                                      className={`icon-button ${checked ? "checked" : ["failed", "unsupported"].includes(value) ? "failed" : ""}`}
                                      aria-label={
                                        checked ? `${title} result` : title
                                      }
                                      title={`${title} · ${label(value)}`}
                                      disabled={
                                        !checked &&
                                        (!enabled ||
                                          (kind !== "trust" &&
                                            (!variants.length ||
                                              !!exports.error)))
                                      }
                                      onClick={() =>
                                        checked
                                          ? void showResult(ledger, kind)
                                          : openReview(kind, ledger)
                                      }
                                    >
                                      <Icon name={checked ? "check" : kind} />
                                    </button>
                                  </ProofPreview>
                                );
                              },
                            )}
                          </div>
                        </div>
                        {gapLabel}
                        <div
                          className="ledger-popover"
                          id={`ledger-${ledger.ledger_hash}`}
                          popover="auto"
                          onToggle={(event) => {
                            const opened =
                              event.currentTarget.matches(":popover-open");
                            setOpenLedger((current) =>
                              opened
                                ? ledgerKey(ledger)
                                : current === ledgerKey(ledger)
                                  ? undefined
                                  : current,
                            );
                          }}
                        >
                          <header>
                            <h2>
                              Ledger{" "}
                              {Number(ledger.ledger_index).toLocaleString()}
                            </h2>
                            <button
                              popoverTarget={`ledger-${ledger.ledger_hash}`}
                              popoverTargetAction="hide"
                              aria-label="Close ledger details"
                            >
                              ×
                            </button>
                          </header>
                          <dl>
                            <dt>State</dt>
                            <dd>
                              Full snapshot ·{" "}
                              {ledger.state === "peer_snapshot"
                                ? "Peer"
                                : "RPC"}
                            </dd>
                            <dt>Trust</dt>
                            <dd>
                              <Badge
                                value={
                                  trustSucceeded
                                    ? "operator_trusted"
                                    : ledger.trust
                                }
                              />
                            </dd>
                            <dt>Payment coverage</dt>
                            <dd>
                              <Badge value={ledger.payments} />
                            </dd>
                            <dt>Tree consistency</dt>
                            <dd>
                              <Badge value={ledger.merkle} />
                            </dd>
                          </dl>
                          {(trustSucceeded ||
                            ledger.trust === "operator_trusted") && (
                            <p className="muted">
                              Operator trust anchors this exact stored ledger
                              commitment. This decision creates no Lean proof or
                              network consensus certificate.
                            </p>
                          )}
                          {openLedger === ledgerKey(ledger) && (
                            <>
                              <ProofViewer
                                kind="merkle"
                                base={base}
                                status={ledger.merkle}
                              />
                              <ProofViewer
                                kind="payments"
                                base={base}
                                status={ledger.payments}
                              />
                            </>
                          )}
                          <details className="technical-details">
                            <summary>Technical details</summary>
                            <dl>
                              {" "}
                              <dt>Ledger hash</dt>
                              <dd>
                                <code>{ledger.ledger_hash}</code>
                              </dd>
                              <dt>Parent hash</dt>
                              <dd>
                                <code>{ledger.parent_hash}</code>
                              </dd>
                              <dt>State root</dt>
                              <dd>
                                <code>{ledger.state_root}</code>
                              </dd>
                            </dl>
                            {variants.map((variant) => (
                              <p key={variant.export_id}>
                                Export #{variant.export_id}
                                <code>SHA-256 {variant.payload_sha256}</code>
                              </p>
                            ))}
                          </details>
                          {ledger.trust === "verified_trusted" && (
                            <p>
                              Tree and Payment checks passed for the same
                              export. Skipped Payments remain outside
                              verification. This covers tree consistency and
                              supported Payment accounting; other transaction
                              semantics and network consensus remain unverified.
                            </p>
                          )}
                          {trustSucceeded && (
                            <p className="inline-result" role="status">
                              Ledger trusted as an operator anchor. Proof
                              results are unchanged.
                            </p>
                          )}
                          {openLedger === ledgerKey(ledger) &&
                            selection.ledger === ledgerKey(ledger) &&
                            selection.job && (
                              <div className="inline-result" aria-live="polite">
                                {jobDetail.error && (
                                  <p role="alert">{jobDetail.error}</p>
                                )}
                                {result && resultMatchesRow ? (
                                  <JobResult
                                    job={result}
                                    base={base}
                                    exportIds={variants.map(
                                      (variant) => variant.export_id,
                                    )}
                                    enabled={enabled}
                                    cancel={() =>
                                      void run({
                                        kind: "cancel_job",
                                        bundle: selection.bundle,
                                        id: result.job_id,
                                      })
                                    }
                                  />
                                ) : (
                                  <p>
                                    {result
                                      ? "The job has not pinned an export for this ledger yet."
                                      : `Loading check #${selection.job}…`}
                                  </p>
                                )}
                              </div>
                            )}
                          {!variants.length && (
                            <p className="help">
                              A captured export is required for verification.
                            </p>
                          )}
                        </div>
                      </li>
                    </Fragment>
                  );
                })}
                {fetchPending &&
                  (fetchingIndex !== nextIndex || !showNextRow) &&
                  (!rows.length ||
                    fetchingIndex > Number(rows.at(-1)!.ledger_index)) &&
                  currentPage === pageCount &&
                  pendingFetchRow()}
              </ol>
              {showNextRow && currentPage === pageCount && (
                <div
                  className="next-ledger ledger-main"
                  aria-label="Next ledger not fetched"
                >
                  <div className="ledger-index-group">
                    <span className="next-index">
                      {nextIndex!.toLocaleString()}
                    </span>
                    {fetchingIndex === nextIndex && fetchStatus()}
                  </div>
                  {nextLedgerButton()}
                </div>
              )}
              {!fullLedgers.length && (
                <div className="empty">
                  <h3>
                    {ledgers.updated
                      ? "No complete ledgers yet"
                      : "Loading ledgers…"}
                  </h3>
                  <p>Fetch a ledger to store its full state here.</p>
                </div>
              )}
              {pageCount > 1 && (
                <div className="pagination" aria-label="Ledger pagination">
                  <span>
                    Showing {(currentPage - 1) * 50 + 1}–
                    {Math.min(currentPage * 50, listLedgers.length)} of{" "}
                    {listLedgers.length}
                  </span>
                  <div>
                    <button
                      disabled={currentPage === 1}
                      onClick={() => setPage(currentPage - 1)}
                    >
                      Previous
                    </button>
                    <button
                      disabled={currentPage === pageCount}
                      onClick={() => setPage(currentPage + 1)}
                    >
                      Next
                    </button>
                  </div>
                </div>
              )}
            </section>
          </section>
        ) : (
          <section id="jobs-view" role="tabpanel" aria-labelledby="tab-jobs">
            <JobsView
              tasks={tasks.data ?? []}
              jobs={jobs.data ?? []}
              openTask={openTask}
              openJob={openJob}
              enabled={enabled}
              cancel={(resource, id) =>
                void run({
                  kind: resource === "task" ? "cancel" : "cancel_job",
                  bundle: selection.bundle,
                  id,
                })
              }
            />
          </section>
        )}
        {taskId && (
          <div
            id="task-result"
            className="ledger-popover task-result"
            popover="auto"
            aria-label="Fetch job details"
            aria-live="polite"
          >
            <header>
              <h2>Fetch #{taskId}</h2>
              <button
                popoverTarget="task-result"
                popoverTargetAction="hide"
                aria-label="Close fetch details"
              >
                ×
              </button>
            </header>
            {liveTask?.task_id === taskId ? (
              <TaskResult
                task={liveTask}
                enabled={enabled}
                cancel={() =>
                  void run({
                    kind: "cancel",
                    bundle: selection.bundle,
                    id: taskId,
                  })
                }
                retry={() =>
                  void run({
                    kind: "retry",
                    bundle: selection.bundle,
                    id: taskId,
                  })
                }
              />
            ) : (
              <p>Loading fetch #{taskId}…</p>
            )}
            {taskDetail.error && <p role="alert">{taskDetail.error}</p>}
            {streamError && <p className="muted">{streamError}</p>}
          </div>
        )}
        {selection.job && !selectedRow && (
          <div
            id="history-result"
            popover="auto"
            onToggle={(event) =>
              setHistoryOpen(event.currentTarget.matches(":popover-open"))
            }
            className="ledger-popover"
            aria-label="Verification result"
            aria-live="polite"
          >
            <header>
              <h2>Check #{selection.job}</h2>
              <button
                popoverTarget="history-result"
                popoverTargetAction="hide"
                aria-label="Close verification result"
              >
                ×
              </button>
            </header>
            {historyOpen && result ? (
              <JobResult
                job={result}
                base={base}
                enabled={enabled}
                cancel={() =>
                  void run({
                    kind: "cancel_job",
                    bundle: selection.bundle,
                    id: result.job_id,
                  })
                }
              />
            ) : (
              <p>Loading check #{selection.job}…</p>
            )}
            {jobDetail.error && <p role="alert">{jobDetail.error}</p>}
          </div>
        )}
      </main>
      {review && (
        <ReviewDialog
          key={`${review.bundle}:${ledgerKey(review.ledger)}:${review.kind}`}
          review={review}
          variants={exports.data ?? []}
          network={health.data?.network_id}
          enabled={
            enabled &&
            (review.kind === "trust" ||
              (hasVerificationState(review.ledger, ledgers.data ?? []) &&
                !!exports.data?.some(
                  (variant) =>
                    variant.ledger_index === review.ledger.ledger_index &&
                    variant.ledger_hash === review.ledger.ledger_hash,
                )))
          }
          busy={busy}
          error={reviewError}
          close={() => {
            if (!busy) setReview(undefined);
          }}
          submit={(command, variant) => void run(command, variant)}
        />
      )}
    </div>
  );
}
function ReviewDialog({
  review,
  variants,
  network,
  enabled,
  busy,
  error,
  close,
  submit,
}: {
  review: Review;
  variants: Export[];
  network?: number;
  enabled: boolean;
  busy: boolean;
  error: string;
  close: () => void;
  submit: (command: Command, variant?: Export) => void;
}) {
  const choices = variants.filter(
    (variant) =>
      variant.ledger_index === review.ledger.ledger_index &&
      variant.ledger_hash === review.ledger.ledger_hash,
  );
  const [exportId, setExportId] = useState(
    choices.length === 1 ? choices[0].export_id : "",
  );
  const [reason, setReason] = useState("");
  const variant = choices.find((choice) => choice.export_id === exportId);
  const title =
    review.kind === "trust"
      ? "Trust ledger"
      : review.kind === "merkle"
        ? "Verify tree"
        : "Verify payment";
  return (
    <Dialog
      title={`${title} ${Number(review.ledger.ledger_index).toLocaleString()}?`}
      close={close}
    >
      <p className="muted">
        {review.kind === "trust"
          ? "Use this exact ledger as an operator trust anchor. This does not create a proof or establish consensus."
          : review.kind === "merkle"
            ? "Check Merkle state consistency with Lean and an axiom audit. An exact trusted parent or checked lineage is required."
            : "Check supported Payments with Lean and report skipped Payments. Tree consistency is checked separately; other transaction semantics are not verified."}
      </p>
      {review.kind !== "trust" && (
        <ProofViewer kind={review.kind} base={`/bundles/${review.bundle}`} />
      )}
      <details className="technical-details">
        <summary>Technical details</summary>
        <dl>
          <dt>Bundle / network</dt>
          <dd>
            {review.bundle} / {network ?? "Unknown"}
          </dd>
          <dt>Ledger hash</dt>
          <dd>
            <code>{review.ledger.ledger_hash}</code>
          </dd>
          <dt>State root</dt>
          <dd>
            <code>{review.ledger.state_root}</code>
          </dd>
        </dl>
        {variant && (
          <p>
            Export #{variant.export_id}
            <code>SHA-256 {variant.payload_sha256}</code>
          </p>
        )}
      </details>
      {review.kind === "trust" ? (
        <label className="field">
          Reason <span className="muted">(optional)</span>
          <input
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder="Operator decision"
            disabled={busy}
          />
        </label>
      ) : (
        <>
          {choices.length > 1 && (
            <label className="field">
              Exact export
              <select
                value={exportId}
                onChange={(event) => setExportId(event.target.value)}
                disabled={busy}
              >
                <option value="">Choose an export</option>
                {choices.map((choice) => (
                  <option key={choice.export_id} value={choice.export_id}>
                    Export #{choice.export_id}
                  </option>
                ))}
              </select>
            </label>
          )}
          {variant && <p className="export">Export #{variant.export_id}</p>}
          {!choices.length && (
            <p>No captured export is available for this ledger.</p>
          )}
        </>
      )}
      {error && (
        <p className="notice error" role="alert">
          {error}
        </p>
      )}
      <div className="dialog-actions">
        <button disabled={busy} onClick={close}>
          Cancel
        </button>
        <button
          className="primary"
          disabled={!enabled || (review.kind !== "trust" && !variant)}
          onClick={() => {
            if (review.kind === "trust")
              submit({
                kind: "trust",
                bundle: review.bundle,
                index: Number(review.ledger.ledger_index),
                hash: review.ledger.ledger_hash,
                reason: reason.trim() || "Operator decision from ledger list",
              });
            else if (variant)
              submit(
                {
                  kind: "verify",
                  bundle: review.bundle,
                  selector: review.ledger.ledger_index,
                  exportId: variant.export_id,
                  checks: [review.kind],
                },
                variant,
              );
          }}
        >
          {busy ? "Submitting…" : `Confirm ${title.toLowerCase()}`}
        </button>
      </div>
    </Dialog>
  );
}
function TaskResult({
  task,
  enabled,
  retry,
  cancel,
}: {
  task: Task;
  enabled: boolean;
  retry: () => void;
  cancel: () => void;
}) {
  const progress = task.progress;
  return (
    <>
      <div className="result-heading">
        <strong>
          Fetch #{task.task_id}
          {progress
            ? ` · Ledger ${progress.ledger_index.toLocaleString()}`
            : ""}
        </strong>
        <Badge value={task.status} />
        {active(task.status) && (
          <button disabled={!enabled || task.cancel_requested} onClick={cancel}>
            {task.cancel_requested ? "Cancelling…" : "Cancel task"}
          </button>
        )}
        {["failed", "interrupted", "cancelled"].includes(task.status) && (
          <button disabled={!enabled} onClick={retry}>
            Retry fetch
          </button>
        )}
      </div>
      {active(task.status) && progress && (
        <>
          <p className="muted">
            {label(progress.phase)} · {progress.transport.toUpperCase()} ·{" "}
            {progress.entries.toLocaleString()} entries ·{" "}
            {progress.nodes.toLocaleString()} nodes
            {progress.incremental
              ? ` · ${progress.reused_subtrees.toLocaleString()} subtrees reused`
              : ""}
          </p>
          {progress.transport === "rpc" && progress.phase !== "rpc_retry" ? (
            <progress
              aria-label="RPC keyspace scanned"
              max={1000}
              value={Math.min(999, progress.keyspace_permille)}
            />
          ) : (
            <progress aria-label="Fetching ledger" />
          )}
          {progress.retry_attempt > 0 && (
            <p className="notice">
              RPC retry #{progress.retry_attempt} · {progress.retry_delay_ms} ms
              · {progress.last_error}
            </p>
          )}
        </>
      )}
      {task.error && <p className="error-text">{task.error}</p>}
      {task.status === "succeeded" && (
        <p>Fetch complete. The ledger list refreshes automatically.</p>
      )}
      <details>
        <summary>Fetch details</summary>
        <Json
          value={{
            request: task.request,
            resolved: task.resolved_request,
            result: task.result,
            retry_of: task.retry_of,
          }}
        />
      </details>
    </>
  );
}
function PaymentSummary({ report }: { report: unknown }) {
  if (!report || typeof report !== "object") return null;
  const r = report as Record<string, unknown>;
  const checked = r.payments_verified;
  const skipped = r.payments_skipped ?? r.payments_unsupported;
  const failed = r.payments_failed;
  if ([checked, skipped, failed].some((count) => typeof count !== "number"))
    return null;
  return (
    <p className="muted">
      {String(checked)} Payments checked · {String(skipped)} skipped ·{" "}
      {String(failed)} failed
    </p>
  );
}
function AttemptProof({
  kind,
  base,
  job,
  verification,
  status,
}: {
  kind: ProofKind;
  base: string;
  job: string;
  verification: string;
  status: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const details = ref.current?.closest("details");
    const update = () => setVisible(!!details?.open);
    update();
    details?.addEventListener("toggle", update);
    return () => details?.removeEventListener("toggle", update);
  }, []);
  return (
    <div ref={ref}>
      {visible && (
        <ProofViewer
          kind={kind}
          base={base}
          status={status}
          attempt={{ job, verification }}
        />
      )}
    </div>
  );
}
function PaymentReasons({ report }: { report: unknown }) {
  if (!report || typeof report !== "object") return null;
  const transactions = (report as Record<string, unknown>).transactions;
  if (!Array.isArray(transactions)) return null;
  return (
    <>
      {transactions
        .filter(
          (tx) =>
            tx &&
            typeof tx === "object" &&
            ["unsupported", "failed"].includes(tx.status),
        )
        .map((tx, index) => (
          <p key={index} className="payment-reason">
            Payment {String(tx.transaction_index ?? tx.index ?? index)} ·{" "}
            {String(tx.status)}:{" "}
            {String(
              tx.reason ?? tx.error ?? "See technical report for details",
            )}
          </p>
        ))}
    </>
  );
}
function JobResult({
  job,
  base,
  exportIds,
  enabled,
  cancel,
}: {
  job: JobDetail;
  base: string;
  exportIds?: string[];
  enabled: boolean;
  cancel: () => void;
}) {
  return (
    <>
      <div className="result-heading">
        <strong>Check #{job.job_id}</strong>
        <Badge value={job.status} />
        {active(job.status) && (
          <button disabled={!enabled || job.cancel_requested} onClick={cancel}>
            {job.cancel_requested ? "Cancelling…" : "Cancel job"}
          </button>
        )}
      </div>
      {job.error && <p className="error-text">{job.error}</p>}
      {active(job.status) && (
        <p className="muted">
          {job.cancel_requested
            ? "Stopping verification…"
            : "Waiting for kernel compilation and the axiom audit…"}
        </p>
      )}
      {job.items
        .filter((item) => !exportIds || exportIds.includes(item.export_id))
        .map((item) => (
          <p key={item.ledger_index} className="job-item">
            Ledger {Number(item.ledger_index).toLocaleString()} · Export #
            {item.export_id || "pending"} <Badge value={item.status} />
            {item.error && <span className="error-text">{item.error}</span>}
          </p>
        ))}
      {job.verifications
        .filter(
          (attempt) => !exportIds || exportIds.includes(attempt.export_id),
        )
        .map((attempt) => (
          <div key={attempt.verification_id}>
            {attempt.kind === "payments" && (
              <PaymentSummary report={attempt.report_json} />
            )}
            <details className="attempt">
              <summary>
                {label(attempt.kind)} result <Badge value={attempt.status} />
              </summary>
              {(attempt.kind === "merkle" || attempt.kind === "payments") && (
                <AttemptProof
                  kind={attempt.kind}
                  base={base}
                  job={job.job_id}
                  verification={attempt.verification_id}
                  status={attempt.status}
                />
              )}
              <PaymentReasons report={attempt.report_json} />
              <details className="technical-details">
                <summary>Technical details</summary>
                <h4>Report</h4>
                <Json value={attempt.report_json} />
                <p className="muted">
                  Attempt #{attempt.verification_id} · Export #
                  {attempt.export_id}
                </p>
                <p className="artifact-path">{attempt.attempt_dir}</p>
                <h4>Artifact metadata</h4>
                <Json value={attempt.artifacts_json} />
              </details>
            </details>
          </div>
        ))}
    </>
  );
}
function JobsView({
  tasks,
  jobs,
  openTask,
  openJob,
  enabled,
  cancel,
}: {
  tasks: Task[];
  jobs: Job[];
  openTask: (id: string) => void;
  openJob: (id: string) => void;
  enabled: boolean;
  cancel: (resource: "task" | "job", id: string) => void;
}) {
  const entries = [
    ...tasks.map((task) => ({
      key: `fetch:${task.task_id}`,
      resource: "task" as const,
      cancelRequested: task.cancel_requested,
      id: task.task_id,
      title: `Fetch #${task.task_id}`,
      ledger: task.progress?.ledger_index
        ? `Ledger ${task.progress.ledger_index.toLocaleString()}`
        : label(task.kind),
      status: task.status,
      error: task.error,
      created: task.created_at,
      icon: "fetch" as const,
      open: () => openTask(task.task_id),
    })),
    ...jobs.map((job) => ({
      key: `check:${job.job_id}`,
      resource: "job" as const,
      cancelRequested: job.cancel_requested,
      id: job.job_id,
      title: `${job.checks.map(label).join(" + ")} #${job.job_id}`,
      ledger: `Ledger ${Number(job.from).toLocaleString()}${job.from !== job.to ? `–${Number(job.to).toLocaleString()}` : ""}`,
      status: job.status,
      error: job.error,
      created: job.created_at,
      icon: "merkle" as const,
      open: () => openJob(job.job_id),
    })),
  ].sort(
    (a, b) =>
      Number(active(b.status)) - Number(active(a.status)) ||
      b.created.localeCompare(a.created) ||
      b.id.length - a.id.length ||
      b.id.localeCompare(a.id),
  );
  return (
    <section className="jobs-panel" aria-label="Jobs">
      <div className="list-heading">
        <h2>
          All jobs <span className="count">{entries.length}</span>
        </h2>
        <span>
          {entries.filter((entry) => entry.status === "running").length} running
        </span>
      </div>
      <ul className="jobs-list">
        {entries.map((entry) => (
          <li key={entry.key}>
            <div className="job-list-row">
              <button className="job-row" onClick={entry.open}>
                <Icon name={entry.icon} />
                <span className="job-name">
                  {entry.title}
                  <small>{entry.ledger}</small>
                </span>
                <span className="job-date">
                  {entry.created ? `${entry.created} UTC` : ""}
                </span>
                <Badge value={entry.status} />
              </button>
              {active(entry.status) && (
                <button
                  className="job-cancel"
                  aria-label={`Cancel ${entry.title}`}
                  disabled={!enabled || entry.cancelRequested}
                  title={
                    !enabled
                      ? "Connect a wallet and refresh the backend to cancel"
                      : undefined
                  }
                  onClick={() => cancel(entry.resource, entry.id)}
                >
                  {entry.cancelRequested ? "Cancelling…" : "Cancel"}
                </button>
              )}
            </div>
            {entry.error && <p className="job-error">{entry.error}</p>}
          </li>
        ))}
      </ul>
      {!entries.length && (
        <div className="empty">
          <h3>No jobs yet</h3>
          <p>Fetch or verify a ledger to start a job.</p>
        </div>
      )}
    </section>
  );
}
