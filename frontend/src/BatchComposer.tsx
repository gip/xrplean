import { useRef, useState } from "react";
import { z } from "zod";
import { api } from "./api.ts";
import { useIdentity } from "./identity.ts";
import { refresh, usePoll } from "./usePoll.ts";

const policySchema = z.object({
  enabled: z.boolean(),
  policy_digest: z.string(),
  policy: z.object({
    version: z.number(),
    network_id: z.number(),
    service_address: z.string(),
    service_fee_drops: z.string(),
  }),
});
const attemptSchema = z.object({
  attempt_id: z.string().regex(/^[1-9]\d*$/),
  status: z.enum([
    "queued",
    "running",
    "kernel_checked",
    "failed",
    "interrupted",
  ]),
  error: z.string(),
  created_at: z.string(),
  prepared: z.object({
    transaction: z.object({
      TransactionType: z.literal("Batch"),
      Account: z.string(),
      Fee: z.string(),
      Flags: z.literal(65536),
      Sequence: z.number().int(),
      LastLedgerSequence: z.number().int(),
      SigningPubKey: z.string(),
      NetworkID: z.number().int().optional(),
      RawTransactions: z
        .array(
          z.object({
            RawTransaction: z.object({
              TransactionType: z.literal("Payment"),
              Account: z.string(),
              Destination: z.string(),
              Amount: z.string(),
              Sequence: z.number().int(),
              Flags: z.literal(1073741824),
              Fee: z.literal("0"),
              SigningPubKey: z.literal(""),
            }),
          }),
        )
        .min(2)
        .max(8),
    }),
    unsigned_bytes: z.string(),
    signing_digest: z.string(),
    policy: policySchema.shape.policy,
    policy_digest: z.string(),
    total_debit_drops: z.string(),
    certificate_source: z.string(),
  }),
  report: z
    .object({ artifacts: z.array(z.string()) })
    .passthrough()
    .nullable(),
});
const historySchema = z.array(
  z.object({
    attempt_id: z.string(),
    status: z.string(),
    created_at: z.string(),
  }),
);
const artifactSchema = z.object({
  name: z.string(),
  content: z.string(),
  sha256: z.string(),
});
const emptyPayment = () => ({
  destination: "",
  amount_drops: "",
  sequence: "",
});
const number = (s: string) => {
  if (!/^[1-9]\d{0,9}$/.test(s) || Number(s) > 4294967295)
    throw new Error(
      "Sequences and ledger expiry must be positive uint32 integers.",
    );
  return Number(s);
};

