import LeanXRPL.Ledger
import LeanXRPL.Handshake
import LeanXRPL.NodeStore

namespace LeanXRPL
open Lean

inductive StateTreeNode where
  | inner (children : Array ByteArray)
  | leaf (key data : ByteArray)
  deriving Inhabited

/-- The leaf commitment is MLN\0 || serialized object || object ID, not a transaction hash. -/
def decodeStateNode (wire : ByteArray) : IO (ByteArray × StateTreeNode) := do
  if wire.isEmpty || wire.size > 2097152 then throw <| IO.userError "state node size limit"
  let typ := wire[wire.size-1]!.toNat
  if typ == 2 || typ == 3 then
    let (hash, node) ← decodeTransactionNode wire
    match node with
    | .inner children => return (hash, .inner children)
    | _ => throw <| IO.userError "expected state inner node"
  if typ != 1 || wire.size < 45 then throw <| IO.userError "expected account-state leaf"
  let raw := wire.extract 0 (wire.size-1)
  let key := raw.extract (raw.size-32) raw.size
  return (← Native.sha512Half (hashPrefix "MLN" ++ raw), .leaf key (raw.extract 0 (raw.size-32)))

def compactStateNode (node : StateTreeNode) (wire : ByteArray) : ByteArray := Id.run do
  match node with
  | .leaf _ _ => return wire
  | .inner children =>
    if (children.filter (· != zeroHash)).size ≥ 12 then return wire
    let mut out := ByteArray.empty
    for i in [:16] do
      if children[i]! != zeroHash then out := out ++ children[i]! |>.push i.toUInt8
    return out.push 3

/-- Must run in a store transaction. Only previously authenticated paths can be populated.
Removing a frontier item and adding its children is one durable operation. -/
def acceptStateNode (store : NodeStore.Store) (id wire : ByteArray) : IO Bool := do
  let path ← IO.ofExcept (decodeNodeID id)
  let expected ← NodeStore.expected store id
  if expected.isEmpty then return false -- duplicate or unsolicited reply: never stored
  let (hash, node) ← decodeStateNode wire
  if hash != expected then throw <| IO.userError "account-state tree hash mismatch"
  let leaf ← match node with
    | .inner children => do
      if path.size ≥ 64 then throw <| IO.userError "state inner node at leaf depth"
      for branch in [:16] do
        if children[branch]! != zeroHash then
          NodeStore.addPending store (nodeID (path.push branch)) children[branch]!
      pure false
    | .leaf key _ => do
      if path.isEmpty || !keyHasPath key path then throw <| IO.userError "account-state leaf path mismatch"
      pure true
  NodeStore.putNode store hash (compactStateNode node wire) leaf
  NodeStore.removePending store id
  return true

private def jsonNat (j : Json) (key : String) : IO Nat := IO.ofExcept ((j.getObjVal? key).bind Json.getNat?)
private def jsonString (j : Json) (key : String) : IO String := IO.ofExcept ((j.getObjVal? key).bind Json.getStr?)

