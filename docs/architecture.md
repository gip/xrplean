# XL architecture and contracts

XLC sends HTTP requests to XLB. XLB alone owns the application database and the
manual verification worker. Lean owns API routing, RPC decoding, ledger identities,
trust decisions, scheduling, state replay, verification policy and proof receipts.
The native application bridge only provides SQLite execution and a process lock.
Reused native code provides OpenSSL and content-addressed node persistence. Python
constructs Merkle proof source and checks export/literal binding; every accepted
certificate is compiled with the pinned Lean kernel. Generator output is not
accepted as a proof by itself.

## API

All endpoints use JSON. The API is local and unauthenticated. All operations use
the backend's configured network. The response from `GET /health` includes it.
Acquisition checks an explicitly reported `server_info.info.network_id` against
that configuration. xrpld omits this optional field when `[network_id]` is unset;
that case permits only the effective Mainnet default (0). Other networks require
an explicit node network ID. A present malformed or out-of-range ID fails closed.

| Method | Route | Input / result |
|---|---|---|
| GET | `/health` | service and network ID |
| GET | `/status` | cached bounded xrpld observation, independent of acquisition |
| GET | `/ledgers` | identities, trust, state availability and latest check statuses |
| POST | `/ledgers` | existing xrpld export envelope; HTTP 204 after durable receipt |
| GET | `/exports` | export IDs, payload digests and per-export check statuses |
| POST | `/fetch/stream` | NDJSON progress/error events and final result; same inputs as `/fetch` |
| POST | `/fetch` | `from` (index or `"latest"`), optional inclusive `to`, boolean `state`, `transport` (`auto`/`peer`/`rpc`), single-ledger `ledger_hash` |
| POST | `/state/discard` | exact `ledger_index`/`ledger_hash`; discard an inactive acquisition, optional explicit `allow_published` with dependency checks |
| POST | `/state/consolidate` | adopt a full snapshot as the shared bundle store and remove superseded unpublished stores |
| POST | `/state` | `ledger_index`, `ledger_hash`, `nodes` with exact `hash`/`wire` |
| POST | `/trust` | `ledger_index`, `ledger_hash`, optional `reason` |
| POST | `/jobs` | `from`, optional `to`, `checks` array, optional single-ledger `ledger_hash` or `export_id` |
| POST | `/tasks` | `kind` (`fetch`, `state_new`, `state_update`), `request`; HTTP 202 after durable queue insertion |
| GET | `/tasks` | acquisition summaries across this network; bundle-prefixed route filters by bundle |
| GET | `/tasks/ID` | acquisition status, input/resolved request, progress, result, error and timestamps |
| POST | `/tasks/ID/stream` | replay durable NDJSON events, then follow progress; optional `after_seq` cursor |
| POST | `/tasks/ID/wait` | wait for result JSON; does not own execution |
| POST | `/tasks/ID/cancel` | request durable cancellation; returns task JSON (HTTP 200); terminal tasks are unchanged |
| POST | `/tasks/ID/retry` | retry failed/interrupted/cancelled acquisition as a new task with `retry_of` and pinned resolved input |
| GET | `/jobs` | durable job history |
| POST | `/jobs/ID/cancel` | durable, idempotent cancellation of queued/running verification; returns job detail (HTTP 200), scoped to bundle/network |
| GET | `/jobs/ID` | ledger item statuses and individual check attempts/reports/artifacts |

Receipt validation is intentionally limited to the envelope; canonical transaction
and state decoding happens in verification. HTTP 204 never means proof success.
Malformed API inputs return 4xx. SQLite/storage failures return 503. Request framing
rejects duplicate headers, transfer encoding, content encoding and unsupported
expectations. Only Content-Length JSON requests are accepted. Header size is
bounded to 32 KiB, bodies to 64 MiB and slow request reads to 30 seconds. Up to eight
application requests (including streams) can be in flight while the dedicated
verification worker runs. Up to sixteen connections may read requests, leaving
room for direct `GET /health` probes when application slots are full. Excess
application requests receive 503 before their handler runs; no mutation is
submitted by that rejected request.

Export inventory uses a covering metadata index, so polling IDs, digests and
timestamps never traverses stored payload overflow pages. Verification status
lookups have a separate export/kind index. Both indexes are installed on startup
for existing databases without changing stored exports or proof history.

## Local TypeScript frontend

