import XLB.Store

/- Read-only views of proof source. File IDs are names from an allowlist assembled
from the selected attempt, never paths supplied by the HTTP client. -/
namespace XLB.ProofSource
open Lean LeanXRPL XL

private def modules (kind : String) : IO (List String) := do
  match kind with
  | "merkle" => return ["KernelMerkle", "SHA512", "SHA512Fast"]
  | "payments" => return ["PaymentModel", "LedgerProofs"]
  | _ => throw <| IO.userError "unknown proof kind"

def definitions (c : Config) (kind : String) : IO Json := do
  let files ← (← modules kind).toArray.mapM fun name => do
    let source ← IO.FS.readFile (c.root / "LeanXRPL" / (name ++ ".lean"))
    return obj [("name",str (name ++ ".lean")),("source",str source)]
  return obj [("kind",str kind),("files",toJson files)]

private structure SourceFile where
  id : String
  name : String
  path : System.FilePath
  role : String
  digest : String := ""

private structure Attempt where
  kind : String
  status : String
  entry : String
  files : Array SourceFile

private def within (path root : System.FilePath) : Bool :=
  path.toString.startsWith (root.toString ++ "/")

private def sourceName (name : String) : Bool :=
  name.endsWith ".lean" && (name.dropEnd 5).toString.toList.all (fun ch =>
    ch.toNat < 128 && (ch.isAlphanum || ch == '_'))

private def attempt (c : Config) (job verification : Nat) : IO Attempt := do
  let rows ← sql c.db s!"SELECT v.kind,v.status,v.attempt_dir,v.artifacts_json,l.idx
    FROM verifications v JOIN jobs j ON j.id=v.job_id JOIN exports e ON e.id=v.export_id
    JOIN ledgers l ON l.id=e.ledger_id WHERE v.id={verification} AND j.id={job}
    AND j.bundle={← quote c.bundle} AND j.network={c.network}"
  require (rows.size == 1) "proof attempt not found in this job, bundle and network"
  let row := rows[0]!
  let kind := row[0]!
  discard <| modules kind
  let entry := if kind == "payments" then "generated_Payments" else "generated_Certificate"
  if row[2]!.isEmpty then return ⟨kind,row[1]!,entry,#[]⟩
  -- A missing attempt is not replaced by another attempt or current source.
  let expected := System.FilePath.mk row[2]!
  let proofRoot := c.bundleDir / "proofs"
  require (within expected proofRoot) "proof attempt outside bundle proof directory"
  let generatedDir := if kind == "payments" then expected else expected / "certificate" / ("Ledger" ++ row[4]!)
  let records ← IO.ofExcept ((Json.parse row[3]!).bind Json.getArr?)
  let mut files : Array SourceFile := #[]
  -- Recorded files remain listed even when missing, so old receipts explain
  -- unavailability instead of silently using today's definitions.
  for record in records do
    let path := System.FilePath.mk (← string record "path")
    let name := path.fileName.getD ""
    if sourceName name && path.parent == some generatedDir then
      files := files.push ⟨"generated_" ++ (name.dropEnd 5).toString,name,path,"generated",← string record "sha256"⟩
    for name in ← modules kind do
      if path == c.root / "LeanXRPL" / (name ++ ".lean") then
        files := files.push ⟨"definition_" ++ name,name ++ ".lean",path,"definition",← string record "sha256"⟩
  -- Running/failed/cancelled attempts may have source without a saved receipt.
  -- Only inspect the known generated-source folder, never arbitrary artifacts.
  if records.isEmpty && (← generatedDir.pathExists) then
    let realRoot ← IO.FS.realPath proofRoot
    let realDir ← IO.FS.realPath generatedDir
    require (within realDir realRoot) "proof source directory outside bundle"
    for item in ← generatedDir.readDir do
      if sourceName item.fileName && (kind != "payments" || item.fileName == "Payments.lean") then
        files := files.push ⟨"generated_" ++ (item.fileName.dropEnd 5).toString,item.fileName,item.path,"generated",""⟩
  files := files.qsort (fun a b => a.id < b.id)
  return ⟨kind,row[1]!,entry,files⟩

def listing (c : Config) (job verification : Nat) : IO Json := do
  let a ← attempt c job verification
  let files := a.files.map fun f => obj [("id",str f.id),("name",str f.name),
    ("role",str f.role),("recorded",toJson (!f.digest.isEmpty))]
  return obj [("kind",str a.kind),("status",str a.status),("entry",str a.entry),("files",toJson files)]

private def boundary (bytes : ByteArray) (offset : Nat) : Nat := Id.run do
  let mut pos := min offset bytes.size
  -- UTF-8 continuation bytes cannot start a page. Adjacent pages use the
  -- identical adjusted boundary, so concatenation reproduces the exact file.
  for _ in [:3] do
    if pos > 0 && pos < bytes.size && bytes[pos]! ≥ 128 && bytes[pos]! < 192 then pos := pos-1
  return pos

def page (c : Config) (job verification : Nat) (fileId : String) (number : Nat) : IO Json := do
  let a ← attempt c job verification
  let some file := a.files.find? (·.id == fileId) | throw <| IO.userError "proof source file not found"
  require (← file.path.pathExists) "recorded proof source unavailable: file is missing"
  let real ← IO.FS.realPath file.path
  if file.role == "generated" then
    let root ← IO.FS.realPath (c.bundleDir / "proofs")
    require (within real root) "proof source outside bundle"
    require (real == file.path) "proof source symlink outside attempt"
  else
    let root ← IO.FS.realPath (c.root / "LeanXRPL")
    require (real.parent == some root) "proof definition outside allowed modules"
  let bytes ← IO.FS.readBinFile file.path
  if !file.digest.isEmpty then
    require (hex (← Native.sha256 bytes) == file.digest) "recorded proof source unavailable: digest mismatch"
  let mut count := 0
  let mut cursor := 0
  let mut start := 0
  let mut finish := 0
  while cursor < bytes.size do
    let next := boundary bytes (cursor+65536)
    if count == number then start := cursor; finish := next
    cursor := next
    count := count+1
  count := max 1 count
  require (number < count) "proof source page out of range"
  let some source := String.fromUTF8? (bytes.extract start finish) | throw <| IO.userError "proof source is not UTF-8"
  return obj [("file_id",str file.id),("page",toJson number),("pages",toJson count),
    ("source",str source),("recorded",toJson (!file.digest.isEmpty))]

end XLB.ProofSource
