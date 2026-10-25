import XL.Basic

namespace XLB.Store
open Lean LeanXRPL XL

def init (c : Config) : IO Unit := do
  IO.FS.createDirAll c.data
  IO.FS.createDirAll (c.data / "proofs")
  let versions ← sql c.db "PRAGMA user_version"
  require (versions == #[#["0"]] || versions == #[#["1"]] || versions == #[#["2"]] || versions == #[#["3"]] || versions == #[#["4"]]) "unsupported XL database schema"
  exec c "PRAGMA journal_mode=WAL; BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS ledgers(
      id INTEGER PRIMARY KEY, network INTEGER NOT NULL, idx INTEGER NOT NULL,
      hash TEXT NOT NULL, parent_hash TEXT NOT NULL, state_root TEXT NOT NULL,
      header_json TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(network,hash));
    CREATE INDEX IF NOT EXISTS ledger_index ON ledgers(network,idx);
    CREATE TABLE IF NOT EXISTS exports(
      id INTEGER PRIMARY KEY, ledger_id INTEGER NOT NULL REFERENCES ledgers(id),
      digest TEXT NOT NULL, payload TEXT NOT NULL, received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(ledger_id,digest));
    CREATE TABLE IF NOT EXISTS trust_anchors(
      id INTEGER PRIMARY KEY, ledger_id INTEGER NOT NULL UNIQUE REFERENCES ledgers(id),
      reason TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    CREATE TABLE IF NOT EXISTS states(
      ledger_id INTEGER PRIMARY KEY REFERENCES ledgers(id), sources_json TEXT NOT NULL,
      origin TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    CREATE TABLE IF NOT EXISTS state_downloads(
      ledger_id INTEGER PRIMARY KEY REFERENCES ledgers(id), path TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL CHECK(status IN ('downloading','complete','invalid')),
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    CREATE TABLE IF NOT EXISTS peer_downloads(
      ledger_id INTEGER PRIMARY KEY REFERENCES ledgers(id), path TEXT NOT NULL UNIQUE,
      status TEXT NOT NULL CHECK(status IN ('downloading','complete','invalid')),
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    CREATE TABLE IF NOT EXISTS jobs(
      id INTEGER PRIMARY KEY, network INTEGER NOT NULL, first_idx INTEGER NOT NULL,
      last_idx INTEGER NOT NULL, checks_json TEXT NOT NULL, status TEXT NOT NULL
        CHECK(status IN ('queued','running','succeeded','blocked','failed','unsupported','interrupted','cancelled')),
      cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancel_requested IN (0,1)),
      error TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    CREATE TABLE IF NOT EXISTS job_items(
      job_id INTEGER NOT NULL REFERENCES jobs(id), idx INTEGER NOT NULL,
      export_id INTEGER REFERENCES exports(id), status TEXT NOT NULL DEFAULT 'pending',
      error TEXT NOT NULL DEFAULT '', PRIMARY KEY(job_id,idx));
    CREATE TABLE IF NOT EXISTS verifications(
      id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL REFERENCES jobs(id),
      export_id INTEGER NOT NULL REFERENCES exports(id), kind TEXT NOT NULL,
      status TEXT NOT NULL, anchor_id INTEGER REFERENCES trust_anchors(id),
      parent_verification_id INTEGER REFERENCES verifications(id),
      report_json TEXT NOT NULL, artifacts_json TEXT NOT NULL, attempt_dir TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    COMMIT;"
  if versions != #[#["3"]] && versions != #[#["4"]] then
    exec c "PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=ON; BEGIN IMMEDIATE;
      CREATE TABLE states_v3(bundle TEXT NOT NULL DEFAULT 'default',ledger_id INTEGER NOT NULL REFERENCES ledgers(id),sources_json TEXT NOT NULL,origin TEXT NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(bundle,ledger_id));
      INSERT INTO states_v3 SELECT 'default',ledger_id,sources_json,origin,created_at FROM states;
      DROP TABLE states; ALTER TABLE states_v3 RENAME TO states;
      CREATE TABLE state_downloads_v3(bundle TEXT NOT NULL DEFAULT 'default',ledger_id INTEGER NOT NULL REFERENCES ledgers(id),path TEXT NOT NULL UNIQUE,status TEXT NOT NULL CHECK(status IN ('downloading','complete','invalid')),updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(bundle,ledger_id));
      INSERT INTO state_downloads_v3 SELECT 'default',ledger_id,path,status,updated_at FROM state_downloads;
      DROP TABLE state_downloads; ALTER TABLE state_downloads_v3 RENAME TO state_downloads;
      CREATE TABLE peer_downloads_v3(bundle TEXT NOT NULL DEFAULT 'default',ledger_id INTEGER NOT NULL REFERENCES ledgers(id),path TEXT NOT NULL UNIQUE,status TEXT NOT NULL CHECK(status IN ('downloading','complete','invalid')),updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(bundle,ledger_id));
      INSERT INTO peer_downloads_v3 SELECT 'default',ledger_id,path,status,updated_at FROM peer_downloads;
      DROP TABLE peer_downloads; ALTER TABLE peer_downloads_v3 RENAME TO peer_downloads;
      CREATE TABLE trust_anchors_v3(id INTEGER PRIMARY KEY,bundle TEXT NOT NULL DEFAULT 'default',ledger_id INTEGER NOT NULL REFERENCES ledgers(id),reason TEXT NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,UNIQUE(bundle,ledger_id));
      INSERT INTO trust_anchors_v3 SELECT id,'default',ledger_id,reason,created_at FROM trust_anchors;
      DROP TABLE trust_anchors; ALTER TABLE trust_anchors_v3 RENAME TO trust_anchors;
      ALTER TABLE jobs ADD COLUMN bundle TEXT NOT NULL DEFAULT 'default';
      PRAGMA user_version=3; COMMIT; PRAGMA foreign_keys=ON; PRAGMA legacy_alter_table=OFF;"
    require (← sql c.db "PRAGMA foreign_key_check").isEmpty "bundle migration foreign key check failed"
  exec c "CREATE TABLE IF NOT EXISTS bundles(name TEXT PRIMARY KEY,network INTEGER NOT NULL,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
    CREATE UNIQUE INDEX IF NOT EXISTS bundle_names_folded ON bundles(lower(name));"
  if versions != #[#["4"]] then
    exec c "BEGIN IMMEDIATE;
      CREATE TABLE peer_downloads_v4(bundle TEXT NOT NULL,ledger_id INTEGER NOT NULL REFERENCES ledgers(id),path TEXT NOT NULL,scope TEXT NOT NULL DEFAULT '',status TEXT NOT NULL CHECK(status IN ('downloading','complete','invalid')),updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(bundle,ledger_id));
      INSERT INTO peer_downloads_v4(bundle,ledger_id,path,status,updated_at) SELECT bundle,ledger_id,path,status,updated_at FROM peer_downloads;
      DROP TABLE peer_downloads; ALTER TABLE peer_downloads_v4 RENAME TO peer_downloads;
      CREATE TABLE state_downloads_v4(bundle TEXT NOT NULL,ledger_id INTEGER NOT NULL REFERENCES ledgers(id),path TEXT NOT NULL,scope TEXT NOT NULL DEFAULT '',status TEXT NOT NULL CHECK(status IN ('downloading','complete','invalid')),updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(bundle,ledger_id));
      INSERT INTO state_downloads_v4(bundle,ledger_id,path,status,updated_at) SELECT bundle,ledger_id,path,status,updated_at FROM state_downloads;
      DROP TABLE state_downloads; ALTER TABLE state_downloads_v4 RENAME TO state_downloads;
      PRAGMA user_version=4; COMMIT;"
  exec c "CREATE TABLE IF NOT EXISTS bundle_node_stores(bundle TEXT PRIMARY KEY REFERENCES bundles(name),path TEXT NOT NULL UNIQUE);
    CREATE TABLE IF NOT EXISTS bundle_cleanup_paths(bundle TEXT NOT NULL,path TEXT NOT NULL,PRIMARY KEY(bundle,path));"
  -- received_at follows the potentially large payload in the table record.
  -- A covering index keeps inventory reads off its overflow pages entirely.
  exec c "CREATE INDEX IF NOT EXISTS exports_metadata ON exports(ledger_id,id,digest,received_at);
    CREATE INDEX IF NOT EXISTS verification_export_kind ON verifications(export_id,kind,id DESC,job_id,status);"
  exec c s!"INSERT OR IGNORE INTO bundles(name,network) VALUES('default',{c.network})"
  let jobFields ← sql c.db "PRAGMA table_info(jobs)"
  if !jobFields.any (fun row => row[1]! == "cancel_requested") then
    exec c "PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=ON; BEGIN IMMEDIATE;
      CREATE TABLE jobs_cancel(id INTEGER PRIMARY KEY,network INTEGER NOT NULL,first_idx INTEGER NOT NULL,
        last_idx INTEGER NOT NULL,checks_json TEXT NOT NULL,status TEXT NOT NULL
          CHECK(status IN ('queued','running','succeeded','blocked','failed','unsupported','interrupted','cancelled')),
        error TEXT NOT NULL DEFAULT '',created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,bundle TEXT NOT NULL DEFAULT 'default',
        cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancel_requested IN (0,1)));
      INSERT INTO jobs_cancel(id,network,first_idx,last_idx,checks_json,status,error,created_at,updated_at,bundle)
        SELECT id,network,first_idx,last_idx,checks_json,status,error,created_at,updated_at,bundle FROM jobs;
      DROP TABLE jobs; ALTER TABLE jobs_cancel RENAME TO jobs;
      COMMIT; PRAGMA foreign_keys=ON; PRAGMA legacy_alter_table=OFF;"
    require (← sql c.db "PRAGMA foreign_key_check").isEmpty "job cancellation migration foreign key check failed"
  exec c "BEGIN IMMEDIATE;
    UPDATE job_items SET status='cancelled',error='verification cancelled' WHERE status IN ('pending','running')
      AND job_id IN (SELECT id FROM jobs WHERE status='running' AND cancel_requested=1);
    UPDATE verifications SET status='cancelled',report_json='{\"error\":\"verification cancelled\"}' WHERE status='running'
      AND job_id IN (SELECT id FROM jobs WHERE status='running' AND cancel_requested=1);
    UPDATE jobs SET status=CASE WHEN cancel_requested=1 THEN 'cancelled' ELSE 'interrupted' END,
      error=CASE WHEN cancel_requested=1 THEN 'verification cancelled' ELSE 'backend stopped during attempt' END,
      updated_at=CURRENT_TIMESTAMP WHERE status='running';
    UPDATE job_items SET status='interrupted',error='backend stopped during attempt' WHERE status='running';
    UPDATE verifications SET status='interrupted',report_json='{}' WHERE status='running'; COMMIT;"

def ensureBundle (c : Config) : IO Unit := do
  require (validBundle c.bundle) "bundle must contain 1..64 ASCII letters, digits, hyphens or underscores"
  let name ← quote c.bundle
  exec c s!"INSERT OR IGNORE INTO bundles(name,network) VALUES({name},{c.network})"
  let rows ← sql c.db s!"SELECT network FROM bundles WHERE name={name}"
  require (rows == #[#[toString c.network]]) "bundle name conflicts by case or belongs to another network"
  IO.FS.createDirAll c.bundleDir

def ensureLedger (c : Config) (network idx : Nat) (h parent root : String)
    (header : Option Json := none) : IO Nat := do
  index idx
  require (network ≤ 4294967295) "network out of range"
  let h ← hash h; let parent ← hash parent; let root ← hash root
  let qh ← quote h; let qp ← quote parent; let qr ← quote root
  let hj ← match header with | none => pure "NULL" | some j => quote j.compress
  let rows ← sql c.db s!"BEGIN IMMEDIATE;
    INSERT INTO ledgers(network,idx,hash,parent_hash,state_root,header_json)
      VALUES({network},{idx},{qh},{qp},{qr},{hj})
      ON CONFLICT(network,hash) DO UPDATE SET header_json=COALESCE(ledgers.header_json,excluded.header_json)
      WHERE ledgers.idx=excluded.idx AND ledgers.parent_hash=excluded.parent_hash AND ledgers.state_root=excluded.state_root;
    SELECT id,idx,parent_hash,state_root FROM ledgers WHERE network={network} AND hash={qh}; COMMIT;"
  let some row := rows[0]? | throw <| IO.userError "ledger insert failed"
  require (row[1]! == toString idx && row[2]! == parent && row[3]! == root) "conflicting header for ledger hash"
  match row[0]!.toNat? with
  | some id => pure id
  | none => throw <| IO.userError "invalid ledger ID"

/-- Validate the cheap envelope on receipt; detailed verification is always queued. -/
def receive (c : Config) (j : Json) : IO Json := do
  require ((← nat j "schema_version") == 1 && (← string j "stage") == "accepted") "invalid export schema or stage"
  let network ← nat j "network_id"
  require (network == c.network) "export belongs to another network"
  let idx ← nat j "ledger_index"
  discard <| array j "transactions"
  discard <| array j "pre_transaction_changes"
  discard <| array j "post_transaction_changes"
  let id ← ensureLedger c network idx (← string j "ledger_hash") (← string j "parent_ledger_hash") (← string j "state_root")
  discard <| hash (← string j "parent_state_root")
  let payload := j.compress
  let sha ← digest payload
  let rows ← sql c.db s!"BEGIN IMMEDIATE;
    INSERT OR IGNORE INTO exports(ledger_id,digest,payload) VALUES({id},{← quote sha},{← quote payload});
    SELECT id FROM exports WHERE ledger_id={id} AND digest={← quote sha}; COMMIT;"
  return obj [("export_id",str rows[0]![0]!), ("receipt",str "stored"), ("trust",str "untrusted")]

def ledger (c : Config) (network idx : Nat) (h : String) : IO (Array String) := do
  let h ← hash h
  let rows ← sql c.db s!"SELECT id,hash,parent_hash,state_root FROM ledgers WHERE network={network} AND idx={idx} AND hash={← quote h}"
  let some row := rows[0]? | throw <| IO.userError "ledger not stored; fetch or receive it first"
  return row

def trust (c : Config) (j : Json) : IO Json := do
  let network := optNat j "network_id" c.network
  require (network == c.network) "wrong network"
  let idx ← nat j "ledger_index"
  let row ← ledger c network idx (← string j "ledger_hash")
  let reason := optString j "reason" "operator decision"
  exec c s!"INSERT INTO trust_anchors(bundle,ledger_id,reason) VALUES({← quote c.bundle},{row[0]!},{← quote reason})
    ON CONFLICT(bundle,ledger_id) DO NOTHING"
  return obj [("ledger_hash",str row[1]!), ("trust",str "operator_trusted"), ("verification",str "unchanged")]

def inventory (c : Config) : IO Json := do
  let paymentSuccess := String.intercalate "," (← successfulPaymentStatuses.mapM quote)
  -- Derive verified trust from the latest checks of one exact export. Keep
  -- operator anchors separate so proof lineage still validates its dependencies.
  rowsJson (← sql c.db s!"SELECT l.idx,l.hash,l.parent_hash,l.state_root,
    CASE WHEN t.id IS NOT NULL THEN 'operator_trusted'
      WHEN m.status='kernel_checked' AND p.status IN ({paymentSuccess}) AND m.export_id=p.export_id
      THEN 'verified_trusted' ELSE 'untrusted' END,
    (SELECT COUNT(*) FROM exports e WHERE e.ledger_id=l.id),
    COALESCE(s.origin,'missing'),COALESCE(l.header_json,'null'),
    COALESCE(m.status,'not_checked'),COALESCE(p.status,'not_checked')
    FROM ledgers l LEFT JOIN trust_anchors t ON t.ledger_id=l.id AND t.bundle={← quote c.bundle}
    LEFT JOIN verifications m ON m.id=(SELECT v.id FROM verifications v JOIN exports e ON e.id=v.export_id JOIN jobs j ON j.id=v.job_id WHERE j.bundle={← quote c.bundle} AND j.network={c.network} AND e.ledger_id=l.id AND v.kind='merkle' ORDER BY v.id DESC LIMIT 1)
    LEFT JOIN verifications p ON p.id=(SELECT v.id FROM verifications v JOIN exports e ON e.id=v.export_id JOIN jobs j ON j.id=v.job_id WHERE j.bundle={← quote c.bundle} AND j.network={c.network} AND e.ledger_id=l.id AND v.kind='payments' ORDER BY v.id DESC LIMIT 1)
    LEFT JOIN states s ON s.ledger_id=l.id AND s.bundle={← quote c.bundle} WHERE l.network={c.network} ORDER BY l.idx,l.hash")
    #["ledger_index","ledger_hash","parent_hash","state_root","trust","export_variants","state","header_json","merkle","payments"]

def exports (c : Config) : IO Json := do
  rowsJson (← sql c.db s!"SELECT e.id,l.idx,l.hash,e.digest,e.received_at,
    COALESCE((SELECT v.status FROM verifications v JOIN jobs j ON j.id=v.job_id WHERE j.bundle={← quote c.bundle} AND v.export_id=e.id AND kind='merkle' ORDER BY v.id DESC LIMIT 1),'not_checked'),
    COALESCE((SELECT v.status FROM verifications v JOIN jobs j ON j.id=v.job_id WHERE j.bundle={← quote c.bundle} AND v.export_id=e.id AND kind='payments' ORDER BY v.id DESC LIMIT 1),'not_checked')
    FROM exports e INDEXED BY exports_metadata JOIN ledgers l ON l.id=e.ledger_id WHERE l.network={c.network} ORDER BY l.idx,e.id")
    #["export_id","ledger_index","ledger_hash","payload_sha256","received_at","merkle","payments"]

def queue (c : Config) (j : Json) : IO Json := do
  let first ← nat j "from"; let last := optNat j "to" first
  index first; index last
  require (last ≥ first && last-first < 10000) "range must contain 1 to 10000 ledgers"
  let checks ← array j "checks"
  require (!checks.isEmpty && checks.all (fun x => x == str "merkle" || x == str "payments")) "checks must select merkle, payments, or both"
  let selected := optString j "ledger_hash"
  require (selected.isEmpty || first == last) "ledger_hash requires a single ledger"
  let filter ← if selected.isEmpty then pure "" else pure s!" AND l.hash={← quote (← hash selected)}"
  let mut inserts := ""
  for idx in [:last-first+1] do
    let i := first+idx
    let candidates ← sql c.db s!"SELECT e.id FROM exports e JOIN ledgers l ON l.id=e.ledger_id
      WHERE l.network={c.network} AND l.idx={i}{filter} ORDER BY e.id"
    require (optNat j "export_id" > 0 || candidates.size ≤ 1) s!"ledger {i} has multiple export variants; select one with export_id"
    let explicitId := optNat j "export_id"
    let exportId ← if explicitId > 0 then do
        require (first == last) "export_id requires one ledger"
        let rows ← sql c.db s!"SELECT e.id FROM exports e JOIN ledgers l ON l.id=e.ledger_id
          WHERE e.id={explicitId} AND l.network={c.network} AND l.idx={i}{filter}"
        require (rows.size == 1) "export_id does not match requested ledger"
        pure (toString explicitId)
      else pure (candidates[0]?.map (·[0]!) |>.getD "NULL")
    inserts := inserts ++ s!"INSERT INTO job_items(job_id,idx,export_id) VALUES((SELECT MAX(id) FROM jobs),{i},{exportId});"
  let rows ← sql c.db s!"BEGIN IMMEDIATE;
    INSERT INTO jobs(bundle,network,first_idx,last_idx,checks_json,status)
      VALUES({← quote c.bundle},{c.network},{first},{last},{← quote (toJson checks).compress},'queued');
    {inserts} SELECT MAX(id) FROM jobs; COMMIT;"
  return obj [("job_id",str rows[0]![0]!), ("status",str "queued")]

def jobs (c : Config) : IO Json := do
  let rows ← sql c.db s!"SELECT id,first_idx,last_idx,checks_json,status,error,created_at,updated_at,cancel_requested FROM jobs WHERE bundle={← quote c.bundle} AND network={c.network} ORDER BY id DESC"
  let summaries ← IO.ofExcept ((← rowsJson rows #["job_id","from","to","checks","status","error","created_at","updated_at","cancel_requested"]).getArr?)
  return toJson (← summaries.mapM fun summary => do
    let .obj fields := summary | throw <| IO.userError "invalid job summary"
    return Json.obj (fields.insert "cancel_requested" (.bool (optString summary "cancel_requested" == "1"))))

def job (c : Config) (id : Nat) : IO Json := do
  let rows ← sql c.db s!"SELECT id,status,error,checks_json,cancel_requested FROM jobs WHERE id={id} AND bundle={← quote c.bundle} AND network={c.network}"
  require (!rows.isEmpty) "job not found"
  let items ← rowsJson (← sql c.db s!"SELECT idx,COALESCE(export_id,''),status,error FROM job_items WHERE job_id={id} ORDER BY idx")
    #["ledger_index","export_id","status","error"]
  let proofs ← rowsJson (← sql c.db s!"SELECT id,export_id,kind,status,report_json,artifacts_json,attempt_dir FROM verifications WHERE job_id={id} ORDER BY id")
    #["verification_id","export_id","kind","status","report_json","artifacts_json","attempt_dir"]
  return obj [("job_id",str rows[0]![0]!), ("status",str rows[0]![1]!), ("error",str rows[0]![2]!),
    ("items",items),("verifications",proofs),("cancel_requested",.bool (rows[0]![4]! == "1"))]

/-- Cancellation retains accepted proof attempts and all completed receipts. -/
def cancelJob (c : Config) (id : Nat) : IO Json := do
  discard <| job c id
  exec c s!"BEGIN IMMEDIATE;
    UPDATE job_items SET status='cancelled',error='verification cancelled'
      WHERE job_id={id} AND status='pending' AND EXISTS(SELECT 1 FROM jobs WHERE id={id} AND status='queued');
    UPDATE jobs SET cancel_requested=1,
      error=CASE WHEN status='queued' THEN 'verification cancelled' ELSE error END,
      status=CASE WHEN status='queued' THEN 'cancelled' ELSE status END,updated_at=CURRENT_TIMESTAMP
      WHERE id={id} AND status IN ('queued','running') AND cancel_requested=0; COMMIT;"
  job c id

end XLB.Store
