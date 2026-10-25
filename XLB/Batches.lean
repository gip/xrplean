import XLB.Proofs
import LeanXRPL.BatchPolicy

namespace XLB.Batches
open Lean LeanXRPL XL

private def strict (j : Json) (names : List String) : IO Unit := do
  let fields ← IO.ofExcept j.getObj?
  for (key, _) in fields.toList do
    require (names.contains key) s!"unsupported field: {key}"

private def drops (s : String) : IO Nat := do
  require (!s.isEmpty && s.length ≤ 18 && s.toList.all (fun ch => ch ≥ '0' && ch ≤ '9')) "expected integer drops as a decimal string"
  let some n := s.toNat? | throw <| IO.userError "invalid drops"
  require (n > 0 && n ≤ BatchPolicy.maxDrops && toString n == s) "drops must be canonical and positive, at most 100000000000000000"
  return n

private def address (s : String) : IO BatchPolicy.Bytes := do
  let raw ← base58CheckDecode 0 s
  let encoded ← IO.ofExcept (base58Decode s)
  require (raw.size == 20 && base58Encode encoded == s) "expected a canonical classic XRPL address"
  return raw.data.toList.map UInt8.toNat

private def bytes (xs : BatchPolicy.Bytes) : ByteArray := byteArray (xs.map Nat.toUInt8)

private def configuredPolicy (c : Config) : IO BatchPolicy.Policy := do
  require (!c.batchServiceAddress.isEmpty && c.batchServiceFee > 0) "Batch preparation is disabled; configure --batch-service-address and --batch-service-fee"
  return ⟨c.network, ← address c.batchServiceAddress, c.batchServiceFee⟩

private def policyJson (c : Config) : Json := obj [
  ("version",toJson (1 : Nat)),("network_id",toJson c.network),
  ("service_address",str c.batchServiceAddress),("service_fee_drops",str (toString c.batchServiceFee))]

def policy (c : Config) : IO Json := do
  return obj [("enabled",toJson (!c.batchServiceAddress.isEmpty)),("policy",policyJson c),
    ("policy_digest",str (← digest (policyJson c).compress)),("max_user_payments",toJson (7 : Nat))]

def init (c : Config) : IO Unit := do
  require (c.batchServiceAddress.isEmpty == (c.batchServiceFee == 0)) "configure both --batch-service-address and --batch-service-fee"
  if !c.batchServiceAddress.isEmpty then
    discard <| configuredPolicy c
    require (c.batchServiceFee ≤ BatchPolicy.maxDrops) "service fee exceeds XRP supply"
  exec c "CREATE TABLE IF NOT EXISTS batch_attempts(
    id INTEGER PRIMARY KEY, network INTEGER NOT NULL, request_json TEXT NOT NULL,
    prepared_json TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('queued','running','kernel_checked','failed','interrupted')),
    error TEXT NOT NULL DEFAULT '', report_json TEXT NOT NULL DEFAULT 'null',
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, finished_at TEXT);
    CREATE INDEX IF NOT EXISTS batch_attempts_queue ON batch_attempts(status,id);
    UPDATE batch_attempts SET status='interrupted',error='backend stopped before certificate completion; create a new preparation',
      finished_at=CURRENT_TIMESTAMP WHERE status IN ('queued','running');"

private def input (c : Config) (j : Json) : IO (BatchPolicy.Policy × BatchPolicy.Batch) := do
  strict j ["account","public_key","sequence","service_sequence","last_ledger_sequence","network_fee_drops","payments","policy_digest"]
  if let .ok supplied := j.getObjVal? "policy_digest" then
    require (supplied == str (← digest (policyJson c).compress)) "service policy changed; refresh and review the fee before preparing"
  let p ← configuredPolicy c
  let source ← address (← string j "account")
  let publicKey ← string j "public_key"
  require (publicKey.length == 66) "expected a 33-byte compressed public key"
  let key ← IO.ofExcept (unhex publicKey)
  require (key.size == 33 && (key[0]! == 2 || key[0]! == 3) && (← Native.secpPublicValid key)) "expected a valid compressed secp256k1 public key"
  require ((← Native.ripemd160 (← Native.sha256 key)) == bytes source) "public key does not derive the source account"
  let ps ← array j "payments"
  require (ps.size ≥ 1 && ps.size ≤ 7) "enter one to seven user Payments"
  let payments ← ps.toList.mapM fun x => do
    strict x ["destination","amount_drops","sequence"]
    return (⟨← address (← string x "destination"), ← drops (← string x "amount_drops"), ← nat x "sequence"⟩ : BatchPolicy.Payment)
  let b : BatchPolicy.Batch := ⟨source,key.data.toList.map UInt8.toNat,← nat j "sequence",← nat j "service_sequence",
    ← nat j "last_ledger_sequence",← drops (← string j "network_fee_drops"),payments⟩
  require (BatchPolicy.check p b (BatchPolicy.serialize p b)) "Batch policy rejected: check account, positive amounts, distinct uint32 sequences, expiry, and total debit"
  return (p,b)

