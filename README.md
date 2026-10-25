# xrplean · XL

XL is a Lean 4 application for collecting XRPL ledgers and checking state transitions
from an explicitly trusted starting ledger. **XLB** owns the HTTP API, SQLite data,
and durable verification queue. **XLC** is its HTTP command-line client. The frontend
provides a compact local ledger list.

Operator trust, Merkle proofs, and Payment coverage are independent records. Data
received from xrpld starts untrusted. A successful proof never silently grants
operator trust, and receipt never counts as verification.

## Build

Install the toolchain pinned in `lean-toolchain` (Lean 4.34.1), a C/C++ compiler,
Python 3, `pkg-config`, OpenSSL, SQLite and Boost development libraries, and `curl`. NuDB 2.0.9 headers
are bundled under `vendor/nudb/`.
On macOS, use Homebrew SQLite (`brew install sqlite openssl boost pkg-config`). On
Debian/Ubuntu, install `build-essential libssl-dev libsqlite3-dev libboost-thread-dev libboost-chrono-dev libboost-atomic-dev pkg-config curl python3`.

```sh
lake build
./xl serve --help
./xl --help
```

No dependency on the reference checkout is required after scaffolding. The source
layout separates components:

```text
XLB/        API, acquisition, persistence, queue, proof orchestration
XLC/        HTTP CLI and backend launch command
lib/XL/     shared configuration, transport, persistence/process interfaces
LeanXRPL/   reused Lean decoding, state trees, Payment model and pure proof definitions
native/     OpenSSL, SQLite/process bridges and NuDB node storage
vendor/     pinned NuDB headers and license
tools/      certificate generation and independent export/literal binding checks
tests/      deterministic integration and acquisition tests
fixtures/   small synthetic reference ledgers and state witnesses
docs/       architecture and source provenance
```

## Start and collect

Use `./xl` for both CLI commands and backend lifecycle management. It builds the
Lean executables when needed and works when invoked from another directory.

```sh
./xl start                  # Ensure the current XLB is running in the background.
./xl status
./xl ledger show
./xl stop
./xl start
# Or keep XLB in the current terminal:
./xl serve --data .xl --listen 127.0.0.1:4001 --rpc http://127.0.0.1:5005 --network-id 0
```

Background logs live in the selected data directory as `backend.log`. `start`
builds as needed, starts XLB if stopped, and keeps a current backend running. If
the executable content or requested settings changed, it stops the old backend
gracefully and starts the current one. Saved listen/RPC/network settings are reused
unless overridden, including after `stop`. `restart` is an alias for `start`;
it is not needed after rebuilding. `stop` and `status` manage backends launched by `./xl start`; stop a
foreground `serve` with Ctrl+C. Use the same `--data DIR` when managing a custom
instance. The launcher verifies PID start time and command before signalling it.
The existing `lake exe xlb` and `lake exe xlc` entry points remain available.

If the dashboard reports a response timeout, XLB may still be running and busy;
inventory refreshes automatically. Check `./xl status` and `./xl health` before
restarting. A failed mutation response may follow durable acceptance: inspect
`./xl task show` / `./xl job show` before submitting it again. XLB keeps health
probes available when its eight application request slots are full and rejects
excess application requests with 503 before running their handlers. Startup
installs metadata indexes so export inventory polling avoids large payloads.

`--project-root DIR` lets XLB locate its pinned Lean environment and proof tools
when launched elsewhere. Keep this source checkout and its compiled modules
available while proving. Use one XLB per data directory; a process lock prevents
concurrent backend workers. The v1 API binds to loopback and has no authentication.

Configure the modified xrpld instance:

```ini
[ledger_export]
url=http://127.0.0.1:4001/ledgers
persist=1
```

XLB accepts the existing schema-version-1 webhook. It validates the envelope and
returns HTTP 204 only after committing the complete payload to SQLite. Exact
retries deduplicate. Distinct payloads and competing hashes remain separate export
variants. Reception does not queue verification. Each request is limited to 64 MiB.
Storage failures return 503 so xrpld's durable outbox can retry.

```sh
./xl health
./xl ledger show
./xl export show
./xl ledger receive --file exported-ledger.json
# Point any client command at another local backend:
./xl job show --backend http://127.0.0.1:4002
```

