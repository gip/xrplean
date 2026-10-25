import LeanXRPL.Transport
import XL.FetchProgress
import XLB.StateReuse

namespace XLB.PeerAcquire
open Lean LeanXRPL XL Std.Async

structure Result where
  path : String
  complete : Bool
  reason : String := ""
  metrics : Json := .null
  sources : Array String := #[]

/-- Resume by exact identity, never by a peer's moving tip. -/
def savedHash (c : Config) (idx : Nat) (selected : String := "") : IO (Option String) := do
  let filter ← if selected.isEmpty then pure "" else pure s!" AND l.hash={← quote selected}"
  let rows ← sql c.db s!"SELECT l.hash FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id
    WHERE l.network={c.network} AND l.idx={idx} AND d.bundle={← quote c.bundle} AND 1=1{filter}"
  require (rows.size ≤ 1) "multiple peer download hashes at this index; select ledger_hash"
  return rows[0]?.map (·[0]!)

private def status (c : Config) (id : Nat) (value : String) : IO Unit := do
  exec c s!"UPDATE peer_downloads SET status={← quote value},updated_at=CURRENT_TIMESTAMP WHERE bundle={← quote c.bundle} AND ledger_id={id}"

private def start (c : Config) (id : Nat) (header : LedgerHeader) : IO (String × String) := do
  let path ← SharedState.path c
  let scope := s!"peer-{hex header.hash}-{← IO.monoNanosNow}"
  let prior ← sql c.db s!"SELECT path,scope,status FROM peer_downloads WHERE bundle={← quote c.bundle} AND ledger_id={id}"
  if let some row := prior[0]? then
    if row[2]! != "invalid" then
      require (row[0]! == path) "discard or consolidate the legacy partial download before retrying"
      return (path,row[1]!)
  let rows ← sql c.db s!"BEGIN IMMEDIATE;
    INSERT INTO peer_downloads(bundle,ledger_id,path,scope,status) VALUES({← quote c.bundle},{id},{← quote path},{← quote scope},'downloading')
      ON CONFLICT(bundle,ledger_id) DO UPDATE SET path=excluded.path,scope=excluded.scope,status='downloading'
      WHERE peer_downloads.status='invalid';
    SELECT path,scope FROM peer_downloads WHERE bundle={← quote c.bundle} AND ledger_id={id}; COMMIT;"
  return (rows[0]![0]!,rows[0]![1]!)

/-- Only failures while parsing or authenticating peer data invalidate a download.
    UI disconnects, cancellation and progress delivery errors leave it resumable. -/
private def checked {α : Type} (c : Config) (ledgerId : Nat) (store : NodeStore.Store) (pending : IO.Ref Bool) (action : IO α) : IO α := do
  try action
  catch e =>
    if ← pending.get then
      pending.set false
      NodeStore.rollback store
    NodeStore.transaction store do NodeStore.putMeta store "xl_peer_invalid_reason" e.toString
    status c ledgerId "invalid"
    throw e

private def flushBatch (store : NodeStore.Store) (pending : IO.Ref Bool) : IO Unit := do
  if ← pending.get then
    pending.set false
    try NodeStore.commit store
    catch e => NodeStore.rollback store; throw e

private structure Flight where
  sent : Nat
  ids : Array ByteArray

/-- The connection is single-owner. A bounded frontier, rather than a pagination cursor,
    determines completion. Node acceptance and frontier advancement commit together. -/