`frontend/` contains the React/Vite state dashboard and a Node TypeScript loopback
server. Dependencies use the pnpm version pinned in `frontend/package.json` and
`frontend/pnpm-lock.yaml`; install with `pnpm --dir frontend install --frozen-lockfile`.
`./xl ui` serves built assets (or Vite middleware with `--dev`) and proxies
an allowlisted `/api` surface to one server-configured loopback XLB origin. The
proxy validates local Host and Origin/Fetch Metadata, rejects arbitrary targets,
forwards explicit Content-Length JSON bodies and relays NDJSON without buffering.
It never opens application databases, invokes ledger commands, serves proof paths,
or implements ledger/proof policy. Production serves only `frontend/dist`; browser
identity fixtures live outside that build. Fonts are bundled locally.

`GET /health` retains its existing contract and does not depend on xrpld.
`GET /status` returns `{service, network_id, xrpld}`. The xrpld object contains
`reachable`, nullable `server_state`, `build_version`, `complete_ledgers`,
`validated_ledger` (`{seq,hash}` or null), reported `network_id`,
`network_compatible`, `error`, `latency_ms`, and `observed_at_unix` (Unix seconds as
a decimal string). Missing fields remain null. A successful HTTP/JSON observation
with an application or network error remains reachable but reports the error;
malformed/unreachable transport reports a failed observation. Omitted network ID
matches only XLB Mainnet (0), following acquisition's effective-default rule.
Node status and validated-tip data are observations, not consensus certificates.

A process-local mutex shares the status observation across all bundle routes.
One `server_info` call uses the configured RPC endpoint, a three-second total
transport deadline and no retries; success and error results are cached for five
seconds after completion. The existing acquisition RPC path keeps its 120-second
attempt deadline and indefinite transient retries. Status never queues acquisition,
changes trust, writes a ledger, or creates proof receipts.

The frontend validates wire responses, preserves string IDs, and decodes embedded
JSON report/artifact fields. Snapshot intervals describe retained complete state;
ledger rows preserve exact forks and exports retain their IDs and SHA-256 digests.
The Ledgers tab includes only `rpc_snapshot` and `peer_snapshot` origins,
ordered numerically with fork variants retained. Consecutive indices have a solid
connector; missing indices have a dashed connector and missing count. This is an
inventory visualization, not ancestry or consensus evidence. Fetch by index always
requests state; Fetch next submits a `state_update` for the retained tip plus one,
and refuses ambiguous tips. When a gap follows the tip, a labeled fetch button
beside the missing count offers the same single-ledger update. It uses the existing
wallet, freshness and active-acquisition guards, including across list pages.
The node's latest validated index joins the ordered,
paginated ledger list with its ordinary gap connectors and follows the five-second
node status poll. Fetch submits a single full-state acquisition pinned to its
displayed index and, when reported, hash. Exact retained snapshots get a Latest
validated label on the existing row rather than a duplicate; the unacquired latest
row does not count as a complete snapshot or expose verification actions.
Unavailable, stale, erroneous, or incompatible node status disables latest fetch.
Details and proof reports open in popovers; icon
checkmarks display successful results. Theme preference persists in local storage.
The Jobs tab combines acquisition and verification history, showing active work
first. Running verification details are polled every two seconds and matched by
current running item, export ID and ledger hash before annotating a ledger row.
Pending range items and other forks do not inherit the running label. Fetch
progress identifies its current index, including a grey row for incomplete state.
Progress and results remain available in popovers from both tabs; the URL retains
the active tab and selected job. The bundle selector uses one centered chevron
with consistent control height in either theme.
Payment controls on the full-state ledger list require an export for the exact
current hash. Tree controls also require a complete snapshot at index N-1 whose
hash matches the current parent. Missing prerequisites hide runnable controls while
retained result checkmarks remain readable. Submission revalidates the applicable
state prerequisites and reviewed export against fresh inventory.
Actions use typed commands. Trust requires a confirmation of the exact stored
commitment. Verification confirms a selected export ID/digest, revalidates it
against fresh inventory before dispatch. Payment and tree actions submit only their
selected check; neither UI action adds the other check. Mutations are never retried
implicitly. A disconnected wallet prevents further UI submissions without
cancelling work already accepted by XLB.

The client allows at most three concurrent requests, including one selected task
stream. Service/inventory observations refresh every five seconds; selected jobs
refresh every two seconds while active and five seconds after termination. Task
observers replay `after_seq`, discard duplicate events and reconnect after a lost
stream. URL selections survive reload; session storage remembers the cursor, while
XLB remains the source of truth. The API still returns full inventories; the UI
filters and renders ledger rows in pages of 50 to bound browser rendering work.
The proxy returns 504 for a backend response timeout and 502 for connection
failures. A timeout reports that XLB may still be busy, and only a refused
connection suggests starting a stopped backend. Failed mutation responses retain
the instruction to inspect durable history before submitting again. The browser
deadline leaves time for the proxy's timeout response to arrive.

