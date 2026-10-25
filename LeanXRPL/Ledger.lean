import LeanXRPL.Signature

namespace LeanXRPL
open Lean

def zeroHash : ByteArray := ⟨Array.replicate 32 0⟩

structure LedgerHeader where
  sequence : Nat
  hash : ByteArray
  parentHash : ByteArray
  transactionRoot : ByteArray
  stateRoot : ByteArray
  closeTime : Nat
  raw : ByteArray
  deriving Inhabited

def verifyLedgerHeader (raw expectedHash : ByteArray) (expectedSequence : Nat) : IO LedgerHeader := do
  if raw.size != 118 then throw <| IO.userError "ledger header must be 118 bytes"
  let hash ← Native.sha512Half (hashPrefix "LWR" ++ raw)
  let sequence := bytesNat (raw.extract 0 4)
  if hash != expectedHash || sequence != expectedSequence then throw <| IO.userError "ledger header commitment mismatch"
  return ⟨sequence, hash, raw.extract 12 44, raw.extract 44 76, raw.extract 76 108,
    bytesNat (raw.extract 112 116), raw⟩

def nodeID (path : Array Nat) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  for i in [:32] do
    out := out.push ((path[2*i]?.getD 0)*16 + path[2*i+1]?.getD 0).toUInt8
  return out.push path.size.toUInt8

def decodeNodeID (id : ByteArray) : ParseResult (Array Nat) := do
  if id.size != 33 || id[32]!.toNat > 64 then throw "invalid SHAMap node ID"
  let depth := id[32]!.toNat
  let path := (List.range depth).toArray.map fun i =>
    if i%2 == 0 then id[i/2]!.toNat/16 else id[i/2]!.toNat%16
  if nodeID path != id then throw "noncanonical SHAMap node ID"
  return path

def keyHasPath (key : ByteArray) (path : Array Nat) : Bool :=
  key.size == 32 && path.size ≤ 64 && (List.range path.size).all (fun i =>
    path[i]! == (if i%2 == 0 then key[i/2]!.toNat/16 else key[i/2]!.toNat%16))

structure LedgerTransaction where
  hash : ByteArray
  raw : ByteArray
  metadata : ByteArray
  deriving Inhabited

inductive TransactionTreeNode where
  | inner (children : Array ByteArray)
  | leaf (tx : LedgerTransaction)
  deriving Inhabited

def decodeTransactionNode (wire : ByteArray) : IO (ByteArray × TransactionTreeNode) := do
  if wire.size == 0 || wire.size > 2097152 then throw <| IO.userError "transaction node size limit"
  let typ := wire[wire.size-1]!.toNat
  let raw := wire.extract 0 (wire.size-1)
  if typ == 2 || typ == 3 then
    let mut children := Array.replicate 16 zeroHash
    if typ == 2 then
      if raw.size != 512 then throw <| IO.userError "invalid full inner node"
      children := (List.range 16).toArray.map (fun i => raw.extract (32*i) (32*i+32))
    else
      if raw.size % 33 != 0 || raw.size > 528 then throw <| IO.userError "invalid sparse inner node"
      let mut seen : Array Nat := #[]
      for i in [:raw.size/33] do
        let branch := raw[i*33+32]!.toNat
        let hash := raw.extract (i*33) (i*33+32)
        if branch ≥ 16 || seen.contains branch || hash == zeroHash then throw <| IO.userError "invalid sparse branch"
        children := children.set! branch hash
        seen := seen.push branch
    if children.all (· == zeroHash) then throw <| IO.userError "empty inner node"
    let hash ← Native.sha512Half (children.foldl (· ++ ·) (hashPrefix "MIN"))
    return (hash, .inner children)
  if typ != 4 || raw.size < 34 then throw <| IO.userError "expected transaction with metadata leaf"
  let key := raw.extract (raw.size-32) raw.size
  let payload := raw.extract 0 (raw.size-32)
  let (tx, c) ← IO.ofExcept (readVL ⟨payload, 0, by omega⟩)
  let (metadata, c) ← IO.ofExcept (readVL c)
  if c.remaining != 0 || tx.size == 0 || metadata.size == 0 then throw <| IO.userError "invalid transaction+metadata payload"
  if (← Native.sha512Half (hashPrefix "TXN" ++ tx)) != key then throw <| IO.userError "transaction ID mismatch"
  return (← Native.sha512Half (hashPrefix "SND" ++ raw), .leaf ⟨key, tx, metadata⟩)