private def sessionLoop (c : Config) (ledgerId : Nat) (stop : IO.Ref Bool) (header : LedgerHeader)
    (store : NodeStore.Store) (reuse : Option StateReuse.Context) (connection : Connection) (initial : ByteArray)
    (progress : FetchProgress → IO Unit) (pending : IO.Ref Bool) : Async (Option String × Json) := do
  let started ← IO.monoMsNow
  let mut lastProgress := started
  let mut lastEmit := 0
  let mut nextPing := started+15000
  let mut controls : SessionState := {}
  let mut pingSeq : UInt32 := 0
  let mut buffer := initial
  let mut flights : Array Flight := #[]
  let mut received := 0
  let mut requests := 0
  let mut localMs := 0
  let mut lastCommit := started
  let mut committedNodes := (← NodeStore.stats store).nodes
  let mut readError : Option String := none
  repeat
    require (!(← stop.get)) "acquisition interrupted; rerun this fetch to resume"
    let now ← IO.monoMsNow
    let stats ← NodeStore.stats store
    if (← pending.get) && (now-lastCommit ≥ 1000 || stats.nodes-committedNodes ≥ 32768 || stats.pending == 0) then
      let before ← IO.monoMsNow
      flushBatch store pending
      localMs := localMs+(← IO.monoMsNow)-before
      lastCommit ← IO.monoMsNow
      committedNodes := stats.nodes
    let now ← IO.monoMsNow
    let metrics := obj [("elapsed_ms",toJson (now-started)),("local_ms",toJson localMs),
      ("received_overlay_bytes",toJson received),("requests",toJson requests),
      ("nodes",toJson stats.nodes),("entries",toJson stats.leaves),("stored_node_bytes",toJson stats.bytes),
      ("incremental",.bool reuse.isSome),("base_ledger_hash",reuse.map (fun r => str (hex r.base.header.hash)) |>.getD .null),
      ("reused_subtrees",toJson ((← NodeStore.getMeta store "xl_peer_reused").toNat?.getD 0))]
    if !(← pending.get) && (now-lastEmit ≥ 1000 || stats.pending == 0) then
      progress {
        ledgerIndex := header.sequence
        phase := "peer_downloading"
        transport := "peer"
        entries := stats.leaves
        stateBytes := stats.bytes
        nodes := stats.nodes
        pending := stats.pending
        incremental := reuse.isSome
        baseLedgerHash := reuse.map (fun r => hex r.base.header.hash) |>.getD ""
        reusedSubtrees := (← NodeStore.getMeta store "xl_peer_reused").toNat?.getD 0
        elapsedMs := now-started
        peerMs := now-started-localMs
        localMs := localMs }
      lastEmit := now
    if stats.pending == 0 then return (none, metrics)
    if now-lastProgress ≥ c.peerTimeout*1000 then return (some "peer acquisition stalled", metrics)
    if now ≥ nextPing then
      let .ok (next, actions) := controls.onTimer pingSeq
        | return (some "peer ping timeout", metrics)
      controls := next
      pingSeq := pingSeq+1
      for action in actions do
        try connection.sendControl action catch e => return (some e.toString, metrics)
      nextPing := now+15000
    let before ← IO.monoMsNow
    let (frames, tail) ← checked c ledgerId store pending (IO.ofExcept (parseFrames buffer))
    buffer := tail
    let mut nodes : Array (Array (ByteArray × ByteArray)) := Array.replicate 65 #[]
    let mut replied : Std.HashSet ByteArray := {}
    for frame in frames do
      if frame.messageType == 3 then
        let (next, actions) := controls.onPing (← checked c ledgerId store pending (IO.ofExcept (decodePing frame.payload)))
        controls := next
        for action in actions do
          try connection.sendControl action catch e => return (some e.toString, metrics)
      else if frame.messageType == 32 then
        let reply ← checked c ledgerId store pending do
          let reply ← IO.ofExcept (decodeLedgerData frame.payload)
          require (reply.hash == header.hash && reply.sequence == header.sequence) "peer reply changed pinned ledger identity"
          require (reply.kind == 2) "unexpected peer ledger reply type"
          return reply
        if reply.error.isSome then return (some s!"peer cannot serve pinned ledger: {reply.error}", metrics)
        for (id, wire) in reply.nodes do
          let id ← checked c ledgerId store pending do
            let some id := id | throw <| IO.userError "state node omitted ID"
            discard <| IO.ofExcept (decodeNodeID id)
            return id
          nodes := nodes.modify id[32]!.toNat (·.push (id,wire))
          replied := replied.insert id
    if nodes.any (fun level => !level.isEmpty) || (flights.size < 4 && (← NodeStore.pendingReady store now.toUInt64)) then
      -- Authenticated nodes, frontier changes and request leases share a bounded
      -- transaction. Read-only requests may use authenticated uncommitted parents;
      -- only committed counters are reported, and recovery restarts at that frontier.
      if !(← pending.get) then
        NodeStore.begin store
        pending.set true
      let (active, batches, count) ← checked c ledgerId store pending do
        let mut count := 0
        -- There are only 65 depths. Bucketing is linear even when thousands
        -- of leaves share one depth; depth-only quicksort is quadratic there.
        for level in nodes do
          for (id,wire) in level do
            if ← StateReuse.accept reuse store id wire then count := count+1
        let mut active := #[]
        for flight in flights do
          if flight.ids.any replied.contains then
            -- xrpld caps replies. Unserved paths must not wait for lease expiry.
            NodeStore.releasePending store (flight.ids.foldl (· ++ ·) ByteArray.empty)
          else if now-flight.sent < 10000 then
            let mut missing := false
            for id in flight.ids do
              if !(← NodeStore.expected store id).isEmpty then missing := true; break
            if missing then active := active.push flight
        let mut batches := #[]
        for _ in [:4-active.size] do
          let packed ← NodeStore.reserve store now.toUInt64 128
          let mut ids := #[]
          for i in [:packed.size/33] do
            let id := packed.extract (i*33) (i*33+33)
            let expected ← NodeStore.expected store id
            if ← StateReuse.reuse reuse store id expected then
              count := count+1
            else
              let existing ← NodeStore.getNode store expected
              let cached ← if existing.isEmpty then StateReuse.cached reuse expected else pure existing
              if cached.isEmpty then ids := ids.push id
              else
                discard <| StateReuse.accept reuse store id cached
                count := count+1
          if !ids.isEmpty then batches := batches.push ids
        return (active,batches,count)
      flights := active
      if count > 0 then lastProgress ← IO.monoMsNow
      for ids in batches do
        try connection.sendAction (.stateNodes header.hash header.sequence ids (if reuse.isSome then 0 else 3))
        catch e => return (some e.toString, metrics)
        requests := requests+1
        flights := flights.push ⟨now,ids⟩
    else
      -- Even a silent peer must eventually free a window slot for a retry.
      flights := flights.filter fun flight => now-flight.sent < 10000
    localMs := localMs+(← IO.monoMsNow)-before
    if let some reason := readError then
      flushBatch store pending
      if (← NodeStore.stats store).pending == 0 then continue
      return (some reason, metrics)
    -- Coalesce a short, bounded receive burst. Unrelated
    -- gossip cannot extend the useful-progress deadline or trigger writes.
    let deadline := (← IO.monoMsNow)+25
    let mut burst := 0
    repeat
      let time ← IO.monoMsNow
      let next ← try connection.readUntil (if burst == 0 then time+20 else deadline)
        catch e => do
          if buffer.isEmpty then return (some e.toString, metrics)
          readError := some e.toString
          pure none
      let some bytes := next | break
      received := received+bytes.size
      require (buffer.size+bytes.size ≤ maxFrameSize+6) "peer receive buffer limit"
      buffer := buffer ++ bytes
      burst := burst+bytes.size
      if burst ≥ 4194304 || (← IO.monoMsNow) ≥ deadline then break