private def transaction (c : Config) (b : BatchPolicy.Batch) : IO Json := do
  let source ← base58CheckEncode 0 (bytes b.source)
  let inners ← (BatchPolicy.innerPayments (← configuredPolicy c) b).mapM fun x => do
    return obj [("RawTransaction",obj [("TransactionType",str "Payment"),("Flags",toJson (0x40000000 : Nat)),
      ("Account",str source),("Destination",str (← base58CheckEncode 0 (bytes x.destination))),
      ("Amount",str (toString x.amount)),("Sequence",toJson x.sequence),("Fee",str "0"),("SigningPubKey",str "")])]
  return obj <| [("TransactionType",str "Batch"),("Account",str source),("Flags",toJson (0x10000 : Nat)),
    ("Sequence",toJson b.sequence),("LastLedgerSequence",toJson b.lastLedger),("Fee",str (toString b.networkFee)),
    ("SigningPubKey",str (hex (bytes b.publicKey))),("RawTransactions",toJson inners)] ++
    (if c.network > 1024 then [("NetworkID",toJson c.network)] else [])

private def literal (xs : BatchPolicy.Bytes) : String := "[" ++ String.intercalate "," (xs.map toString) ++ "]"
private def certificate (p : BatchPolicy.Policy) (b : BatchPolicy.Batch) (raw : BatchPolicy.Bytes) : String :=
  "import LeanXRPL.BatchPolicy\nopen LeanXRPL.BatchPolicy\nset_option maxRecDepth 10000\nset_option maxHeartbeats 4000000\n" ++
  s!"def policy : Policy := ⟨{p.network},{literal p.recipient},{p.fee}⟩\n" ++
  s!"def batch : Batch := ⟨{literal b.source},{literal b.publicKey},{b.sequence},{b.serviceSequence},{b.lastLedger},{b.networkFee},[" ++
  String.intercalate "," (b.payments.map fun x => s!"⟨{literal x.destination},{x.amount},{x.sequence}⟩") ++ "]⟩\n" ++
  s!"def raw : List Nat := {literal raw}\n" ++
  "theorem batch_certified : Certified policy batch raw := check_sound (by decide)\n" ++
  "theorem exact_bytes : raw = serialize policy batch := certified_bytes batch_certified\n" ++
  "#print axioms batch_certified\n#print axioms exact_bytes\n"

/-- Read-only export binding check. Python orchestrates compilation, but never
    decodes XRPL addresses, serializes transactions, or interprets policy. -/
def verifyArtifacts (dir : System.FilePath) : IO Json := do
  let request ← IO.ofExcept (Json.parse (← IO.FS.readFile (dir/"request.json")))
  let saved ← IO.ofExcept (Json.parse (← IO.FS.readFile (dir/"policy.json")))
  strict saved ["version","network_id","service_address","service_fee_drops"]
  require ((← nat saved "version") == 1) "unsupported policy version"
  let network ← nat saved "network_id"
  let recipient ← string saved "service_address"
  let fee ← drops (← string saved "service_fee_drops")
  let c : Config := {network, batchServiceAddress := recipient, batchServiceFee := fee}
  let (p,b) ← input c request
  let wire := bytes (BatchPolicy.serialize p b)
  require ((← IO.FS.readFile (dir/"Certificate.lean")) == certificate p b (BatchPolicy.serialize p b)) "certificate literal binding failed"
  require ((← IO.FS.readFile (dir/"unsigned.hex")) == hex wire ++ "\n") "unsigned bytes differ from certificate"
  require ((← IO.FS.readFile (dir/"transaction.json")) == (← transaction c b).pretty) "transaction JSON differs from certified bytes"
  let binding ← IO.ofExcept (Json.parse (← IO.FS.readFile (dir/"binding.json")))
  require ((← string binding "policy_digest") == (← digest (policyJson c).compress) &&
    (← string binding "signing_digest") == hex (← Native.sha512Half (hashPrefix "STX" ++ wire))) "export digest binding failed"
  return obj [("status",str "exact_literals_checked"),("policy_digest",← get binding "policy_digest"),
    ("signing_digest",← get binding "signing_digest")]

private def artifactNames := ["request.json","transaction.json","unsigned.hex","policy.json","Certificate.lean",
  "BatchPolicy.lean","lean-toolchain","kernel.log","kernel.log.stderr","binding.json","report.json","manifest.json"]

private def directory (c : Config) (id : Nat) := c.data / "batch-attempts" / toString id