/-- Recheck the archived publisher list, manifests and quorum signatures at acquisition time.
The archive authenticates the exact pinned ledger on restart; it is not a fresh network vote. -/
def restoreStateCertificate (text publisher : String) : IO ValidationCertificate := do
  if text.utf8ByteSize > 33554432 then throw <| IO.userError "state certificate size limit"
  let j ← IO.ofExcept (Json.parse text)
  if (← jsonString j "publisher_key") != publisher then throw <| IO.userError "state certificate publisher mismatch"
  let verifiedAt ← jsonNat j "verified_at_xrpl_time"
  let mut trust ← verifyValidatorList (← jsonString j "validator_list") publisher verifiedAt
  let manifests ← IO.ofExcept ((j.getObjVal? "manifests").bind Json.getArr?)
  if manifests.size > 1024 then throw <| IO.userError "state certificate manifest limit"
  for m in manifests do
    trust ← IO.ofExcept (trust.applyManifest (← verifyManifest (← IO.ofExcept (m.getStr?.bind unhex))) true)
  let sequence ← jsonNat j "anchor_sequence"
  let hash ← IO.ofExcept ((← jsonString j "anchor_hash") |> unhex)
  if sequence == 0 || sequence > 4294967295 || hash.size != 32 then throw <| IO.userError "invalid state anchor"
  let votes ← IO.ofExcept ((j.getObjVal? "validations").bind Json.getArr?)
  if votes.size > 1024 then throw <| IO.userError "state certificate vote limit"
  let mut bucket : VoteBucket := { sequence }
  for vote in votes do
    let v ← verifyValidation trust (← IO.ofExcept ((← jsonString vote "validation_raw_hex") |> unhex)) verifiedAt
    if v.ledgerSequence != sequence then throw <| IO.userError "state certificate sequence mismatch"
    bucket := bucket.add v
  let some certificate := bucket.certificate trust verifiedAt | throw <| IO.userError "state certificate has no quorum"
  if certificate.hash != hash then throw <| IO.userError "state certificate hash mismatch"
  let raws ← match j.getObjVal? "ancestry_headers" with
    | .error _ => pure #[]
    | .ok value => IO.ofExcept value.getArr?
  if raws.size > 100000 then throw <| IO.userError "state certificate ancestry limit"
  let mut derived := certificate
  for raw in raws do
    let header ← verifyLedgerHeader (← IO.ofExcept (raw.getStr?.bind unhex)) derived.hash derived.sequence
    if header.sequence ≤ 1 then throw <| IO.userError "state certificate ancestry underflow"
    derived := { derived with hash := header.parentHash, sequence := header.sequence-1, ancestry := derived.ancestry.push header.raw }
  if (← jsonNat j "ledger_index") != derived.sequence || (← jsonString j "ledger_hash") != hex derived.hash then
    throw <| IO.userError "state certificate hash mismatch"
  return derived

/-- Resolve shared certificate evidence and authenticate the exact target through
parent-linked headers. Legacy self-contained certificates remain readable. -/
def restoreStoredStateCertificate (store : NodeStore.Store) (text publisher : String) : IO ValidationCertificate := do
  let j ← IO.ofExcept (Json.parse text)
  let readPool (kind id : String) : IO String := do
    let content ← NodeStore.getMeta store s!"sync_pool:{kind}:{id}"
    if content == "" || hex (← Native.sha512Half content.toUTF8) != id then
      throw <| IO.userError "state sync archive pool commitment mismatch"
    return content
  let expand (j : Json) : IO ValidationCertificate := do
    if (j.getObjVal? "trust_ref").isOk then
      let trust ← readPool "trust" (← jsonString j "trust_ref")
      let manifests ← IO.ofExcept (Json.parse (← readPool "manifests" (← jsonString j "manifests_ref")))
      let .obj fields := j | throw <| IO.userError "invalid state certificate"
      restoreStateCertificate (.obj (fields.insert "validator_list" (.str trust) |>.insert "manifests" manifests) : Json).compress publisher
    else restoreStateCertificate j.compress publisher
  if !(j.getObjVal? "anchor_ref").isOk then return ← expand j
  let anchor ← IO.ofExcept (Json.parse (← readPool "certificate" (← jsonString j "anchor_ref")))
  let mut c ← expand anchor
  let sequence ← jsonNat j "ledger_index"
  if sequence == 0 || sequence > c.sequence || c.sequence-sequence > 100000 then
    throw <| IO.userError "invalid archived certificate ancestry"
  for _ in [:c.sequence-sequence] do
    let raw ← IO.ofExcept (unhex (← NodeStore.getMeta store s!"certificate_header:{hex c.hash}"))
    let h ← verifyLedgerHeader raw c.hash c.sequence
    c := { c with hash := h.parentHash, sequence := c.sequence-1, ancestry := c.ancestry.push h.raw }
  if (← jsonString j "ledger_hash") != hex c.hash then throw <| IO.userError "state certificate hash mismatch"
  return c

