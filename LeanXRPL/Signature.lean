import LeanXRPL.Trust
import LeanXRPL.SignatureFields

namespace LeanXRPL
open Lean

structure SignatureField where
  code : Nat
  value : ByteArray
  encoded : ByteArray
  deriving Inhabited

def signatureFieldID (typ field : Nat) : ByteArray :=
  let head := byteArray [((if typ < 16 then typ else 0)*16 + (if field < 16 then field else 0)).toUInt8]
  let head := if typ < 16 then head else head.push typ.toUInt8
  if field < 16 then head else head.push field.toUInt8

private def skipIssue (c : Cursor) : ParseResult Cursor := do
  let (currency, c) ← c.take 20
  if currency.data.all (· == 0) then return c
  let (issuer, c) ← c.take 20
  if issuer == uintBytes 1 20 then return (← c.take 4).2
  return c

mutual
  /-- Unlike basic field decoding, signature serialization supports every pinned binary type.
  Nesting, work, field IDs and ordering are checked even in omitted signing objects. -/
  private def parseSignatureContainer (depth : Nat) (start : Cursor)
      (endCode : Option Nat) (arrayMode : Bool) : ParseResult (Array SignatureField × Cursor) := do
    match depth with
    | 0 => throw "signature nesting limit"
    | depth+1 =>
      let mut c := start
      let mut out := #[]
      let mut previous := 0
      for _ in [:min (start.remaining+1) 65537] do
        if c.remaining == 0 then
          if endCode.isSome then throw "unterminated signature container"
          return (out, c)
        let (typ, field, next) ← readFieldID c
        if c.bytes.extract c.pos next.pos != signatureFieldID typ field then
          throw "noncanonical signature field ID"
        let code := typ*256+field
        if endCode == some code then return (out, next)
        if typ == 14 && field == 1 || typ == 15 && field == 1 then
          throw "unexpected signature end marker"
        if !signatureFieldCodes.contains code then throw s!"unsupported signature field {typ}/{field}"
        if arrayMode then
          if typ != 14 then throw "signature array member is not an object"
        else if code ≤ previous then throw "noncanonical/duplicate signature field order"
        if out.size ≥ 65536 then throw "signature field limit"
        let finish ← skipSignatureValue depth typ next
        let value ← if typ == 7 || typ == 8 || typ == 19 then pure (← readVL next).1
          else pure (c.bytes.extract next.pos finish.pos)
        if typ == 8 && value.size != 0 && value.size != 20 then throw "invalid signature AccountID length"
        if typ == 19 && value.size % 32 != 0 then throw "invalid signature Vector256 length"
        out := out.push ⟨code, value, c.bytes.extract c.pos finish.pos⟩
        previous := code
        c := finish
      throw "signature parser work limit"

  private def skipSignatureValue (depth typ : Nat) (c : Cursor) : ParseResult Cursor := do
    if typ == 14 || typ == 15 then
      return (← parseSignatureContainer depth c (some (typ*256+1)) (typ == 15)).2
    if typ == 6 then
      let (head, _) ← c.uint 8
      return (← c.take (if head ≥ 2^63 then 48 else if head / 2^61 % 2 == 1 then 33 else 8)).2
    if typ == 24 then return ← skipIssue c
    if typ == 25 then
      let (door, c) ← readVL c
      if door.size != 20 then throw "invalid bridge door AccountID"
      let c ← skipIssue c
      let (door, c) ← readVL c
      if door.size != 20 then throw "invalid bridge door AccountID"
      skipIssue c
    else skipValue 32 typ c
end

def parseSignatureFields (raw : ByteArray) : ParseResult (Array SignatureField) := do
  if raw.size > 1048576 then throw "transaction signature byte limit"
  return (← parseSignatureContainer 32 ⟨raw, 0, by omega⟩ none false).1

def signatureObjects (field : SignatureField) : ParseResult (Array SignatureField) := do
  let typ := field.code/256
  if typ != 14 && typ != 15 then throw "expected signature object/array"
  let (fields, endCursor) ← parseSignatureContainer 32 ⟨field.value, 0, by omega⟩ (some (typ*256+1)) (typ == 15)
  if endCursor.remaining != 0 then throw "trailing signature container bytes"
  return fields

