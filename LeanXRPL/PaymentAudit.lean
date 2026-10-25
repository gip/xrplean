import LeanXRPL.AuditData
import LeanXRPL.PaymentModel
import LeanXRPL.LedgerProofs

namespace LeanXRPL.PaymentAudit
open Lean AuditData

structure Transaction where
  index : Nat
  hash : ByteArray
  typeCode : Nat
  typeName : String
  json : Json
  fields : Array SignatureField
  metadata : Json
  metadataFields : Array SignatureField
  result : String
  resultCode : Nat
  changes : Array Change
  deriving Inhabited

structure Export where
  index : Nat
  hash : ByteArray
  parentHash : ByteArray
  parentRoot : StateTree.Hash
  root : StateTree.Hash
  network : Nat
  pre : Array Change
  transactions : Array Transaction
  post : Array Change
  deriving Inhabited

private def container (fs : Array SignatureField) (code : Nat) : IO (Array SignatureField) := do
  let some f := fs.find? (·.code == code) | throw <| IO.userError s!"missing container {code}"
  IO.ofExcept (signatureObjects f)

private def metadataChanges (tx : Transaction) : IO Unit := do
  let nodes ← container tx.metadataFields 0xf08
  let jsonNodes ← array tx.metadata "AffectedNodes"
  require (nodes.size == tx.changes.size && jsonNodes.size == nodes.size) "affected-node/change count mismatch"
  for j in jsonNodes do
    let .obj fields := j | throw <| IO.userError "affected node must be an object"
    require (fields.size == 1) "ambiguous JSON affected-node wrapper"
  let mut seen : List ByteArray := []
  for node in nodes do
    let fs ← IO.ofExcept (signatureObjects node)
    let key ← field fs 0x506
    require (!seen.contains key) "duplicate affected-node key"
    seen := key :: seen
    let some change := tx.changes.find? (·.key == key) | throw <| IO.userError "affected node absent from changes"
    let (operation, wrapper, finalCode) ← match node.code with
      | 0xe03 => pure ("create", "CreatedNode", 0xe08)
      | 0xe04 => pure ("delete", "DeletedNode", 0xe07)
      | 0xe05 => pure ("modify", "ModifiedNode", 0xe07)
      | _ => throw <| IO.userError "invalid affected-node wrapper"
    require (change.operation == operation && (← fieldNat fs 0x101) == change.entryType) "affected-node operation/type mismatch"
    let mut jsonNode : Option Json := none
    for candidate in jsonNodes do
      if has candidate wrapper then
        let body ← IO.ofExcept (candidate.getObjVal? wrapper)
        if (← hashBytes (← string body "LedgerIndex")) == key then
          require jsonNode.isNone "duplicate JSON affected node"
          jsonNode := some body
    let some j := jsonNode | throw <| IO.userError "JSON affected node missing"
    let image := (change.after.or change.before).get!
    require ((← string j "LedgerEntryType") == (← string image.json "LedgerEntryType")) "JSON affected-node type mismatch"
    if change.entryType == 97 || change.entryType == 114 then
      let finalName := if operation == "create" then "NewFields" else "FinalFields"
      require (hasField fs finalCode == has j finalName) "metadata field-container presence mismatch"
      let fields ← if hasField fs finalCode then container fs finalCode else pure #[]
      let fieldsJSON ← if has j finalName then IO.ofExcept (j.getObjVal? finalName) else pure (Json.mkObj [])
      checkProjection fieldsJSON fields
      require (hasField fs 0xe06 == has j "PreviousFields") "previous-field container presence mismatch"
      if operation != "delete" then
        -- Final/NewFields are a subset: history stamps live in the node header.
        for f in fields do
          require ((signatureValue image.fields f.code).toOption == some f.value) "metadata final field disagrees with state image"
      if hasField fs 0xe06 then
        let previous ← container fs 0xe06
        let previousJSON ← IO.ofExcept (j.getObjVal? "PreviousFields")
        checkProjection previousJSON previous
        if operation == "modify" then
          let some before := change.before | throw <| IO.userError "modified node missing before"
          for f in previous do
            require ((signatureValue before.fields f.code).toOption == some f.value) "metadata previous field disagrees with state image"
      if operation == "modify" then
        checkProjection j fs
        if let some before := change.before then
          for code in [0x602, 0x204] do
            if (signatureValue before.fields code).toOption != (signatureValue image.fields code).toOption then
              require (hasField fields code && hasField fs 0xe06) "changed financial field missing from metadata"
              let previous ← container fs 0xe06
              require (hasField previous code) "previous financial field missing from metadata"
          for code in [0x505, 0x205] do
            if hasField fs code then
              require ((signatureValue before.fields code).toOption == (signatureValue fs code).toOption) "metadata previous history mismatch"

