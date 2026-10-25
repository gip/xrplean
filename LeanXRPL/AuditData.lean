import LeanXRPL.Signature
import LeanXRPL.StateTree
import LeanXRPL.PaymentModel

namespace LeanXRPL.AuditData
open Lean

def string (j : Json) (key : String) : IO String := IO.ofExcept ((j.getObjVal? key).bind Json.getStr?)
def nat (j : Json) (key : String) : IO Nat := IO.ofExcept ((j.getObjVal? key).bind Json.getNat?)
def array (j : Json) (key : String) : IO (Array Json) := IO.ofExcept ((j.getObjVal? key).bind Json.getArr?)
def has (j : Json) (key : String) : Bool := (j.getObjVal? key).isOk
def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

def hashBytes (s : String) : IO ByteArray := do
  let b ← IO.ofExcept (unhex s)
  require (b.size == 32) "hash must be 32 bytes"
  return b

def accountBytes (s : String) : IO ByteArray := do
  let b ← base58CheckDecode 0 s
  require (b.size == 20) "account must be 20 bytes"
  return b

def currencyBytes (s : String) : IO ByteArray := do
  let b ← if s.utf8ByteSize == 3 then
    pure (ByteArray.mk (Array.replicate 12 0) ++ s.toUTF8 ++ ByteArray.mk (Array.replicate 5 0))
    else IO.ofExcept (unhex s)
  require (b.size == 20 && !b.data.all (· == 0)) "invalid token currency"
  return b

/-- Exact decimal to integer units of 10^-96. No floating point, rounding, or
unbounded exponentiation from user input. -/
def decimalUnits (s : String) : Except String Int := do
  if s.isEmpty || s.utf8ByteSize > 256 then throw "invalid decimal length"
  let pieces := s.toLower.splitOn "e"
  if pieces.length > 2 then throw "invalid decimal exponent"
  let exponent ← if pieces.length == 2 then do
    let text := pieces[1]!
    let text := if text.startsWith "+" then text.drop 1 |>.toString else text
    let some exponent := text.toInt? | throw "invalid decimal exponent"
    if exponent < -200 || exponent > 200 then throw "decimal exponent out of range"
    pure exponent
    else pure 0
  let text := pieces[0]!
  let negative := text.startsWith "-"
  let text := if negative then text.drop 1 |>.toString else text
  let digits := text.splitOn "."
  if digits.length > 2 || digits[0]!.isEmpty then throw "invalid decimal"
  if digits.length == 2 && digits[1]!.isEmpty then throw "invalid fractional part"
  let coefficientText := String.intercalate "" digits
  if coefficientText.toList.any (fun c => c < '0' || c > '9') then throw "invalid decimal digit"
  let some coefficient := coefficientText.toNat? | throw "invalid decimal coefficient"
  let scale : Int := exponent + 96 - Int.ofNat (if digits.length == 2 then digits[1]!.length else 0)
  let magnitude ← if scale ≥ 0 then pure (coefficient * 10^scale.toNat)
    else do
      let divisor := 10^(-scale).toNat
      if coefficient % divisor != 0 then throw "decimal is not exactly representable"
      pure (coefficient / divisor)
  return if negative then -Int.ofNat magnitude else Int.ofNat magnitude

inductive Amount where
  | xrp (drops : Int)
  | token (currency issuer : ByteArray) (units : Int)
  deriving BEq

def decodeAmount (b : ByteArray) : Except String Amount := do
  if b.size != 8 && b.size != 48 then throw "unsupported amount (including MPT)"
  let head := bytesNat (b.extract 0 8)
  if b.size == 8 then
    if head ≥ 2^63 || head / 2^61 % 2 != 0 then throw "invalid native amount tag"
    let magnitude := head % 2^62
    if magnitude > 100000000000000000 || (magnitude == 0 && head != 2^62) then
      throw "noncanonical native amount"
    return .xrp (if head / 2^62 % 2 == 0 then -Int.ofNat magnitude else Int.ofNat magnitude)
  if head < 2^63 then throw "invalid issued amount tag"
  let magnitude := head % 2^54
  let exponent : Int := Int.ofNat (head / 2^54 % 256) - 97
  if magnitude == 0 then
    if head != 2^63 then throw "noncanonical issued zero"
  else if magnitude < 10^15 || magnitude > 10^16-1 || exponent < -96 || exponent > 80 then
    throw "noncanonical issued amount"
  let units := Int.ofNat (magnitude * 10^(exponent+96).toNat)
  return .token (b.extract 8 28) (b.extract 28 48)
    (if head / 2^62 % 2 == 0 then -units else units)

def jsonAmount (j : Json) : IO Amount := do
  match j with
  | .str text =>
    let some n := text.toInt? | throw <| IO.userError "invalid XRP amount"
    return .xrp n
  | .obj _ =>
    return .token (← currencyBytes (← string j "currency"))
      (← accountBytes (← string j "issuer")) (← IO.ofExcept (decimalUnits (← string j "value")))
  | _ => throw <| IO.userError "invalid amount JSON"

