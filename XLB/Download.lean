import XLB.SharedState
import XL.FetchProgress

namespace XLB.Download
open Lean LeanXRPL XL

/-- The node catalog owns the cursor and reconstructed root in one transaction.
The application DB only locates the catalog; it is never the per-page authority. -/
structure Cursor where
  tree : StateTree.Tree := StateTree.Tree.empty
  marker : Option Json := none
  previousKey : Option String := none
  done : Bool := false
  progress : FetchProgress

structure Saved where
  ledgerId : String
  ledgerHash : String
  path : String
  scope : String := ""
  cursor : Cursor

def encode (c : Config) (h : String) (cursor : Cursor) : Json :=
  obj [("version",toJson (1:Nat)),("network",toJson c.network),
    ("ledger_hash",str h),("root",str (hex cursor.tree.root.bytes)),
    ("marker",cursor.marker.getD .null),
    ("previous_key",cursor.previousKey.map str |>.getD .null),
    ("done",.bool cursor.done),("progress",cursor.progress.json)]

def decode (c : Config) (idx : Nat) (h : String) (text : String) : IO Cursor := do
  if text.isEmpty then return {progress := {ledgerIndex := idx}}
  let j ← IO.ofExcept (Json.parse text)
  require ((← nat j "version") == 1 && (← nat j "network") == c.network &&
    (← hash (← string j "ledger_hash")) == h) "download checkpoint identity mismatch"
  let p ← get j "progress"
  require ((← nat p "ledger_index") == idx) "download checkpoint index mismatch"
  let previous ← get j "previous_key"
  let previousKey ← if previous == .null then pure none else
    pure (some (← hash (← IO.ofExcept previous.getStr?)))
  let marker ← get j "marker"
  let done ← IO.ofExcept ((← get j "done").getBool?)
  let pages ← nat p "pages"
  let entries ← nat p "entries"
  require ((!done || marker == .null) && (pages > 0 || (entries == 0 && previousKey.isNone)) &&
    (entries == 0 || previousKey.isSome)) "invalid download checkpoint cursor"
  let root ← IO.ofExcept (StateTree.Hash.ofBytes (← IO.ofExcept (unhex (← hash (← string j "root")))) )
  return {
    tree := ⟨root⟩
    marker := if marker == .null then none else some marker
    previousKey := previousKey
    done := done
    progress := {
      ledgerIndex := idx
      phase := "resuming"
      pages := pages
      entries := entries
      stateBytes := ← nat p "state_bytes"
      elapsedMs := ← nat p "elapsed_ms"
      keyspacePermille := ← nat p "keyspace_permille"
      rpcMs := ← nat p "rpc_ms"
      localMs := ← nat p "local_ms" }}

private def readCursor (c : Config) (idx : Nat) (h path scope : String) : IO Cursor := do
  if !(← System.FilePath.pathExists path) then return {progress := {ledgerIndex := idx}}
  if !scope.isEmpty then
    let tables ← sql path "SELECT name FROM sqlite_master WHERE name='acquisition_counters'"
    if tables.isEmpty then return {progress := {ledgerIndex := idx}}
    let rows ← sql path s!"SELECT scope FROM acquisition_counters WHERE scope={← quote scope}"
    if rows.isEmpty then return {progress := {ledgerIndex := idx}}
  let store ← NodeStore.openMetadata path 1099511627776
  try
    NodeStore.setScope store scope
    decode c idx h (← NodeStore.getMeta store "xl_download")
  finally NodeStore.dispose store

/-- Index lookup can resume only an unambiguous, exact hash on this network. -/
def find (c : Config) (idx : Nat) (selected : String := "") : IO (Option Saved) := do
  let filter ← if selected.isEmpty then pure "" else pure s!" AND l.hash={← quote selected}"
  let rows ← sql c.db s!"SELECT d.ledger_id,l.hash,d.path,d.scope FROM state_downloads d
    JOIN ledgers l ON l.id=d.ledger_id WHERE l.network={c.network} AND l.idx={idx}
    AND d.bundle={← quote c.bundle} AND d.status!='invalid'{filter} ORDER BY l.id DESC"
  require (rows.size ≤ 1) "multiple downloaded ledger hashes at this index; acquisition is ambiguous"
  let some row := rows[0]? | return none
  return some ⟨row[0]!,row[1]!,row[2]!,row[3]!,← readCursor c idx row[1]! row[2]! row[3]!⟩

def start (c : Config) (idx : Nat) (id : Nat) (h : String) : IO Saved := do
  let proposed ← SharedState.path c
  let scope := s!"rpc-{h}-{← IO.monoNanosNow}"
  let rows ← sql c.db s!"BEGIN IMMEDIATE;
    INSERT INTO state_downloads(bundle,ledger_id,path,scope,status) VALUES({← quote c.bundle},{id},{← quote proposed},{← quote scope},'downloading')
      ON CONFLICT(bundle,ledger_id) DO UPDATE SET path=excluded.path,scope=excluded.scope,status='downloading',updated_at=CURRENT_TIMESTAMP
      WHERE state_downloads.status='invalid';
    SELECT path,scope FROM state_downloads WHERE bundle={← quote c.bundle} AND ledger_id={id}; COMMIT;"
  let path := rows[0]![0]!
  require (path == proposed) "discard or consolidate the legacy RPC checkpoint before retrying"
  let savedScope := rows[0]![1]!
  return ⟨toString id,h,path,savedScope,← readCursor c idx h path savedScope⟩

def status (c : Config) (id value : String) : IO Unit := do
  exec c s!"UPDATE state_downloads SET status={← quote value},updated_at=CURRENT_TIMESTAMP WHERE bundle={← quote c.bundle} AND ledger_id={id}"

end XLB.Download
