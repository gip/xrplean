import LeanXRPL.Transaction

namespace LeanXRPL
open Lean

def foundationPublisher := "ED42AEC58B701EEBB77356FFFEC26F83C1F0407263530F068C7C73D392C7E06FD1"
def foundationHost := "unl.xrplf.org"
def hashPrefix (s : String) : ByteArray := s.toUTF8.push 0

structure SerializedField where
  typ : Nat
  field : Nat
  encoded : ByteArray
  value : ByteArray
  deriving Inhabited

/-- Authentication objects are small, canonical, and have explicitly allowed fields. -/
def parseSerialized (b : ByteArray) (allowed : Array Nat) : ParseResult (Array SerializedField) := do
  if b.size > 16384 then throw "authentication object too large"
  let mut c : Cursor := ⟨b, 0, by omega⟩
  let mut previous := 0
  let mut fields := #[]
  for _ in [:128] do
    if c.remaining == 0 then return fields
    let (typ, field, next) ← readFieldID c
    let code := typ*256+field
    if code ≤ previous || !allowed.contains code then throw "invalid authentication field/order"
    let finish ← skipValue 32 typ next
    let value ← if typ == 7 || typ == 19 then pure (← readVL next).1
      else pure (b.extract next.pos finish.pos)
    fields := fields.push ⟨typ, field, b.extract c.pos finish.pos, value⟩
    previous := code
    c := finish
  throw "authentication field limit"

def serializedValue (fs : Array SerializedField) (typ field : Nat) : ParseResult ByteArray :=
  match fs.find? (fun f => f.typ == typ && f.field == field) with
  | some f => .ok f.value
  | none => .error s!"missing authentication field {typ}/{field}"

def bytesNat (b : ByteArray) : Nat := b.data.foldl (fun n v => n*256+v.toNat) 0

def signingData (domain : String) (fs : Array SerializedField) : ByteArray :=
  fs.foldl (fun b f => if f.typ == 7 && (f.field == 6 || f.field == 18) then b else b ++ f.encoded)
    (hashPrefix domain)

def validPublicKey (b : ByteArray) : Bool :=
  b.size == 33 && (b[0]! == 2 || b[0]! == 3 || b[0]! == 0xed)

def verifyMessage (pub message signature : ByteArray) : IO Bool := do
  if !validPublicKey pub then return false
  if pub[0]! == 0xed then return ← Native.edVerify (pub.extract 1 33) message signature
  Native.verifyCanonical pub (← Native.sha512Half message) signature true

structure Manifest where
  master : ByteArray
  signing : Option ByteArray
  sequence : Nat
  raw : ByteArray
  deriving Inhabited, BEq