private def session (c : Config) (ledgerId : Nat) (stop : IO.Ref Bool) (header : LedgerHeader)
    (store : NodeStore.Store) (reuse : Option StateReuse.Context) (connection : Connection) (initial : ByteArray)
    (progress : FetchProgress → IO Unit) : Async (Option String × Json) := do
  let pending ← IO.mkRef false
  try sessionLoop c ledgerId stop header store reuse connection initial progress pending
  finally flushBatch store pending

private def localReady (reuse : Option StateReuse.Context) (stop : IO.Ref Bool)
    (store : NodeStore.Store) : IO Bool := do
  if reuse.isNone then return (← NodeStore.stats store).pending == 0
  repeat
    require (!(← stop.get)) "acquisition interrupted; rerun this fetch to resume"
    if (← NodeStore.stats store).pending == 0 then return true
    let needsNetwork ← NodeStore.transaction store do
      let packed ← NodeStore.reserve store (← IO.monoMsNow).toUInt64 128
      let mut missing := ByteArray.empty
      for i in [:packed.size/33] do
        let id := packed.extract (i*33) (i*33+33)
        let expected ← NodeStore.expected store id
        unless ← StateReuse.reuse reuse store id expected do
          let wire ← StateReuse.cached reuse expected
          if wire.isEmpty then missing := missing ++ id
          else discard <| StateReuse.accept reuse store id wire
      if !missing.isEmpty then NodeStore.releasePending store missing
      return !missing.isEmpty || packed.isEmpty
    if needsNetwork then return false

private def finish (c : Config) (id : Nat) (header : LedgerHeader) (store : NodeStore.Store)
    (path : String) (reuse : Option StateReuse.Context) (metrics : Json) (started : Nat) : IO Result := do
  require ((← NodeStore.stats store).pending == 0) "peer snapshot remains incomplete"
  let backing := reuse.bind (fun r => r.stores.toList.getLast?)
  let repo ← StateTree.Repository.readOnly store 134217728 backing
  if header.stateRoot != zeroHash then discard <| repo.load (← IO.ofExcept (StateTree.Hash.ofBytes header.stateRoot))
  let sources ← StateReuse.publish reuse store path
  let .obj fields := metrics | throw <| IO.userError "invalid acquisition metrics"
  let metrics := Json.obj (fields.insert "elapsed_ms" (toJson ((← IO.monoMsNow)-started)))
  NodeStore.transaction store do
    NodeStore.putMeta store "xl_peer_complete" "true"
    NodeStore.putMeta store "xl_peer_metrics" metrics.compress
  NodeStore.checkpoint store
  status c id "complete"
  return ⟨path,true,"",metrics,sources⟩