Commands use `./xl <resource> <action>` with named selectors: `--index` for ledger
indices or inclusive `START:END` ranges, `--id` for task/job IDs, and `--file` for
input files. Global `--backend` and `--bundle` options may appear before or after
the command; `-b` and `-i` abbreviate `--bundle` and `--index`. `show` lists records;
`job show --id ID` and `task show --id ID` return one record. `ledger show --index INDEX` filters the inventory while retaining fork variants; add `--hash` to select
an exact fork. `bundle show` lists bundles; `bundle show --bundle NAME` reports
one bundle. `list` is also accepted for inventory commands.

The earlier flat commands (`fetch`, `ledgers`, `exports`, `receive`, `trust`,
`verify`, `jobs`, `job ID`, `tasks`, `task ID`) and `state new/update/info/list`
remain compatibility aliases. Backend lifecycle stays at the top level.

## Retrieve ledgers and bootstrap state

State is organized into **bundles**, following leanxrpl's named state-history model.
Exports and ledger identities are shared. Each bundle has one content-addressed
node store with multiple retained ledger roots. Download checkpoints, operator
trust anchors and proof progress are independent per bundle.
Bundle names contain 1–64 ASCII letters, digits, hyphens or underscores. Names that
differ only by case cannot coexist. Existing commands select `default`; its data
paths and migrated proof/anchor IDs are preserved. Named bundles keep their state
and proof artifacts under the backend data directory's `bundles/NAME/` directory.

```sh
./xl bundle new --bundle main --index latest
./xl bundle update --bundle main --index latest
./xl bundle update -b main -i :107881000
./xl bundle show -b main
./xl bundle show
# Ledger commands accept the same bundle selector:
./xl ledger get --index 107881001 --state --bundle main
./xl ledger trust --bundle main --index 107881001 --hash EXACT_LEDGER_HASH
./xl ledger verify --bundle main --index 107881002 --checks merkle,payments
```

`new` starts or resumes a base acquisition. `update` requires a completed base in
that bundle and acquires each successive ledger through the requested target,
including intervening ledgers for `latest` or a later index. Explicit update
intervals must begin immediately after the retained tip. Intervals are inclusive
and limited to 10,000 ledgers per invocation. Every header must extend the exact
previous hash; a gap or fork mismatch stops the range. A second bundle starts its
own acquisition and does not implicitly borrow another bundle's state or trust.
`bundle show --bundle NAME` reports retained intervals, gaps and unfinished
attempts. Commands return JSON; acquisition progress remains on stderr.

Acquisitions are durable XLB tasks. The CLI submits work over HTTP and observes
progress; closing the CLI or pressing Ctrl+C leaves acquisition running in XLB.
Use `--detach` to return a task ID immediately. `--no-progress` waits quietly for
the result. Task listing includes queued, running, succeeded, failed, interrupted and cancelled
acquisitions across all bundles; an explicit bundle selector filters it. Detail
includes saved progress, the exact resolved request, result, error and timestamps.

```sh
./xl bundle new --bundle aaa --index latest --detach
./xl task show --running              # Queued and running acquisitions.
./xl task show --done                 # Succeeded, failed, interrupted and cancelled history.
./xl task show --bundle aaa
./xl task show --id 12
./xl task wait --id 12                  # Attach to progress and wait for the result.
./xl task cancel --id 12                # Stop queued/running acquisition; preserve its checkpoint.
./xl task retry --id 12                 # Retry failed/interrupted/cancelled work with a new ID.
./xl ledger get --index 1233 --state --detach
```

XLB runs acquisition separately from HTTP observers and the proof worker, with one
acquisition at a time. Each bundle can have one queued or running acquisition.
All terminal task histories remain available after backend restarts.
Queued tasks run on restart; an acquisition interrupted by backend shutdown or a
crash is marked `interrupted` and can be retried explicitly. Retries retain the
resolved range (including the original `latest` target) and reuse authenticated
checkpoints; the previous task's history remains intact. Verification continues
to use the separate `job show` / `job show --id ID` commands.

Cancel a task with `./xl task cancel --id ID` or **Cancel task** in the frontend’s
fetch details (open it from the running fetch badge or Jobs tab). Queued work is
cancelled immediately. Running work reports `cancel_requested: true` while it
stops at a safe boundary, then becomes `cancelled`; its bundle stays reserved
until cleanup finishes. In-flight RPC waits and retry backoff observe cancellation.
Committed pages and ledgers remain available, and an explicit retry resumes the
pinned target from its checkpoint. Repeating cancellation is safe; finished tasks
keep their result. Cancellation survives backend restarts and never stops another
task or the backend.