def decodeTransaction (j : Json) : IO Transaction := do
  let index ← nat j "TransactionIndex"
  let hash ← hashBytes (← string j "hash")
  let raw ← IO.ofExcept (unhex (← string j "transaction_blob"))
  require ((← Native.sha512Half (hashPrefix "TXN" ++ raw)) == hash) "transaction hash mismatch"
  let fields ← IO.ofExcept (parseSignatureFields raw)
  let typeCode ← fieldNat fields 0x102
  let json ← IO.ofExcept (j.getObjVal? "transaction")
  if has json "hash" then require ((← hashBytes (← string json "hash")) == hash) "nested transaction hash mismatch"
  let reportedType ← string json "TransactionType"
  let typeName := (transactionTypeName typeCode).getD (if typeCode == 71 then "Batch" else s!"code_{typeCode}")
  if !typeName.startsWith "code_" then require (reportedType == typeName) "JSON transaction type mismatch"
  let metadata ← IO.ofExcept (j.getObjVal? "metadata")
  let mraw ← IO.ofExcept (unhex (← string j "metadata_blob"))
  let metadataFields ← IO.ofExcept (parseSignatureFields mraw)
  require ((← nat metadata "TransactionIndex") == index && (← fieldNat metadataFields 0x21c) == index) "metadata index mismatch"
  let result ← string j "result"
  require (result == (← string metadata "TransactionResult")) "metadata result mismatch"
  let resultCode ← fieldNat metadataFields 0x1003
  for (code, name) in [(0, "tesSUCCESS"), (101, "tecPATH_PARTIAL"), (128, "tecPATH_DRY")] do
    if resultCode == code || result == name then require (resultCode == code && result == name) "JSON/blob result mismatch"
  let changes ← (← array j "changes").mapM decodeChange
  let mut keys : List ByteArray := []
  for c in changes do
    require (!keys.contains c.key) "duplicate transaction change key"
    keys := c.key :: keys
  let tx := Transaction.mk index hash typeCode typeName json fields metadata metadataFields result resultCode changes
  metadataChanges tx
  return tx

def decodeExport (j : Json) : IO Export := do
  require ((← nat j "schema_version") == 1 && (← string j "stage") == "accepted") "unsupported export schema/stage"
  let index ← nat j "ledger_index"
  require (index > 0 && index ≤ 4294967295) "ledger index out of range"
  let hash ← hashBytes (← string j "ledger_hash")
  let parentHash ← hashBytes (← string j "parent_ledger_hash")
  let parentRoot ← IO.ofExcept (StateTree.Hash.ofBytes (← hashBytes (← string j "parent_state_root")))
  let root ← IO.ofExcept (StateTree.Hash.ofBytes (← hashBytes (← string j "state_root")))
  let network ← nat j "network_id"
  let pre ← (← array j "pre_transaction_changes").mapM decodeChange
  let transactions ← (← array j "transactions").mapM decodeTransaction
  let transactions := transactions.qsort (fun a b => a.index < b.index)
  let mut hashes : List ByteArray := []
  for i in [:transactions.size] do
    require (transactions[i]!.index == i) "transaction indices must be unique and contiguous from zero"
    require (!hashes.contains transactions[i]!.hash) "duplicate transaction hash"
    hashes := transactions[i]!.hash :: hashes
  let post ← (← array j "post_transaction_changes").mapM decodeChange
  return ⟨index, hash, parentHash, parentRoot, root, network, pre, transactions, post⟩

def Export.allChanges (e : Export) : Array Change :=
  e.pre ++ e.transactions.foldl (fun cs t => cs ++ t.changes) #[] ++ e.post

/-- Cross-transaction image continuity is checked even without a parent tree.
First occurrences are unanchored until Merkle replay checks them against it. -/
def continueImages (e : Export) (initial : Std.HashMap String (Option ByteArray) := {}) :
    IO (Std.HashMap String (Option ByteArray)) := do
  let mut images := initial
  for c in e.allChanges do
    let key := hex c.key
    if let some previous := images[key]? then
      require (previous == c.before.map (·.raw)) s!"broken before/after chain: {key}"
    images := images.insert key (c.after.map (·.raw))
  return images

def checkContinuity (e : Export) : IO Unit := discard (continueImages e)

structure Verdict where
  status : String
  reason : String := ""
  facts : Option PaymentModel.Facts := none
  deriving Inhabited

