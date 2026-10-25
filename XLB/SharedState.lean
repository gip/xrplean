import XLB.Store

namespace XLB.SharedState
open Lean LeanXRPL XL

/-- Adopt a retained full store in place. A fresh bundle creates one node store.
    Acquisitions share its payload catalog and have independent checkpoint scopes. -/
def path (c : Config) : IO String := do
  let rows ← sql c.db s!"SELECT path FROM bundle_node_stores WHERE bundle={← quote c.bundle}"
  if let some row := rows[0]? then return row[0]!
  let retained ← sql c.db s!"SELECT s.sources_json FROM states s JOIN ledgers l ON l.id=s.ledger_id
    WHERE s.bundle={← quote c.bundle} AND l.network={c.network} AND s.origin IN ('peer_snapshot','rpc_snapshot') ORDER BY l.idx,l.hash"
  let mut selected := (c.bundleDir / "nodes.sqlite3").toString
  if let some row := retained[0]? then
    let sources ← IO.ofExcept ((Json.parse row[0]!).bind Json.getArr?)
    require (!sources.isEmpty) "completed snapshot has no node store"
    selected ← IO.ofExcept sources[0]!.getStr?
    if sources.size == 2 then
      let view ← NodeStore.openReadOnly (← IO.ofExcept sources[1]!.getStr?) 1099511627776
      try selected ← NodeStore.viewBase view finally NodeStore.dispose view
  -- A legacy in-progress store can also become the shared store without copying.
  else
    let pending ← sql c.db s!"SELECT path FROM peer_downloads WHERE bundle={← quote c.bundle} AND status!='invalid'
      UNION ALL SELECT path FROM state_downloads WHERE bundle={← quote c.bundle} AND status!='invalid' LIMIT 1"
    if let some row := pending[0]? then selected := row[0]!
  exec c s!"INSERT INTO bundle_node_stores(bundle,path) VALUES({← quote c.bundle},{← quote selected})"
  return selected

def openScope (path scope : String) (readonly := false) : IO NodeStore.Store := do
  let store ← if readonly then NodeStore.openReadOnly path 1099511627776 else NodeStore.openStore path 1099511627776 .nudb
  try NodeStore.setScope store scope; return store
  catch e => NodeStore.dispose store; throw e

private def cleanup (c : Config) : IO Nat := do
  let garbage ← sql c.db s!"SELECT path FROM bundle_cleanup_paths WHERE bundle={← quote c.bundle}"
  for row in garbage do
    let file := System.FilePath.mk row[0]!
    require (file.parent == some (c.bundleDir / "states")) "cleanup outside bundle states directory"
    let references ← sql c.db s!"SELECT path FROM bundle_node_stores WHERE path={← quote row[0]!}
      UNION SELECT path FROM peer_downloads WHERE path={← quote row[0]!}
      UNION SELECT path FROM state_downloads WHERE path={← quote row[0]!}
      UNION SELECT sources_json FROM states WHERE sources_json LIKE '%' || {← quote row[0]!} || '%'
      UNION SELECT report_json FROM verifications WHERE report_json LIKE '%' || {← quote row[0]!} || '%'"
    require references.isEmpty "cleanup path still has live references"
    let dir := System.FilePath.mk (row[0]! ++ ".nodes")
    if ← dir.pathExists then
      require ((← IO.FS.realPath dir).parent == some (c.bundleDir / "states")) "node directory outside bundle"
      IO.FS.removeDirAll dir
    for suffix in ["-wal","-shm",".lock",""] do
      let item := System.FilePath.mk (row[0]! ++ suffix)
      if ← item.pathExists then IO.FS.removeFile item
    exec c s!"DELETE FROM bundle_cleanup_paths WHERE bundle={← quote c.bundle} AND path={← quote row[0]!}"
  return garbage.size

/-- Adopt the existing full tree in place and remove superseded, unpublished
    transport stores. Published roots and acquisition/proof task history remain. -/