export function BatchComposer({
  attemptId,
  onSelect,
}: {
  attemptId?: string;
  onSelect: (id: string) => void;
}) {
  const identity = useIdentity();
  const identityRef = useRef(identity);
  identityRef.current = identity;
  const policy = usePoll("/batches/policy", policySchema);
  const history = usePoll("/batches", historySchema);
  const detail = usePoll(
    attemptId ? `/batches/${attemptId}` : null,
    attemptSchema,
    1000,
    true,
  );
  const [payments, setPayments] = useState([emptyPayment()]);
  const [advanced, setAdvanced] = useState({
    public_key: "",
    sequence: "",
    service_sequence: "",
    last_ledger_sequence: "",
    network_fee_drops: "",
  });
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [error, setError] = useState("");
  const [submitted, setSubmitted] = useState<{ id: string; draft: string }>();
  const draft = JSON.stringify({
    account: identity.address,
    advanced,
    payments,
    policy: policy.data?.policy_digest,
  });
  const currentDraft = useRef(draft);
  currentDraft.current = draft;
  const result =
    detail.data?.attempt_id === attemptId ? detail.data : undefined;
  const current =
    !!result &&
    submitted?.id === result.attempt_id &&
    submitted.draft === draft &&
    identity.connected;
  const fresh =
    !!policy.updated && Date.now() - policy.updated < 15000 && !policy.error;

  async function prepare() {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setError("");
    try {
      if (!identity.connected || !identity.address)
        throw new Error("Connect a wallet before preparing.");
      if (!policy.data?.enabled || !fresh)
        throw new Error("Refresh and review the configured service fee first.");
      const before = draft,
        address = identity.address;
      const payload = {
        account: address,
        public_key: advanced.public_key,
        sequence: number(advanced.sequence),
        service_sequence: number(advanced.service_sequence),
        last_ledger_sequence: number(advanced.last_ledger_sequence),
        network_fee_drops: advanced.network_fee_drops,
        policy_digest: policy.data.policy_digest,
        payments: payments.map((p) => ({ ...p, sequence: number(p.sequence) })),
      };
      const accepted = await api(
        "/batches/prepare",
        attemptSchema,
        undefined,
        payload,
        () => {
          if (
            !identityRef.current.connected ||
            identityRef.current.address !== address ||
            currentDraft.current !== before
          )
            throw new Error(
              "Draft or wallet changed before preparation; review it again.",
            );
        },
      );
      setSubmitted({ id: accepted.attempt_id, draft: before });
      onSelect(accepted.attempt_id);
      refresh();
    } catch (e) {
      setError(
        `${e instanceof Error ? e.message : String(e)} No automatic retry was sent. Inspect previous preparations before submitting again.`,
      );
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }
  async function download(name: string) {
    if (!result) return;
    try {
      setError("");
      const artifact = await api(
        `/batches/${result.attempt_id}/artifacts/${name}`,
        artifactSchema,
      );
      if (artifact.name !== name) throw new Error("Artifact identity mismatch");
      const hash = Array.from(
        new Uint8Array(
          await crypto.subtle.digest(
            "SHA-256",
            new TextEncoder().encode(artifact.content),
          ),
        ),
        (b) => b.toString(16).padStart(2, "0"),
      )
        .join("")
        .toUpperCase();
      if (hash !== artifact.sha256) throw new Error("Artifact digest mismatch");
      const url = URL.createObjectURL(
        new Blob([artifact.content], { type: "text/plain;charset=utf-8" }),
      );
      const link = document.createElement("a");
      link.href = url;
      link.download = `batch-${result.attempt_id}-${name}`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }
  function payment(
    i: number,
    key: keyof ReturnType<typeof emptyPayment>,
    value: string,
  ) {
    setPayments((old) =>
      old.map((p, n) => (n === i ? { ...p, [key]: value } : p)),
    );
  }
  return (
    <div className="batch-composer">
      <p className="notice">
        Prepare an unsigned all-or-nothing XRP Batch. Wallet connection supplies
        identity only. No signing or submission.
      </p>
      {policy.error && (
        <p role="alert" className="notice error">
          {policy.error}
        </p>
      )}
      {policy.data && (
        <section className="batch-policy" aria-label="Service fee policy">
          <h2>Service fee</h2>
          {policy.data.enabled ? (
            <>
              <p>
                <strong>{policy.data.policy.service_fee_drops} drops</strong>{" "}
                per batch to <code>{policy.data.policy.service_address}</code>.
              </p>
              <p className="muted">
                Network {policy.data.policy.network_id} · Policy{" "}
                {policy.data.policy_digest.slice(0, 16)}…
              </p>
            </>
          ) : (
            <p>
              Batch preparation is disabled. Configure the service address and
              fee in XLB.
            </p>
          )}
        </section>
      )}
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void prepare();
        }}
      >
        <p>
          Source account:{" "}
          <code>
            {identity.connected ? identity.address : "Connect a wallet"}
          </code>
        </p>
        <h2>Payments</h2>
        {payments.map((p, i) => (
          <fieldset className="batch-payment" key={i}>
            <legend>Payment {i + 1}</legend>
            <label>
              Destination
              <input
                required
                value={p.destination}
                onChange={(e) => payment(i, "destination", e.target.value)}
                placeholder="r…"
              />
            </label>
            <label>
              Amount (drops)
              <input
                required
                inputMode="numeric"
                pattern="[1-9][0-9]*"
                value={p.amount_drops}
                onChange={(e) => payment(i, "amount_drops", e.target.value)}
              />
            </label>
            <label>
              Sequence
              <input
                required
                inputMode="numeric"
                value={p.sequence}
                onChange={(e) => payment(i, "sequence", e.target.value)}
              />
            </label>
            <button
              type="button"
              disabled={payments.length === 1}
              onClick={() =>
                setPayments((old) => old.filter((_, n) => n !== i))
              }
            >
              Remove
            </button>
          </fieldset>
        ))}
        <button
          type="button"
          disabled={payments.length >= 7}
          onClick={() => setPayments((old) => [...old, emptyPayment()])}
        >
          Add Payment
        </button>
        <fieldset className="batch-advanced">
          <legend>Transaction details · explicit values, no autofill</legend>
          {(
            [
              ["public_key", "Compressed secp256k1 public key"],
              ["sequence", "Outer sequence"],
              ["service_sequence", "Service Payment sequence"],
              ["last_ledger_sequence", "Last ledger sequence"],
              ["network_fee_drops", "Network fee (drops)"],
            ] as const
          ).map(([key, label]) => (
            <label key={key}>
              {label}
              <input
                required
                value={advanced[key]}
                onChange={(e) =>
                  setAdvanced((old) => ({ ...old, [key]: e.target.value }))
                }
              />
            </label>
          ))}
        </fieldset>
        <button
          type="submit"
          className="primary"
          disabled={
            busy || !identity.connected || !policy.data?.enabled || !fresh
          }
        >
          {busy ? "Creating attempt…" : "Prepare and check in Lean"}
        </button>
      </form>
      {error && (
        <p role="alert" className="notice error">
          {error}
        </p>
      )}
      {history.error && (
        <p role="alert" className="notice error">
          {history.error}
        </p>
      )}
      {!!history.data?.length && (
        <label className="batch-history">
          Previous preparations
          <select
            value={attemptId ?? ""}
            onChange={(e) => {
              if (e.target.value) onSelect(e.target.value);
            }}
          >
            <option value="">Select an attempt</option>
            {history.data.map((a) => (
              <option key={a.attempt_id} value={a.attempt_id}>
                #{a.attempt_id} · {a.status} · {a.created_at}
              </option>
            ))}
          </select>
        </label>
      )}
      {detail.error && (
        <p role="alert" className="notice error">
          {detail.error}
        </p>
      )}
      {result && (
        <section
          className="batch-result"
          aria-label="Batch preparation result"
          aria-live="polite"
        >
          <h2>
            Attempt #{result.attempt_id} ·{" "}
            {result.status === "kernel_checked"
              ? "Kernel checked"
              : result.status}
          </h2>
          <p>
            {current
              ? "Prepared for the current draft."
              : "Previous preparation — this result does not certify the current draft."}
          </p>
          <p>
            <strong>
              {result.status === "kernel_checked"
                ? "Unsigned transaction · policy checked · no funds sent"
                : "Unsigned transaction · no funds sent"}
            </strong>
          </p>
          {result.error && (
            <p role="alert" className="notice error">
              {result.error}
            </p>
          )}
          <dl>
            <dt>Source</dt>
            <dd>{String(result.prepared.transaction.Account)}</dd>
            <dt>Service fee</dt>
            <dd>
              {result.prepared.policy.service_fee_drops} drops →{" "}
              {result.prepared.policy.service_address}
            </dd>
            <dt>Network fee</dt>
            <dd>{String(result.prepared.transaction.Fee)} drops</dd>
            <dt>Outer sequence</dt>
            <dd>{result.prepared.transaction.Sequence}</dd>
            <dt>Ledger expiry</dt>
            <dd>{result.prepared.transaction.LastLedgerSequence}</dd>
            <dt>Total debit</dt>
            <dd>{result.prepared.total_debit_drops} drops</dd>
            <dt>Signing digest</dt>
            <dd>
              <code>{result.prepared.signing_digest}</code>
            </dd>
          </dl>
          <div className="batch-payment-summary">
            <table aria-label="Prepared Payments">
              <thead>
                <tr>
                  <th>Payment</th>
                  <th>Recipient</th>
                  <th>Drops</th>
                  <th>Sequence</th>
                </tr>
              </thead>
              <tbody>
                {result.prepared.transaction.RawTransactions.map(
                  ({ RawTransaction: tx }, i, all) => (
                    <tr key={i}>
                      <td>{i === all.length - 1 ? "Service fee" : i + 1}</td>
                      <td>
                        <code>{tx.Destination}</code>
                      </td>
                      <td>{tx.Amount}</td>
                      <td>{tx.Sequence}</td>
                    </tr>
                  ),
                )}
              </tbody>
            </table>
          </div>
          <p className="muted">
            The certificate checks policy and exact bytes. It does not establish
            wallet ownership, funds availability, execution success, or network
            consensus.
          </p>
          <details>
            <summary>Prepared transaction</summary>
            <pre>{JSON.stringify(result.prepared.transaction, null, 2)}</pre>
          </details>
          <div className="batch-downloads">
            {(result.report?.artifacts ?? []).map((name) => (
              <button
                type="button"
                key={name}
                onClick={() => void download(name)}
              >
                Download {name}
              </button>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