private def unsupported (reason : String) : Verdict := ⟨"unsupported", reason, none⟩
private def xrp (amount : Amount) : IO Int :=
  match amount with | .xrp n => pure n | _ => throw <| IO.userError "expected XRP amount"

private def modified (c : Change) : IO (Image × Image) := do
  let some before := c.before | throw <| IO.userError "missing before-image"
  let some after := c.after | throw <| IO.userError "missing after-image"
  require (c.operation == "modify") "expected modified object"
  return (before, after)

private def accountKey (id : ByteArray) : IO ByteArray := Native.sha512Half (uintBytes 0x61 2 ++ id)
private def lineKey (a b currency : ByteArray) : IO ByteArray :=
  let (low, high) := if StateTree.compareBytes a b == .lt then (a, b) else (b, a)
  Native.sha512Half (uintBytes 0x72 2 ++ low ++ high ++ currency)

/-- Interpret the shared balance from the requested holder's perspective. -/
def lineBalance (image : Image) (holder issuer currency : ByteArray) : IO (Int × Int) := do
  let .token bc bi balance ← fieldAmount image.fields 0x602 | throw <| IO.userError "invalid line balance"
  let .token lc low lowLimit ← fieldAmount image.fields 0x606 | throw <| IO.userError "invalid low limit"
  let .token hc high highLimit ← fieldAmount image.fields 0x607 | throw <| IO.userError "invalid high limit"
  require (bc == currency && lc == currency && hc == currency && bi == uintBytes 1 20) "trust-line currency/balance issuer mismatch"
  require (StateTree.compareBytes low high == .lt) "trust-line endpoint ordering mismatch"
  require ((holder == low && issuer == high) || (holder == high && issuer == low)) "trust-line endpoint mismatch"
  return if holder == low then (balance, lowLimit) else (-balance, highLimit)

