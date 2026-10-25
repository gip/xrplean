import XLB.Store
import LeanXRPL.PaymentAudit
import LeanXRPL.KernelMerkle
import LeanXRPL.SHA512Fast

namespace XLB.Proofs
open Lean LeanXRPL XL

private def singletonWitness (repo : StateTree.Repository) (out : NodeStore.Store)
    (fuel : Nat) (root : StateTree.Hash) : IO Unit := do
  match fuel with
  | 0 => pure ()
  | fuel+1 =>
    if root.isZero then return
    let node ← repo.load root
    NodeStore.putNode out root.bytes (← IO.ofExcept (StateTree.encode node)) (match node with | .leaf .. => true | _ => false)
    if let .inner children := node then
      let nonempty := children.toArray.filter (fun h => !h.isZero)
      if nonempty.size == 1 then singletonWitness repo out fuel nonempty[0]!

private def pathWitness (repo : StateTree.Repository) (out : NodeStore.Store)
    (key : StateTree.ObjectID) (deletion : Bool) (fuel depth : Nat) (root : StateTree.Hash) : IO Unit := do
  match fuel with
  | 0 => pure ()
  | fuel+1 =>
    if root.isZero then return
    let node ← repo.load root
    NodeStore.putNode out root.bytes (← IO.ofExcept (StateTree.encode node)) (match node with | .leaf .. => true | _ => false)
    if let .inner children := node then
      if h : depth < 64 then
        let branch := key.branch ⟨depth,h⟩
        -- Only deletion can collapse a branch. A sibling can become the sole
        -- survivor only when this non-root inner node has two occupied slots.
        -- Keep that sibling's unary chain open so the kernel can decide whether
        -- it collapses to a leaf; all other untouched subtrees stay opaque.
        if deletion && depth > 0 && (children.toArray.filter (fun child => !child.isZero)).size == 2 then
          for i in [:16] do
            if i != branch.val then singletonWitness repo out 65 children.toArray[i]!
        pathWitness repo out key deletion fuel (depth+1) (children.get branch)

private partial def collectFiles (dir : System.FilePath) : IO (Array Json) := do
  let mut records := #[]
  for entry in ← dir.readDir do
    if ← entry.path.isDir then records := records ++ (← collectFiles entry.path)
    else if !entry.fileName.endsWith "-wal" && !entry.fileName.endsWith "-shm" && !entry.fileName.endsWith ".lock" then
      let bytes ← IO.FS.readBinFile entry.path
      records := records.push (obj [("path",str entry.path.toString),("sha256",str (hex (← Native.sha256 bytes)))])
  return records

private def validateArtifacts (text : String) : IO Unit := do
  let records ← IO.ofExcept ((Json.parse text).bind Json.getArr?)
  require (!records.isEmpty) "blocked: parent proof has no artifacts"
  for record in records do
    let path ← string record "path"
    require (← (System.FilePath.mk path).pathExists) s!"blocked: missing proof artifact {path}"
    let bytes ← IO.FS.readBinFile path
    require (hex (← Native.sha256 bytes) == (← string record "sha256")) s!"blocked: changed proof artifact {path}"

/-- Verify the retained dependency chain before using a derived Merkle base. -/
private def validateChain (c : Config) (fuel id : Nat) : IO Unit := do
  match fuel with
  | 0 => throw <| IO.userError "blocked: proof dependency chain too long"
  | fuel+1 =>
    let rows ← sql c.db s!"SELECT artifacts_json,COALESCE(parent_verification_id,0),anchor_id FROM verifications WHERE job_id IN (SELECT id FROM jobs WHERE bundle={← quote c.bundle}) AND id={id} AND kind='merkle' AND status='kernel_checked'"
    require (rows.size == 1) "blocked: parent Merkle proof missing"
    let row := rows[0]!
    validateArtifacts row[0]!
    let parent := row[1]!.toNat?.getD 0
    if parent > 0 then validateChain c fuel parent
    let anchors ← sql c.db s!"SELECT id FROM trust_anchors WHERE bundle={← quote c.bundle} AND id={row[2]!}"
    require (anchors.size == 1) "blocked: proof trust anchor missing"

structure Basis where
  anchor : Nat
  verification : Nat
  sources : Array String