def signatureValue (fs : Array SignatureField) (code : Nat) : ParseResult ByteArray :=
  match fs.find? (·.code == code) with
  | some f => .ok f.value
  | none => .error s!"missing signature field {code/256}/{code%256}"

def transactionSigningBytes (fs : Array SignatureField) (domain : String) : ByteArray :=
  fs.foldl (fun b f => if nonSigningFieldCodes.contains f.code then b else b ++ f.encoded) (hashPrefix domain)

private def fieldNat (fs : Array SignatureField) (code : Nat) (default := 0) : Nat :=
  (signatureValue fs code).toOption.map bytesNat |>.getD default

private def accountValue (fs : Array SignatureField) (code := 0x801) : ParseResult ByteArray := do
  let account ← signatureValue fs code
  if account.size != 20 then throw "signature account must contain 20 bytes"
  return account

private def hasField (fs : Array SignatureField) (code : Nat) : Bool := fs.any (·.code == code)

private def scalarCanonical (sig : ByteArray) : Bool := Id.run do
  if sig.size != 64 then return false
  let order := uintBytes 7237005577332262213973186563042994240857116359379907606001950938285454250989 32
  for i in [:32] do
    let a := sig[63-i]!
    let b := order[i]!
    if a < b then return true
    if a > b then return false
  return false

/-- xrpld 3.4.1 requires fully canonical (low-S) transaction ECDSA signatures,
including when tfFullyCanonicalSig is absent. Ed25519 signs the original message. -/
def verifyTransactionMessage (key message signature : ByteArray) : IO Bool := do
  if !validPublicKey key then return false
  if key[0]! == 0xed then
    if !scalarCanonical signature then return false
    Native.edVerify (key.extract 1 33) message signature
  else Native.verifyCanonical key (← Native.sha512Half message) signature true

structure CheckedTransactionSignature where
  role : String
  account : Option ByteArray
  publicKey : ByteArray
  signature : ByteArray
  domain : String
  deriving Inhabited

structure TransactionSignatureVerification where
  status : String := "verified"
  mode : String := "single"
  signatures : Array CheckedTransactionSignature := #[]
  parentBatch : Option ByteArray := none
  error : Option String := none
  deriving Inhabited

def TransactionSignatureVerification.toJson (v : TransactionSignatureVerification) : IO Json := do
  let checks ← v.signatures.mapM fun s => do
    let account ← s.account.mapM (base58CheckEncode 0)
    return Json.mkObj [("role", .str s.role), ("account", Lean.toJson account),
      ("public_key", .str (hex s.publicKey)), ("algorithm", .str (if s.publicKey[0]! == 0xed then "ed25519" else "secp256k1")),
      ("signature_hex", .str (hex s.signature)), ("signing_prefix", .str (s.domain ++ "\\0")), ("verified", .bool true)]
  return Json.mkObj [("status", .str v.status), ("mode", .str v.mode), ("signatures", Lean.toJson checks),
    ("parent_batch_hash", Lean.toJson (v.parentBatch.map hex)), ("error", Lean.toJson v.error),
    ("account_authorization", .str "not_checked"), ("signer_list_quorum", .str "not_checked"),
    ("amendment_rules", .str "not_checked")]

private def checkedSignature (role : String) (account : Option ByteArray)
    (fs : Array SignatureField) (messages : Array (String × ByteArray)) : IO CheckedTransactionSignature := do
  let key ← IO.ofExcept (signatureValue fs 0x703)
  let signature ← IO.ofExcept (signatureValue fs 0x704)
  for (domain, message) in messages do
    if ← verifyTransactionMessage key message signature then return ⟨role, account, key, signature, domain⟩
  throw <| IO.userError s!"invalid {role} transaction signature"

