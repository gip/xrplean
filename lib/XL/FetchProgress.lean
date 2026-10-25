import XL.Basic

namespace XL

/-- Entry totals are unknown. Keyspace progress measures the sorted key prefix scanned. -/
structure FetchProgress where
  ledgerIndex : Nat
  ledgerNumber : Nat := 1
  ledgersTotal : Nat := 1
  phase : String := "checking_node"
  pages : Nat := 0
  entries : Nat := 0
  stateBytes : Nat := 0
  elapsedMs : Nat := 0
  keyspacePermille : Nat := 0
  rpcMs : Nat := 0
  localMs : Nat := 0
  transport : String := "rpc"
  peerMs : Nat := 0
  nodes : Nat := 0
  pending : Nat := 0
  incremental : Bool := false
  baseLedgerHash : String := ""
  reusedSubtrees : Nat := 0
  resumed : Bool := false
  checkpointEntries : Nat := 0
  runEntries : Nat := 0
  runElapsedMs : Nat := 0
  retryAttempt : Nat := 0
  retryDelayMs : Nat := 0
  lastError : String := ""

def FetchProgress.json (p : FetchProgress) : Lean.Json :=
  obj [("event",str "progress"),("ledger_index",Lean.toJson p.ledgerIndex),
    ("ledger_number",Lean.toJson p.ledgerNumber),("ledgers_total",Lean.toJson p.ledgersTotal),
    ("phase",str p.phase),("pages",Lean.toJson p.pages),("entries",Lean.toJson p.entries),
    ("state_bytes",Lean.toJson p.stateBytes),("elapsed_ms",Lean.toJson p.elapsedMs),
    ("keyspace_permille",Lean.toJson p.keyspacePermille),
    ("rpc_ms",Lean.toJson p.rpcMs),("local_ms",Lean.toJson p.localMs),
    ("transport",str p.transport),("peer_ms",Lean.toJson p.peerMs),
    ("nodes",Lean.toJson p.nodes),("pending",Lean.toJson p.pending),
    ("incremental",.bool p.incremental),("base_ledger_hash",str p.baseLedgerHash),
    ("reused_subtrees",Lean.toJson p.reusedSubtrees),
    ("resumed",.bool p.resumed),("checkpoint_entries",Lean.toJson p.checkpointEntries),
    ("run_entries",Lean.toJson p.runEntries),("run_elapsed_ms",Lean.toJson p.runElapsedMs),
    ("retry_attempt",Lean.toJson p.retryAttempt),("retry_delay_ms",Lean.toJson p.retryDelayMs),
    ("last_error",str p.lastError)]

end XL