def field (fs : Array SignatureField) (code : Nat) : IO ByteArray := IO.ofExcept (signatureValue fs code)
def fieldNat (fs : Array SignatureField) (code : Nat) : IO Nat := return bytesNat (← field fs code)
def hasField (fs : Array SignatureField) (code : Nat) : Bool := fs.any (·.code == code)
def fieldAmount (fs : Array SignatureField) (code : Nat) : IO Amount :=
  return ← IO.ofExcept (decodeAmount (← field fs code))

/-- JSON comparisons cover every financial/identity field used by the model.
Unknown fields remain opaque and are compared byte-for-byte in field frames. -/
def checkProjection (j : Json) (fs : Array SignatureField) : IO Unit := do
  for (key, code) in [("Flags", 0x202), ("Sequence", 0x204), ("PreviousTxnLgrSeq", 0x205),
      ("OwnerCount", 0x20d), ("TransactionIndex", 0x21c), ("LastLedgerSequence", 0x21b),
      ("TicketSequence", 0x229)] do
    if has j key then require ((← nat j key) == (← fieldNat fs code)) s!"JSON/blob mismatch: {key}"
  for (key, code) in [("Account", 0x801), ("Destination", 0x803)] do
    if has j key then require ((← accountBytes (← string j key)) == (← field fs code)) s!"JSON/blob mismatch: {key}"
  for (key, code) in [("PreviousTxnID", 0x505)] do
    if has j key then require ((← hashBytes (← string j key)) == (← field fs code)) s!"JSON/blob mismatch: {key}"
  for (key, code) in [("Balance", 0x602), ("Amount", 0x601), ("Fee", 0x608), ("SendMax", 0x609),
      ("DeliverMin", 0x60a), ("LowLimit", 0x606), ("HighLimit", 0x607), ("DeliveredAmount", 0x612)] do
    if has j key then
      require ((← jsonAmount (← IO.ofExcept (j.getObjVal? key))) == (← fieldAmount fs code)) s!"JSON/blob mismatch: {key}"
  for (key, code) in [("LowNode", 0x307), ("HighNode", 0x308)] do
    if has j key then
      let text ← string j key
      require (!text.isEmpty && text.length ≤ 16) "invalid UInt64 hexadecimal"
      let padded := String.ofList (List.replicate (16-text.length) '0') ++ text
      let b ← IO.ofExcept (unhex padded)
      require (bytesNat b == (← fieldNat fs code)) s!"JSON/blob mismatch: {key}"

structure Image where
  raw : ByteArray
  json : Json
  fields : Array SignatureField
  deriving Inhabited

structure Change where
  key : ByteArray
  operation : String
  entryType : Nat
  before : Option Image
  after : Option Image
  deriving Inhabited

def decodeImage (j : Json) (key : ByteArray) (entryType : Nat) : IO Image := do
  let raw ← IO.ofExcept (unhex (← string j "blob"))
  let fields ← IO.ofExcept (parseSignatureFields raw)
  require ((← fieldNat fields 0x101) == entryType) "state entry type mismatch"
  let json ← IO.ofExcept (j.getObjVal? "json")
  require ((← hashBytes (← string json "index")) == key) "state JSON key mismatch"
  -- Only supported account/trust-line projections are interpreted financially.
  if entryType == 97 || entryType == 114 then
    require ((← string json "LedgerEntryType") == (if entryType == 97 then "AccountRoot" else "RippleState")) "state JSON type mismatch"
    checkProjection json fields
  return ⟨raw, json, fields⟩

def decodeChange (j : Json) : IO Change := do
  let key ← hashBytes (← string j "key")
  let entryType ← nat j "entry_type"
  let exportedOperation ← string j "operation"
  let operation := if exportedOperation == "insert" then "create" else exportedOperation
  let before ← if has j "before" then do
    let value ← IO.ofExcept (j.getObjVal? "before")
    if value == .null then pure none else pure (some (← decodeImage value key entryType))
    else pure none
  let after ← if has j "after" then do
    let value ← IO.ofExcept (j.getObjVal? "after")
    if value == .null then pure none else pure (some (← decodeImage value key entryType))
    else pure none
  require ((operation == "create" && before.isNone && after.isSome) ||
    (operation == "modify" && before.isSome && after.isSome) ||
    (operation == "delete" && before.isSome && after.isNone)) "invalid change operation/images"
  return ⟨key, operation, entryType, before, after⟩

def Change.treeChange (c : Change) : IO StateTree.Change := do
  return ⟨← IO.ofExcept (StateTree.ObjectID.ofBytes c.key), c.before.map (·.raw), c.after.map (·.raw)⟩

def frameEqual (before after : Image) (allowed : List Nat) : Bool :=
  let fields := fun (fs : Array SignatureField) =>
    fs.toList.map (fun f => (f.code, f.value.data.toList))
  PaymentModel.checkFrame (fields before.fields) (fields after.fields) allowed

def stamped (after : Image) (hash : ByteArray) (ledger : Nat) : IO Bool :=
  return (← field after.fields 0x505) == hash && (← fieldNat after.fields 0x205) == ledger

end LeanXRPL.AuditData
