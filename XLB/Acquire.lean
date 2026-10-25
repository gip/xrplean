import XLB.Download
import XLB.PeerAcquire
import XL.Rpc
import XL.FetchProgress

namespace XLB.Acquire
open Lean LeanXRPL XL Std.Async

private def rpc (c : Config) (stop : IO.Ref Bool) (method : String) (params : List (String × Json))
    (onRetry : Nat → Nat → String → IO Unit := fun _ _ _ => pure ()) : Async Json := do
  let response ← Rpc.request c (obj [("method",str method),("params",toJson #[obj (("api_version",toJson (2:Nat))::params)])]) stop onRetry
  let result ← get response "result"
  require (optString result "status" == "success" && !(result.getObjVal? "error").isOk)
    s!"xrpld RPC {method}: {result.compress}"
  return result

private def retryProgress (progress : FetchProgress → IO Unit) (p : FetchProgress)
    (attempt delay : Nat) (error : String) : IO Unit :=
  progress {p with phase := "rpc_retry", retryAttempt := attempt, retryDelayMs := delay, lastError := error}

/-- Use only an advertised peer port on the configured RPC host. This does not
discover other hosts or follow overlay redirects. An explicit --peer wins. -/
private def advertisedPeer (c : Config) (info : Json) : Option Endpoint := do
  if let some endpoint := c.peer then return endpoint
  let uri ← Std.Http.URI.parse? c.rpc
  let authority ← uri.authority
  let host := match authority.host with
    | .ipv4 a => toString a
    | .ipv6 a => toString a
    | .name name => toString name
  let ports ← (info.getObjVal? "ports").toOption >>= (·.getArr?.toOption)
  ports.findSome? fun entry => do
    let protocols ← (entry.getObjVal? "protocol").toOption >>= (·.getArr?.toOption)
    if !protocols.contains (str "peer") then none else do
      let raw ← (entry.getObjVal? "port").toOption
      let port ← raw.getNat?.toOption <|> (raw.getStr?.toOption >>= String.toNat?)
      if port == 0 || port > 65535 then none else
        some ⟨host,port.toUInt16,true⟩

def latestIndex (c : Config) (stop : IO.Ref Bool)
    (progress : FetchProgress → IO Unit := fun _ => pure ()) : Async Nat := do
  let info ← get (← rpc c stop "server_info" [] (retryProgress progress {ledgerIndex := 0})) "info"
  let idx ← nat (← get info "validated_ledger") "seq"
  index idx
  return idx

/-- Resolve a moving fetch selector in XLB, before the task persists its numeric target.
Retries use the saved target instead of consulting a later validated tip. -/
def resolve (c : Config) (stop : IO.Ref Bool) (j : Json)
    (progress : FetchProgress → IO Unit := fun _ => pure ()) : Async Json := do
  if (← get j "from") != str "latest" then return j
  if let .ok last := j.getObjVal? "to" then
    require (last == str "latest") "latest selects a single ledger; omit to"
  let idx ← latestIndex c stop progress
  let .obj fields := j | throw <| IO.userError "fetch request must be an object"
  return .obj (fields.insert "from" (toJson idx) |>.insert "to" (toJson idx))

private def saveState (c : Config) (ledgerId : String) (sources : Array String) (origin : String) : IO Unit := do
  exec c s!"INSERT INTO states(bundle,ledger_id,sources_json,origin) VALUES({← quote c.bundle},{ledgerId},{← quote (toJson sources).compress},{← quote origin})
    ON CONFLICT(bundle,ledger_id) DO UPDATE SET sources_json=excluded.sources_json,origin=excluded.origin"

/-- Import exact wire witnesses. Trust is granted only through the separate trust endpoint. -/
def importState (c : Config) (j : Json) : IO Json := do
  let idx ← nat j "ledger_index"
  let h ← hash (← string j "ledger_hash")
  let row ← Store.ledger c c.network idx h
  let nodes ← array j "nodes"
  let path ← SharedState.path c
  let store ← SharedState.openScope path s!"witness-{h}-{← digest j.compress}"
  try
    NodeStore.transaction store do
      for node in nodes do
        let expected ← IO.ofExcept (unhex (← hash (← string node "hash")))
        let wire ← IO.ofExcept (unhex (← string node "wire"))
        let (computed, decoded) ← decodeStateNode wire
        require (computed == expected) "imported node content hash mismatch"
        NodeStore.putNode store expected wire (match decoded with | .leaf .. => true | _ => false)
    let root ← IO.ofExcept (StateTree.Hash.ofBytes (← IO.ofExcept (unhex row[3]!)))
    let repo ← StateTree.Repository.readOnly store
    if !root.isZero then discard <| repo.load root
    NodeStore.checkpoint store
  finally NodeStore.dispose store
  saveState c row[0]! #[path] "imported_witnesses"
  return obj [("state",str "stored"),("trust",str "unchanged")]

private def fetchOne (c : Config) (stop : IO.Ref Bool) (idx : Nat) (withState : Bool)
    (transport selected expectedParent : String) (position total : Nat) (progress : FetchProgress → IO Unit) : Async Json := do
  let saved ← if withState then Download.find c idx selected else pure none
  let peerHash ← if withState && transport != "rpc" then PeerAcquire.savedHash c idx selected else pure none
  if selected.isEmpty then
    if let some prior := saved then
      if let some ph := peerHash then require (prior.ledgerHash == ph) "download transports have different forks; select ledger_hash"
  let initial := saved.map (·.cursor.progress) |>.getD {ledgerIndex := idx}
  let started ← IO.monoMsNow
  let elapsed : Unit → IO Nat := fun _ => do pure (initial.elapsedMs+(← IO.monoMsNow)-started)
  let emit : FetchProgress → IO Unit := fun p => do
    let elapsedMs ← if p.transport == "peer" then pure p.elapsedMs else elapsed ()
    progress {p with elapsedMs := elapsedMs}
  let mut p := {initial with
    ledgerNumber := position, ledgersTotal := total,
    phase := if initial.pages > 0 then "resuming" else "fetching_ledger"}
  emit p
  let rpcStarted ← IO.monoMsNow
  -- Resume the exact fork, even if the node's index lookup now selects another hash.
  let pinned := if !selected.isEmpty then some selected else (saved.map (·.ledgerHash)).or peerHash
  let selection := pinned.map (fun h => ("ledger_hash",str h)) |>.getD ("ledger_index",toJson idx)
  let response ← rpc c stop "ledger" [selection,("transactions",.bool true),("expand",.bool true),("binary",.bool true)] (retryProgress emit p)
  p := {p with rpcMs := p.rpcMs+(← IO.monoMsNow)-rpcStarted}
  let ledger ← get response "ledger"
  require ((← get ledger "closed") == .bool true) "xrpld returned an open ledger"
  let h ← hash (← string response "ledger_hash")
  if let some pinned := pinned then require (pinned == h) "header changed pinned ledger hash"
  if let some prior := saved then require (prior.ledgerHash == h) "resumed header changed ledger"
  let raw ← IO.ofExcept (unhex (← string ledger "ledger_data"))
  let header ← verifyLedgerHeader raw (← IO.ofExcept (unhex h)) idx
  require (expectedParent.isEmpty || hex header.parentHash == expectedParent) "range does not extend the exact preceding ledger"
  let stored := obj [("rpc",response),("header_raw_hex",str (hex raw)),
    ("transaction_root",str (hex header.transactionRoot))]
  let id ← Store.ensureLedger c c.network idx h (hex header.parentHash) (hex header.stateRoot) (some stored)
  let mut fallback := ""
  if withState && transport == "auto" && c.peer.isNone && !(saved.any (·.cursor.done)) then
    fallback := "xrpld did not advertise a usable peer port; configure --peer HOST:PORT"
    emit {p with phase := "rpc_fallback", lastError := fallback}
  if withState && transport != "rpc" && (transport == "peer" || c.peer.isSome) &&
      !(transport == "auto" && (saved.any (·.cursor.done))) then
    let latest ← IO.mkRef p
    let peer ← PeerAcquire.run c stop header id fun event => do
      latest.set event
      emit {event with ledgerNumber := position, ledgersTotal := total, rpcMs := p.rpcMs}
    require (!(← stop.get)) "acquisition interrupted; rerun this fetch to resume"
    if peer.complete then
      saveState c (toString id) peer.sources "peer_snapshot"
      emit { (← latest.get) with
        phase := "complete", transport := "peer", keyspacePermille := 1000,
        entries := optNat peer.metrics "entries", nodes := optNat peer.metrics "nodes",
        incremental := (peer.metrics.getObjVal? "incremental").toOption == some (.bool true),
        baseLedgerHash := optString peer.metrics "base_ledger_hash",
        reusedSubtrees := optNat peer.metrics "reused_subtrees",
        stateBytes := optNat peer.metrics "stored_node_bytes"}
      return obj [("bundle",str c.bundle),("ledger_index",toJson idx),("ledger_hash",str h),("state_root",str (hex header.stateRoot)),
        ("trust",str "untrusted"),("state_downloaded",.bool true),("state_backend",str "nudb"),
        ("acquisition_transport",str "peer"),("metrics",peer.metrics)]
    if transport == "peer" then throw <| IO.userError s!"peer acquisition unavailable: {peer.reason}"
    fallback := peer.reason
    emit {p with phase := "rpc_fallback", lastError := fallback}
  if withState then
    let download ← Download.start c idx id h
    -- The writer lock excludes simultaneous fetches of this ledger. Read the
    -- authoritative cursor again after acquiring it, rather than using UI hints.
    let store ← SharedState.openScope download.path download.scope
    try
      let cursor ← Download.decode c idx h (← NodeStore.getMeta store "xl_download")
      let repo ← StateTree.Repository.ofStore store
      let mut tree := cursor.tree
      if !tree.root.isZero then discard <| repo.load tree.root
      let mut marker := cursor.marker
      let mut previousKey := cursor.previousKey
      p := {cursor.progress with
        ledgerNumber := position, ledgersTotal := total,
        rpcMs := p.rpcMs, phase := if cursor.progress.pages > 0 then "resuming" else "downloading"}
      emit p
      unless cursor.done do
        repeat
          require (!(← stop.get)) "acquisition interrupted; rerun this fetch to resume"
          emit {p with phase := "downloading"}
          let params := [("ledger_hash",str h),("binary",.bool true),("limit",toJson (2048:Nat))] ++
            (marker.map (fun m => [("marker",m)] ) |>.getD [])
          let rpcStarted ← IO.monoMsNow
          let page ← rpc c stop "ledger_data" params (retryProgress emit p)
          p := {p with rpcMs := p.rpcMs+(← IO.monoMsNow)-rpcStarted}
          let localStarted ← IO.monoMsNow
          require ((← hash (← string page "ledger_hash")) == h && (← nat page "ledger_index") == idx) "state page changed ledger"
          let entries ← array page "state"
          let nextMarker := (page.getObjVal? "marker").toOption
          if let some m := nextMarker then
            require (m != .null && !entries.isEmpty && marker != some m) "state pagination did not advance"
          let committed := p
          let mut changes := #[]
          for entry in entries do
            let key ← hash (← string entry "index")
            if let some prev := previousKey then require (prev < key) "state page repeats or reorders keys"
            previousKey := some key
            let bytes ← IO.ofExcept (unhex (← string entry "data"))
            p := {p with stateBytes := p.stateBytes+bytes.size}
            let objectId ← IO.ofExcept (StateTree.ObjectID.ofBytes (← IO.ofExcept (unhex key)))
            changes := changes.push (objectId,bytes)
          p := {p with entries := p.entries+entries.size, pages := p.pages+1, phase := "building"}
          -- Report committed counters until the new page is safely stored.
          emit {committed with phase := "building"}
          if let some key := previousKey then
            let keyPrefix ← IO.ofExcept (unhex ((key.take 8).toString))
            p := {p with keyspacePermille := min 999 (bytesNat keyPrefix*1000/4294967296)}
          let durable := p
          let lastKey := previousKey
          tree ← repo.appendSorted tree changes fun next => do
            let checkpoint : Download.Cursor := {
              tree := next, marker := nextMarker,
              previousKey := lastKey, done := nextMarker.isNone,
              progress := {durable with
                elapsedMs := ← elapsed (),
                localMs := durable.localMs+(← IO.monoMsNow)-localStarted}}
            NodeStore.putMeta store "xl_download" (Download.encode c h checkpoint).compress
          p := {p with localMs := p.localMs+(← IO.monoMsNow)-localStarted}
          emit p
          marker := nextMarker
          if marker.isNone then break
      emit {p with phase := "checking_root"}
      if hex tree.root.bytes != hex header.stateRoot then
        Download.status c (toString id) "invalid"
        throw <| IO.userError "downloaded state does not match ledger root"
      repo.checkpoint
      saveState c (toString id) #[download.path] "rpc_snapshot"
      Download.status c (toString id) "complete"
    finally NodeStore.dispose store
  emit {p with phase := "complete", keyspacePermille := 1000}
  return obj [("bundle",str c.bundle),("ledger_index",toJson idx),("ledger_hash",str h),("state_root",str (hex header.stateRoot)),
    ("trust",str "untrusted"),("state_downloaded",.bool withState),
    ("state_backend",if withState then str "nudb" else .null),
    ("acquisition_transport",str "rpc"),("fallback_reason",str fallback),
    ("metrics",obj [("elapsed_ms",toJson (← elapsed ())), ("rpc_ms",toJson p.rpcMs),
      ("local_ms",toJson p.localMs),("entries",toJson p.entries),("pages",toJson p.pages),
      ("state_bytes",toJson p.stateBytes)])]

private def fetchUnlocked (c : Config) (stop : IO.Ref Bool) (j : Json)
    (progress : FetchProgress → IO Unit := fun _ => pure ()) : Async Json := do
  let first ← nat j "from"; let last := optNat j "to" first
  index first; index last
  require (last ≥ first && last-first < 10000) "range must contain 1 to 10000 ledgers"
  let withState := (j.getObjVal? "state").toOption == some (.bool true)
  let transport ← match j.getObjVal? "transport" with
    | .error _ => pure "auto"
    | .ok value => IO.ofExcept value.getStr?
  require (["auto","rpc","peer"].contains transport) "transport must be auto, peer, or rpc"
  let selected ← match j.getObjVal? "ledger_hash" with
    | .error _ => pure ""
    | .ok value => hash (← IO.ofExcept value.getStr?)
  require (selected.isEmpty || first == last) "ledger_hash requires a single ledger"
  let saved ← if withState then Download.find c first selected else pure none
  let initial := saved.map (·.cursor.progress) |>.getD {ledgerIndex := first}
  progress {initial with
    ledgersTotal := last-first+1,
    phase := if initial.pages > 0 then "resuming" else "checking_node"}
  let info ← rpc c stop "server_info" [] (retryProgress progress initial)
  let details ← get info "info"
  discard <| IO.ofExcept details.getObj?
  match details.getObjVal? "network_id" with
  | .ok value =>
    let some network := value.getNat?.toOption
      | throw <| IO.userError "xrpld server_info.info.network_id must be an unsigned 32-bit integer"
    require (network ≤ 4294967295) "xrpld server_info.info.network_id must be an unsigned 32-bit integer"
    require (network == c.network) "xrpld network_id does not match XLB configuration"
  | .error _ =>
    -- xrpld omits the optional overlay network ID when [network_id] is unset.
    -- Its effective Config.networkId still defaults to Mainnet (0).
    require (c.network == 0)
      "xrpld omitted network_id; non-Mainnet acquisition requires an explicit [network_id] in xrpld configuration"
  let c := {c with peer := advertisedPeer c details}
  let mut results := #[]
  let mut expectedParent := optString j "expected_parent_hash"
  if !expectedParent.isEmpty then expectedParent ← hash expectedParent
  for offset in [:last-first+1] do
    require (!(← stop.get)) "acquisition interrupted"
    let result ← fetchOne c stop (first+offset) withState transport selected expectedParent (offset+1) (last-first+1) progress
    expectedParent ← string result "ledger_hash"
    results := results.push result
  return toJson results

def fetch (c : Config) (stop : IO.Ref Bool) (j : Json)
    (progress : FetchProgress → IO Unit := fun _ => pure ()) : Async Json := do
  Store.ensureBundle c
  let lock ← try XL.lock (c.bundleDir / "acquisition.lock").toString
    catch e => throw <| IO.userError s!"bundle acquisition already in use or unavailable: {e}"
  try fetchUnlocked c stop j progress
  finally XL.unlock lock

end XLB.Acquire