Transient RPC connection errors, timeouts and HTTP 408/429/500/502/503/504 responses
retry in XLB with exponential backoff: 1, 2, 4, 8, 16, then at most 30 seconds.
Retries continue indefinitely while xrpld is unavailable. The task stays running
and resumes automatically on the same pinned request when xrpld returns.
Retry progress reports the attempt, delay and last error. The exact RPC parameters,
ledger hash and page marker stay fixed across retries. Invalid JSON/protocol data,
other HTTP errors, XRPL RPC errors and failed identity/integrity checks fail
immediately. Backend shutdown interrupts the task and preserves its checkpoint.

```sh
./xl start --rpc-backoff-max 30   # Cap in seconds (1..30); settings persist.
# The same option works with ./xl serve. There is no retry-count limit.
```

Legacy `--rpc-retries` arguments and saved finite retry counts are ignored.

**Peer downloads reuse existing full state.** A completed peer or RPC snapshot in
the same bundle and network can supply the base, including a later ledger for a
historical download. XL prefers the exact parent, then the nearest ledger (with
stable index/hash tie breaking). It compares the target tree's commitments against
the complete base at the same radix positions. Equal commitments retain entire
subtrees without visiting their descendants, requesting their nodes, or copying
their payloads. Changed nodes are inserted into the same bundle-wide NuDB store.
A content hash has one catalog entry and one payload, regardless of how many
retained roots reference it. Every published root resolves the full state,
including unchanged objects; no per-ledger payload tree or overlay is created.

Earlier roots remain available. Peer and RPC acquisition each retain their own
checkpoint namespace (identity, frontier or cursor, counters and status) inside
the shared catalog. Node writes and checkpoint changes commit atomically after
NuDB flush. Invalid attempts retain their namespace; retries create a fresh
namespace, sharing authenticated payloads without mixing transport cursors.
An interrupted download resumes its exact target and pinned base. An unfinished
full download without a base can attach a completed snapshot on resume without
discarding saved progress. Range updates still check exact parents. An unchanged
root can complete locally with zero peer requests. Metrics and live progress
report `incremental`, `base_ledger_hash` and `reused_subtrees`; entry/node counters
count newly stored content in that attempt, not the total retained state.

Fresh bundles use `nodes.sqlite3` plus its adjacent `.nodes/` NuDB directory.
An existing full snapshot can be adopted in place with no payload copy. The
backend's `POST /bundles/NAME/state/consolidate` registers that shared store and
removes superseded unpublished transport stores. Legacy multi-store snapshots
are preserved and consolidation refuses them until their payloads are migrated.
`POST /bundles/NAME/state/discard` discards an exact unpublished download selected
by `ledger_index` and `ledger_hash`; it never deletes shared payloads. Explicitly
allowing published-state removal also requires another complete root and rejects
operator anchors and referenced stores. Task and proof history remain available.

These runtime completeness checks do not grant operator trust, establish network
consensus or produce kernel proof receipts. Verification still needs exact captured
exports, actual Lean compilation, and the axiom audit. Merkle verification also
needs an explicit anchor or checked lineage in the same bundle. Unsupported Payment
coverage remains separate.

Ranges are inclusive. XLB uses xrpld's existing `server_info` and binary `ledger`
RPCs to pin the header and transactions. State acquisition can use one configured
XRPL peer connection or paginated binary `ledger_data`. An explicitly reported network ID must match
XLB's configuration. When xrpld omits the optional `server_info.info.network_id`
because `[network_id]` is unset, XLB permits its Mainnet default (0). Other networks
require an explicit network ID from xrpld. Malformed IDs are rejected.

```sh
./xl ledger get --bundle aaa-mainnet --index latest
./xl ledger get --index 1233
./xl ledger get --index 1233:1240
./xl ledger get --index 1233 --state
# Configure your existing node's peer port (2459 on the local development node):
./xl start --peer 127.0.0.1:2459
./xl ledger get --index 1233 --state --transport auto  # Prefer peer; RPC fallback on unavailability
./xl ledger get --index 1233 --state --transport peer  # Require peer; useful for benchmarking
./xl ledger get --index 1233 --state --transport rpc   # Force the paginated RPC path
./xl ledger get --index 1233 --state --hash EXACT_LEDGER_HASH
```

