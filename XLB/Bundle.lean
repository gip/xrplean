import XLB.Acquire

namespace XLB.Bundle
open Lean LeanXRPL XL Std.Async

def info (c : Config) : IO Json := do
  let registered ← sql c.db s!"SELECT network FROM bundles WHERE name={← quote c.bundle}"
  require (registered == #[#[toString c.network]]) "bundle not found on this network"
  let rows ← sql c.db s!"SELECT l.idx,l.hash,l.state_root,s.origin FROM states s JOIN ledgers l ON l.id=s.ledger_id
    WHERE s.bundle={← quote c.bundle} AND l.network={c.network} AND s.origin IN ('peer_snapshot','rpc_snapshot') ORDER BY l.idx,l.hash"
  let mut indices : Array Nat := #[]
  for row in rows do
    let some idx := row[0]!.toNat? | throw <| IO.userError "invalid retained ledger index"
    if indices.toList.getLast? != some idx then indices := indices.push idx
  let mut intervals : Array (Nat × Nat) := #[]
  for idx in indices do
    if let some last := intervals.toList.getLast? then
      if last.2+1 == idx then intervals := intervals.set! (intervals.size-1) (last.1,idx)
      else intervals := intervals.push (idx,idx)
    else intervals := intervals.push (idx,idx)
  let pending ← sql c.db s!"SELECT l.idx,l.hash,d.status FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id
    WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND d.status!='complete' AND NOT EXISTS (SELECT 1 FROM states s WHERE s.bundle=d.bundle AND s.ledger_id=d.ledger_id AND s.origin IN ('peer_snapshot','rpc_snapshot'))
    UNION SELECT l.idx,l.hash,d.status FROM state_downloads d JOIN ledgers l ON l.id=d.ledger_id
    WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND d.status!='complete' AND NOT EXISTS (SELECT 1 FROM states s WHERE s.bundle=d.bundle AND s.ledger_id=d.ledger_id AND s.origin IN ('peer_snapshot','rpc_snapshot'))"
  let tip := rows.toList.getLast?
  let shared ← sql c.db s!"SELECT path FROM bundle_node_stores WHERE bundle={← quote c.bundle}"
  return obj [("bundle",str c.bundle),("network_id",toJson c.network),("path",str c.bundleDir.toString),
    ("status",str (if !pending.isEmpty then "acquiring" else if rows.isEmpty then "empty" else "complete")),
    ("ledger_count",toJson indices.size),("snapshot_count",toJson rows.size),("ledger_intervals",toJson (intervals.map fun (a,b) => obj [("first",toJson a),("last",toJson b)])),
    ("has_gaps",.bool (intervals.size > 1)),("first_ledger",toJson indices[0]?),
    ("last_ledger",toJson indices.toList.getLast?),("ledger_hash",tip.map (fun r => str r[1]!) |>.getD .null),
    ("state_root",tip.map (fun r => str r[2]!) |>.getD .null),
    ("pending",toJson (pending.map fun r => obj [("ledger_index",str r[0]!),("ledger_hash",str r[1]!)])),
    ("node_store",shared[0]?.map (fun row => str row[0]!) |>.getD .null),
    ("trust",str "unchanged"),("proofs",str "separate")]

def list (c : Config) : IO Json := do
  let rows ← sql c.db s!"SELECT name FROM bundles WHERE network={c.network} ORDER BY name"
  return toJson (← rows.mapM fun row => info {c with bundle := row[0]!})

def prepare (c : Config) (stop : IO.Ref Bool) (action : String) (j : Json)
    (progress : FetchProgress → IO Unit := fun _ => pure ()) : Async Json := do
  Store.ensureBundle c
  let summary ← info c
  let current := optNat summary "last_ledger"
  require (action == "new" || current > 0) "bundle update requires a completed base in this bundle"
  let selector ← string j "index"
  let parse (raw : String) : IO Nat := do
    let some idx := raw.toNat? | throw <| IO.userError "index must be latest, INDEX, START:END, or :END"
    index idx
    return idx
  let (first,last) ← match selector.splitOn ":" with
    | ["latest"] =>
      let active ← if action == "new" && current == 0 then
        sql c.db s!"SELECT l.idx FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id WHERE d.bundle={← quote c.bundle} AND d.status!='complete' AND NOT EXISTS (SELECT 1 FROM states s WHERE s.bundle=d.bundle AND s.ledger_id=d.ledger_id AND s.origin IN ('peer_snapshot','rpc_snapshot'))
          UNION SELECT l.idx FROM state_downloads d JOIN ledgers l ON l.id=d.ledger_id WHERE d.bundle={← quote c.bundle} AND d.status!='complete' AND NOT EXISTS (SELECT 1 FROM states s WHERE s.bundle=d.bundle AND s.ledger_id=d.ledger_id AND s.origin IN ('peer_snapshot','rpc_snapshot'))"
        else pure #[]
      require (active.size ≤ 1) "multiple unfinished targets; select an explicit index"
      let last ← if let some row := active[0]? then parse row[0]! else Acquire.latestIndex c stop progress
      pure (if action == "update" && last > current then current+1 else last,last)
    | [raw] =>
      let last ← parse raw
      pure (if action == "update" && last > current then current+1 else last,last)
    | [a,b] =>
      let last ← parse b
      let first ← if a.isEmpty then
        require (action == "update" && current > 0) ":END requires a completed bundle"
        pure (current+1)
        else parse a
      pure (first,last)
    | _ => throw <| IO.userError "invalid ledger interval"
  require (first ≤ last && last-first < 10000) "range must contain 1 to 10000 ledgers"
  if action == "new" && current > 0 then
    require (last ≤ current) "bundle already has a completed base; use bundle update"
  let mut fields := [("from",toJson first),("to",toJson last),("state",.bool true),
    ("transport",str (optString j "transport" "auto"))]
  if let .ok value := j.getObjVal? "ledger_hash" then fields := ("ledger_hash",value)::fields
  if action == "update" && first > current then
    require (first == current+1) "update interval must start immediately after the completed bundle tip"
    let tips ← sql c.db s!"SELECT l.hash FROM states s JOIN ledgers l ON l.id=s.ledger_id
      WHERE s.bundle={← quote c.bundle} AND l.network={c.network} AND l.idx={current} AND s.origin IN ('peer_snapshot','rpc_snapshot')"
    require (tips.size == 1) "bundle tip has fork variants; acquire the exact fork with ledger get --index INDEX --hash HASH"
    fields := ("expected_parent_hash",str tips[0]![0]!)::fields
  return obj fields

def acquire (c : Config) (stop : IO.Ref Bool) (action : String) (j : Json)
    (progress : FetchProgress → IO Unit := fun _ => pure ()) : Async Json := do
  Acquire.fetch c stop (← prepare c stop action j progress) progress

end XLB.Bundle