private def checkSignatureSet (role : String) (fs : Array SignatureField)
    (owner : Option ByteArray) (messages : Array (String × ByteArray))
    (allowMissingKey := false) : IO (Array CheckedTransactionSignature × String) := do
  let key ← if allowMissingKey then pure ((signatureValue fs 0x703).toOption.getD ByteArray.empty)
    else IO.ofExcept (signatureValue fs 0x703)
  if !key.isEmpty then
    if hasField fs 0xf03 then throw <| IO.userError "cannot both single- and multi-sign"
    return (#[← checkedSignature role owner fs messages], "single")
  if hasField fs 0x704 then throw <| IO.userError "multisigned transaction contains TxnSignature"
  let some signers := fs.find? (·.code == 0xf03) | throw <| IO.userError "empty SigningPubKey without Signers"
  let objects ← IO.ofExcept (signatureObjects signers)
  if objects.isEmpty || objects.size > 32 then throw <| IO.userError "multisigner count must be 1..32"
  let mut last := uintBytes 0 20
  let mut signers := #[]
  for object in objects do
    if object.code != 0xe10 then throw <| IO.userError "Signers array entry must be Signer"
    let fields ← IO.ofExcept (signatureObjects object)
    if fields.size != 3 || fields.any (fun f => f.code != 0x703 && f.code != 0x704 && f.code != 0x801) then
      throw <| IO.userError "invalid multisigner fields"
    let account ← IO.ofExcept (accountValue fields)
    if bytesNat account ≤ bytesNat last then throw <| IO.userError "duplicate/unsorted multisigner accounts"
    if owner == some account then throw <| IO.userError "initiator cannot multisign for itself"
    let key ← IO.ofExcept (signatureValue fields 0x703)
    if key.isEmpty then throw <| IO.userError "empty multisigner public key"
    signers := signers.push (account, fields)
    last := account
  -- All members of one multisigner set must use the same signing domain.
  for (domain, message) in messages do
    let mut checks := #[]
    let mut valid := true
    for (account, fields) in signers do
      try
        checks := checks.push (← checkedSignature role (some account) fields #[(domain, message ++ account)])
      catch _ => valid := false; break
    if valid then return (checks, "multi")
  throw <| IO.userError s!"invalid {role} multisignature set"

private def unsignedInner (fs : Array SignatureField) : ParseResult Unit := do
  if (← signatureValue fs 0x703).size != 0 || hasField fs 0x704 || hasField fs 0xf03 then
    throw "inner Batch transaction must be unsigned"
  for code in [0xe25, 0xe26] do
    if let some field := fs.find? (·.code == code) then
      let inner ← signatureObjects field
      if (signatureValue inner 0x703).toOption.any (·.size != 0) || hasField inner 0x704 || hasField inner 0xf03 then
        throw "inner Batch role must be unsigned"

def batchInnerBytes (fs : Array SignatureField) : ParseResult (Array ByteArray) := do
  let some raws := fs.find? (·.code == 0xf1e) | throw "Batch omitted RawTransactions"
  let objects ← signatureObjects raws
  if objects.size < 2 || objects.size > 8 then throw "Batch inner count must be 2..8"
  let mut out := #[]
  for object in objects do
    if object.code != 0xe22 then throw "Batch entry must be RawTransaction"
    let inner ← signatureObjects object
    if fieldNat inner 0x102 == 71 || fieldNat inner 0x202 / 2^30 % 2 != 1 then
      throw "invalid nested Batch/inner flag"
    unsignedInner inner
    -- The object delimiter is not part of the standalone transaction hash.
    out := out.push (object.value.extract 0 (object.value.size-1))
  return out

private def verifySignedFields (fs : Array SignatureField) : IO TransactionSignatureVerification := do
  let account ← IO.ofExcept (accountValue fs)
  let initiator := (signatureValue fs 0x80c).toOption.getD account -- sfDelegate
  let multi := (signatureValue fs 0x703).toOption.any (·.isEmpty)
  let (checks, mode) ← checkSignatureSet "transaction" fs (some initiator)
    #[(if multi then "SMT" else "STX", transactionSigningBytes fs (if multi then "SMT" else "STX"))]
  let mut checks := checks
  for (code, role, singlePrefix, multiPrefix) in [(0xe25, "counterparty", "CPT", "CPM"), (0xe26, "sponsor", "SPN", "SPM")] do
    if let some field := fs.find? (·.code == code) then
      let fields ← IO.ofExcept (signatureObjects field)
      if fields.any (fun f => f.code != 0x703 && f.code != 0x704 && f.code != 0xf03) then
        throw <| IO.userError "invalid transaction role signature fields"
      let multi := ((signatureValue fields 0x703).toOption.getD ByteArray.empty).isEmpty
      let domain := if multi then multiPrefix else singlePrefix
      let legacy := if multi then "SMT" else "STX"
      -- Account-state amendment rules are outside this client. Both published
      -- domains are checked, and the exact matching domain is preserved as evidence.
      let (extra, _) ← checkSignatureSet role fields none
        #[(domain, transactionSigningBytes fs domain), (legacy, transactionSigningBytes fs legacy)] true
      checks := checks ++ extra
  if fieldNat fs 0x102 == 71 then
    let raws ← IO.ofExcept (batchInnerBytes fs)
    let mut ids := #[]
    for raw in raws do
      let id ← Native.sha512Half (hashPrefix "TXN" ++ raw)
      if ids.contains id then throw <| IO.userError "duplicate inner Batch transaction"
      ids := ids.push id
    if let some signers := fs.find? (·.code == 0xf1f) then
      let objects ← IO.ofExcept (signatureObjects signers)
      if objects.size > 24 then throw <| IO.userError "Batch signer count exceeds 24"
      let seq := fieldNat fs 0x229 (fieldNat fs 0x204) -- sfTicketSequence
      let base := ids.foldl (· ++ ·) (hashPrefix "BCH" ++ account ++ uintBytes seq 4 ++ uintBytes (fieldNat fs 0x202) 4 ++ uintBytes ids.size 4)
      let mut last := uintBytes 0 20
      for object in objects do
        if object.code != 0xe23 then throw <| IO.userError "BatchSigners entry must be BatchSigner"
        let fields ← IO.ofExcept (signatureObjects object)
        if fields.any (fun f => f.code != 0x801 && f.code != 0x703 && f.code != 0x704 && f.code != 0xf03) then
          throw <| IO.userError "invalid Batch signer fields"
        let signer ← IO.ofExcept (accountValue fields)
        if bytesNat signer ≤ bytesNat last || signer == account then throw <| IO.userError "duplicate/unsorted/outer Batch signer"
        let (extra, _) ← checkSignatureSet "batch" fields (some signer) #[("BCH", base ++ signer)] true
        checks := checks ++ extra
        last := signer
  else if hasField fs 0xf1f || hasField fs 0xf1e then throw <| IO.userError "Batch fields on non-Batch transaction"
  return { signatures := checks, mode }

/-- Pure-byte signature verification; account-state authorization is intentionally separate.
Unsigned Batch inner transactions require a verified parent from the same complete ledger. -/
def verifyTransactionSignatures (raw : ByteArray) : IO TransactionSignatureVerification := do
  try
    let fs ← IO.ofExcept (parseSignatureFields raw)
    let typ := fieldNat fs 0x102 65535
    if typ == 100 || typ == 101 || typ == 102 then
      let account ← IO.ofExcept (accountValue fs)
      if account.data.any (· != 0) || (← IO.ofExcept (signatureValue fs 0x703)).size != 0 ||
          (signatureValue fs 0x704).toOption.any (·.size != 0) || hasField fs 0xf03 ||
          hasField fs 0xe25 || hasField fs 0xe26 || hasField fs 0xf1f || fieldNat fs 0x204 != 0 ||
          (← IO.ofExcept (signatureValue fs 0x608)) != uintBytes (2^62) 8 then
        throw <| IO.userError "malformed unsigned system transaction"
      return { status := "not_applicable", mode := "system" }
    if fieldNat fs 0x202 / 2^30 % 2 == 1 then
      IO.ofExcept (unsignedInner fs)
      return { status := "requires_parent_batch", mode := "batch_inner" }
    verifySignedFields fs
  catch e =>
    return { status := if e.toString.startsWith "unsupported signature" then "unsupported" else "invalid", error := some e.toString }

end LeanXRPL
