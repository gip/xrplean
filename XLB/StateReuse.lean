import XLB.SharedState

namespace XLB.StateReuse
open Lean LeanXRPL XL

structure Base where
  header : LedgerHeader
  sources : Array String

structure Context where
  base : Base
  stores : Array NodeStore.Store
  loader : StateTree.Repository
  refs : IO.Ref (Std.TreeMap ByteArray ByteArray StateTree.compareBytes)

def Context.close (r : Context) : IO Unit := r.stores.forM NodeStore.dispose

private def sourceArray (j : Json) : IO (Array String) := do
  (← array j "sources").mapM (IO.ofExcept ·.getStr?)

private def snapshotJson (c : Config) (h : LedgerHeader) (sources : Array String) : Json :=
  obj [("network",toJson c.network),("bundle",str c.bundle),("ledger_index",toJson h.sequence),
    ("ledger_hash",str (hex h.hash)),("root",str (hex h.stateRoot)),("header",str (hex h.raw)),
    ("sources",toJson sources)]

private def decodeHeader (c : Config) (j : Json) : IO LedgerHeader := do
  require ((← nat j "network") == c.network && (← string j "bundle") == c.bundle)
    "incremental base belongs to another network or bundle"
  let h ← verifyLedgerHeader (← IO.ofExcept (unhex (← string j "header")))
    (← IO.ofExcept (unhex (← string j "ledger_hash"))) (← nat j "ledger_index")
  require (hex h.stateRoot == (← string j "root")) "incremental base root disagrees with its header"
  return h

/-- Witness-only and unfinished stores cannot certify subtree completeness. -/
private def checkSnapshot (c : Config) (h : LedgerHeader) (sources : Array String) : IO Unit := do
  require (sources.size == 1) "snapshot must use the bundle shared node store; consolidate legacy overlays first"
  let rows ← sql c.db s!"SELECT d.path,d.scope,'peer' FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id
    WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND l.hash={← quote (hex h.hash)} AND d.status='complete'
    UNION ALL SELECT d.path,d.scope,'rpc' FROM state_downloads d JOIN ledgers l ON l.id=d.ledger_id
    WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND l.hash={← quote (hex h.hash)} AND d.status='complete'"
  let some row := rows.find? (fun row => row[0]! == sources[0]!)
    | throw <| IO.userError "complete snapshot checkpoint missing"
  let store ← NodeStore.openMetadata row[0]! 1099511627776
  try
    NodeStore.setScope store row[1]!
    if row[2]! == "peer" then
      let j ← IO.ofExcept (Json.parse (← NodeStore.getMeta store "xl_peer"))
      require ((← nat j "network") == c.network && (← nat j "ledger_index") == h.sequence &&
        (← string j "ledger_hash") == hex h.hash && (← string j "root") == hex h.stateRoot &&
        (← NodeStore.getMeta store "xl_peer_complete") == "true" && (← NodeStore.stats store).pending == 0)
        "incremental peer base is incomplete or has another identity"
      let savedBundle ← NodeStore.getMeta store "xl_peer_bundle"
      require (savedBundle == c.bundle || (savedBundle.isEmpty && c.bundle == "default")) "base bundle mismatch"
    else
      let j ← IO.ofExcept (Json.parse (← NodeStore.getMeta store "xl_download"))
      require ((← nat j "network") == c.network &&
        (← string j "ledger_hash") == hex h.hash && (← string j "root") == hex h.stateRoot &&
        (← nat (← get j "progress") "ledger_index") == h.sequence &&
        (j.getObjVal? "done").toOption == some (.bool true)) "incremental RPC base is incomplete or has another identity"
  finally NodeStore.dispose store

private def choose (c : Config) (target : LedgerHeader) : IO (Option Base) := do
  -- Snapshot reuse is content reuse, not a claim of ledger ancestry. Prefer the
  -- exact parent, then the nearest complete state (including a later ledger).
  let rows ← sql c.db s!"SELECT s.sources_json,s.origin,l.header_json,l.state_root,l.idx,l.hash FROM states s
    JOIN ledgers l ON l.id=s.ledger_id WHERE s.bundle={← quote c.bundle} AND l.network={c.network}
    AND s.origin IN ('peer_snapshot','rpc_snapshot') AND l.hash!={← quote (hex target.hash)}
    ORDER BY CASE WHEN l.idx={target.sequence-1} AND l.hash={← quote (hex target.parentHash)} THEN 0 ELSE 1 END,
      ABS(l.idx-{target.sequence}),l.idx,l.hash LIMIT 1"
  let some row := rows[0]? | return none
  if row[1]! != "peer_snapshot" && row[1]! != "rpc_snapshot" then return none
  let stored ← IO.ofExcept (Json.parse row[2]!)
  let some baseIndex := row[4]!.toNat? | throw <| IO.userError "invalid base ledger index"
  let parent ← verifyLedgerHeader (← IO.ofExcept (unhex (← string stored "header_raw_hex")))
    (← IO.ofExcept (unhex row[5]!)) baseIndex
  require (hex parent.stateRoot == row[3]!) "base snapshot disagrees with stored header"
  let sources ← IO.ofExcept ((Json.parse row[0]!).bind Json.getArr?) >>= Array.mapM (IO.ofExcept ·.getStr?)
  checkSnapshot c parent sources
  return some ⟨parent,sources⟩