XRPL Connect 1.0.0 and its official React binding register Ledger and Xaman
by default. Xaman requires its public application key to connect. An explicitly enabled development server can also register
Ledger (Speculos). Wallet connections are UI identity, not authenticated backend sessions;
no ledger transaction is submitted. Xaman owns its provider-specific SignIn flow. The local API's authorization
boundary is unchanged. Wallet network discovery is configured separately and
cannot change XLB's network. Public Xaman key/return URL configuration is embedded
at build time; secrets must never enter `VITE_` configuration. XRPL decoding,
acquisition, verification policy, scheduling and all application data writes stay
in Lean/XLB. Lean remains pinned to 4.34.1.

### Speculos development identity

`./xl speculos prepare|run` delegates only emulator build/lifecycle to
`tools/speculos.py`. The helper pins the official XRP source, ARM64 Ledger image,
Nano S Plus SDK revision and compiled ELF hash in `tools/speculos-lock.json`.
Downloads and generated artifacts stay in a separate temporary directory. The
emulator uses its built-in public test seed; its default account must never hold
funds. Nothing in this helper reads XLB data or changes trust/proof policy.

`./xl ui --dev --speculos http://127.0.0.1:5000` enables a third wallet alongside
Ledger and Xaman at the same default frontend URL, `http://localhost:4173`.
Xaman stays registered, but XRPL Connect hides its option until the application key
is configured. The UI opens the picker without adding a separate help block. The flag is rejected without `--dev`. The Vite flag
is injected by the server; its build default is false, and `import.meta.env.DEV`
removes the dynamic adapter import from production assets. `/dev/speculos` and
`POST /dev/speculos/apdu` exist only for the opted-in development instance.

The server fixes a numeric HTTP loopback origin at startup, rejects redirects and
cross-origin requests, limits requests to 1 KiB and responses to 4 KiB, allows one
APDU in flight, and applies a three-second deadline. Only the XRP version APDU and
silent secp256k1 default-path address APDU are accepted. This is not an arbitrary
APDU proxy and exposes no signing or emulator-control route. Disconnects abort the
observer request; bridge failures never trigger automatic replay.

The adapter uses LedgerJS's XRP SDK, validates that the returned address derives
from its compressed public key, implements generation-safe cancellation and live
account refresh, and declares all signing capabilities false. The frontend refreshes
a connected emulated account every five seconds and clears identity after failure.
These reads establish connected test identity, not verified backend login, network
consensus or hardware protection. Physical Ledger and Xaman code paths are retained.

XRPL Connect restores its saved provider/session on refresh (`autoConnect: true`)
with the SDK's existing storage and expiry policy. The UI remains disconnected
until the provider responds; a cached address is never sufficient to enable a
command. Speculos opts into the SDK's exact saved-account comparison, in addition
to checking the live public key/address binding. Explicit Disconnect clears saved
state; missing providers, expired sessions and failed reconnects leave the UI
signed out. No backend authentication/session API or private-key storage is added.

## Command line

`xl` keeps `start`, `stop`, `status`, `restart` (compatibility alias), and `serve`
at the top level. XLC uses resource/action commands: `ledger get/show/receive/trust/verify`,
`bundle new/update/show`, `job show/cancel`, `task show/wait/retry/cancel`, `export show`, and
`state import`. Ledger selection uses `--index INDEX` or inclusive `START:END`;
`ledger get` also accepts `latest` for one validated ledger. `bundle new/update`
accept their existing `latest` and `:END` selectors.
Task/job selection uses `--id ID`; imports use `--file PATH` and `--hash HASH`.
`ledger get` retains the fetch contract: headers/transactions by default, complete
state only with `--state`. `show` lists records by default; task/job `--id` selects
a detail record, while ledger `--index`/`--hash` filter without hiding fork variants.
`bundle show` lists bundles unless `--bundle` selects one. Inventory commands also
accept `list`. Old flat and `state new/update/info/list` spellings normalize to the
same dispatcher for compatibility.

Global `--backend` and `--bundle`/`-b` may appear on either side of the command;
`--index` also accepts `-i`. Unknown, duplicate, missing and conflicting options
are rejected before HTTP submission. Output and endpoint contracts are unchanged:
JSON on stdout, progress on stderr, acquisition through durable `/tasks`, proof
submission through `/jobs`. Task inspection without a bundle remains network-wide;
verification jobs retain their existing default-bundle scope. All database and
ledger mutations remain in XLB.