def listAttempts (c : Config) : IO Json := do
  let rows ← sql c.db s!"SELECT id,status,created_at FROM batch_attempts WHERE network={c.network} ORDER BY id DESC LIMIT 50"
  rowsJson rows #["attempt_id","status","created_at"]

def getAttempt (c : Config) (id : Nat) : IO Json := do
  let rows ← sql c.db s!"SELECT status,error,prepared_json,report_json,created_at,COALESCE(finished_at,'') FROM batch_attempts WHERE id={id} AND network={c.network}"
  let some row := rows[0]? | throw <| IO.userError "batch attempt not found"
  let prepared ← IO.ofExcept (Json.parse row[2]!)
  let storedReport ← IO.ofExcept (Json.parse row[3]!)
  let report ← if row[0]! == "interrupted" && storedReport == .null then do
    let mut available := []
    for name in artifactNames do
      if ← (directory c id/name).pathExists then available := available ++ [name]
    pure (obj [("status",str "interrupted"),("error",str row[1]!), ("artifacts",toJson available)])
    else pure storedReport
  return obj [("attempt_id",str (toString id)),("status",str row[0]!), ("error",str row[1]!),
    ("prepared",prepared),("report",report),
    ("created_at",str row[4]!), ("finished_at",str row[5]!)]

def submit (c : Config) (j : Json) : IO Json := do
  let (p,b) ← input c j
  let raw := BatchPolicy.serialize p b
  let wire := bytes raw
  let source := certificate p b raw
  let prepared := obj [("transaction",← transaction c b),("unsigned_bytes",str (hex wire)),
    ("signing_digest",str (hex (← Native.sha512Half (hashPrefix "STX" ++ wire)))),
    ("policy",policyJson c),("policy_digest",str (← digest (policyJson c).compress)),
    ("total_debit_drops",str (toString (b.networkFee+p.fee+(b.payments.map BatchPolicy.Payment.amount).sum))),
    ("certificate_source",str source)]
  let rows ← sql c.db s!"BEGIN IMMEDIATE;
    INSERT INTO batch_attempts(network,request_json,prepared_json,status)
      SELECT {c.network},{← quote j.compress},{← quote prepared.compress},'queued'
      WHERE (SELECT COUNT(*) FROM batch_attempts WHERE status IN ('queued','running'))<8 RETURNING id;
    COMMIT;"
  let some row := rows[0]? | throw <| IO.userError "batch queue is full; wait for existing preparations"
  getAttempt c (row[0]!.toNat?.getD 0)

def artifact (c : Config) (id : Nat) (name : String) : IO Json := do
  discard <| getAttempt c id
  require (artifactNames.contains name) "unknown batch artifact"
  let path := directory c id / name
  require (← path.pathExists) "artifact is not available yet"
  let content ← IO.FS.readFile path
  return obj [("name",str name),("content",str content),("sha256",str (← digest content))]