private def baseJson (c : Config) (b : Base) : Json := snapshotJson c b.header b.sources

def prepare (c : Config) (target : LedgerHeader) (store : NodeStore.Store)
    (completed : Bool) : IO (Option Context) := do
  let saved ← NodeStore.getMeta store "xl_peer_base"
  -- An unfinished full download may acquire a base on resume. Existing nodes
  -- and its authenticated frontier stay intact. Once selected, a base is pinned.
  let base ← if saved.isEmpty || (!completed && saved == "null") then
      if completed then pure none else do
        let selected ← choose c target
        NodeStore.transaction store do
          NodeStore.putMeta store "xl_peer_base" (selected.map (baseJson c) |>.getD .null).compress
        pure selected
    else do
      let j ← IO.ofExcept (Json.parse saved)
      if j == .null then pure none else
        pure (some ⟨← decodeHeader c j, ← sourceArray j⟩)
  let some base := base | return none
  checkSnapshot c base.header base.sources
  let mut stores := #[]
  try
    for path in base.sources do stores := stores.push (← NodeStore.openReadOnly path 1099511627776)
    let some first := stores[0]? | throw <| IO.userError "empty incremental base"
    let loader ← StateTree.Repository.readOnly first 134217728 stores[1]?
    if base.header.stateRoot != zeroHash then
      discard <| loader.load (← IO.ofExcept (StateTree.Hash.ofBytes base.header.stateRoot))
    return some ⟨base,stores,loader,← IO.mkRef {}⟩
  catch e =>
    stores.forM NodeStore.dispose
    throw e

private def previous (r : Context) (id : ByteArray) : IO ByteArray := do
  let path ← IO.ofExcept (decodeNodeID id)
  let mut refs ← r.refs.get
  if let some commitment := refs[id]? then return commitment
  if refs.size ≥ 65536 then refs := {}
  let mut commitment := r.base.header.stateRoot
  for depth in [:path.size] do
    if commitment == zeroHash then return zeroHash
    let parentId := nodeID (path.extract 0 depth)
    let node ← r.loader.load (← IO.ofExcept (StateTree.Hash.ofBytes commitment))
    match node with
    | .leaf key _ =>
      require (keyHasPath key.bytes (path.extract 0 depth)) "base leaf path mismatch"
      return zeroHash
    | .inner children =>
      refs := refs.insert parentId commitment
      commitment := children.toArray[path[depth]!]!.bytes
  r.refs.set (refs.insert id commitment)
  return commitment

/-- Equality at an authenticated position reuses the entire completed subtree.
    No unchanged descendants are visited, copied, or inserted into the new catalog. -/
def reuse (r : Option Context) (store : NodeStore.Store) (id expected : ByteArray) : IO Bool := do
  let some r := r | return false
  if expected != (← previous r id) then return false
  NodeStore.removePending store id
  let count := (← NodeStore.getMeta store "xl_peer_reused").toNat?.getD 0
  NodeStore.putMeta store "xl_peer_reused" (toString (count+1))
  return true

def cached (r : Option Context) (expected : ByteArray) : IO ByteArray := do
  if let some r := r then
    for store in r.stores do
      let wire ← NodeStore.getNode store expected
      if !wire.isEmpty then return wire
  return ByteArray.empty

def accept (r : Option Context) (store : NodeStore.Store) (id wire : ByteArray) : IO Bool := do
  if r.isNone then return ← acceptStateNode store id wire
  let expected ← NodeStore.expected store id
  if expected.isEmpty then return false
  if ← reuse r store id expected then return true
  acceptStateNode store id wire

def publish (_ : Option Context) (_ : NodeStore.Store) (path : String) : IO (Array String) :=
  pure #[path]

end XLB.StateReuse