def verifyManifest (raw : ByteArray) : IO Manifest := do
  if raw.size > 1024 then throw <| IO.userError "manifest too large"
  let fs ← IO.ofExcept (parseSerialized raw #[0x110, 0x204, 0x701, 0x703, 0x706, 0x707, 0x712])
  let master ← IO.ofExcept (serializedValue fs 7 1)
  let sequence := bytesNat (← IO.ofExcept (serializedValue fs 2 4))
  if !validPublicKey master then throw <| IO.userError "invalid manifest master key"
  if let some version := fs.find? (fun f => f.typ == 1 && f.field == 16) then
    if bytesNat version.value != 0 then throw <| IO.userError "unsupported manifest version"
  let signing := (fs.find? (fun f => f.typ == 7 && f.field == 3)).map (·.value)
  let sig := (fs.find? (fun f => f.typ == 7 && f.field == 6)).map (·.value)
  let message := signingData "MAN" fs
  if sequence == 4294967295 then
    if signing.isSome || sig.isSome then throw <| IO.userError "invalid manifest revocation"
  else
    let some key := signing | throw <| IO.userError "manifest omitted signing key"
    let some signature := sig | throw <| IO.userError "manifest omitted signing signature"
    if key == master || !(← verifyMessage key message signature) then
      throw <| IO.userError "manifest signing signature failed"
  if !(← verifyMessage master message (← IO.ofExcept (serializedValue fs 7 18))) then
    throw <| IO.userError "manifest master signature failed"
  return ⟨master, signing, sequence, raw⟩

structure ValidatorTrust where
  publisher : Manifest
  sequence : Nat
  effective : Nat
  expiration : Nat
  validators : Array ByteArray
  manifests : Array Manifest
  document : String
  deriving Inhabited

/-- Conservative quorum: no Negative UNL reductions are applied. -/
def ValidatorTrust.quorum (t : ValidatorTrust) : Nat := (t.validators.size*4+4)/5
def ValidatorTrust.active (t : ValidatorTrust) (now : Nat) : Bool :=
  t.validators.size > 0 && t.effective ≤ now && now < t.expiration

def ValidatorTrust.signerMaster (t : ValidatorTrust) (signer : ByteArray) : Option ByteArray :=
  t.validators.find? fun master =>
    match t.manifests.find? (fun m => m.master == master) with
    | some m => m.signing == some signer
    | none => master == signer

def ValidatorTrust.applyManifest (t : ValidatorTrust) (m : Manifest) (retainHistorical := false) : ParseResult ValidatorTrust := do
  if !retainHistorical && !t.validators.contains m.master && !t.manifests.any (·.master == m.master) then return t
  if let some old := t.manifests.find? (fun old => old.master == m.master) then
    if m.sequence < old.sequence then return t
    if m.sequence == old.sequence then
      if m.signing != old.signing then throw "conflicting manifest sequence"
      return t
  if let some signing := m.signing then
    if t.manifests.any (fun old => old.master != m.master && old.signing == some signing) ||
        t.validators.any (fun key => key != m.master && key == signing) then
      throw "validator signing key collision"
  if !t.manifests.any (·.master == m.master) && t.manifests.size ≥ 1024 then
    throw "validator manifest history limit"
  return { t with manifests := (t.manifests.filter (·.master != m.master)).push m }

def ValidatorTrust.isSuccessor (new old : ValidatorTrust) : Bool :=
  new.sequence ≥ old.sequence && new.publisher.sequence ≥ old.publisher.sequence &&
    (new.publisher.sequence != old.publisher.sequence || new.publisher.signing == old.publisher.signing) &&
    (new.sequence != old.sequence || (new.expiration == old.expiration && new.effective == old.effective &&
      new.validators.size == old.validators.size && new.validators.all old.validators.contains))

private def jsonNat (j : Json) (name : String) : ParseResult Nat := do
  (← j.getObjVal? name).getNat?
private def jsonString (j : Json) (name : String) : ParseResult String := do
  (← j.getObjVal? name).getStr?
private def jsonArray (j : Json) (name : String) : ParseResult (Array Json) := do
  (← j.getObjVal? name).getArr?

def verifyValidatorList (document publisherHex : String) (now : Nat)
    (checkTime := true) : IO ValidatorTrust := do
  if document.utf8ByteSize > 1048576 then throw <| IO.userError "validator list too large"
  let root ← IO.ofExcept (Json.parse document)
  let pinned ← IO.ofExcept (unhex publisherHex)
  let publisher ← verifyManifest (← IO.ofExcept (base64Decode (← IO.ofExcept (jsonString root "manifest"))))
  if publisher.master != pinned then throw <| IO.userError "untrusted validator-list publisher"
  if publisher.signing.isNone then throw <| IO.userError "validator-list publisher revoked"
  let version ← IO.ofExcept (jsonNat root "version")
  let blobs ← if version == 1 then pure #[root] else if version == 2 then
    IO.ofExcept (jsonArray root "blobs_v2")
    else throw <| IO.userError "unsupported validator list version"
  if blobs.isEmpty || blobs.size > 16 then throw <| IO.userError "invalid validator list collection"
  let mut best : Option ValidatorTrust := none
  for entry in blobs do
    let pub ← match entry.getObjVal? "manifest" with
      | .ok value => verifyManifest (← IO.ofExcept (base64Decode (← IO.ofExcept value.getStr?)))
      | .error _ => pure publisher
    if pub.master != pinned then throw <| IO.userError "untrusted list manifest"
    if pub.signing.isNone then throw <| IO.userError "validator-list publisher revoked"
    let blob ← IO.ofExcept (base64Decode (← IO.ofExcept (jsonString entry "blob")))
    let signature ← IO.ofExcept (unhex (← IO.ofExcept (jsonString entry "signature")))
    if !(← verifyMessage pub.signing.get! blob signature) then throw <| IO.userError "validator list signature failed"
    let some text := String.fromUTF8? blob | throw <| IO.userError "invalid list text"
    let list ← IO.ofExcept (Json.parse text)
    let sequence ← IO.ofExcept (jsonNat list "sequence")
    let expiration ← IO.ofExcept (jsonNat list "expiration")
    let effective := (jsonNat list "effective").toOption.getD 0
    if sequence > 4294967295 || expiration > 4294967295 || expiration ≤ effective then
      throw <| IO.userError "invalid list time/sequence"
    let entries ← IO.ofExcept (jsonArray list "validators")
    if entries.isEmpty || entries.size > 256 then throw <| IO.userError "invalid validator list size"
    let mut trust : ValidatorTrust := ⟨pub, sequence, effective, expiration, #[], #[], document⟩
    for validator in entries do
      let key ← IO.ofExcept (unhex (← IO.ofExcept (jsonString validator "validation_public_key")))
      if !validPublicKey key || trust.validators.contains key then throw <| IO.userError "invalid/duplicate validator"
      trust := { trust with validators := trust.validators.push key }
      if let .ok manifest := jsonString validator "manifest" then
        let m ← verifyManifest (← IO.ofExcept (base64Decode manifest))
        if m.master != key then throw <| IO.userError "list validator manifest mismatch"
        trust ← IO.ofExcept (trust.applyManifest m)
    if trust.manifests.any (fun m => m.signing.any (fun signer =>
        trust.validators.any (fun master => master != m.master && master == signer))) then
      throw <| IO.userError "validator signing key collides with another master"
    if effective ≤ now && (!checkTime || now < expiration) then
      if best.isNone || sequence > best.get!.sequence then best := some trust
  let some trust := best | throw <| IO.userError "no currently valid validator list"
  return trust

structure VerifiedValidation where
  master : ByteArray
  signer : ByteArray
  ledgerHash : ByteArray
  ledgerSequence : Nat
  signingTime : Nat
  raw : ByteArray
  deriving Inhabited

def verifyValidation (trust : ValidatorTrust) (raw : ByteArray) (now : Nat) : IO VerifiedValidation := do
  if !trust.active now then throw <| IO.userError "validator trust expired/not effective"
  let fs ← IO.ofExcept (parseSerialized raw #[0x202, 0x206, 0x207, 0x209, 0x218, 0x21f, 0x220,
    0x305, 0x30a, 0x30b, 0x501, 0x517, 0x519, 0x616, 0x617, 0x618, 0x703, 0x706, 0x1303])
  let signer ← IO.ofExcept (serializedValue fs 7 3)
  let some master := trust.signerMaster signer | throw <| IO.userError "untrusted validation signer"
  if signer.size != 33 || (signer[0]! != 2 && signer[0]! != 3) then
    throw <| IO.userError "validations require secp256k1 signing keys"
  let flags := bytesNat (← IO.ofExcept (serializedValue fs 2 2))
  if flags % 2 != 1 then throw <| IO.userError "partial validation does not vote"
  let sequence := bytesNat (← IO.ofExcept (serializedValue fs 2 6))
  let signingTime := bytesNat (← IO.ofExcept (serializedValue fs 2 9))
  if sequence == 0 || signingTime+180 ≤ now || now+300 ≤ signingTime then
    throw <| IO.userError "stale/future validation"
  let ledgerHash ← IO.ofExcept (serializedValue fs 5 1)
  if ledgerHash.data.all (· == 0) then throw <| IO.userError "zero validated hash"
  let digest ← Native.sha512Half (signingData "VAL" fs)
  if !(← Native.verifyCanonical signer digest (← IO.ofExcept (serializedValue fs 7 6)) (flags / 2^31 % 2 == 1)) then
    throw <| IO.userError "validation signature failed"
  return ⟨master, signer, ledgerHash, sequence, signingTime, raw⟩

end LeanXRPL