Verification jobs also persist `cancel_requested`. A dedicated monitor supplies
an individual stop flag to replay, Payment iteration and proof subprocesses, so
cancelling one job never stops the worker or backend. Subprocess groups are
terminated and joined before finalization. Finalization checks the request in one
SQLite transaction, marking unfinished items/attempts cancelled while retaining
completed receipts and immutable attempt directories. Proof receipt publication
also checks the request atomically. Queued jobs cancel without starting; claims
are conditional on still being queued. Startup honours crash-left cancellation
requests. Existing jobs tables migrate transactionally, preserving job/item/proof
IDs and foreign keys. The frontend exposes cancellation on every active Jobs row
and in verification details; `./xl job cancel --id ID --bundle NAME` uses the same
endpoint. Repeating cancellation or cancelling a terminal job is harmless.

## Acquisition tasks and RPC transport

Explicit `POST /tasks/ID/cancel` persists `cancel_requested` transactionally.
Queued tasks transition directly to `cancelled` with one terminal error event.
Running tasks keep their active ownership until cooperative cancellation unwinds
acquisition and closes stores/locks; a per-task monitor signals the existing stop
checks in acquisition, RPC waits and retry backoff without setting the backend
stop flag. Finalization atomically checks the durable request, so an accepted
cancellation cannot be overwritten by a racing success or failure. Completed
pages/ledgers remain retained. Cancellation is idempotent, scoped by network and
optional bundle, and terminal tasks remain unchanged. Wait and stream observers
terminate with the cancellation error. Startup finalizes crash-left running tasks
with a cancellation request as cancelled. Existing task tables are rebuilt
transactionally to extend their status CHECK and add the request flag, preserving
IDs, retry links, event sequences and the active-bundle unique index. XLC exposes
`task cancel --id ID`; frontend fetch details expose **Cancel task**, disable it
while cancellation is pending, and allow cancelled work to be retried explicitly.

`acquisition_tasks` and `acquisition_events` are additive tables on schema version 3.
Submission commits a queued task before returning HTTP 202 or starting a legacy
synchronous/streaming response. A partial unique index allows at most one queued
or running task per network/bundle. One backend acquisition runner consumes the
queue in ID order, separately from the verification worker. Task status is queued,
running, succeeded, failed, interrupted or cancelled. Latest/range selection resolves once
and commits `resolved_json` before snapshot acquisition; retries copy this exact
resolved input to a new task and retain the original task's terminal history.
For `fetch`, `from: "latest"` resolves through `server_info.info.validated_ledger.seq`
to one numeric `from`/`to` pair in XLB when execution starts; `to` must be omitted
or also `"latest"`. State remains optional. The saved numeric request is reused
on retry, so a moving tip cannot retarget an already resolved task.
Existing hash-pinned download checkpoints continue to own fork identity and atomic
NuDB page/frontier recovery.

Progress and terminal events are journaled transactionally with the task's current
progress/result/error. HTTP streams replay this journal in bounded batches and
follow it using asynchronous sleeps. Events include `task_id` and `event_seq`.
Observers cannot cancel the runner or invalidate its checkpoint. A broken pipe
only ends that observer. Legacy `/fetch`, `/state/new`, `/state/update` and their
stream variants also submit tasks and wait/observe; their final JSON contracts
are preserved. XLC submits `/tasks` directly, prints the ID on stderr when showing
progress, and can return immediately with `--detach`. Task inspection without an
explicit bundle selector covers the configured network; bundle-prefixed detail,
wait, stream, retry and cancel routes enforce bundle membership.

Backend shutdown stops the active runner and records interruption. Startup also
marks any crash-left `running` task interrupted (or cancelled if cancellation was
requested) and appends its terminal error.
Already queued work remains queued and is picked up on startup. Failed/interrupted/cancelled
work needs explicit retry. Neither acquisition tasks nor their retries grant trust
or proof receipts, and verification job IDs/history remain separate.

The acquisition runner, peer transport and HTTP observers run on `Std.Async`.
Plain HTTP RPC uses its event-loop TCP/DNS transport and `Std.Http.Protocol.H1`
response decoding (Content-Length, chunked or close-delimited), with a 32 KiB
header limit, 64 MiB body limit and 120-second per-attempt deadline. HTTPS retains
curl's certificate verification on a separate IO task. The CLI's HTTP helper
continues to use curl. Lean owns all RPC JSON, identity and integrity checks.