private def basis (c : Config) (j : Json) : IO Basis := do
  let idx ← nat j "ledger_index"
  let parent ← hash (← string j "parent_ledger_hash")
  let root ← hash (← string j "parent_state_root")
  let rows ← sql c.db s!"SELECT l.id,l.state_root,t.id,COALESCE(s.sources_json,'[]') FROM ledgers l
    LEFT JOIN trust_anchors t ON t.ledger_id=l.id AND t.bundle={← quote c.bundle} LEFT JOIN states s ON s.ledger_id=l.id AND s.bundle={← quote c.bundle}
    WHERE l.network={c.network} AND l.idx={idx-1} AND l.hash={← quote parent}"
  require (rows.size == 1) "blocked: parent ledger not stored"
  let row := rows[0]!
  require (row[1]! == root) "parent state root disagrees with stored parent header"
  let sourceList := fun text => IO.ofExcept ((Json.parse text).bind Json.getArr?) >>= Array.mapM (fun x => IO.ofExcept x.getStr?)
  if !row[2]!.isEmpty then
    let sources ← sourceList row[3]!
    require (!sources.isEmpty || root == hex zeroHash) "blocked: trusted parent needs state witnesses or a snapshot"
    return ⟨row[2]!.toNat?.getD 0,0,sources⟩
  let proofs ← sql c.db s!"SELECT v.id,v.anchor_id,v.report_json FROM verifications v JOIN exports e ON e.id=v.export_id
    WHERE v.job_id IN (SELECT id FROM jobs WHERE bundle={← quote c.bundle}) AND e.ledger_id={row[0]!} AND v.kind='merkle' AND v.status='kernel_checked' ORDER BY v.id DESC LIMIT 1"
  require (!proofs.isEmpty) "blocked: parent needs operator trust or a kernel-checked Merkle lineage"
  let p := proofs[0]!
  let id := p[0]!.toNat?.getD 0
  validateChain c 100000 id
  let report ← IO.ofExcept (Json.parse p[2]!)
  let sources ← (← array report "state_sources").mapM (fun x => IO.ofExcept x.getStr?)
  return ⟨p[1]!.toNat?.getD 0,id,sources⟩