def verifyPayment (e : Export) (t : Transaction) : IO Verdict := do
  if t.typeCode != 0 then return ⟨"not_payment", "", none⟩
  try
    if (signatureValue t.fields 0x601).toOption.any (·.size == 33) ||
        (signatureValue t.fields 0x609).toOption.any (·.size == 33) then
      return unsupported "MPT amount"
    if hasField t.fields 0x229 || hasField t.metadataFields 0x524 || hasField t.fields 0x80c ||
        hasField t.fields 0xe26 || hasField t.fields 0xe25 then
      return unsupported "tickets, batch execution, delegation, or sponsorship"
    let fee ← xrp (← fieldAmount t.fields 0x608)
    let sequence ← fieldNat t.fields 0x204
    let sender ← field t.fields 0x801
    require (sender.size == 20) "invalid sender"
    let sourceKey ← accountKey sender
    let some sourceChange := t.changes.find? (fun c => c.key == sourceKey && c.entryType == 97)
      | throw <| IO.userError "sender AccountRoot change missing"
    let (sourceBefore, sourceAfter) ← modified sourceChange
    checkProjection t.json t.fields
    require ((← field sourceBefore.fields 0x801) == sender && (← field sourceAfter.fields 0x801) == sender) "sender identity mismatch"
    let common : PaymentModel.Facts := {
      kind := .feeOnly, amount := 0, fee
      sourceXrpBefore := ← xrp (← fieldAmount sourceBefore.fields 0x602)
      sourceXrpAfter := ← xrp (← fieldAmount sourceAfter.fields 0x602)
      sequenceBefore := ← fieldNat sourceBefore.fields 0x204
      sequenceAfter := ← fieldNat sourceAfter.fields 0x204
      transactionSequence := sequence
      identityOK := true
      frameOK := frameEqual sourceBefore sourceAfter [0x602, 0x204, 0x505, 0x205]
      historyOK := ← stamped sourceAfter t.hash e.index
      deliveryOK := !hasField t.metadataFields 0x612 && !has t.metadata "DeliveredAmount" }
    let flags := (signatureValue t.fields 0x202).toOption.map bytesNat |>.getD 0
    if t.resultCode != 0 then
      if t.resultCode != 101 && t.resultCode != 128 then return unsupported "failure result not modeled"
      if t.changes.size != 1 then return unsupported "failure has additional cleanup effects"
      return ⟨if PaymentModel.check common then "verified" else "failed", "fee-only accounting", some common⟩
    if flags &&& 0x7fffffff != 0 || hasField t.fields 0x1201 || hasField t.fields 0x60a then
      return unsupported "partial payment, paths, quality flags, or DeliverMin"
    let destination ← field t.fields 0x803
    require (destination.size == 20 && destination != sender) "invalid or identical destination"
    let amountBytes ← field t.fields 0x601
    if amountBytes.size == 33 then return unsupported "MPT amount"
    let amount ← IO.ofExcept (decodeAmount amountBytes)
    let delivered ← if hasField t.metadataFields 0x612 then
      let delivered ← fieldAmount t.metadataFields 0x612
      require (has t.metadata "DeliveredAmount") "DeliveredAmount JSON missing"
      checkProjection t.metadata t.metadataFields
      pure (delivered == amount)
      else pure (!has t.metadata "DeliveredAmount")
    match amount with
    | .xrp drops =>
      if hasField t.fields 0x609 then return unsupported "XRP payment with SendMax/conversion"
      if t.changes.any (fun c => c.operation != "modify") then return unsupported "account creation or deletion"
      require (t.changes.size == 2 && t.changes.all (·.entryType == 97)) "direct XRP unexpected change set"
      let destinationKey ← accountKey destination
      let some destinationChange := t.changes.find? (·.key == destinationKey) | throw <| IO.userError "destination AccountRoot change missing"
      let (db, da) ← modified destinationChange
      require ((← field db.fields 0x801) == destination && (← field da.fields 0x801) == destination) "destination identity mismatch"
      let facts := { common with
        kind := .xrp
        amount := drops
        destinationXrpBefore := ← xrp (← fieldAmount db.fields 0x602)
        destinationXrpAfter := ← xrp (← fieldAmount da.fields 0x602)
        frameOK := common.frameOK && frameEqual db da [0x602, 0x505, 0x205]
        historyOK := common.historyOK && (← stamped da t.hash e.index)
        deliveryOK := delivered }
      return ⟨if PaymentModel.check facts then "verified" else "failed", "direct XRP accounting", some facts⟩
    | .token currency issuer units =>
      if issuer == sender || issuer == destination then return unsupported "token issuance/redemption"
      if t.changes.any (fun c => c.operation != "modify" || (c.entryType != 97 && c.entryType != 114)) then
        return unsupported "token transfer has conversion or object-lifecycle effects"
      require (t.changes.size == 3 && (t.changes.filter (·.entryType == 97)).size == 1) "simple token unexpected change set"
      let mut sendMax := units
      if hasField t.fields 0x609 then
        match ← fieldAmount t.fields 0x609 with
        | .token sc si value =>
          if sc != currency || si != issuer then return unsupported "different SendMax asset"
          sendMax := value
        | _ => return unsupported "cross-currency SendMax"
      let sourceLineKey ← lineKey sender issuer currency
      let destinationLineKey ← lineKey destination issuer currency
      let some sl := t.changes.find? (·.key == sourceLineKey) | throw <| IO.userError "sender trust-line change missing"
      let some dl := t.changes.find? (·.key == destinationLineKey) | throw <| IO.userError "destination trust-line change missing"
      let (sb, sa) ← modified sl
      let (db, da) ← modified dl
      let (sourceUnits, _) ← lineBalance sb sender issuer currency
      let (sourceAfterUnits, _) ← lineBalance sa sender issuer currency
      let (destinationUnits, _) ← lineBalance db destination issuer currency
      let (destinationAfterUnits, limit) ← lineBalance da destination issuer currency
      if sourceUnits - sourceAfterUnits != units then return unsupported "nonexact token debit/transfer fee or rounding"
      let facts := { common with
        kind := .token
        amount := units
        sendMax := sendMax
        sourceTokenBefore := sourceUnits
        sourceTokenAfter := sourceAfterUnits
        destinationTokenBefore := destinationUnits
        destinationTokenAfter := destinationAfterUnits
        destinationLimit := limit
        frameOK := common.frameOK && frameEqual sb sa [0x602, 0x505, 0x205] && frameEqual db da [0x602, 0x505, 0x205]
        historyOK := common.historyOK && (← stamped sa t.hash e.index) && (← stamped da t.hash e.index)
        deliveryOK := delivered }
      return ⟨if PaymentModel.check facts then "verified" else "failed", "same-issuer token accounting", some facts⟩
  catch err => return ⟨"failed", err.toString, none⟩