`ledger get --index latest` retrieves the node's latest validated ledger, with
`--state` optional as for a numeric index. XLB resolves `latest` when the queued
task starts and saves the numeric index before retrieval. Retrying that task
retains its original target even if the node's validated tip has advanced.

`auto` is the default. It prefers an explicit `--peer`. Otherwise it uses a peer
port advertised by `server_info.info.ports` on the configured RPC host. It does
not use advertised hostnames, seed discovery or redirects. If no usable peer port
is advertised, or that endpoint is unavailable, it reports the reason and uses
RPC, retaining any partial RPC checkpoint for fallback.
Completed RPC snapshots are reused directly.
XLB connects only to that selected endpoint, with at most one peer session at a
time and four outstanding state requests. It does not discover peers or follow
redirects. Both transports stay pinned to the same network, ledger index/hash,
parent and state root; a fallback never selects a newer ledger. The optional
`ledger_hash` API field / `--hash` CLI flag selects an exact fork for a single
ledger. RPC remains necessary for the initial header and transaction response.

Peer replies supply binary SHAMap nodes directly. Lean checks their content hashes
against already authenticated parent commitments, checks leaf paths, and commits
accepted nodes and the missing-node frontier atomically. Receive bursts are
bounded by 4 MiB or 25 ms. Durable transactions group authenticated nodes and
request reservations for up to one second or 32768 newly stored nodes, and flush
before completion. Progress counts only committed objects; crashes restore the
last committed frontier. Full snapshots request up to three extra
tree levels per path, reducing request overhead; incremental updates retain
depth zero to avoid downloading unchanged siblings. Retry leases are kept in
memory, while missing paths, authenticated nodes and counters remain durable.
Writers use a bounded 128 MiB SQLite cache.
Every commit still synchronizes its WAL, and publication waits for the final
checkpoint.
Capped replies release unserved paths immediately; they do not wait for the
ten-second retry lease. Peer and RPC checkpoint namespaces are separate, so
fallback cannot mix their cursors or frontiers. Disconnections,
rejected handshakes, missing ledgers and stalls permit `auto` fallback; corrupt
nodes, changed identities and malformed replies fail closed. `--peer-timeout 30`
configures seconds without useful node progress before fallback. Partial peer
checkpoints survive shutdown and hard crashes. Invalid attempts are retained and a
retry creates a fresh checkpoint namespace in the same store. The current peer client negotiates XRPL/2.1–2.2 with
compression disabled. A peer snapshot requires every reachable branch, not merely
the presence of the root. It is reported as `peer_snapshot` and remains untrusted.

Progress is displayed automatically on stderr. Terminals get a live bar; redirected
output gets periodic plain-text updates. Final JSON stays on stdout. The display
shows keyspace traversed, received entries/pages/MiB, elapsed time, rate, and separate
RPC/local processing times. The RPC does not report a total entry count, so the
percentage measures the sorted 256-bit keyspace scanned. It reaches 100% only
after the final root comparison and durable snapshot publication. Peer acquisition
reports verified node/object counts and pending paths; its total size is unknown
until completion, so it does not display an estimated percentage.

```sh
./xl ledger get --index 1233 --state --no-progress  # Suppress progress for scripts.
```

Each retrieved ledger stores its binary header, transaction/metadata response, and
identity. Header hashes are recomputed locally. RPC `--state` downloads every
state entry, pins all pages to the same ledger hash, builds the SHAMap locally,
and compares its root with the header before publishing the snapshot. Peer
acquisition authenticates downloaded nodes and completed inherited subtrees against
the pinned root before publishing the complete snapshot. Fetching
and root consistency checks leave operator trust unchanged.

SHAMap node payloads use **NuDB**, with one node catalog per bundle;
NuDB files live beside it under `.sqlite3.nodes/`. SQLite retains the verification
queue, receipts and metadata. No SQLite node-payload fallback is used for new stores.
Set `BOOST_PREFIX` (or `NUDB_PREFIX` to override bundled NuDB) if dependencies are
installed outside the detected Conan/Homebrew/system locations. Existing SQLite
state stores remain readable as historical proof inputs.

A complete snapshot can be large. Fetch is synchronous; individual node RPC calls
time out after 120 seconds. After an interruption or backend restart, rerun the
same `./xl ledger get --index INDEX --state` command. It resumes the exact ledger hash at the
last committed page, restoring the cursor, SHAMap root, counts and progress.
The backend does not restart the HTTP request automatically. Completed snapshots
are reused without downloading their state again. Root mismatches invalidate an
attempt; the next fetch uses a fresh store and retains the failed files for diagnosis.
A node that has pruned the requested ledger returns an explicit error.

