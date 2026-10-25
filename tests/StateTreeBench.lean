import LeanXRPL.StateTree
import Lean

open LeanXRPL LeanXRPL.StateTree

private def ensure (ok : Bool) (message : String) : IO Unit :=
  unless ok do throw <| IO.userError message

private def objects (count : Nat) : IO (Array (ObjectID × ByteArray)) := do
  let mut entries := #[]
  let clustered := min 16 count
  for i in [:count] do
    -- Uniform top prefixes plus long common prefixes stress both shallow
    -- branching and the full 64-nibble path. Values include the minimum size.
    let key := if i < clustered then uintBytes (i+1) 32 else
      uintBytes ((i-clustered+1)*(2^256/(count-clustered+1))) 32
    entries := entries.push (← IO.ofExcept (ObjectID.ofBytes key), uintBytes (i+1) (12+i%128))
  return entries

private def run (path : String) (entries : Array (ObjectID × ByteArray)) (batchSize : Nat)
    (bulk : Bool) : IO (Hash × Nat × Nat) := do
  let store ← NodeStore.openStore path 1099511627776 .nudb
  try
    let repo ← Repository.ofStore store
    let start ← IO.monoMsNow
    let mut tree := Tree.empty
    for pageIndex in [:(entries.size+batchSize-1)/batchSize] do
      let lo := pageIndex*batchSize
      let page := entries.extract lo (min entries.size (lo+batchSize))
      tree ← if bulk then repo.appendSorted tree page fun next =>
          NodeStore.putMeta store "test_root" (hex next.root.bytes)
        else repo.updateMany tree page
    let elapsed := (← IO.monoMsNow)-start
    let stats ← repo.cacheStats
    -- Verify lookups before and after reopening, not just agreement on a root.
    for i in [0, entries.size/2, entries.size-1] do
      ensure ((← repo.lookup tree entries[i]!.1) == some entries[i]!.2) "lookup mismatch"
    if bulk then
      ensure ((← NodeStore.getMeta store "test_root") == hex tree.root.bytes) "checkpoint root mismatch"
      let previous := hex tree.root.bytes
      let nextKey ← IO.ofExcept (ObjectID.ofBytes (uintBytes (2^256-1) 32))
      let mut rejected := false
      try
        discard <| repo.appendSorted tree #[(nextKey,uintBytes 9 12)] fun _ => do
          NodeStore.putMeta store "test_root" "must roll back"
          throw <| IO.userError "injected checkpoint error"
      catch _ => rejected := true
      ensure rejected "failed callback was accepted"
      ensure ((← NodeStore.getMeta store "test_root") == previous) "metadata rollback failed"
      ensure ((← repo.lookup tree nextKey) == none) "staged page leaked through cache"
      for page in [#[entries[0]!,entries[0]!], #[entries[1]!,entries[0]!], #[entries[0]!]] do
        let mut invalidRejected := false
        try discard <| repo.appendSorted tree page
        catch _ => invalidRejected := true
        ensure invalidRejected "duplicate, reordered or overlapping keys accepted"
    NodeStore.checkpoint store
    return (tree.root,elapsed,stats.diskWrites)
  finally NodeStore.dispose store

def main (args : List String) : IO Unit := do
  let [directory] := args | throw <| IO.userError "provide a temporary benchmark directory"
  let entries ← objects 4096
  for size in [1,127,2048] do
    let path := s!"{directory}/bulk-{size}.sqlite3"
    let (root,elapsed,writes) ← run path entries size true
    let (baseline,oldElapsed,oldWrites) ← run s!"{directory}/old-{size}.sqlite3" entries size false
    ensure (root == baseline) "bulk root differs from per-entry reference"
    let store ← NodeStore.openReadOnly path 1099511627776
    try
      let repo ← Repository.readOnly store
      for i in [0,2048,4095] do
        ensure ((← repo.lookup ⟨root⟩ entries[i]!.1) == some entries[i]!.2) "reopened path mismatch"
    finally NodeStore.dispose store
    IO.println (Lean.Json.mkObj [
      ("entries",Lean.toJson entries.size),("page_size",Lean.toJson size),
      ("baseline_ms",Lean.toJson oldElapsed),("bulk_ms",Lean.toJson elapsed),
      ("baseline_writes",Lean.toJson oldWrites),("bulk_writes",Lean.toJson writes)]).compress
  -- Empty snapshots and a single entry keep the canonical inner root.
  let store ← NodeStore.openStore s!"{directory}/edge.sqlite3" 1099511627776 .nudb
  try
    let repo ← Repository.ofStore store
    ensure ((← repo.appendSorted Tree.empty #[]).root.isZero) "empty root mismatch"
    let singleton ← repo.appendSorted Tree.empty #[entries[0]!]
    let original ← repo.updateMany Tree.empty #[entries[0]!]
    ensure (singleton.root == original.root) "singleton root mismatch"
  finally NodeStore.dispose store