def factsJson (f : PaymentModel.Facts) : Json := Json.mkObj [
  ("kind", .str (match f.kind with | .xrp => "xrp" | .token => "token" | .feeOnly => "fee_only")),
  ("amount_units", .str (toString f.amount)), ("fee_drops", .str (toString f.fee)),
  ("xrp_delta", .str (toString (PaymentModel.xrpDelta f))),
  ("sequence_before", toJson f.sequenceBefore), ("sequence_after", toJson f.sequenceAfter),
  ("transaction_sequence", toJson f.transactionSequence),
  ("source_xrp_before", .str (toString f.sourceXrpBefore)), ("source_xrp_after", .str (toString f.sourceXrpAfter)),
  ("destination_xrp_before", .str (toString f.destinationXrpBefore)), ("destination_xrp_after", .str (toString f.destinationXrpAfter)),
  ("source_token_before", .str (toString f.sourceTokenBefore)), ("source_token_after", .str (toString f.sourceTokenAfter)),
  ("destination_token_before", .str (toString f.destinationTokenBefore)), ("destination_token_after", .str (toString f.destinationTokenAfter)),
  ("destination_token_limit", .str (toString f.destinationLimit)), ("send_max_units", .str (toString f.sendMax)),
  ("identity_matches", .bool f.identityOK), ("field_frame_matches", .bool f.frameOK),
  ("history_matches", .bool f.historyOK), ("delivery_matches", .bool f.deliveryOK)]

def verdictJson (e : Export) (t : Transaction) (v : Verdict) : Json := Json.mkObj [
  ("record_type", .str "payment_audit"), ("ledger_index", toJson e.index),
  ("transaction_index", toJson t.index), ("transaction_hash", .str (hex t.hash)),
  ("transaction_type", .str t.typeName), ("transaction_type_code", toJson t.typeCode),
  ("result", .str t.result), ("status", .str v.status), ("reason", .str v.reason),
  ("facts", v.facts.map factsJson |>.getD .null),
  ("proof_scope", .str "normalized exported accounting; parsing/native hashing trusted"),
  ("signature_verification", .str "not_checked"),
  ("reserve_and_authorization", .str "not_checked")]

/-- Kernel-checkable certificates are optional. Compilation is a separate,
explicit command; writing a file never reports it as kernel checked. -/
def proofSource (e : Export) (entries : Array (Transaction × Verdict)) : String := Id.run do
  let mut out := "import LeanXRPL.LedgerProofs\nopen LeanXRPL PaymentModel LedgerProofs\nset_option maxRecDepth 4096\nset_option maxHeartbeats 5000000\n\n"
  out := out ++ s!"-- Ledger {e.index}: {hex e.hash}\n-- Exact normalized facts; IOU unit = 10^-96.\n-- Does not authenticate blobs or prove unsupported transactions.\n"
  let mut names : List String := []
  for (t, v) in entries do
    if v.status == "verified" then
      if let some facts := v.facts then
        let name := s!"payment_{t.index}"
        names := names ++ [name]
        let literal := String.intercalate "\n" ((reprStr facts).splitOn "\n" |>.map ("  " ++ ·))
        out := out ++ s!"\n-- Transaction {hex t.hash}\ndef {name} : Facts :=\n{literal}\n"
        out := out ++ s!"theorem {name}_valid : Valid {name} := by decide\n"
        out := out ++ s!"theorem {name}_fee : xrpDelta {name} + {name}.fee = 0 := fee_accounting {name}_valid\n"
        out := out ++ s!"theorem {name}_sequence : {name}.sequenceAfter = {name}.transactionSequence + 1 := sequence_consumed {name}_valid\n"
        if facts.kind == .token then
          out := out ++ s!"theorem {name}_tokens : {name}.sourceTokenAfter + {name}.destinationTokenAfter = {name}.sourceTokenBefore + {name}.destinationTokenBefore := token_conservation {name}_valid (by rfl)\n"
          out := out ++ s!"theorem {name}_no_overdraft : 0 ≤ {name}.sourceTokenAfter := token_no_overdraft {name}_valid (by rfl)\n"
  out := out ++ s!"\ndef supportedPayments : List Facts := [{String.intercalate ", " names}]\n"
  out := out ++ "theorem supported_valid : ∀ f ∈ supportedPayments, Valid f := by\n  intro f h\n"
  if names.isEmpty then out := out ++ "  simp [supportedPayments] at h\n"
  else
    out := out ++ "  simp only [supportedPayments, List.mem_cons, List.not_mem_nil, or_false] at h\n"
    if names.length == 1 then out := out ++ s!"  subst f; exact {names[0]!}_valid\n"
    else
      out := out ++ "  rcases h with " ++ String.intercalate " | " (names.map (fun _ => "h")) ++ "\n"
      for name in names do out := out ++ s!"  · subst f; exact {name}_valid\n"
  out := out ++ "theorem supported_xrp_accounting : (supportedPayments.map xrpDelta).sum + (supportedPayments.map (·.fee)).sum = 0 := payment_accounting supportedPayments supported_valid\n"
  return out

end LeanXRPL.PaymentAudit