State construction batches each sorted page by radix branch, writing shared
ancestors once per page. This avoids storing a separate intermediate root and its
ancestors for every entry. NuDB durability and exact final root comparison remain
required. Resume checkpoints are committed with the node catalog only after NuDB
payloads have flushed. Older partial downloads created before checkpoint support
have no saved cursor and cannot be resumed by this mechanism.

To compare fresh complete snapshots on one node, build XL, then run:

```sh
python3 tools/benchmark_acquisition.py --rpc http://127.0.0.1:5005 \
  --peer 127.0.0.1:2459 --work /private/tmp/xl-acquisition-benchmark
```

Use `--order peer` or `--order rpc` to measure only one transport.
The work directory must be new. The tool freezes one XLB executable, pins one
ledger hash, and runs `peer` and `rpc` sequentially with independent empty stores.
It checks matching roots/object counts, records wall time and component metrics,
and confirms acquisition created no trust anchors or proof receipts. Use
`--ledger-hash HASH` to choose a retained ledger or `--order rpc,peer` to reverse
the order. It leaves temporary stores, progress logs and `report.json` for review;
it does not restart managed XL services or modify xrpld configuration. The node
must retain the pinned ledger until both runs finish. OS/node caches are not
cleared, so ordering and other workloads affect the result. Acquisition timing
does not include construction or kernel checking of transition certificates.

**Historical RPC data and webhook exports are different inputs.** Standard ledger
RPCs do not preserve the full per-transaction before/after images captured by the
modified node. Fetch can bootstrap a parent snapshot and retain historical ledger
data, but transition proving also requires the target ledger's captured export.
This version reports a missing export instead of reconstructing missing execution
history from incomplete metadata. No xrpld changes were needed for the implemented
retrieval and live-export workflows.

To import authenticated paths already obtained from another source:

```sh
./xl state import --index 1233 --hash PARENT_LEDGER_HASH --file witnesses.json
```

The ledger must already be stored. The file is `{"nodes":[{"hash":"HEX","wire":"HEX"},...]}`,
using the reference node-store wire format. XLB recomputes every imported node hash
and checks the declared root is available. Partial paths are allowed; proof replay
fails explicitly if a required path or deletion-collapse witness is missing.
Imports are copied into XLB's own state storage and do not grant trust.

## Establish trust and queue proofs

```sh
./xl ledger trust --index 1233 --hash PARENT_LEDGER_HASH --reason 'Independent checkpoint'
./xl ledger verify --index 1234 --checks merkle,payments
./xl ledger verify --index 1234 --checks payments
./xl ledger verify --index 1234:1240 --checks merkle
./xl job show
./xl job show --id 1
```

`trust` grants an explicit operator trust anchor to a stored ledger's exact
network, index, hash and state-root commitment. It does not fabricate a proof or
check an external consensus certificate. Supply a snapshot or enough paths for
that root before proving its successor.

Each job pins exact export IDs and SHA-256 digests at submission. Missing exports
produce a blocked job; acquire the missing input and submit a new job. Ambiguous
variants require a selection:

```sh
./xl export show
./xl ledger verify --index 1234 --checks merkle --export-id 7
# --hash selects a single fork when that fork has only one payload variant:
./xl ledger verify --index 1234 --checks merkle --hash LEDGER_HASH
```

The single worker processes jobs in order and ledger ranges consecutively. A gap
or failed required check stops that range, leaving later items pending.
Unsupported Payments are skipped and reported while supported Payment checks and
subsequent ledgers continue. Jobs and check attempts record status, errors, timestamps,
input IDs, dependency links, reports and proof-artifact paths. Submit another job
to retry; earlier attempts stay available. Queued work survives restarts. Work
interrupted by shutdown is recorded as interrupted; it needs a new manual job.
Cancel queued or running verification with `./xl job cancel --id ID` (add
`--bundle NAME` for its bundle), or use **Cancel** beside its Tree/Payment row in
the frontend Jobs tab. Fetch rows also expose **Cancel**. Verification details
have a **Cancel job** button. As with other UI actions, connect a wallet first.
Running work shows **Cancelling…** until its subprocess group has stopped.
Cancellation preserves attempt directories and completed kernel receipts, marks
unfinished items/attempts `cancelled`, and prevents a cancelled attempt from
publishing a successful receipt. Submit a new verification job to try again.
Repeated cancellation is safe and terminal jobs stay unchanged. A durable
cancellation request survives a backend crash. SIGINT/SIGTERM stops active proof
subprocess groups and preserves queue history.