Transient transport failures/timeouts and HTTP 408/429/500/502/503/504 responses
retry indefinitely, keeping the task running until xrpld recovers, the task is cancelled or XLB shuts down.
Each call resends the identical request, including its ledger hash and pagination
marker, so recovery resumes automatically without a new task or target selection.
The delay starts at one second and doubles to a default and hard maximum of
30 seconds. `--rpc-backoff-max` (1..30 seconds) can lower the cap for `serve` and
managed `start`. Delay arithmetic saturates at the cap rather than computing an
unbounded power as the attempt count grows. Old `--rpc-retries` arguments are
accepted without limiting retries; managed startup drops saved finite retry
counts and clamps older saved backoff caps to 30 seconds. Waiting yields to the
event loop and checks shutdown every 50 ms. Retry events retain committed counters
and include `retry_attempt`, `retry_delay_ms` and `last_error`; an upstream outage
never exhausts a retry budget or creates a terminal failure by itself.
Malformed protocol/JSON, permanent HTTP errors, XRPL application errors and failed
header/network/root checks do not retry.

## Persistence

Schema version 4 retains the version 3 bundle scope for `states`, `state_downloads`, `peer_downloads` and
`trust_anchors` by `(bundle, ledger_id)` and tags jobs with their bundle. Ledger
identities and immutable export payloads remain global. Existing schema 1/2 data
migrates transactionally into `default`, preserving anchor, job, export and proof
IDs and existing artifact paths. Foreign keys are checked after migration. Bundle
names are validated ASCII identifiers and cannot collide by case. API routes
`/bundles/NAME/...` select a bundle; unprefixed routes select `default`. `GET
/bundles` and `GET /bundles/NAME/state/info` report bundle metadata. `POST
/bundles/NAME/state/new` and `/state/update` accept an `index` selector; `/stream`
variants use the existing NDJSON progress protocol. XLC's `--bundle`/`-b` applies
to state, trust, job, inventory and verification commands. Shared exports retain
their global IDs/digests while verification summaries are bundle-specific.

The worker reads each queued job's bundle and retains it throughout parent-state,
anchor and lineage lookup and Payment receipt storage. A checked receipt or explicit
anchor in another bundle cannot authorize a Merkle proof. Per-bundle acquisition locks serialize
updates; the backend-wide peer-session lock still permits only one configured peer
connection overall. Bundle updates pin the exact preceding hash and stop at a gap
or fork mismatch. Full-state acquisition does not advance proof/trust status.

`.xl/xl.sqlite3` uses WAL, foreign keys, synchronous FULL and short transactions.
Tables store immutable ledger identities, complete export variants, explicit
operator trust anchors, state-source references, durable jobs/items and all started
verification attempts. SQLite owns export payloads and application metadata; state nodes live in
one content-addressed NuDB store per bundle, with separate proof attempt stores. Their
`.sqlite3` files contain SQLite metadata/catalogs, with NuDB payloads in adjacent
`.sqlite3.nodes/` directories. New stores require NuDB; old SQLite sources can still
be opened read-only. Proof witnesses also use NuDB; the Python certificate generator
receives a separate bounded portable SQLite witness artifact.

Schema version 2 adds `state_downloads`, locating the active NuDB catalog for each
exact ledger identity and recording downloading/complete/invalid status. Existing
schema version 1 databases migrate additively. Each catalog's `xl_download`
metadata contains the version, network, ledger hash/index, reconstructed root,
opaque next marker, last sorted key, pagination-complete flag and progress counters.
An ordered page uses one node transaction for its payload catalog and checkpoint.
NuDB flush precedes SQLite COMMIT, so a crash before COMMIT leaves the previous
cursor/root intact, even if orphan payloads reached disk. Resume reopens the same
store under its writer lock and pins the header RPC to the recorded hash. It never
publishes partial state. Reissuing a completed fetch checks the root and reuses
the store without further state page requests. A root mismatch invalidates the
attempt and retains it; a subsequent request starts a separate checkpoint namespace in the same store. Downloads
from older builds lacking checkpoints are retained, but are not resumable.

Snapshot construction uses `Repository.appendSorted`: pages are partitioned by
radix branch, unchanged children are retained, and each affected ancestor is
persisted once per page. The imported `updateMany` replay path is unchanged.
Both paths use the same node encoding, content hashes and authenticated reads.
Regression benchmarks compare roots and reopened paths against per-entry updates,
exercise deep common prefixes and transaction rollback, and report time and node
writes. They make no claim of consensus or execution verification.