structure StateSnapshot where
  store : NodeStore.Store
  path : System.FilePath
  networkID : Nat
  certificate : Option ValidationCertificate := none
  header : Option LedgerHeader := none
  startedMs : Nat
  previousMs : Nat := 0
  startedUnixMs : Nat
  receivedBytes : Nat := 0
  previousReceivedBytes : Nat := 0
  requests : Nat := 0
  previousRequests : Nat := 0
  verificationMs : Nat := 0
  previousVerificationMs : Nat := 0
  nextBase : Nat := 0
  sentAt : Std.HashMap String Nat := {}
  peerProgress : Std.HashMap String Nat := {}
  objectsUntil : Std.HashMap String Nat := {}
  objectRequests : Nat := 0
  previousObjectRequests : Nat := 0
  completed : Bool := false
  requestedLedger : Option Nat := none

def stateAnchorJson (c : ValidationCertificate) : Json :=
  match certificateJson c with
  | .obj fields => Json.obj (fields.insert "ledger_index" (toJson c.sequence) |>.insert "ledger_hash" (.str (hex c.hash)))
  | _ => .null

def StateSnapshot.open (path : System.FilePath) (networkID : Nat) (publisher : String)
    (maxBytes : Nat) (readOnly := false) (nodeBackend : NodeStore.Backend := .detect)
    (requestedLedger : Option Nat := none) : IO StateSnapshot := do
  if !readOnly then IO.FS.createDirAll (path.parent.getD ".")
  let store ← if readOnly then NodeStore.openReadOnly path.toString maxBytes.toUInt64
    else NodeStore.openStore path.toString maxBytes.toUInt64 nodeBackend
  let network ← NodeStore.getMeta store "network_id"
  let anchor ← NodeStore.getMeta store "anchor"
  if network != "" && network != toString networkID then throw <| IO.userError "state store network mismatch"
  let headerText ← NodeStore.getMeta store "header"
  let certificate ← if anchor == "" then pure none else do
    let mut c ← restoreStoredStateCertificate store anchor publisher
    let tip := (← NodeStore.getMeta store "snapshot_chain_sequence").toNat?.getD c.sequence
    if headerText == "" then
      if tip > c.sequence || c.sequence-tip > 100000 then throw <| IO.userError "invalid snapshot header-chain checkpoint"
      for _ in [:c.sequence-tip] do
        let raw ← IO.ofExcept (unhex (← NodeStore.getMeta store s!"snapshot_chain:{hex c.hash}"))
        let h ← verifyLedgerHeader raw c.hash c.sequence
        c := { c with hash := h.parentHash, sequence := c.sequence-1, ancestry := c.ancestry.push h.raw }
    pure (some c)
  let header ← if headerText == "" then pure none else do
    let some c := certificate | throw <| IO.userError "state header without certificate"
    some <$> verifyLedgerHeader (← IO.ofExcept (unhex headerText)) c.hash c.sequence
  if certificate.isNone && (← NodeStore.stats store).nodes != 0 then throw <| IO.userError "unanchored node store"
  let startedUnix ← NodeStore.getMeta store "started_unix_ms"
  let elapsed ← NodeStore.getMeta store "elapsed_ms"
  let received ← NodeStore.getMeta store "received_bytes"
  let requests ← NodeStore.getMeta store "requests"
  let verification ← NodeStore.getMeta store "verification_ms"
  let objectRequests ← NodeStore.getMeta store "object_requests"
  let complete ← NodeStore.getMeta store "complete"
  let requested ← NodeStore.getMeta store "snapshot_requested_ledger"
  if requestedLedger.isSome && requested != "" && requested.toNat? != requestedLedger then
    throw <| IO.userError "snapshot already targets a different ledger"
  let requestedLedger := requestedLedger.or requested.toNat?
  if !readOnly && requested == "" && requestedLedger.isSome then
    NodeStore.transaction store do NodeStore.putMeta store "snapshot_requested_ledger" (toString (requestedLedger.getD 0))
  let updating := (← NodeStore.getMeta store "sync_mode") == "snapshot_update"
  if complete == "true" && (header.isNone || (!updating && (← NodeStore.stats store).pending != 0)) then
    throw <| IO.userError "invalid completed state store"
  return {
    store, path, networkID, certificate, header, startedMs := (← IO.monoMsNow),
    startedUnixMs := startedUnix.toNat?.getD (((← networkTime)+946684800)*1000),
    previousMs := elapsed.toNat?.getD 0, previousReceivedBytes := received.toNat?.getD 0,
    previousRequests := requests.toNat?.getD 0, previousVerificationMs := verification.toNat?.getD 0,
    previousObjectRequests := objectRequests.toNat?.getD 0,
    completed := complete == "true", requestedLedger }