def consolidate (c : Config) : IO Json := do
  let lock ← XL.lock (c.bundleDir / "acquisition.lock").toString
  try
    let active ← sql c.db s!"SELECT id FROM acquisition_tasks WHERE bundle={← quote c.bundle} AND status IN ('queued','running')"
    require active.isEmpty "stop active bundle acquisition before consolidating storage"
    let proofs ← sql c.db s!"SELECT id FROM jobs WHERE bundle={← quote c.bundle} AND status IN ('queued','running')"
    require proofs.isEmpty "finish active proof jobs before consolidating storage"
    let shared ← path c
    let retained ← sql c.db s!"SELECT sources_json FROM states WHERE bundle={← quote c.bundle}"
    for row in retained do
      require ((← IO.ofExcept ((Json.parse row[0]!).bind Json.getArr?)) == #[str shared])
        "legacy multi-store snapshots require payload migration before consolidation"
    let store ← NodeStore.openStore shared 1099511627776 .nudb
    try
      let owner := obj [("network",toJson c.network),("bundle",str c.bundle)]
      let previous ← NodeStore.getMeta store "xl_bundle_store"
      require (previous.isEmpty || previous == owner.compress) "shared store belongs to another bundle or network"
      NodeStore.transaction store (NodeStore.putMeta store "xl_bundle_store" owner.compress)
      NodeStore.checkpoint store
    finally NodeStore.dispose store
    for table in ["peer_downloads","state_downloads"] do
      exec c s!"BEGIN IMMEDIATE;
        INSERT OR IGNORE INTO bundle_cleanup_paths SELECT d.bundle,d.path FROM {table} d
          WHERE d.bundle={← quote c.bundle} AND d.path!={← quote shared} AND d.status!='complete'
          AND EXISTS(SELECT 1 FROM states s WHERE s.bundle=d.bundle AND s.ledger_id=d.ledger_id
            AND s.origin IN ('peer_snapshot','rpc_snapshot'));
        DELETE FROM {table} WHERE bundle={← quote c.bundle} AND path!={← quote shared} AND status!='complete'
          AND EXISTS(SELECT 1 FROM states s WHERE s.bundle={table}.bundle AND s.ledger_id={table}.ledger_id
            AND s.origin IN ('peer_snapshot','rpc_snapshot')); COMMIT;"
    let removed ← cleanup c
    return obj [("bundle",str c.bundle),("node_store",str shared),("retained_roots",toJson retained.size),
      ("removed_stores",toJson removed)]
  finally XL.unlock lock

/-- Explicit operator deletion of an unpublished acquisition. Shared payloads are
    never removed: other retained roots can refer to the same content hashes. -/
def discard (c : Config) (j : Json) : IO Json := do
  let idx ← nat j "ledger_index"
  let h ← hash (← string j "ledger_hash")
  let lock ← XL.lock (c.bundleDir / "acquisition.lock").toString
  try
    let active ← sql c.db s!"SELECT id FROM acquisition_tasks WHERE bundle={← quote c.bundle} AND status IN ('queued','running')"
    require active.isEmpty "stop active bundle acquisition before discarding its checkpoint"
    let proofs ← sql c.db s!"SELECT id FROM jobs WHERE bundle={← quote c.bundle} AND status IN ('queued','running')"
    require proofs.isEmpty "finish active proof jobs before discarding state"
    let complete ← sql c.db s!"SELECT l.id FROM states s JOIN ledgers l ON l.id=s.ledger_id
      WHERE s.bundle={← quote c.bundle} AND l.network={c.network} AND l.idx={idx} AND l.hash={← quote h}"
    if !complete.isEmpty then
      require ((j.getObjVal? "allow_published").toOption == some (.bool true)) "cannot discard a published ledger state"
      let retained ← sql c.db s!"SELECT s.ledger_id FROM states s JOIN ledgers l ON l.id=s.ledger_id
        WHERE s.bundle={← quote c.bundle} AND l.network={c.network} AND l.hash!={← quote h}
        AND s.origin IN ('peer_snapshot','rpc_snapshot')"
      require (!retained.isEmpty) "cannot discard the bundle's only completed snapshot"
      let anchors ← sql c.db s!"SELECT t.id FROM trust_anchors t JOIN ledgers l ON l.id=t.ledger_id
        WHERE t.bundle={← quote c.bundle} AND l.network={c.network} AND l.hash={← quote h}"
      require anchors.isEmpty "cannot discard an operator trust anchor's state"
    let rows ← sql c.db s!"SELECT d.path,d.scope FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id
      WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND l.idx={idx} AND l.hash={← quote h}
      UNION SELECT d.path,d.scope FROM state_downloads d JOIN ledgers l ON l.id=d.ledger_id
      WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND l.idx={idx} AND l.hash={← quote h}"
    let shared ← sql c.db s!"SELECT path FROM bundle_node_stores WHERE bundle={← quote c.bundle}"
    for row in rows do
      if !(shared.any (·[0]! == row[0]!)) then
        require ((System.FilePath.mk row[0]!).parent == some (c.bundleDir / "states")) "checkpoint outside bundle states directory"
        let references ← sql c.db s!"SELECT ledger_id FROM states WHERE sources_json LIKE '%' || {← quote row[0]!} || '%'
          AND NOT (bundle={← quote c.bundle} AND ledger_id IN (SELECT id FROM ledgers WHERE network={c.network} AND idx={idx} AND hash={← quote h}))
          UNION SELECT id FROM verifications WHERE report_json LIKE '%' || {← quote row[0]!} || '%'"
        require references.isEmpty "checkpoint is referenced by a retained state"
        -- An interrupted overlay may have created an otherwise unused view.
        let source ← NodeStore.openMetadata row[0]! 1099511627776
        let view ← try
          NodeStore.setScope source row[1]!
          NodeStore.getMeta source "xl_peer_view"
        finally NodeStore.dispose source
        if !view.isEmpty then
          require ((System.FilePath.mk view).parent == some (c.bundleDir / "states")) "view outside bundle states directory"
          let refs ← sql c.db s!"SELECT sources_json FROM states WHERE sources_json LIKE '%' || {← quote view} || '%'
            AND NOT (bundle={← quote c.bundle} AND ledger_id IN (SELECT id FROM ledgers WHERE network={c.network} AND idx={idx} AND hash={← quote h}))
            UNION SELECT report_json FROM verifications WHERE report_json LIKE '%' || {← quote view} || '%'"
          if refs.isEmpty then
            exec c s!"INSERT OR IGNORE INTO bundle_cleanup_paths VALUES({← quote c.bundle},{← quote view})"
    exec c s!"BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO bundle_cleanup_paths SELECT d.bundle,d.path FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id
        WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND l.idx={idx} AND l.hash={← quote h}
        AND NOT EXISTS(SELECT 1 FROM bundle_node_stores b WHERE b.path=d.path);
      INSERT OR IGNORE INTO bundle_cleanup_paths SELECT d.bundle,d.path FROM state_downloads d JOIN ledgers l ON l.id=d.ledger_id
        WHERE d.bundle={← quote c.bundle} AND l.network={c.network} AND l.idx={idx} AND l.hash={← quote h}
        AND NOT EXISTS(SELECT 1 FROM bundle_node_stores b WHERE b.path=d.path);
      DELETE FROM peer_downloads WHERE bundle={← quote c.bundle} AND ledger_id IN (SELECT id FROM ledgers WHERE network={c.network} AND idx={idx} AND hash={← quote h});
      DELETE FROM state_downloads WHERE bundle={← quote c.bundle} AND ledger_id IN (SELECT id FROM ledgers WHERE network={c.network} AND idx={idx} AND hash={← quote h});
      DELETE FROM states WHERE bundle={← quote c.bundle} AND ledger_id IN (SELECT id FROM ledgers WHERE network={c.network} AND idx={idx} AND hash={← quote h}); COMMIT;"
    let removed ← cleanup c
    return obj [("discarded",.bool true),("ledger_index",toJson idx),("ledger_hash",str h),
      ("checkpoints",toJson rows.size),("removed_stores",toJson removed)]
  finally XL.unlock lock

end XLB.SharedState