The additive `peer_downloads` table (also installed for existing schema version 2
databases) locates the shared bundle catalog and an independent checkpoint scope per exact ledger identity. `xl_peer`
metadata binds the network, index, ledger hash and state root. The peer importer
uses `acceptStateNode` to authenticate each node against its pending parent
commitment and check radix paths. Node writes, pending-frontier advancement and
counters share a NuDB-flush-before-SQLite-COMMIT transaction. Empty frontier plus
an initialized matching header is required for completion; merely storing a root
is insufficient. After a durable completion marker and checkpoint, XLB publishes
the catalog in `states` with origin `peer_snapshot`. A crash between completion
and publication is repaired by reissuing the same fetch. Invalid attempts retain
their checkpoint namespace and receive a new namespace on retry.

Incremental peer acquisition chooses a completed full snapshot in the same bundle
and network. It prefers the exact parent index/hash, then the nearest ledger with
stable index/hash tie breaking; later snapshots may supply historical downloads.
The selected header hash/index/root and completeness are validated independently
of target ancestry. Range advancement and proof lineage still check exact parents.
Witness imports and partial downloads are ineligible. `xl_peer_base` freezes the
base header, complete source manifest, network and bundle for restart. The full base may be an
RPC snapshot or a peer snapshot. Unchanged subtrees are recognized by equality of
their authenticated hashes at the same radix position; their descendants are not
walked, copied or requested. Requests for changed branches use depth zero to avoid
downloading unchanged siblings. The inherited snapshot's completion, rather than
the presence of an arbitrary cached inner node, permits skipping a whole subtree.

Each bundle has one physical node catalog and one NuDB generation. All its
published `states.sources_json` manifests contain that same single catalog path;
content-addressed nodes are append-only and shared across all retained roots.
There is no per-ledger payload overlay or source index in the new layout.
`bundle_node_stores` registers the path. New bundles use `nodes.sqlite3`; a legacy
full snapshot can be adopted at its existing path without scanning/copying its
payloads. Legacy multi-store snapshots remain readable; consolidation refuses
those manifests until their payloads have been migrated.

Schema 4 removes unique-path constraints from `peer_downloads`/`state_downloads`
and adds `scope`. A fresh scope identifies each transport attempt; old entries
retain the empty legacy namespace. Within the shared node catalog,
`acquisition_pending(scope,id,hash)` holds each frontier,
`acquisition_counters` holds per-attempt counters, and `metadata` keys begin with
`acquisition/SCOPE/`. Native persistence prepares scoped queries; all XRPL
identity, authentication, reuse and completion policy remains in Lean. Global
node counters and scoped checkpoints commit with node catalog visibility in one
SQLite transaction, after NuDB flush. Rollback restores both sets of counters.
Read-only retained roots can pin the shared catalog; scoped writer checkpoints
use passive WAL checkpointing instead of waiting for those readers. WAL commits
remain synchronous FULL. Crash recovery never publishes a partial snapshot.

Resume revalidates the pinned base and its checkpoint binding. An unfinished
checkpoint with a null base may attach an eligible snapshot on resume. Live
progress reports the base hash and reused subtree count. Entirely unchanged
roots complete locally. RPC fallback shares only authenticated node content;
its cursor and the peer frontier stay in separate namespaces. Invalid attempts
cannot overwrite old checkpoint namespaces or grant completeness to arbitrary
cached inner nodes. Neither reuse nor shared storage supplies operator trust,
consensus evidence or kernel certificates.

Explicit discard and consolidation run in XLB under the bundle acquisition lock
and refuse active acquisition/proof jobs. Deletion is pinned to an exact ledger
hash/index. Published roots require explicit `allow_published`, another retained
complete root, no operator anchor and no store references from other states or
proofs. Shared node payloads are never deleted by discard. Legacy unpublished
catalogs are removed only after references are detached and cleanup paths are
recorded durably. Cleanup is limited to registered paths in that bundle's states
directory and can be retried after interruption. Consolidation adopts the full
store and retires superseded unpublished transport stores, preserving task,
ledger, export and proof history.

