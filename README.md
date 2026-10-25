# xrplean · XL

From “code is law” to “spec is law.” leanXRPL uses Lean to produce machine-checked proofs that XRPL transactions satisfy explicit security and compliance specifications.

Financial institutions need to protect assets, enforce policies and demonstrate that their controls work. Today, these responsibilities sit across custody platforms, proprietary systems and audit processes. leanXRPL explores how formal verification can provide a shared foundation: precise specifications, independently checkable proofs and evidence tied to concrete transactions.

The opportunity spans the XRPL ecosystem and the institutions using it. Developers gain reusable specifications for ledger primitives and payment behavior. Financial institutions gain a path toward stronger controls, clearer audit evidence and lower operational risk.

We are developing this vision across three layers:
- Ledger integrity: verify that exported state changes connect a trusted starting state to the resulting Merkle root.
- Payment correctness: prove that supported payments satisfy defined accounting rules, expanding coverage over time.
- Institutional compliance: express institution-defined policies as formal specifications and require evidence that a transaction satisfies them before authorization.
The prototype already supports Lean-checked Merkle replay, bounded Payment accounting and unsigned batch certificates that bind a defined policy to exact transaction bytes. These establish specific properties within an explicit scope; network consensus remains a separate guarantee.

The longer-term ambition is to bring verification into secure hardware, making proof of policy satisfaction a condition for authorizing a transaction. For institutions, the business value is compliance embedded in the transaction workflow: controls enforced before assets move, with verifiable evidence for subsequent review.

Why now? AI-assisted proof construction is making formal methods more practical. AI can help write specifications and construct proofs, while Lean’s kernel checks that each proof establishes its stated claim. This supports a shift toward specifications as operational controls.

Our architectural vision is a small XRPL core surrounded by reusable, independently verifiable specifications. For the ecosystem, that means stronger foundations for building financial applications. For institutions, it means a path to adopting XRPL with security and compliance controls they can inspect, enforce and demonstrate.

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
