import XLB.Proofs

namespace XLB.Worker
open Lean LeanXRPL XL

private def finish (c : Config) (job : Nat) (status error : String) (current := "0") : IO Unit := do
  let cancelled := s!"EXISTS(SELECT 1 FROM jobs WHERE id={job} AND cancel_requested=1)"
  let finalStatus := s!"CASE WHEN {cancelled} THEN 'cancelled' ELSE {← quote status} END"
  let finalError := s!"CASE WHEN {cancelled} THEN 'verification cancelled' ELSE {← quote error} END"
  let report := obj [("error",str error)]
  let cancelledReport := obj [("error",str "verification cancelled")]
  exec c s!"BEGIN IMMEDIATE;
    UPDATE verifications SET status={finalStatus},report_json=CASE WHEN {cancelled}
      THEN {← quote cancelledReport.compress} ELSE {← quote report.compress} END WHERE job_id={job} AND status='running';
    UPDATE job_items SET status={finalStatus},error={finalError} WHERE job_id={job} AND idx={current} AND status='running';
    UPDATE job_items SET status='cancelled',error='verification cancelled' WHERE job_id={job}
      AND status IN ('pending','running') AND {cancelled};
    UPDATE jobs SET status={finalStatus},error={finalError},updated_at=CURRENT_TIMESTAMP WHERE id={job}; COMMIT;"

private def runJob (c : Config) (stop : IO.Ref Bool) (id : Nat) (checks : Array Json) : IO Unit := do
  let items ← sql c.db s!"SELECT idx,COALESCE(export_id,0) FROM job_items WHERE job_id={id} ORDER BY idx"
  let mut current := "0"
  try
    for item in items do
      require (!(← stop.get)) "interrupted"
      current := item[0]!
      let exportId := item[1]!.toNat?.getD 0
      require (exportId > 0) s!"blocked: no export stored for ledger {current} when job was queued; fetch/receive it and submit a new job"
      let rows ← sql c.db s!"SELECT payload,digest FROM exports WHERE id={exportId}"
      require (rows.size == 1) "blocked: pinned export missing"
      require ((← digest rows[0]![0]!) == rows[0]![1]!) "stored export digest mismatch"
      let j ← IO.ofExcept (Json.parse rows[0]![0]!)
      exec c s!"UPDATE job_items SET status='running' WHERE job_id={id} AND idx={current}"
      if checks.contains (str "merkle") then
        exec c s!"INSERT INTO verifications(job_id,export_id,kind,status,report_json,artifacts_json) VALUES({id},{exportId},'merkle','running','null','[]')"
        Proofs.merkle c stop id exportId j
      require (!(← stop.get)) "interrupted"
      if checks.contains (str "payments") then
        exec c s!"INSERT INTO verifications(job_id,export_id,kind,status,report_json,artifacts_json) VALUES({id},{exportId},'payments','running','null','[]')"
        let status ← Proofs.payments c stop id exportId j
        if !["kernel_checked", "supported_checked", "no_supported_payments"].contains status then
          exec c s!"UPDATE job_items SET status={← quote status},error='Supported Payment verification failed' WHERE job_id={id} AND idx={current}"
          finish c id status "Supported Payment verification failed; proof artifacts retained"
          return
      require (!(← stop.get)) "interrupted"
      exec c s!"UPDATE job_items SET status='succeeded' WHERE job_id={id} AND idx={current}"
    finish c id "succeeded" ""
  catch error =>
    let message := error.toString
    let status := if ← stop.get then "interrupted" else if (message.splitOn "blocked:").length > 1 then "blocked" else "failed"
    finish c id status message current

private def execute (c : Config) (stop : IO.Ref Bool) (id : Nat) (checks : Array Json) : IO Unit := do
  let jobStop ← IO.mkRef false
  let done ← IO.mkRef false
  let monitor ← IO.asTask (do
    try
      while !(← done.get) do
        let rows ← sql c.db s!"SELECT cancel_requested FROM jobs WHERE id={id}"
        if (← stop.get) || rows[0]![0]! == "1" then jobStop.set true; return
        IO.sleep 50
    catch error => jobStop.set true; throw error) (prio := .dedicated)
  try runJob c jobStop id checks
  finally
    done.set true
    IO.ofExcept monitor.get

def run (c : Config) (stop : IO.Ref Bool) : IO Unit := do
  while !(← stop.get) do
    let rows ← sql c.db s!"SELECT id,checks_json,bundle FROM jobs WHERE status='queued' AND network={c.network} ORDER BY id LIMIT 1"
    if let some row := rows[0]? then
      let id := row[0]!.toNat?.getD 0
      let claimed ← sql c.db s!"UPDATE jobs SET status='running',updated_at=CURRENT_TIMESTAMP WHERE id={id} AND status='queued' RETURNING id"
      if claimed.isEmpty then continue
      let checks ← IO.ofExcept ((Json.parse row[1]!).bind Json.getArr?)
      execute {c with bundle := row[2]!} stop id checks
    else IO.sleep 100

end XLB.Worker