Only XLB owns the peer connection. `--peer HOST:PORT` selects exactly one endpoint.
Otherwise `server_info.info.ports` may supply a peer port on the configured RPC
host: only a `peer` protocol entry and a port in 1..65535 are accepted. Advertised
host fields are ignored. An explicit peer wins. No seeds, overlay discovery,
redirects, transaction relay or consensus messages are used. A backend-wide session
lock prevents concurrent peer connections across fetches.
The imported Lean transport negotiates signed TLS/HTTP upgrade and XRPL/2.1–2.2;
compression and newer node-reference encodings are not negotiated. At most four
bounded state requests are outstanding on the single connection. The whole
request window is reserved in the same transaction that accepts the received nodes.
Transactions span bounded receive/request cycles, flushing after one second or
32768 newly stored nodes, and always before completion. A final decoded reply
may cross the node limit by its bounded size. Requests can reference already
authenticated uncommitted parents; a crash simply restores the prior committed
frontier. Progress reports only committed counters. Integrity errors roll back
the active batch before invalidating the attempt; graceful interruption commits
authenticated work. Transport EOF is handled after decoding any complete buffered
replies. NuDB flush and FULL-synchronous WAL commit remain one atomic frontier
publication boundary.
Ten-second request leases live in a connection-local in-memory SQLite table;
they only schedule retries and disappear on reopen. The durable `pending` table
still owns every missing path and commitment. The old `pending_due` index is
removed on writable open, and its legacy `due` column is retained for compatibility.
Writers use a 128 MiB page cache and a 16384-page WAL checkpoint threshold.
The cache is a bound, not an upfront allocation.
NuDB detects duplicate inserts; only duplicates require a SQLite visibility
lookup. Uncataloged orphan payloads still require byte comparison before adoption.
New payloads always precede catalog insertion. Synchronous FULL, NuDB flush
ordering and the final truncating checkpoint remain required.
Incoming bursts are bounded by 4 MiB or 25 ms (individual frames retain their
existing size bound). Complete replies are grouped into bounded authenticated
node/frontier transactions. Parents are authenticated before descendants across the batch using 65 linear-time depth
buckets, avoiding quadratic depth-only quicksort on large equal-depth leaf batches.
A reply containing a requested path retires that request and atomically releases
its unserved leases,
so xrpld reply caps do not impose a ten-second stall. Other outstanding requests
retain their leases. NuDB flush still precedes catalog commit. Parsing and
verification remain in Lean; the existing native bridge provides TLS and crypto.
Useful-progress deadlines ignore unrelated gossip. Endpoint errors, rejection,
disconnects, unavailable ledgers or stalls return an explicit fallback reason;
malformed data, wrong ledger identities and failed node authentication abort.

The default `auto` transport prefers an explicit or RPC-advertised peer and reuses
completed RPC snapshots directly. An absent usable port or unavailable peer is
reported in a durable `rpc_fallback` event and in the RPC result
`fallback_reason`. The CLI always prints that event, including its reason.
Fallback uses `ledger_data` with the already pinned header/hash, resuming any
existing partial RPC catalog and cursor. `peer` requires successful
peer acquisition and `rpc` forces pagination. An explicit `ledger_hash` requires
a single ledger; resume without a hash rejects ambiguous fork selections across
either transport. Both transports retain RPC header/transaction acquisition and
strict network-ID checks. Completed peer snapshots are reused without another
connection. No peer certificate is promoted to an operator anchor. Downloading
state and runtime Merkle consistency checks never produce kernel proof receipts;
the existing export-pinned verification pipeline, axiom audit, bounded Payment
coverage and consensus/trust distinctions are unchanged.

Ledger identity is `(network, ledger_hash)` with a fixed index, parent hash and
state root. Sequence numbers alone never select a fork. Identical receipt retries
deduplicate by ledger identity plus payload digest; different payloads remain
separate. Jobs pin one exact export per index and fail closed on ambiguity. SQL
values are quoted centrally and NUL is rejected.

RPC snapshots are published only after rebuilding their complete root; peer
snapshots require the complete authenticated frontier/view described above. Witness
imports authenticate individual nodes and the root, with path completeness checked
when replay needs it. Attempts write fresh state overlays and witnesses. Partial
work from a failed attempt is never published as a valid lineage. Parent stores
are read-only, and all accessed nodes are checked against content hashes.

Proof witness extraction opens each changed path before and after its edit. Only
deletion needs sibling evidence: at a non-root inner node with two occupied slots,
the other slot may become the sole survivor, so its unary chain is opened through
the first leaf or branching inner node. Nodes with three or more occupied slots
cannot collapse from deleting one child, and the root remains an inner node.
Untouched sibling subtrees otherwise remain opaque in the kernel certificate.

Independent hash batches compile with six workers by default (`--proof-jobs`,
1–64, persisted by the managed launcher). Each Lean subprocess uses `-j 1`;
tree/edit chains and root composition retain their dependency ordering. Generated
hash lemmas keep the original `KernelMerkle.nodeHash` statements, using
`SHA512Fast.half_eq` to transfer kernel-evaluated optimized hashes to the reference
SHA-512Half definition. The fast implementation and its universal equivalence
proof are included in retained artifact identities. Compilation, axiom auditing
and independent export/literal binding remain mandatory.