def run (c : Config) (stop : IO.Ref Bool) (header : LedgerHeader) (id : Nat)
    (progress : FetchProgress → IO Unit) : Async Result := do
  let started ← IO.monoMsNow
  let lock ← XL.lock (c.data / "peer-session.lock").toString
  try
    let (path,scope) ← start c id header
    let store ← SharedState.openScope path scope
    try
      let identity := obj [("version",toJson (1:Nat)),("network",toJson c.network),
        ("ledger_index",toJson header.sequence),("ledger_hash",str (hex header.hash)),
        ("root",str (hex header.stateRoot))]
      let checkpoint ← NodeStore.getMeta store "xl_peer"
      if checkpoint.isEmpty then
        NodeStore.transaction store do
          require ((← NodeStore.stats store).nodes == 0) "unidentified peer node store"
          NodeStore.putMeta store "xl_peer" identity.compress
          NodeStore.putMeta store "xl_peer_bundle" c.bundle
          if header.stateRoot != zeroHash then NodeStore.addPending store (nodeID #[]) header.stateRoot
      else require ((← IO.ofExcept (Json.parse checkpoint)) == identity) "peer checkpoint identity mismatch"
      let savedBundle ← NodeStore.getMeta store "xl_peer_bundle"
      require (savedBundle == c.bundle || (savedBundle.isEmpty && c.bundle == "default")) "peer checkpoint bundle mismatch"
      let completed := (← NodeStore.getMeta store "xl_peer_complete") == "true"
      let initialStats ← NodeStore.stats store
      let resumed := !checkpoint.isEmpty
      let progress : FetchProgress → IO Unit := fun p => do
        let elapsed := (← IO.monoMsNow)-started
        progress {p with
          resumed, checkpointEntries := initialStats.leaves,
          runEntries := p.entries-initialStats.leaves, runElapsedMs := elapsed, elapsedMs := elapsed}
      let reuse ← StateReuse.prepare c header store completed
      try
        if completed then
          require ((← NodeStore.stats store).pending == 0) "completed peer store has missing nodes"
          let backing := reuse.bind (fun r => r.stores.toList.getLast?)
          let repo ← StateTree.Repository.readOnly store 134217728 backing
          if header.stateRoot != zeroHash then discard <| repo.load (← IO.ofExcept (StateTree.Hash.ofBytes header.stateRoot))
          status c id "complete"
          let metrics ← IO.ofExcept (Json.parse (← NodeStore.getMeta store "xl_peer_metrics"))
          let .obj fields := metrics | throw <| IO.userError "invalid peer snapshot metrics"
          return ⟨path,true,"",.obj (fields.insert "reused" (.bool true)),
            #[path]⟩
        if ← localReady reuse stop store then
          let stats ← NodeStore.stats store
          return ← finish c id header store path reuse (obj [
            ("elapsed_ms",toJson (0:Nat)),("requests",toJson (0:Nat)),("nodes",toJson stats.nodes),
            ("entries",toJson stats.leaves),("stored_node_bytes",toJson stats.bytes),
            ("incremental",.bool reuse.isSome),("base_ledger_hash",reuse.map (fun r => str (hex r.base.header.hash)) |>.getD .null),
            ("reused_subtrees",toJson ((← NodeStore.getMeta store "xl_peer_reused").toNat?.getD 0))]) started
        let some endpoint := c.peer | return ⟨path,false,"peer endpoint is not configured",.null,#[]⟩
        let key ← Native.keyLoad (c.data / "peer-identity.pem").toString
        let selfPublic ← Native.keyPublic key
        let key ← Std.Mutex.new key
        let permits ← Std.Semaphore.new 1
        progress {
          ledgerIndex := header.sequence
          phase := if resumed then "peer_resuming" else "peer_connecting"
          transport := "peer"
          entries := (← NodeStore.stats store).leaves
          nodes := (← NodeStore.stats store).nodes
          pending := (← NodeStore.stats store).pending
          incremental := reuse.isSome
          baseLedgerHash := reuse.map (fun r => hex r.base.header.hash) |>.getD ""
          reusedSubtrees := (← NodeStore.getMeta store "xl_peer_reused").toNat?.getD 0
          stateBytes := (← NodeStore.stats store).bytes }
        let connected ← try pure (Except.ok (← connectPeer endpoint key selfPublic c.network permits))
          catch e => pure (Except.error e.toString)
        require (!(← stop.get)) "acquisition interrupted; rerun this fetch to resume"
        match connected with
        | .error reason => return ⟨path,false,reason,.null,#[]⟩
        | .ok (.redirects _) => return ⟨path,false,"configured peer redirected; redirects are not followed",.null,#[]⟩
        | .ok (.peer connection _ tail) =>
          let (failure, metrics) ← try
            session c id stop header store reuse connection tail progress
          finally connection.release
          if let some reason := failure then return ⟨path,false,reason,metrics,#[]⟩
          finish c id header store path reuse metrics started
      finally if let some reuse := reuse then reuse.close
    finally NodeStore.dispose store
  finally XL.unlock lock

end XLB.PeerAcquire