structure TreeSlot where
  path : Array Nat
  expected : ByteArray
  node : Option TransactionTreeNode := none
  deriving Inhabited

structure TransactionTree where
  slots : Std.HashMap String TreeSlot := {}
  missing : Std.HashSet String := {}
  transactions : Std.HashMap String LedgerTransaction := {}
  bytes : Nat := 0
  deriving Inhabited

def TransactionTree.start (root : ByteArray) : TransactionTree :=
  if root == zeroHash then {} else
    let name := hex (nodeID #[])
    { slots := ({} : Std.HashMap String TreeSlot).insert name ⟨#[], root, none⟩,
      missing := ({} : Std.HashSet String).insert name }

/-- A node is attached only to a previously authenticated parent commitment. -/
def TransactionTree.insert (tree : TransactionTree) (id wire : ByteArray) : IO TransactionTree := do
  let path ← IO.ofExcept (decodeNodeID id)
  let name := hex id
  let some slot := tree.slots[name]? | throw <| IO.userError "unsolicited/unlinked transaction node"
  let (hash, node) ← decodeTransactionNode wire
  if hash != slot.expected then throw <| IO.userError "transaction tree hash mismatch"
  if slot.node.isSome then return tree
  if tree.bytes+wire.size > 134217728 || tree.slots.size > 200000 then
    throw <| IO.userError "ledger transaction-tree resource limit"
  let mut tree := { tree with bytes := tree.bytes+wire.size, slots := tree.slots.insert name { slot with node := some node }, missing := tree.missing.erase name }
  match node with
  | .inner children =>
    if path.size ≥ 64 then throw <| IO.userError "inner node at leaf depth"
    for branch in [:16] do
      if children[branch]! != zeroHash then
        let nextPath := path.push branch
        let nextName := hex (nodeID nextPath)
        if tree.slots.contains nextName then throw <| IO.userError "duplicate tree path"
        tree := { tree with slots := tree.slots.insert nextName ⟨nextPath, children[branch]!, none⟩, missing := tree.missing.insert nextName }
        if tree.slots.size > 200000 then throw <| IO.userError "ledger transaction-tree resource limit"
  | .leaf tx =>
    if !keyHasPath tx.hash path || tree.transactions.contains (hex tx.hash) then
      throw <| IO.userError "transaction leaf path/duplicate mismatch"
    tree := { tree with transactions := tree.transactions.insert (hex tx.hash) tx }
  return tree

def TransactionTree.complete (tree : TransactionTree) : Bool := tree.missing.isEmpty
def TransactionTree.requests (tree : TransactionTree) : Array ByteArray :=
  tree.missing.toArray.qsort (· < ·) |>.extract 0 16 |>.filterMap (fun key => (unhex key).toOption)

structure LedgerData where
  hash : ByteArray
  sequence : Nat
  kind : Nat
  nodes : Array (Option ByteArray × ByteArray)
  error : Option Nat
  deriving Inhabited

def decodeLedgerData (payload : ByteArray) : ParseResult LedgerData := do
  let fs ← parseProto payload
  let some hash := protoBytes fs 1 | throw "missing ledger reply hash"
  let some sequence := protoNat fs 2 | throw "missing ledger reply sequence"
  let some kind := protoNat fs 3 | throw "missing ledger reply kind"
  if hash.size != 32 || sequence > 4294967295 || kind > 3 then throw "invalid ledger reply envelope"
  let mut nodes := #[]
  for f in fs do
    if f.number == 4 then
      let .bytes b := f.value | throw "invalid ledger node wire type"
      let fields ← parseProto b
      let some wire := protoBytes fields 1 | throw "missing ledger node data"
      if wire.size > 2097152 || nodes.size ≥ 12288 then throw "ledger reply node limit"
      -- XRPL/2.2 uses legacy nodeid, and cannot negotiate the 2.3 depth feature.
      if (protoBytes fields 3).isSome || (protoNat fields 4).isSome then throw "unnegotiated ledger node depth feature"
      nodes := nodes.push (protoBytes fields 2, wire)
  return ⟨hash, sequence, kind, nodes, protoNat fs 6⟩

structure ValidationCertificate where
  hash : ByteArray
  sequence : Nat
  listSequence : Nat
  quorum : Nat
  votes : Array VerifiedValidation
  publisher : String := foundationPublisher
  trustDocument : String := ""
  manifests : Array ByteArray := #[]
  verifiedAt : Nat := 0
  anchorHash : ByteArray := ByteArray.empty
  anchorSequence : Nat := 0
  ancestry : Array ByteArray := #[]
  deriving Inhabited

structure LedgerAcquisition where
  certificate : ValidationCertificate
  header : Option LedgerHeader := none
  tree : TransactionTree := {}
  nextRequest : Nat := 0
  attempts : Nat := 0
  headersOnly : Bool := false
  deriving Inhabited

def LedgerAcquisition.accept (a : LedgerAcquisition) (reply : LedgerData) (headersOnly := false) : IO LedgerAcquisition := do
  if reply.hash != a.certificate.hash || reply.sequence != a.certificate.sequence then
    throw <| IO.userError "ledger reply certificate mismatch"
  if reply.error.isSome then return a
  if headersOnly then
    if reply.kind != 0 then return a
    if reply.nodes.isEmpty || reply.nodes[0]!.1.isSome then throw <| IO.userError "invalid ledger header reply"
    let header ← verifyLedgerHeader reply.nodes[0]!.2 a.certificate.hash a.certificate.sequence
    return { a with header := some header, tree := {}, attempts := 0, headersOnly := true }
  let activeHeaderMissing := a.header.isNone
  let beforeBytes := a.tree.bytes
  let mut a := a
  if reply.kind == 0 then
    if reply.nodes.isEmpty || reply.nodes.any (·.1.isSome) then throw <| IO.userError "invalid ledger base reply"
    let header ← verifyLedgerHeader reply.nodes[0]!.2 a.certificate.hash a.certificate.sequence
    if a.header.isNone then a := { a with header := some header, tree := TransactionTree.start header.transactionRoot }
    -- Header, account-state root, transaction root: account-state data is ignored.
    if reply.nodes.size ≥ 3 && header.transactionRoot != zeroHash then
      a := { a with tree := ← a.tree.insert (nodeID #[]) reply.nodes[2]!.2 }
  else if reply.kind == 1 then
    if a.header.isNone then throw <| IO.userError "transaction nodes before ledger header"
    let mut nodes : Array (ByteArray × ByteArray) := #[]
    for (id, wire) in reply.nodes do
      let some id := id | throw <| IO.userError "transaction node omitted ID"
      discard <| IO.ofExcept (decodeNodeID id)
      nodes := nodes.push (id, wire)
    nodes := nodes.qsort (fun x y => x.1[32]!.toNat < y.1[32]!.toNat)
    for (id, wire) in nodes do a := { a with tree := ← a.tree.insert id wire }
  else throw <| IO.userError "unexpected account-state/candidate-tree reply"
  if a.header.isSome && (activeHeaderMissing || a.tree.bytes > beforeBytes) then
    return { a with attempts := 0 }
  return a

def LedgerAcquisition.complete (a : LedgerAcquisition) : Bool := a.header.isSome && (a.headersOnly || a.tree.complete)
def LedgerAcquisition.request (a : LedgerAcquisition) : OutboundAction :=
  if a.header.isNone then .ledgerBase a.certificate.hash
  else .transactionNodes a.certificate.hash a.tree.requests

def certificateJson (c : ValidationCertificate) : Json := Json.mkObj [
  ("publisher_key", .str c.publisher), ("validator_list_sequence", toJson c.listSequence),
  ("validator_list", .str c.trustDocument), ("manifests", toJson (c.manifests.map hex)),
  ("verified_at_xrpl_time", toJson c.verifiedAt),
  ("anchor_hash", .str (hex c.anchorHash)), ("anchor_sequence", toJson c.anchorSequence),
  ("ancestry_headers", toJson (c.ancestry.map hex)),
  ("quorum", toJson c.quorum), ("validations", toJson (c.votes.map fun v => Json.mkObj [
    ("validator_master_key", .str (hex v.master)), ("validation_raw_hex", .str (hex v.raw))]))]

def ledgerSummaryJson (a : LedgerAcquisition) (signatureChecks : Std.HashMap String TransactionSignatureVerification) : Json :=
  let h := a.header.get!
  let signaturesVerified := !a.headersOnly && a.tree.transactions.toArray.all fun (key, _) =>
    signatureChecks[key]?.any (fun result => result.status == "verified" || result.status == "not_applicable")
  let systemTransactions := signatureChecks.toArray.filter (fun (_, result) => result.status == "not_applicable") |>.size
  Json.mkObj [("record_type", .str "validated_ledger"), ("ledger_index", toJson h.sequence),
    ("ledger_hash", .str (hex h.hash)), ("parent_hash", .str (hex h.parentHash)),
    ("transaction_root", .str (hex h.transactionRoot)), ("header_raw_hex", .str (hex h.raw)),
    ("close_time", toJson h.closeTime), ("transaction_count", toJson a.tree.transactions.size),
    ("certificate", certificateJson a.certificate), ("complete", .bool (a.complete && !a.headersOnly)),
    ("transaction_signatures_verified", .bool signaturesVerified), ("unsigned_system_transactions", toJson systemTransactions)]

/-- All signatures are checked before any ledger completion marker or checkpoint.
Batch inner transactions are bound to an independently verified parent in this tree. -/
def verifyLedgerTransactionSignatures (transactions : Std.HashMap String LedgerTransaction) : IO (Std.HashMap String TransactionSignatureVerification) := do
  let mut checks : Std.HashMap String TransactionSignatureVerification := {}
  for (key, tx) in transactions do
    let result ← verifyTransactionSignatures tx.raw
    if result.status == "invalid" || result.status == "unsupported" then
      throw <| IO.userError s!"transaction signature verification failed for {key}: {result.error.getD result.status}"
    checks := checks.insert key result
  for (key, tx) in transactions do
    let result := checks[key]!
    if result.status == "requires_parent_batch" then
      let metadata ← IO.ofExcept (parseSignatureFields tx.metadata)
      let parentHash ← IO.ofExcept (signatureValue metadata 0x524)
      if parentHash.size != 32 then throw <| IO.userError "invalid ParentBatchID"
      let some parent := transactions[hex parentHash]? | throw <| IO.userError "inner Batch parent missing from complete ledger"
      let some parentCheck := checks[hex parentHash]? | throw <| IO.userError "inner Batch parent was not checked"
      if parentCheck.status != "verified" then throw <| IO.userError "inner Batch parent signature not verified"
      let parentFields ← IO.ofExcept (parseSignatureFields parent.raw)
      if bytesNat (← IO.ofExcept (signatureValue parentFields 0x102)) != 71 then throw <| IO.userError "ParentBatchID does not reference Batch"
      let raws ← IO.ofExcept (batchInnerBytes parentFields)
      if !raws.contains tx.raw then throw <| IO.userError "inner Batch bytes absent from signed parent"
      checks := checks.insert key { result with status := "verified", parentBatch := some parentHash, signatures := parentCheck.signatures }
  return checks

/-- Metadata bytes are authenticated even when field decoding is partial. -/
def decodeMetadataFields (raw : ByteArray) : DecodedTransaction := Id.run do
  let mut cursor : Cursor := ⟨raw, 0, by omega⟩
  let mut fields : List (String × Json) := []
  let mut previous := 0
  for _ in [:raw.size] do
    if cursor.remaining == 0 then return ⟨fields.reverse, none⟩
    match readFieldID cursor with
    | .error e => return ⟨fields.reverse, some e⟩
    | .ok (typ, field, next) =>
      let code := typ*256+field
      if code ≤ previous then return ⟨fields.reverse, some "noncanonical metadata field order"⟩
      previous := code
      match skipValue 32 typ next with
      | .error e => return ⟨fields.reverse, some e⟩
      | .ok finish =>
        let value := if typ == 2 && field == 28 || typ == 16 && field == 3 then
          bytesNat (raw.extract next.pos finish.pos) else 0
        if typ == 2 && field == 28 then fields := ("TransactionIndex", toJson value) :: fields
        if typ == 16 && field == 3 then
          fields := ("TransactionResultCode", toJson value) :: fields
          fields := ("successful", .bool (value == 0)) :: fields
          if value == 0 then fields := ("TransactionResult", .str "tesSUCCESS") :: fields
        cursor := finish
  return ⟨fields.reverse, some "metadata decoding limit"⟩

def ledgerTransactionJson (a : LedgerAcquisition) (tx : LedgerTransaction)
    (signatureCheck : TransactionSignatureVerification) : IO Json := do
  let decoded ← decodeFields tx.raw
  let metadata := decodeMetadataFields tx.metadata
  return Json.mkObj [("record_type", .str "validated_transaction"),
    ("ledger_index", toJson a.certificate.sequence), ("ledger_hash", .str (hex a.certificate.hash)),
    ("transaction_hash", .str (hex tx.hash)), ("raw_hex", .str (hex tx.raw)),
    ("metadata_raw_hex", .str (hex tx.metadata)), ("metadata_fields", Json.mkObj metadata.fields),
    ("metadata_decoding_error", toJson metadata.error), ("fields", Json.mkObj decoded.fields),
    ("decoding_error", toJson decoded.error), ("confirmation", .str "validated"),
    ("inclusion_verification", .str "transaction_tree"), ("transaction_signature_verification", .str signatureCheck.status),
    ("transaction_signatures", ← signatureCheck.toJson), ("execution_verification", .str "not_reexecuted")]

structure VoteBucket where
  sequence : Nat
  votes : Array VerifiedValidation := #[]
  equivocators : Array ByteArray := #[]
  /-- Retained when consumers drain the certificate queue; the bucket window is bounded. -/
  certifiedHash : Option ByteArray := none
  deriving Inhabited

def VoteBucket.add (b : VoteBucket) (v : VerifiedValidation) : VoteBucket :=
  if b.equivocators.contains v.master then b
  else match b.votes.find? (·.master == v.master) with
    | none => { b with votes := b.votes.push v }
    | some old => if old.ledgerHash == v.ledgerHash then b else
        { b with votes := b.votes.filter (·.master != v.master), equivocators := b.equivocators.push v.master }

def VoteBucket.certificate (b : VoteBucket) (trust : ValidatorTrust) (now : Nat) : Option ValidationCertificate := do
  let current := b.votes.filter (fun v => now < v.signingTime+180 && v.signingTime < now+300)
  let winner ← current.find? fun v => (current.filter (·.ledgerHash == v.ledgerHash)).size ≥ trust.quorum
  return { hash := winner.ledgerHash, sequence := b.sequence, listSequence := trust.sequence, quorum := trust.quorum, votes := current.filter (·.ledgerHash == winner.ledgerHash), publisher := hex trust.publisher.master, trustDocument := trust.document, manifests := trust.manifests.map (·.raw), verifiedAt := now, anchorHash := winner.ledgerHash, anchorSequence := b.sequence }

structure LedgerTracker where
  trust : ValidatorTrust
  headersOnly : Bool := false
  buckets : Array VoteBucket := #[]
  certificates : Array ValidationCertificate := #[]
  active : Option LedgerAcquisition := none
  deferred : Array LedgerAcquisition := #[]
  lastEmitted : Option (Nat × ByteArray) := none
  firstSequence : Option Nat := none
  emitting : Bool := false
  deriving Inhabited

def LedgerTracker.addValidation (t : LedgerTracker) (v : VerifiedValidation) (now : Nat) : ParseResult LedgerTracker := do
  if t.lastEmitted.any (fun last => v.ledgerSequence ≤ last.1) then return t
  let bucket := (t.buckets.find? (·.sequence == v.ledgerSequence)).getD { sequence := v.ledgerSequence }
  let bucket := bucket.add v
  let buckets := ((t.buckets.filter (·.sequence != v.ledgerSequence)).push bucket).qsort (fun a b => a.sequence > b.sequence)
  let mut t : LedgerTracker := { t with buckets := buckets.extract 0 128 }
  if let some certificate := bucket.certificate t.trust now then
    if t.active.any (fun a => a.certificate.sequence == certificate.sequence && a.certificate.hash != certificate.hash) ||
        t.deferred.any (fun a => a.certificate.sequence == certificate.sequence && a.certificate.hash != certificate.hash) then
      throw "conflicting validator quorums"
    if let some old := bucket.certifiedHash then
      if old != certificate.hash then throw "conflicting validator quorums"
      return t
    if let some old := t.certificates.find? (·.sequence == certificate.sequence) then
      if old.hash != certificate.hash then throw "conflicting validator quorums"
      return t
    if t.certificates.size ≥ 128 then throw "validated-ledger backlog limit exceeded"
    t := { t with certificates := (t.certificates.push certificate).qsort (fun a b => a.sequence < b.sequence) }
    t := { t with buckets := t.buckets.map fun b =>
      if b.sequence == certificate.sequence then { b with certifiedHash := some certificate.hash } else b }
    if t.firstSequence.isNone then t := { t with firstSequence := some certificate.sequence }
  return t

def LedgerTracker.nextSequence (t : LedgerTracker) : Nat :=
  t.lastEmitted.map (fun last => last.1+1) |>.getD (t.firstSequence.getD 0)

def maxLedgerGap : Nat := 256

/-- One global acquisition: peers rotate on retries, with no duplicated workers. -/
def LedgerTracker.reserveRequest (t : LedgerTracker) (now : Nat) : ParseResult (LedgerTracker × Option OutboundAction) := do
  if t.emitting then return (t, none)
  let mut t := t
  if t.active.isNone then
    if !t.deferred.isEmpty then
      t := { t with active := some t.deferred.back!, deferred := t.deferred.pop }
    else if let some c := t.certificates.find? (fun c => c.sequence ≥ t.nextSequence) then
      t := { t with active := some { certificate := c } }
  let some a := t.active | return (t, none)
  -- The quorum certificate already authenticates the target sequence. Reject
  -- an impossible recovery before spending one request per ancestor.
  let gap := a.certificate.sequence - t.nextSequence
  if gap > maxLedgerGap then
    throw s!"ledger gap exceeds {maxLedgerGap} ledgers: next required ledger={t.nextSequence}, certified target={a.certificate.sequence}, ancestor ledgers={gap}"
  if a.complete || now < a.nextRequest then return (t, none)
  let action := a.request
  let delay := if a.attempts ≥ 120 then 30000 else 1500
  return ({ t with active := some { a with nextRequest := now+delay, attempts := min 120 (a.attempts+1) } }, some action)

def LedgerTracker.acceptData (t : LedgerTracker) (reply : LedgerData) : IO LedgerTracker := do
  let some active := t.active | return t
  if reply.hash != active.certificate.hash then return t -- late response from an earlier attempt
  let a ← active.accept reply t.headersOnly
  if (t.deferred.foldl (fun bytes a => bytes+a.tree.bytes) a.tree.bytes) > 268435456 then
    throw <| IO.userError "ledger transaction-tree resource limit"
  if let some header := a.header then
    if header.sequence > t.nextSequence then
      if t.deferred.size ≥ maxLedgerGap then throw <| IO.userError s!"ledger gap exceeds {maxLedgerGap} ledgers"
      let c := a.certificate
      let parent := { c with hash := header.parentHash, sequence := header.sequence-1, ancestry := c.ancestry.push header.raw }
      if t.certificates.any (fun known => known.sequence == parent.sequence && known.hash != parent.hash) then
        throw <| IO.userError "conflicting validator quorums"
      return { t with deferred := t.deferred.push a, active := some { certificate := parent } }
    if let some last := t.lastEmitted then
      if header.sequence != last.1+1 || header.parentHash != last.2 then
        throw <| IO.userError "validated ledger does not extend saved checkpoint"
  return { t with active := some a }

def LedgerTracker.takeComplete (t : LedgerTracker) : LedgerTracker × Option LedgerAcquisition :=
  if t.emitting then (t, none) else
  match t.active with
  | some a => if a.complete then ({ t with emitting := true }, some a) else (t, none)
  | none => (t, none)

def LedgerTracker.acknowledge (t : LedgerTracker) (a : LedgerAcquisition) : LedgerTracker :=
  { t with active := none, emitting := false, lastEmitted := some (a.certificate.sequence, a.certificate.hash), certificates := t.certificates.filter (·.sequence > a.certificate.sequence), buckets := t.buckets.filter (·.sequence > a.certificate.sequence) }

end LeanXRPL