private def replay (c : Config) (stop : IO.Ref Bool) (j : Json) (b : Basis)
    (dir : System.FilePath) : IO Json := do
  let e ← StateIngest.decode j c.network
  let workPath := dir / "state.sqlite3"
  let witnessPath := dir / "witness-catalog.sqlite3"
  let mut backing : Array NodeStore.Store := #[]
  try
    for path in b.sources do
      require (← (System.FilePath.mk path).pathExists) "blocked: parent state store missing"
      backing := backing.push (← NodeStore.openReadOnly path 1099511627776)
    let work ← NodeStore.openStore workPath.toString 1099511627776 .nudb
    try
      let witness ← NodeStore.openStore witnessPath.toString 1099511627776 .nudb
      try
        let repo ← StateTree.Repository.ofStore work 134217728 backing[0]? (backing.extract 1 backing.size)
        let mut tree := StateTree.Tree.mk e.parentRoot
        let mut trace : Array Json := #[]
        NodeStore.transaction witness (singletonWitness repo witness 65 tree.root)
        for change in e.changes do
          require (!(← stop.get)) "interrupted"
          let previous := tree.root
          NodeStore.transaction witness (pathWitness repo witness change.key change.after.isNone 65 0 tree.root)
          tree ← repo.applyChanges tree #[change]
          NodeStore.transaction witness (pathWitness repo witness change.key false 65 0 tree.root)
          trace := trace.push (obj [("before_root",str (hex previous.bytes)),("after_root",str (hex tree.root.bytes)),("key",str (hex change.key.bytes))])
        require (tree.root == e.root) "state replay does not reach exported root"
        repo.checkpoint
        NodeStore.checkpoint witness
        -- The untrusted Python generator consumes a bounded, portable witness copy.
        NodeStore.exportSQLite witness (dir / "witness.sqlite3").toString
        return obj [("merkle_replay",str "verified"),("parent_root",str (hex e.parentRoot.bytes)),
          ("computed_root",str (hex tree.root.bytes)),("root_transitions",toJson trace),
          ("state_sources",toJson (#[workPath.toString] ++ b.sources)),
          ("coverage",str "all exported state changes; transaction semantics are separate")]
      finally NodeStore.dispose witness
    finally NodeStore.dispose work
  finally
    for store in backing do NodeStore.dispose store

private def checkAxioms (text : String) : IO Unit := do
  require ((text.splitOn "sorryAx").length == 1 && (text.splitOn "Lean.ofReduceBool").length == 1) "unexpected proof axiom"
  let mut found := false
  for line in text.splitOn "\n" do
    if (line.splitOn "depends on axioms:").length > 1 then
      found := true
      let tail := (line.splitOn "depends on axioms:").getLast!
      let cleaned := tail.replace "[" "" |>.replace "]" "" |>.replace "," " "
      for name in cleaned.splitOn " " do
        require (["", "propext", "Classical.choice", "Quot.sound"].contains name.trimAscii.toString) s!"unexpected proof axiom: {name}"
    if (line.splitOn "does not depend on any axioms").length > 1 then found := true
  require found "missing axiom audit"

private def save (c : Config) (job exportId : Nat) (kind status : String) (b : Basis)
    (report : Json) (dir : System.FilePath) : IO Unit := do
  let mut artifacts ← collectFiles dir
  -- Retain identities of the imported theorem definitions and compiled modules.
  for name in ["SHA512", "SHA512Fast", "KernelMerkle", "PaymentModel", "LedgerProofs"] do
    for path in [c.root / "LeanXRPL" / (name ++ ".lean"), c.root / ".lake/build/lib/lean/LeanXRPL" / (name ++ ".olean")] do
      artifacts := artifacts.push (obj [("path",str path.toString),("sha256",str (hex (← Native.sha256 (← IO.FS.readBinFile path))))])
  let toolchain := c.root / "lean-toolchain"
  artifacts := artifacts.push (obj [("path",str toolchain.toString),("sha256",str (hex (← Native.sha256 (← IO.FS.readBinFile toolchain))))])
  exec c s!"UPDATE verifications SET status={← quote status},anchor_id={if b.anchor == 0 then "NULL" else toString b.anchor},
    parent_verification_id={if b.verification == 0 then "NULL" else toString b.verification},
    report_json={← quote report.compress},artifacts_json={← quote (toJson artifacts).compress}
    WHERE job_id={job} AND export_id={exportId} AND kind={← quote kind} AND status='running'
      AND NOT EXISTS(SELECT 1 FROM jobs WHERE id={job} AND cancel_requested=1)"

def merkle (c : Config) (stop : IO.Ref Bool) (job exportId : Nat) (j : Json) : IO Unit := do
  let b ← basis c j
  let dir := c.bundleDir / "proofs" / s!"{job}-{exportId}-merkle-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  exec c s!"UPDATE verifications SET attempt_dir={← quote dir.toString} WHERE job_id={job} AND export_id={exportId} AND kind='merkle' AND status='running'"
  IO.FS.writeFile (dir / "export.json") j.compress
  let report ← replay c stop j b dir
  IO.FS.writeFile (dir / "replay.jsonl") (report.compress ++ "\n")
  let cert := dir / "certificate"
  let code ← process c stop "python3" #["-I","-u","tools/generate_merkle_certificate.py",(dir/"export.json").toString,
    (dir/"witness.sqlite3").toString,(dir/"replay.jsonl").toString,cert.toString,"--check","--jobs",toString c.proofJobs] (dir/"kernel.log")
  require (code == 0) s!"Merkle kernel checking failed; see {dir}/kernel.log"
  let code ← process c stop "python3" #["-I","tools/verify_certificate_inputs.py",(dir/"export.json").toString,cert.toString] (dir/"binding.log")
  require (code == 0) "certificate differs from exact export bytes/order"
  let kernel ← IO.ofExcept (Json.parse (← IO.FS.readFile (cert/"kernel-verification.json")))
  require (optString kernel "status" == "kernel_checked") "missing kernel receipt"
  checkAxioms (← string kernel "axiom_audit")
  save c job exportId "merkle" "kernel_checked" b report dir

/-- Payment accounting checks the pinned export independently of Merkle replay. -/
def payments (c : Config) (stop : IO.Ref Bool) (job exportId : Nat) (j : Json) : IO String := do
  let b : Basis := ⟨0,0,#[]⟩
  let e ← PaymentAudit.decodeExport j
  PaymentAudit.checkContinuity e
  let mut entries : Array (PaymentAudit.Transaction × PaymentAudit.Verdict) := #[]
  let mut reports := #[]
  let mut unsupported := 0; let mut failed := 0; let mut verified := 0; let mut other := 0
  for t in e.transactions do
    require (!(← stop.get)) "interrupted"
    let verdict ← PaymentAudit.verifyPayment e t
    entries := entries.push (t,verdict)
    reports := reports.push (PaymentAudit.verdictJson e t verdict)
    if verdict.status == "unsupported" then unsupported := unsupported+1
    else if verdict.status == "failed" then failed := failed+1
    else if verdict.status == "verified" then verified := verified+1
    else other := other+1
  let dir := c.bundleDir / "proofs" / s!"{job}-{exportId}-payments-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  exec c s!"UPDATE verifications SET attempt_dir={← quote dir.toString} WHERE job_id={job} AND export_id={exportId} AND kind='payments' AND status='running'"
  IO.FS.writeFile (dir/"export.json") j.compress
  IO.FS.writeFile (dir/"Payments.lean") (PaymentAudit.proofSource e entries ++
    "\n#print axioms supported_valid\n#print axioms supported_xrp_accounting\n")
  let code ← process c stop "lake" #["env","lean",(dir/"Payments.lean").toString] (dir/"kernel.log")
  require (code == 0) s!"Payment kernel checking failed; see {dir}/kernel.log"
  checkAxioms (← IO.FS.readFile (dir/"kernel.log"))
  let status := if failed > 0 then "failed"
    else if unsupported > 0 then
      if verified > 0 then "supported_checked" else "no_supported_payments"
    else "kernel_checked"
  let report := obj [("payments_verified",toJson verified),("payments_failed",toJson failed),
    ("payments_unsupported",toJson unsupported),("payments_skipped",toJson unsupported),
    ("coverage",str "supported_payments_only"),("other_transactions",toJson other),
    ("transactions",toJson reports),("supported_proofs",str "kernel_checked"),
    ("state_authentication",str "not_checked_by_payments"),
    ("full_ledger_semantics",str "not_proved"),("trust",str "unchanged")]
  IO.FS.writeFile (dir/"report.json") report.compress
  save c job exportId "payments" status b report dir
  return status

end XLB.Proofs