Merkle proofs use six parallel hash workers by default. Set `./xl start --proof-jobs 6`
or `./xl serve --proof-jobs 6` to choose 1–64 workers; managed starts retain this
setting. Each worker runs one Lean compiler thread. Hash proofs evaluate the proved
`SHA512Fast` implementation and use its equivalence theorem to establish the
original SHA-512Half statement. Every certificate still requires kernel compilation,
the axiom audit, and the independent exact-input comparison. Witnesses open changed
paths and the surviving sibling chains needed for deletion collapse; other subtrees
remain opaque commitments.

A successful Merkle proof can supply the parent state for another Merkle proof,
with its lineage linked back to the operator anchor. This extends the **verified
state lineage**, while the successor remains operator-untrusted. Retained proof
artifacts are hashed and checked before dependency reuse.

### What each check establishes

- **`merkle`** replays every exported pre-transaction, transaction and
  post-transaction change against authenticated parent paths. It checks exact
  before-images, insertion/deletion rules and the final state root. Pure Lean
  SHA-512Half and Merkle certificates must compile in Lean's kernel, pass the axiom
  audit, and match the exact exported keys, before/after bytes and execution order.
- **`payments`** checks the reused bounded Payment model against the exact pinned
  export independently of Merkle verification. It requires no trust anchor, parent
  snapshot or Merkle receipt. Queue `payments` to run only accounting checks, or
  `merkle,payments` to request both. Supported accounting certificates must compile
  in Lean's kernel and pass the axiom audit. Reports count supported, failed,
  unsupported and non-Payment transactions separately and record
  `state_authentication: "not_checked_by_payments"`. A Payment receipt authenticates
  no state root and supplies no Merkle lineage. Unsupported Payments are recorded
  as skipped with their reasons; a job succeeds when no supported Payment fails.
  An attempt with both checked and skipped Payments has status `supported_checked`;
  an attempt with only skipped Payments has status `no_supported_payments` and
  claims no Payment was verified. Reports include `payments_skipped` and
  `coverage: "supported_payments_only"`. Failures still stop the job and range.

Payment coverage includes ordinary-sequence direct XRP transfers between existing
accounts, exact same-issuer holder-to-holder token transfers without transfer fees,
and limited fee-only `tecPATH_DRY`/`tecPATH_PARTIAL` failures. Partial payments,
paths, conversions, account creation, tickets, batch execution, sponsorship and
other unsupported cases remain visible. General reserves, authorization, amendments,
non-Payment execution, and network consensus are outside these proofs. JSON/binary
parsing and normalization are explicit trust boundaries inherited from the reference
Payment model. Merkle certificates prove the declared state transition; they do
not establish the target ledger's consensus acceptance, header hash, or transaction
tree commitment. Fetched headers and transaction data remain acquisition records.

## Local dashboard

The React/TypeScript dashboard has two tabs: **Ledgers** and **Jobs**. Ledgers
shows complete RPC and peer snapshots in ascending ledger order. Each row shows
its ledger number and small icons for operator trust, bounded Payment verification,
and tree consistency verification.
Checkmarks open results; ledger numbers open commitment and export details in a
popover. Solid lines connect consecutive indices; dashed lines and a missing count
show gaps. These lines describe inventory order, not proven ancestry.

Fetch by index always requests full state. A grey next-ledger row below the final
ledger has a fetch icon that extends the completed bundle tip when the latest
validated ledger is already retained. When the latest validated ledger is farther
ahead, a **Fetch INDEX** button beside the tip's missing count acquires full state
for the immediate next ledger, one step at a time. The node's latest validated
index appears in normal list order, with the same gap connectors as other rows, and refreshes
with status polling every five seconds. Its fetch icon acquires full state for
the displayed index and hash, including in an empty bundle; an exact retained
snapshot gets the Latest validated label on its existing row. Unavailable, stale,
or incompatible node status disables the latest fetch action.
Forks remain separate rows, and an ambiguous tip disables automatic extension. The list
is paginated in groups of 50. Light/dark mode follows the system initially and
remembers the user's selection.