Successful receipts retain source, compiled modules, kernel logs, the input export,
exact root/change reports, witnesses and artifact SHA-256 digests, including the
core proof definitions, compiled proof modules and pinned toolchain identity. Merkle lineage
reuse checks ancestor artifacts recursively and requires the recorded operator
anchor to exist. Each new attempt has its own directory; successful input/proof
artifacts are not overwritten. There is no pruning policy yet.

## Trust and proof progression

Operator trust is an explicit anchor record and remains unchanged by receipt,
acquisition and verification. A Merkle receipt has its own originating anchor and
parent-proof dependency. To prove ledger N, its parent must match exact network,
index N-1, parent hash and state root, and must be either an operator anchor or
have a kernel-checked Merkle lineage back to one. Bounded Payment checks run directly
on the pinned export without a parent snapshot, trust anchor or Merkle dependency.
Their receipts have null `anchor_id` and `parent_verification_id` and report
`state_authentication: "not_checked_by_payments"`. Actual Lean compilation and the
axiom audit remain required. A standalone Payment result proves supported exported
accounting facts; it does not authenticate state commitments or authorize Merkle
lineage. Both checks may be queued together or as separate jobs in either order.

Merkle consistency and supported Payment accounting do not constitute full XRPL
execution verification. Non-Payment transactions may contribute declared state
changes without their execution rules being modeled. Payment jobs check supported
cases and retain unsupported transactions as skipped with their reasons. Skips do
not stop a range. A failed supported check still stops it. Mixed coverage uses
verification status `supported_checked`; only skipped Payments uses
`no_supported_payments`, without claiming a Payment was verified. Jobs and items
succeed when no supported check fails. Reports retain `payments_unsupported`, add
`payments_skipped`, and declare `coverage: "supported_payments_only"`. Neither
status authenticates state or supplies Merkle lineage. Existing attempt statuses
and artifacts remain unchanged. The UI labels mixed coverage "Supported Payments
checked" and displays checked/skipped/failed counts with the detailed report.
The target root comes from the export. Consensus certification,
header proofs and transaction-tree proofs are separate future verification kinds.

## Source reuse

`docs/reference-files.json` records SHA-256 hashes at import time for selected
files copied from `~/gip/AMN/leanxrpl`, which had no Git metadata. The imported Lean
modules retain the `LeanXRPL` namespace. The signed transport is integrated into
XLB; the listener runners, old CLI, live peer discovery and bulk local data were
not copied. Bundle naming/history commands follow the reference model while
remaining HTTP operations owned by XLB. Generic state-view persistence is a local
addition; its policies and XRPL checks remain in Lean.
The node-store native implementation and dependency-discovery script are reused
with NuDB required. NuDB 2.0.9 headers and their Boost license are bundled under
`vendor/nudb/`, with provenance and file hashes. Boost remains a build dependency.

Shared Lean sources live in `lib/XL/` so the root `xl` launcher also works on
case-insensitive filesystems. The launcher delegates ledger commands to Lean XLC
and backend lifecycle to a small POSIX/Python process controller. Background PID
records are bound to process start time and command; stale PID reuse is not signalled.
`start` ensures the managed process uses the current executable SHA-256 and
configuration, reusing its PID when both match and gracefully replacing it when
either changes. `restart` is a compatibility alias with identical behavior.
Successful launches persist settings in `backend-config.json` so `start` can reuse
them after `stop`; `backend-process.json` also records the executable fingerprint
and process identity. Older process records without fingerprints upgrade once.

Task progress streams use close-delimited HTTP NDJSON. XLB's runner commits events
independently of observers; each observer reads a bounded journal page and flushes
events as they become available. Progress counts received state entries and
canonical payload bytes, and reports RPC versus local rebuild time. Keyspace
progress is capped below 100% until root comparison, NuDB flushing and snapshot
publication have succeeded. Errors are terminal events; a disconnected/truncated
stream never produces a successful XLC result, while XLB's task continues.
Redirected progress is throttled and contains no terminal escapes. `--no-progress`
waits for task result JSON without progress output.

The two imported Python tools have small local adaptations: network-neutral
certificate names and case-insensitive comparisons of hexadecimal commitments.
They run with Python isolation enabled so environment optimization cannot disable
their assertion-based input checks. StateTree has an additive sorted snapshot
builder; proof definitions, authenticated path logic and Payment coverage are
unchanged from the imported files.