private def execute (c : Config) (stop : IO.Ref Bool) (id : Nat) : IO Unit := do
  let dir := directory c id
  let mut report := obj [("status",str "failed")]
  try
    require (!(← dir.pathExists)) "attempt directory already exists; artifacts will not be overwritten"
    IO.FS.createDirAll dir
    let rows ← sql c.db s!"SELECT request_json,prepared_json FROM batch_attempts WHERE id={id}"
    let request ← IO.ofExcept (Json.parse rows[0]![0]!)
    let prepared ← IO.ofExcept (Json.parse rows[0]![1]!)
    IO.FS.writeFile (dir/"request.json") request.pretty
    IO.FS.writeFile (dir/"transaction.json") (← get prepared "transaction").pretty
    IO.FS.writeFile (dir/"unsigned.hex") ((← string prepared "unsigned_bytes") ++ "\n")
    IO.FS.writeFile (dir/"policy.json") (← get prepared "policy").pretty
    IO.FS.writeFile (dir/"Certificate.lean") (← string prepared "certificate_source")
    let moduleSource ← IO.FS.readFile (c.root/"LeanXRPL/BatchPolicy.lean")
    let moduleBinaryHash := hex (← Native.sha256 (← IO.FS.readBinFile (c.root/".lake/build/lib/lean/LeanXRPL/BatchPolicy.olean")))
    IO.FS.writeFile (dir/"BatchPolicy.lean") moduleSource
    IO.FS.writeFile (dir/"lean-toolchain") (← IO.FS.readFile (c.root/"lean-toolchain"))
    let code ← process c stop "lake" #["env","lean","--memory=2048",(dir/"Certificate.lean").toString] (dir/"kernel.log") #[] 120000
    require (code == 0) "Lean certificate compilation failed; inspect kernel.log and kernel.log.stderr"
    Proofs.checkAxioms (← IO.FS.readFile (dir/"kernel.log"))
    require ((← IO.FS.readFile (c.root/"LeanXRPL/BatchPolicy.lean")) == moduleSource &&
      hex (← Native.sha256 (← IO.FS.readBinFile (c.root/".lake/build/lib/lean/LeanXRPL/BatchPolicy.olean"))) == moduleBinaryHash)
      "proof module changed during compilation; create a new preparation after rebuilding"
    -- Reconstruct from the immutable request and its frozen policy, independently
    -- of generated source literals. No JSON success marker can bypass compilation.
    let savedPolicy ← get prepared "policy"
    let savedAddress ← string savedPolicy "service_address"
    let savedFee ← string savedPolicy "service_fee_drops"
    let frozen : Config := {c with batchServiceAddress := savedAddress, batchServiceFee := savedFee.toNat?.getD 0}
    let (p,b) ← input frozen request
    let expected := certificate p b (BatchPolicy.serialize p b)
    require ((← IO.FS.readFile (dir/"Certificate.lean")) == expected) "certificate literal binding failed"
    let wire := bytes (BatchPolicy.serialize p b)
    require ((← string prepared "unsigned_bytes") == hex wire &&
      (← IO.FS.readFile (dir/"unsigned.hex")) == hex wire ++ "\n" &&
      (← IO.FS.readFile (dir/"transaction.json")) == (← transaction frozen b).pretty &&
      (← string prepared "signing_digest") == hex (← Native.sha512Half (hashPrefix "STX" ++ wire)) &&
      (← string prepared "policy_digest") == (← digest savedPolicy.compress)) "export binding failed"
    IO.FS.writeFile (dir/"binding.json") (obj [("status",str "exact_literals_checked"),
      ("unsigned_sha256",str (hex (← Native.sha256 wire))), ("certificate_sha256",str (← digest expected)),
      ("signing_digest",← get prepared "signing_digest"),("policy_digest",← get prepared "policy_digest")]).pretty
    let mut files := #[]
    for name in ["request.json","transaction.json","unsigned.hex","policy.json","Certificate.lean","BatchPolicy.lean","lean-toolchain","kernel.log","binding.json"] do
      files := files.push (obj [("name",str name),("sha256",str (← digest (← IO.FS.readFile (dir/name))))])
    for name in ["LeanXRPL/BatchPolicy.lean",".lake/build/lib/lean/LeanXRPL/BatchPolicy.olean"] do
      files := files.push (obj [("name",str name),("sha256",str (hex (← Native.sha256 (← IO.FS.readBinFile (c.root/name)))) )])
    IO.FS.writeFile (dir/"manifest.json") (toJson files).pretty
    report := obj [("status",str "kernel_checked"),("theorem",str "batch_certified"),
      ("bytes_binding",str "kernel_checked_serialization_equality"),("axiom_audit",str (← IO.FS.readFile (dir/"kernel.log"))),
      ("key_source_binding",str "openssl_checked_not_kernel_proved"),
      ("funds_available",toJson false),("wallet_ownership",toJson false),("execution_proved",toJson false),
      ("network_consensus",toJson false),("artifacts",toJson (artifactNames.filter (· != "kernel.log.stderr")))]
    IO.FS.writeFile (dir/"report.json") report.pretty
    exec c s!"UPDATE batch_attempts SET status='kernel_checked',report_json={← quote report.compress},finished_at=CURRENT_TIMESTAMP WHERE id={id}"
  catch error =>
    let status := if ← stop.get then "interrupted" else "failed"
    let mut available := ["report.json"]
    for name in artifactNames do
      if name != "report.json" && (← (dir/name).pathExists) then available := available ++ [name]
    report := obj [("status",str status),("error",str error.toString),("artifacts",toJson available)]
    if ← dir.pathExists then
      unless ← (dir/"report.json").pathExists do IO.FS.writeFile (dir/"report.json") report.pretty
    exec c s!"UPDATE batch_attempts SET status={← quote status},error={← quote error.toString},report_json={← quote report.compress},finished_at=CURRENT_TIMESTAMP WHERE id={id}"

/-- A single dedicated worker; HTTP clients only enqueue and observe. -/
def run (c : Config) (stop : IO.Ref Bool) : IO Unit := do
  while !(← stop.get) do
    let rows ← sql c.db "UPDATE batch_attempts SET status='running' WHERE id=(SELECT id FROM batch_attempts WHERE status='queued' ORDER BY id LIMIT 1) AND status='queued' RETURNING id,network"
    if let some row := rows[0]? then
      execute {c with network := row[1]!.toNat?.getD 0} stop (row[0]!.toNat?.getD 0)
    else IO.sleep 50

end XLB.Batches
