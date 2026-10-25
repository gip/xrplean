# xrplean (XL)

XL uses Lean 4.34.1, pinned in lean-toolchain. Do not upgrade incidentally.

- XLB/: backend API, acquisition, SQLite orchestration, durable manual verification queue.
- XLC/: HTTP CLI. Keep ledger/database mutations behind XLB.
- lib/XL/: shared types, HTTP transport, SQLite/process FFI declarations.
- LeanXRPL/: selected reference modules copied from ~/gip/AMN/leanxrpl.
- native/: OpenSSL/SQLite/POSIX bridges and reference NuDB node storage.
- vendor/nudb/: pinned NuDB headers and their license; Boost is a build dependency.
- xl: single entry point; start/stop/status/restart manage the local backend.
- tools/: reference certificate generation and independent literal binding verification.
- tests/: deterministic loopback integration tests using real Lean kernel checking.

Build with `lake build`; test with `python3 tests/integration.py` and
`python3 tests/acquisition.py`. Tests use temporary data and loopback mock nodes.
`python3 tests/progress.py` checks streaming/terminal progress; `python3 tests/launcher.py`
checks the single entry point and managed backend lifecycle. State payloads and proof
overlays use NuDB; SQLite retains the queue, metadata/catalog, and portable proof witnesses.
`python3 tests/resume.py` tests hard crashes and atomic page recovery;
`python3 tests/state_tree.py` compares batched snapshot roots, paths and write costs
against the reference importer on temporary NuDB stores.
Proof construction may use Python, but XRPL decoding, replay, policy and the
backend/CLI stay in Lean. All successful proof results require actual compilation
and an axiom audit. Never use sorry, custom axioms, or native_decide in proof paths.

Keep operator trust, kernel-checked Merkle consistency, bounded Payment coverage,
and network consensus separate. A webhook acknowledgment only means durable
receipt. Unsupported Payments must remain visible; other transaction semantics
are not established by Merkle replay. Pin exports by ID/digest, preserve fork
variants, check exact parent index/hash/root/network, and stop a range at gaps
or failed/unsupported required checks. Never overwrite an attempt's artifacts.

Do not scan or commit .xl/, source-repo user databases, keys, or bulk ledger dumps.
Record reference imports in docs/reference-files.json. Consult docs/architecture.md
and README.md when changing API, CLI, persistence or proof contracts.