def StateSnapshot.pin (s : StateSnapshot) (c : ValidationCertificate) : IO StateSnapshot := do
  if s.certificate.isSome then return s
  if s.requestedLedger.any (· > c.sequence) then return s
  if s.requestedLedger.any (fun n => c.sequence-n > 100000) then
    throw <| IO.userError "requested ledger exceeds the 100000-header ancestry limit"
  NodeStore.transaction s.store do
    NodeStore.putMeta s.store "network_id" (toString s.networkID)
    NodeStore.putMeta s.store "anchor" ((stateAnchorJson c).compress)
    NodeStore.putMeta s.store "started_unix_ms" (toString s.startedUnixMs)
  return { s with certificate := some c }

def StateSnapshot.accept (s : StateSnapshot) (reply : LedgerData) (peer := "") : IO StateSnapshot := do
  if s.completed then return s
  let some c := s.certificate | return s
  if reply.hash != c.hash || reply.sequence != c.sequence || reply.error.isSome then return s
  if reply.kind != 0 && reply.kind != 2 then return s
  if reply.kind == 0 && s.requestedLedger.any (· < c.sequence) then
    if reply.nodes.isEmpty || reply.nodes.any (·.1.isSome) then throw <| IO.userError "invalid state ledger base reply"
    let h ← verifyLedgerHeader reply.nodes[0]!.2 c.hash c.sequence
    let parent := { c with hash := h.parentHash, sequence := c.sequence-1, ancestry := c.ancestry.push h.raw }
    NodeStore.transaction s.store do
      NodeStore.putMeta s.store s!"snapshot_chain:{hex c.hash}" (hex h.raw)
      NodeStore.putMeta s.store "snapshot_chain_sequence" (toString parent.sequence)
    return { s with certificate := some parent, nextBase := 0 }
  let started ← IO.monoMsNow
  let before ← NodeStore.stats s.store
  let header ← NodeStore.transaction s.store do
    if reply.kind == 0 then
      if reply.nodes.isEmpty || reply.nodes.any (·.1.isSome) then throw <| IO.userError "invalid state ledger base reply"
      let header ← verifyLedgerHeader reply.nodes[0]!.2 c.hash c.sequence
      if s.header.isNone then
        NodeStore.putMeta s.store "anchor" (stateAnchorJson c).compress
        NodeStore.putMeta s.store "header" (hex header.raw)
        if header.stateRoot != zeroHash then NodeStore.addPending s.store (nodeID #[]) header.stateRoot
      if reply.nodes.size ≥ 2 && header.stateRoot != zeroHash then
        discard <| acceptStateNode s.store (nodeID #[]) reply.nodes[1]!.2
      return some header
    else
      if s.header.isNone then throw <| IO.userError "state nodes before ledger header"
      let mut nodes : Array (ByteArray × ByteArray) := #[]
      for (id, wire) in reply.nodes do
        let some id := id | throw <| IO.userError "state node omitted ID"
        discard <| IO.ofExcept (decodeNodeID id)
        nodes := nodes.push (id, wire)
      -- Replies may include several levels out of order. Parent commitments come first.
      for (id, wire) in nodes.qsort (fun a b => a.1[32]! < b.1[32]!) do
        discard <| acceptStateNode s.store id wire
      return s.header
  let progressed := (← NodeStore.stats s.store).nodes > before.nodes
  let finished ← IO.monoMsNow
  return { s with
    header,
    peerProgress := if progressed then s.peerProgress.insert peer finished else s.peerProgress,
    receivedBytes := s.receivedBytes + (reply.nodes.foldl (fun n x => n + x.2.size) 0),
    verificationMs := s.verificationMs + finished-started }

/-- NodeStore objects use hash prefixes instead of SHAMap wire type suffixes. -/
def stateObjectWire (data : ByteArray) : IO ByteArray := do
  if data.size < 4 || data.size > 2097155 then throw <| IO.userError "state object size limit"
  let domain := data.extract 0 4
  let raw := data.extract 4 data.size
  if domain == hashPrefix "MIN" && raw.size == 512 then return raw.push 2
  if domain == hashPrefix "MLN" then return raw.push 1
  throw <| IO.userError "unexpected state object prefix"

def StateSnapshot.acceptObjects (s : StateSnapshot) (payload : ByteArray) (peer : String) : IO StateSnapshot := do
  if s.completed then return s
  let some c := s.certificate | return s
  let fields ← IO.ofExcept (parseProto payload)
  if protoNat fields 1 != some 4 || protoNat fields 2 != some 0 || protoBytes fields 4 != some c.hash then return s
  let objects := fields.filter (·.number == 6)
  if objects.size > 64 then throw <| IO.userError "state object reply limit"
  let started ← IO.monoMsNow
  let before ← NodeStore.stats s.store
  let received ← NodeStore.transaction s.store do
    let mut received := 0
    for object in objects do
      let .bytes raw := object.value | throw <| IO.userError "invalid state object protobuf"
      let fs ← IO.ofExcept (parseProto raw)
      let some hash := protoBytes fs 1 | throw <| IO.userError "state object omitted hash"
      let some id := protoBytes fs 3 | throw <| IO.userError "state object omitted index"
      let some data := protoBytes fs 4 | throw <| IO.userError "state object omitted data"
      if hash.size != 32 || (protoNat fs 5).any (· != c.sequence) then throw <| IO.userError "state object envelope mismatch"
      discard <| IO.ofExcept (decodeNodeID id)
      received := received + data.size
      let expected ← NodeStore.expected s.store id
      if !expected.isEmpty then
        if hash != expected then throw <| IO.userError "state object commitment mismatch"
        discard <| acceptStateNode s.store id (← stateObjectWire data)
    return received
  let progressed := (← NodeStore.stats s.store).nodes > before.nodes
  let finished ← IO.monoMsNow
  return { s with
    receivedBytes := s.receivedBytes + received,
    peerProgress := if progressed then s.peerProgress.insert peer finished else s.peerProgress,
    verificationMs := s.verificationMs + finished-started }

def StateSnapshot.request (s : StateSnapshot) (peer : String) (now limit depth : Nat) : IO (StateSnapshot × Option OutboundAction) := do
  if limit == 0 || limit > 256 || depth > 3 then throw <| IO.userError "invalid state request bounds"
  let some c := s.certificate | return (s, none)
  if s.completed || now < s.sentAt[peer]?.getD 0 then return (s, none)
  let mut s := s
  let recent := s.peerProgress.toArray.filter (fun entry => now < entry.2+120000)
  let progress := recent.foldl (fun (m : Std.HashMap String Nat) entry => m.insert entry.1 entry.2) {}
  let last := progress[peer]?.getD now
  let routes := s.objectsUntil.toArray.filter (fun entry => now < entry.2)
  let routes := routes.foldl (fun (m : Std.HashMap String Nat) entry => m.insert entry.1 entry.2) {}
  let useObjects := routes.contains peer || now ≥ last+10000
  s := { s with
    peerProgress := progress.insert peer last,
    objectsUntil := if useObjects then routes.insert peer (routes[peer]?.getD (now+60000)) else routes }
  let action ← if s.header.isNone then do
    if now < s.nextBase then pure none else
      s := { s with nextBase := now+2000 }
      pure (some (.ledgerBase c.hash))
    else NodeStore.transaction s.store do
      let packed ← NodeStore.reserve s.store now.toUInt64 (if useObjects then min limit 64 else limit).toUInt32
      let mut ids := #[]
      let mut objects := #[]
      for i in [:packed.size/33] do
        let id := packed.extract (i*33) (i*33+33)
        let hash ← NodeStore.expected s.store id
        let cached ← NodeStore.getNode s.store hash
        if cached.isEmpty then
          ids := ids.push id
          objects := objects.push (id, hash)
        else discard <| acceptStateNode s.store id cached
      -- Include the pinned sequence and permit indirect routing to peers retaining the ledger.
      pure (if ids.isEmpty then none else if useObjects then some (.stateObjects c.hash c.sequence objects)
        else some (.stateNodes c.hash c.sequence ids depth))
  if action.isSome then
    let recent := s.sentAt.toArray.filter (fun entry => now < entry.2)
    let sentAt := recent.foldl (fun (map : Std.HashMap String Nat) entry => map.insert entry.1 entry.2) {}
    let isObjects := match action with | some (.stateObjects ..) => true | _ => false
    s := { s with
      requests := s.requests+1, objectRequests := s.objectRequests+(if isObjects then 1 else 0),
      sentAt := sentAt.insert peer (now+(if isObjects then 250 else 100)) }
  return (s, action)

def StateSnapshot.complete (s : StateSnapshot) : IO Bool := do
  return s.header.isSome && (← NodeStore.stats s.store).pending == 0

def StateSnapshot.report (s : StateSnapshot) (complete : Bool) : IO Json := do
  let stats ← NodeStore.stats s.store
  let treeNodes ← NodeStore.getMeta s.store "snapshot_tree_nodes"
  let treeLeaves ← NodeStore.getMeta s.store "snapshot_tree_leaves"
  let backend ← NodeStore.backendName s.store
  let elapsed := s.previousMs+(← IO.monoMsNow)-s.startedMs
  return Json.mkObj [
    ("record_type", .str "state_snapshot"), ("complete", .bool complete), ("node_backend", .str backend),
    ("network_id", toJson s.networkID), ("ledger_index", toJson (s.certificate.map (·.sequence))),
    ("ledger_hash", toJson (s.certificate.map (fun c => hex c.hash))),
    ("state_root", toJson (s.header.map (fun h => hex h.stateRoot))),
    ("verified_nodes", toJson (treeNodes.toNat?.getD stats.nodes)),
    ("ledger_objects", toJson (treeLeaves.toNat?.getD stats.leaves)),
    ("stored_node_bytes", toJson stats.bytes), ("pending_paths", toJson stats.pending),
    ("received_node_bytes", toJson (s.previousReceivedBytes+s.receivedBytes)),
    ("requests", toJson (s.previousRequests+s.requests)), ("elapsed_ms", toJson elapsed),
    ("object_requests", toJson (s.previousObjectRequests+s.objectRequests)),
    ("verification_and_store_ms", toJson (s.previousVerificationMs+s.verificationMs)),
    ("store_path", .str s.path.toString), ("execution_verification", .str "not_reexecuted")]

/-- FULL-synchronous commit precedes checkpoint and publication of a completed snapshot. -/
def StateSnapshot.saveProgress (s : StateSnapshot) (complete : Bool) : IO Json := do
  if complete && !(← s.complete) then throw <| IO.userError "state snapshot is incomplete"
  let report ← s.report complete
  NodeStore.transaction s.store do
    NodeStore.putMeta s.store "elapsed_ms" (toString (← jsonNat report "elapsed_ms"))
    NodeStore.putMeta s.store "received_bytes" (toString (s.previousReceivedBytes+s.receivedBytes))
    NodeStore.putMeta s.store "requests" (toString (s.previousRequests+s.requests))
    NodeStore.putMeta s.store "object_requests" (toString (s.previousObjectRequests+s.objectRequests))
    NodeStore.putMeta s.store "verification_ms" (toString (s.previousVerificationMs+s.verificationMs))
    NodeStore.putMeta s.store "complete" (if complete then "true" else "false")
    NodeStore.putMeta s.store "benchmark" report.compress
  if complete then NodeStore.checkpoint s.store
  let databaseBytes := (← NodeStore.diskBytes s.store).toNat
  let backend ← NodeStore.backendName s.store
  let report := match report with
    | .obj fields => Json.obj (fields.insert "database_bytes" (toJson databaseBytes) |>.insert "node_backend" (.str backend))
    | _ => report
  let target := System.FilePath.mk (s.path.toString ++ ".benchmark.json")
  let temporary := System.FilePath.mk (target.toString ++ ".tmp")
  IO.FS.writeFile temporary (report.pretty ++ "\n")
  IO.FS.rename temporary target
  return report

end LeanXRPL