Install Node.js **22.18+** (24 LTS is supported) and pnpm **10.34.5**, then run:

```sh
pnpm --dir frontend install --frozen-lockfile
pnpm --dir frontend run build
./xl start
./xl ui
```

Open **http://localhost:4173**. `./xl ui` runs in the foreground and does not start,
stop or reconfigure XLB. Stop the UI with Ctrl+C; durable backend work continues.
Use `./xl ui --backend http://127.0.0.1:4001 --port 4173` for an explicit fixed
loopback backend, or `./xl ui --dev` for Vite development through the same proxy.
`XL_UI_BACKEND` also configures the upstream. Browser requests cannot select it.
The browser uses same-origin `/api` requests; XLB and xrpld remain on loopback.

Configure wallets before building:

```sh
cp frontend/.env.example frontend/.env
```

Set `VITE_XAMAN_API_KEY` to a registered Xaman application's **public API key**,
and `VITE_XAMAN_RETURN_URL` to its registered return URL, normally
`http://localhost:4173/`. Never include an API secret, seed or private key. Xaman cannot connect without
a registered public application key.
The production build embeds public `VITE_` settings; rebuild after changing them.
Xaman's OAuth/QR flow requires access to its service. Ledger requires Chrome/Edge
with WebHID or WebUSB, an unlocked device with the XRP app open, and Ledger Live
closed. The normal UI registers these two wallet adapters. See the
[XRPL Connect setup](https://xrpl-commons.github.io/xrpl-connect/guide/getting-started.html).

`VITE_WALLET_NETWORK` selects the wallet discovery network (`mainnet`, `testnet`, or
`devnet`, default `mainnet`). Wallet discovery may contact XRPL Connect's configured
public network service. The UI displays the wallet network independently of XLB's
network; connecting never retargets acquisition or verification. Refresh restores
a valid saved wallet session by reconnecting to the provider and reading its account.
Commands stay disabled until that connection succeeds; cached addresses alone do
not unlock submissions. Without a saved session, the UI starts disconnected.
Disconnect clears the remembered session, so refreshing after sign-out stays
signed out. Ledger may require browser permission or its unlocked XRP app, and
Xaman may require renewed authorization when its provider session expires.
A connected account unlocks UI submissions; status/history remain readable. This is connected identity, **not server-verified login**. Local machine
access authorizes backend operations; the existing XLB API remains unauthenticated.
The dashboard never submits a ledger transaction. Xaman manages its own
provider-specific connection/SignIn flow.

Payment actions on the full-state ledger list require an export for the current
hash. Tree actions also require the exact previous ledger's complete state: its
index must be one less and its hash must match the current parent hash. These
prerequisites are rechecked before submission; existing results remain readable
when inputs are unavailable.

Trust and verification take one confirmation. Trust reviews the exact bundle,
network, hash and root. Verification pins an export ID and reviewed SHA-256 digest;
multiple variants require an explicit choice. Payment verification submits only
the Payment check. Tree verification is a separate action and can run before or
after it.
Unsupported Payments and failed checks stay visible in the result popover.
Payment results summarize checked, skipped and failed counts. Partial coverage is
labeled "Supported Payments checked"; earlier unsupported attempts retain their
original status and can be checked again in a new job.
Acquisition, trust, tree consistency and Payment coverage remain independent of
network consensus. Only backend kernel compilation and the axiom audit can produce
successful proof receipts.

The compact header retains the bundle and wallet selectors. The Jobs tab keeps
acquisition and verification history, running work first, with details in popovers
and a **Cancel** button beside each queued or running row.
A small label beside the ledger number identifies its running fetch or verification
job. Verification labels follow the current item and exact export, retaining fork
isolation; fetch progress without complete state uses a grey pending row. Failed,
interrupted and cancelled acquisitions can be retried as new tasks. Selections are
kept in the URL; task streams reconnect using their durable event cursor. Closing the browser
only detaches observers. Errors never trigger automatic mutation retries: inspect
the Jobs tab if a submission loses its response. Artifact paths and hashes are
metadata; the UI does not serve arbitrary backend files. The CLI retains its full
command surface.

Frontend checks (all generated data and browser fixtures are temporary):

```sh
pnpm --dir frontend run build
pnpm --dir frontend test
cd frontend
pnpm exec playwright install chromium
pnpm run test:browser
pnpm run test:backend
```

Browser tests use a development-only identity fixture, plus a real wallet-provider
startup check. The fixture is excluded from the production build. Actual hardware
and Xaman account connections require a device and registered application and must
be validated manually; automated tests do not claim that coverage.

### Speculos development wallet

The optional **Ledger (Speculos · development)** adapter runs the real XRP app in
Ledger's Speculos emulator. Physical Ledger and configured Xaman remain available
in the same wallet picker. Production builds exclude the emulator adapter, and the
production server rejects the Speculos flag. Development mode alone does not
enable it: the server must also receive `--speculos` explicitly.

With Docker Desktop/Engine running, prepare the pinned app and start the emulator:

```sh
./xl speculos prepare
./xl speculos run
```

The first command downloads the exact official XRP source revision and builds it
inside the pinned Ledger development image. It checks the SDK revision and ELF
SHA-256. Subsequent runs reuse that verified build. Source, artifacts and the
manifest live under the system temporary directory's `xrplean-speculos/`, outside
XLB's data. `--directory DIR` selects a different build directory; an incomplete or
mismatched build is retained and requires a fresh directory. The pin currently
uses a Linux ARM64 image (native on Apple Silicon; other hosts need Docker's ARM64
emulation). No container needs privileged mode or access to application data.

The foreground emulator exposes its web display/API only at
**http://127.0.0.1:5000**. Stop it with Ctrl+C. `./xl speculos run --port 5001`
selects another loopback port. In another terminal:

```sh
./xl ui --dev --speculos http://127.0.0.1:5000
```

Use the single frontend URL **http://localhost:4173** in either mode. Stop the
current UI with Ctrl+C before switching its mode; do not run a second frontend.
The development wallet picker supports **Ledger**, **Xaman**, and
**Ledger (Speculos · development)** together. Xaman needs its public application
key before XRPL Connect displays its connection option; missing configuration is
available in the wallet picker. Choose **Connect wallet → Ledger (Speculos · development)**.
Its account is read from the emulator at `44'/144'/0'/0/0`, checked against the
returned public key, and displayed as a development identity. Like the physical
Ledger adapter's connect operation, this is a silent address read; it does not
request transaction approval. The connected account is refreshed every five
seconds; a failed refresh disconnects it. Disconnecting or cancelling an in-flight
connection cannot restore stale identity.

The pinned XRP 2.8.2 app runs on Nano S Plus API level 27 with Speculos 0.27.1.
`tools/speculos-lock.json` records source/image/SDK revisions and the expected ELF
hash. The emulator uses its **built-in public test seed** and produces
`ra7Zr8ddy9tB88RaXL8B87YkqhEJG2vkAJ`. **Never fund this account or enter a real
wallet seed into Speculos.** Emulated identity provides no hardware key protection.
XLB's configured network and trust/proof contracts are unchanged.

The same-origin bridge accepts only the fixed XRP version and silent default
account APDUs. Signing, arbitrary derivation paths, emulator controls and proxy
targets are rejected. Requests have size/deadline/concurrency bounds and are not
retried automatically. This adapter deliberately declares transaction signing,
submission and arbitrary message signing unsupported.

After starting the emulator and development UI, test the actual connection:

```sh
pnpm --dir frontend run test:speculos
```

This uses the real XRP app and XRPL Connect, without a mocked wallet identity.
The regular unit suite checks APDU restrictions, unavailable/malformed/timed-out
emulators and production isolation; browser tests exercise errors and reconnects.
Real USB/browser transport and Xaman account tests still require their actual
providers.

## Test

```sh
make test
```

The tests use temporary data and loopback mock nodes. They run actual Lean kernel
proof checking; they do not substitute successful proof receipts. They cover
webhook retries, manual jobs, trust isolation, lineage, gaps, variants, artifact
tampering, failed roots, restart, historical retrieval, state pagination and
corrupt/mismatched RPC data, NuDB catalogs/payloads, live streaming and terminal
progress, noun/action CLI routing and validation, and launcher lifecycle commands.
`tests/witnesses.py` checks reduced witnesses, nested deletion collapse, parallel
and single-worker certificates, exact input binding and rejection of false or
incomplete certificates through actual kernel compilation.
`tests/cli.py` uses an HTTP recorder to check command routing; proof acceptance
is exercised by the kernel integration tests. Loopback sockets require permission
in restricted sandboxes. See [architecture](docs/architecture.md) for the persistence/API contract
and [reference provenance](docs/reference-files.json) for imported file hashes.
