import XLB.Bundle

namespace XLB.Tasks
open Lean LeanXRPL XL Std.Async

private def taskTable (name : String) := s!"CREATE TABLE IF NOT EXISTS {name}(
    id INTEGER PRIMARY KEY, network INTEGER NOT NULL, bundle TEXT NOT NULL REFERENCES bundles(name),
    kind TEXT NOT NULL CHECK(kind IN ('fetch','state_new','state_update')),
    request_json TEXT NOT NULL, resolved_json TEXT,
    status TEXT NOT NULL CHECK(status IN ('queued','running','succeeded','failed','interrupted','cancelled')),
    progress_json TEXT NOT NULL DEFAULT 'null', result_json TEXT NOT NULL DEFAULT 'null',
    error TEXT NOT NULL DEFAULT '', retry_of INTEGER REFERENCES acquisition_tasks(id),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, started_at TEXT, finished_at TEXT,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancel_requested IN (0,1)));"

private def cancelledError := "acquisition cancelled; retry this task to resume"
private def errorEvent (error : String) := obj [("event",str "error"),("error",str error)]

/-- Acquisition ownership and history are independent of HTTP observers. -/
def init (c : Config) : IO Unit := do
  exec c (taskTable "acquisition_tasks")
  let fields ← sql c.db "PRAGMA table_info(acquisition_tasks)"
  if !fields.any (fun row => row[1]! == "cancel_requested") then
    -- Rebuild the old status CHECK without changing IDs or incoming references.
    exec c s!"PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=ON; BEGIN IMMEDIATE;
      {taskTable "acquisition_tasks_cancel"}
      INSERT INTO acquisition_tasks_cancel SELECT *,0 FROM acquisition_tasks;
      DROP TABLE acquisition_tasks; ALTER TABLE acquisition_tasks_cancel RENAME TO acquisition_tasks;
      COMMIT; PRAGMA foreign_keys=ON; PRAGMA legacy_alter_table=OFF;"
    require (← sql c.db "PRAGMA foreign_key_check").isEmpty "task cancellation migration foreign key check failed"
  exec c "CREATE UNIQUE INDEX IF NOT EXISTS acquisition_tasks_active ON acquisition_tasks(network,bundle)
      WHERE status IN ('queued','running');
    CREATE TABLE IF NOT EXISTS acquisition_events(
      seq INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES acquisition_tasks(id), event_json TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS acquisition_events_task ON acquisition_events(task_id,seq);"
  let interrupted := "backend stopped during acquisition; retry this task to resume"
  exec c s!"BEGIN IMMEDIATE;
    INSERT INTO acquisition_events(task_id,event_json)
      SELECT id,CASE WHEN cancel_requested=1 THEN {← quote (errorEvent cancelledError).compress}
        ELSE {← quote (errorEvent interrupted).compress} END FROM acquisition_tasks WHERE status='running';
    UPDATE acquisition_tasks SET status=CASE WHEN cancel_requested=1 THEN 'cancelled' ELSE 'interrupted' END,
      error=CASE WHEN cancel_requested=1 THEN {← quote cancelledError} ELSE {← quote interrupted} END,
      finished_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP WHERE status='running'; COMMIT;"

private def scope (c : Config) (bundleOnly : Bool) : IO String := do
  let bundle ← quote c.bundle
  return s!"network={c.network}" ++ (if bundleOnly then s!" AND bundle={bundle}" else "")

private def decode (row : Array String) : IO Json := do
  let parse := fun text => IO.ofExcept (Json.parse text)
  return obj [("task_id",str row[0]!),("bundle",str row[1]!),("kind",str row[2]!),
    ("status",str row[3]!),("request",← parse row[4]!),("resolved_request",← parse row[5]!),
    ("progress",← parse row[6]!),("result",← parse row[7]!),("error",str row[8]!),
    ("retry_of",if row[9]!.isEmpty then .null else str row[9]!),
    ("created_at",str row[10]!),("started_at",str row[11]!),("finished_at",str row[12]!),
    ("updated_at",str row[13]!),("cancel_requested",.bool (row[14]! == "1"))]

private def columns := "id,bundle,kind,status,request_json,COALESCE(resolved_json,'null'),progress_json,result_json,error,COALESCE(retry_of,''),created_at,COALESCE(started_at,''),COALESCE(finished_at,''),updated_at,cancel_requested"

def getTask (c : Config) (id : Nat) (bundleOnly := false) : IO Json := do
  let rows ← sql c.db s!"SELECT {columns} FROM acquisition_tasks WHERE id={id} AND {← scope c bundleOnly}"
  let some row := rows[0]? | throw <| IO.userError "task not found"
  decode row

def list (c : Config) (bundleOnly := false) : IO Json := do
  let rows ← sql c.db s!"SELECT id,bundle,kind,status,'null','null',progress_json,'null',error,COALESCE(retry_of,''),
    created_at,COALESCE(started_at,''),COALESCE(finished_at,''),updated_at,cancel_requested
    FROM acquisition_tasks WHERE {← scope c bundleOnly} ORDER BY id DESC"
  return toJson (← rows.mapM fun row => do
    let .obj fields ← decode row | throw <| IO.userError "invalid task summary"
    return Json.obj (fields.erase "request" |>.erase "resolved_request" |>.erase "result"))

private def insertTask (c : Config) (kind : String) (body : Json)
    (resolved : Json := .null) (retryOf : Option Nat := none) : IO Json := do
  Store.ensureBundle c
  require (["fetch","state_new","state_update"].contains kind) "task kind must be fetch, state_new, or state_update"
  let resolved ← if resolved == .null then pure "NULL" else quote resolved.compress
  let prior := retryOf.map toString |>.getD "NULL"
  let rows ← sql c.db s!"BEGIN IMMEDIATE;
    INSERT INTO acquisition_tasks(network,bundle,kind,request_json,resolved_json,status,retry_of)
      SELECT {c.network},{← quote c.bundle},{← quote kind},{← quote body.compress},{resolved},'queued',{prior}
      WHERE NOT EXISTS(SELECT 1 FROM acquisition_tasks WHERE network={c.network} AND bundle={← quote c.bundle} AND status IN ('queued','running'))
      RETURNING id; COMMIT;"
  let some row := rows[0]? | throw <| IO.userError "bundle acquisition already in use; inspect task show or attach with task wait --id ID"
  getTask c (row[0]!.toNat?.getD 0)

def submit (c : Config) (kind : String) (body : Json) : IO Json :=
  insertTask c kind body

/-- A retry gets a fresh history ID while retaining the exact resolved range. -/
def retry (c : Config) (id : Nat) (bundleOnly := false) : IO Json := do
  let prior ← getTask c id bundleOnly
  require (["failed","interrupted","cancelled"].contains (optString prior "status")) "only failed, interrupted, or cancelled tasks can be retried"
  insertTask {c with bundle := ← string prior "bundle"} (← string prior "kind")
    (← get prior "request") (← get prior "resolved_request") (some id)

/-- Durable, idempotent cancellation. Running work retains ownership until it unwinds. -/
def cancel (c : Config) (id : Nat) (bundleOnly := false) : IO Json := do
  discard <| getTask c id bundleOnly
  exec c s!"BEGIN IMMEDIATE;
    INSERT INTO acquisition_events(task_id,event_json)
      SELECT id,{← quote (errorEvent cancelledError).compress} FROM acquisition_tasks WHERE id={id} AND status='queued';
    UPDATE acquisition_tasks SET cancel_requested=1,
      error=CASE WHEN status='queued' THEN {← quote cancelledError} ELSE error END,
      finished_at=CASE WHEN status='queued' THEN CURRENT_TIMESTAMP ELSE finished_at END,
      status=CASE WHEN status='queued' THEN 'cancelled' ELSE status END,updated_at=CURRENT_TIMESTAMP
      WHERE id={id} AND status IN ('queued','running') AND cancel_requested=0; COMMIT;"
  getTask c id bundleOnly

private def recordProgress (c : Config) (id : Nat) (p : FetchProgress) : IO Unit := do
  let event ← quote p.json.compress
  exec c s!"BEGIN IMMEDIATE;
    UPDATE acquisition_tasks SET progress_json={event},updated_at=CURRENT_TIMESTAMP WHERE id={id};
    INSERT INTO acquisition_events(task_id,event_json) VALUES({id},{event}); COMMIT;"

private def finish (c : Config) (id : Nat) (status : String) (result : Json) (error : String) : IO Unit := do
  let event := if status == "succeeded" then obj [("event",str "result"),("data",result)]
    else errorEvent error
  exec c s!"BEGIN IMMEDIATE;
    UPDATE acquisition_tasks SET status=CASE WHEN cancel_requested=1 THEN 'cancelled' ELSE {← quote status} END,
      result_json=CASE WHEN cancel_requested=1 THEN 'null' ELSE {← quote result.compress} END,
      error=CASE WHEN cancel_requested=1 THEN {← quote cancelledError} ELSE {← quote error} END,
      updated_at=CURRENT_TIMESTAMP,finished_at=CURRENT_TIMESTAMP WHERE id={id};
    INSERT INTO acquisition_events(task_id,event_json)
      SELECT id,CASE WHEN cancel_requested=1 THEN {← quote (errorEvent cancelledError).compress}
        ELSE {← quote event.compress} END FROM acquisition_tasks WHERE id={id}; COMMIT;"

private def execute (c : Config) (stop : IO.Ref Bool) (id : Nat) : Async Unit := do
  let taskStop ← IO.mkRef false
  let done ← IO.mkRef false
  let monitor : Async Unit := do
    while !(← done.get) do
      let rows ← sql c.db s!"SELECT cancel_requested FROM acquisition_tasks WHERE id={id}"
      if (← stop.get) || rows[0]![0]! == "1" then
        taskStop.set true
        return
      sleep (.ofInt 50)
  let work : Async Unit := do
    try
      let task ← getTask c id
      let body ← get task "request"
      let saved ← get task "resolved_request"
      let kind ← string task "kind"
      require (!(← taskStop.get)) "acquisition interrupted"
      let resolved ← if saved != .null then pure saved else if kind == "fetch" then Acquire.resolve c taskStop body (recordProgress c id)
        else Bundle.prepare c taskStop (if kind == "state_new" then "new" else "update") body (recordProgress c id)
      -- In particular, latest is frozen before the first snapshot request.
      exec c s!"UPDATE acquisition_tasks SET resolved_json={← quote resolved.compress} WHERE id={id}"
      let result ← Acquire.fetch c taskStop resolved (recordProgress c id)
      finish c id "succeeded" result ""
    catch error =>
      finish c id (if ← stop.get then "interrupted" else "failed") .null error.toString
    finally done.set true
  discard <| Async.concurrently monitor work

/-- One acquisition runner, separate from proof work and all HTTP clients. -/
def run (c : Config) (stop : IO.Ref Bool) : Async Unit := do
  while !(← stop.get) do
    let rows ← sql c.db s!"SELECT id,bundle FROM acquisition_tasks WHERE status='queued' AND network={c.network} ORDER BY id LIMIT 1"
    if let some row := rows[0]? then
      let id := row[0]!.toNat?.getD 0
      let claimed ← sql c.db s!"UPDATE acquisition_tasks SET status='running',started_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP WHERE id={id} AND status='queued' RETURNING id"
      if !claimed.isEmpty then execute {c with bundle := row[1]!} stop id
    else sleep (.ofInt 50)

def waitResult (c : Config) (stop : IO.Ref Bool) (id : Nat) : Async Json := do
  repeat
    let task ← getTask c id
    match optString task "status" with
    | "succeeded" => return ← get task "result"
    | "failed" | "interrupted" | "cancelled" => throw <| IO.userError (optString task "error")
    | _ =>
      require (!(← stop.get)) "backend stopping; acquisition task retained"
      sleep (.ofInt 50)

/-- Observers replay durable events. Sending one can never affect the runner. -/
def watch (c : Config) (stop : IO.Ref Bool) (id : Nat) (emit : Json → Async Unit)
    (afterSeq : Nat := 0) : Async Unit := do
  discard <| getTask c id
  let mut cursor := afterSeq
  repeat
    let events ← sql c.db s!"SELECT seq,event_json FROM acquisition_events WHERE task_id={id} AND seq>{cursor} ORDER BY seq LIMIT 128"
    for row in events do
      let event ← IO.ofExcept (Json.parse row[1]!)
      cursor := row[0]!.toNat?.getD cursor
      let .obj fields := event | throw <| IO.userError "invalid task event"
      emit (.obj (fields.insert "event_seq" (toJson cursor) |>.insert "task_id" (str (toString id))))
      if ["result","error"].contains (optString event "event") then return
    if events.isEmpty then
      let task ← getTask c id
      -- A runner may have committed events between the empty read and this
      -- status read. Drain them before synthesizing a terminal reply.
      let latest ← sql c.db s!"SELECT COALESCE(MAX(seq),0) FROM acquisition_events WHERE task_id={id}"
      if latest[0]![0]!.toNat?.getD 0 > cursor then continue
      match optString task "status" with
      | "succeeded" | "failed" | "interrupted" | "cancelled" =>
        let terminal ← sql c.db s!"SELECT seq,event_json FROM acquisition_events WHERE task_id={id} ORDER BY seq DESC LIMIT 1"
        let .obj fields ← IO.ofExcept (Json.parse terminal[0]![1]!) | throw <| IO.userError "invalid terminal task event"
        emit (.obj (fields.insert "event_seq" (toJson (terminal[0]![0]!.toNat?.getD 0)) |>.insert "task_id" (str (toString id))))
        return
      | _ => pure ()
    require (!(← stop.get)) "backend stopping; acquisition task retained"
    if events.isEmpty then sleep (.ofInt 50)

end XLB.Tasks
