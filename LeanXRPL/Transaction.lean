import Lean.Data.Json
import Std.Time
import LeanXRPL.Encoding
import LeanXRPL.Protocol

namespace LeanXRPL
open Lean

def readFieldID (c : Cursor) : ParseResult (Nat × Nat × Cursor) := do
  let (b, c) ← c.byte
  let (typ, c) ← if b.toNat/16 == 0 then c.uint 1 else pure (b.toNat/16, c)
  let (field, c) ← if b.toNat%16 == 0 then c.uint 1 else pure (b.toNat%16, c)
  if typ == 0 || field == 0 then throw "invalid XRPL field ID"
  return (typ, field, c)

def readVL (c : Cursor) : ParseResult (ByteArray × Cursor) := do
  let (a, c) ← c.uint 1
  let (len, c) ← if a ≤ 192 then pure (a, c)
    else if a ≤ 240 then do
      let (b, c) ← c.uint 1
      pure (193 + (a-193)*256 + b, c)
    else if a ≤ 254 then do
      let (b, c) ← c.uint 1
      let (d, c) ← c.uint 1
      pure (12481 + (a-241)*65536 + b*256 + d, c)
    else throw "invalid XRPL variable length prefix"
  if len > 918744 then throw "XRPL variable length exceeds serializer limit"
  c.take len

def encodeVL (b : ByteArray) : ParseResult ByteArray := do
  let n := b.size
  let tag ← if n ≤ 192 then pure (uintBytes n 1)
    else if n ≤ 12480 then pure (byteArray [(193+(n-193)/256).toUInt8, ((n-193)%256).toUInt8])
    else if n ≤ 918744 then pure (byteArray [(241+(n-12481)/65536).toUInt8, ((n-12481)/256%256).toUInt8, ((n-12481)%256).toUInt8])
    else throw "XRPL VL size limit"
  return tag ++ b

/-- Bounded nesting. Unsupported layouts stop parsing without guessing a length. -/
def skipValue (depth : Nat) (typ : Nat) (c : Cursor) : ParseResult Cursor := do
  match depth with
  | 0 => throw "XRPL nesting limit reached"
  | depth+1 =>
    let width := match typ with
      | 1 => 2 | 2 => 4 | 3 => 8 | 4 => 16 | 5 => 32 | 9 => 12
      | 10 => 4 | 11 => 8 | 16 => 1 | 17 => 20 | 20 => 12
      | 21 => 24 | 22 => 48 | 23 => 64 | 26 => 20 | _ => 0
    if width > 0 then return (← c.take width).2
    if typ == 7 || typ == 8 || typ == 19 then return (← readVL c).2
    if typ == 6 then
      let (head, _) ← c.uint 8
      if head ≥ 2^63 then return (← c.take 48).2
      if head / 2^61 % 2 == 1 then throw "unsupported MPT amount"
      return (← c.take 8).2
    if typ == 14 || typ == 15 then
      let mut cur := c
      for _ in [:c.remaining] do
        let (t, f, next) ← readFieldID cur
        if t == typ && f == 1 then return next
        if t == 14 && f == 1 || t == 15 && f == 1 then throw "unexpected nested end marker"
        if typ == 15 && t != 14 then throw "array member is not an object"
        cur ← skipValue depth t next
      throw "unterminated nested XRPL value"
    if typ == 18 then
      let mut cur := c
      for _ in [:c.remaining] do
        let (flag, next) ← cur.uint 1
        cur := next
        if flag == 0 then return cur
        if flag != 255 then
          if flag == 0 || flag &&& 0xCE != 0 then throw "invalid path element"
          let n := (if flag &&& 1 != 0 then 20 else 0) +
            (if flag &&& 16 != 0 then 20 else 0) + (if flag &&& 32 != 0 then 20 else 0)
          cur := (← cur.take n).2
      throw "unterminated path set"
    throw s!"unsupported XRPL serialized type {typ}"

def transactionTypeName (n : Nat) : Option String :=
  match n with
  | 0 => some "Payment" | 1 => some "EscrowCreate" | 2 => some "EscrowFinish"
  | 3 => some "AccountSet" | 4 => some "EscrowCancel" | 5 => some "SetRegularKey"
  | 7 => some "OfferCreate" | 8 => some "OfferCancel" | 10 => some "TicketCreate"
  | 12 => some "SignerListSet" | 13 => some "PaymentChannelCreate"
  | 14 => some "PaymentChannelFund" | 15 => some "PaymentChannelClaim"
  | 16 => some "CheckCreate" | 17 => some "CheckCash" | 18 => some "CheckCancel"
  | 19 => some "DepositPreauth" | 20 => some "TrustSet" | 21 => some "AccountDelete"
  | 25 => some "NFTokenMint" | 26 => some "NFTokenBurn" | 27 => some "NFTokenCreateOffer"
  | 28 => some "NFTokenCancelOffer" | 29 => some "NFTokenAcceptOffer" | _ => none

private def amountJSON (b : ByteArray) : IO Json := do
  let n := b.data[:8].toArray.foldl (fun n v => n*256+v.toNat) 0
  if b.size == 8 then
    let value := n % 2^62
    return Json.str ((if value != 0 && n/2^62%2 == 0 then "-" else "") ++ toString value)
  let currency := b.extract 8 28
  let standard := (currency.extract 0 12).data.all (· == 0) &&
    (currency.extract 15 20).data.all (· == 0) &&
    (currency.extract 12 15).data.all (fun v => v.toNat ≥ 33 && v.toNat ≤ 126)
  let currencyStr := if standard then String.fromUTF8! (currency.extract 12 15) else hex currency
  let mantissa := n % 2^54
  let exponent : Int := Int.ofNat (n/2^54%256) - 97
  let value := if mantissa == 0 then "0" else
    (if n/2^62%2 == 0 then "-" else "") ++ s!"{mantissa}e{exponent}"
  return Json.mkObj [("currency", .str currencyStr),
    ("issuer", .str (← base58CheckEncode 0 (b.extract 28 48))), ("value", .str value)]

structure DecodedTransaction where
  fields : List (String × Json) := []
  error : Option String := none
  deriving Inhabited

def decodeFields (b : ByteArray) : IO DecodedTransaction := do
  let mut c : Cursor := ⟨b, 0, by omega⟩
  let mut out : List (String × Json) := []
  let mut previous := 0
  for _ in [:b.size] do
    if c.remaining == 0 then return ⟨out.reverse, none⟩
    match readFieldID c with
    | .error e => return ⟨out.reverse, some e⟩
    | .ok (typ, field, next) =>
      let code := typ*256+field
      if code ≤ previous then return ⟨out.reverse, some "noncanonical or duplicate field order"⟩
      previous := code
      match skipValue 32 typ next with
      | .error e => return ⟨out.reverse, some e⟩
      | .ok finish =>
        let raw := b.extract next.pos finish.pos
        if typ == 1 && field == 2 then
          let n := raw.data.foldl (fun n v => n*256+v.toNat) 0
          out := ("TransactionTypeCode", toJson n) :: out
          if let some name := transactionTypeName n then out := ("TransactionType", .str name) :: out
        else if typ == 2 && (field == 2 || field == 4) then
          let name := if field == 2 then "Flags" else "Sequence"
          out := (name, toJson (raw.data.foldl (fun n v => n*256+v.toNat) 0)) :: out
        else if typ == 8 && (field == 1 || field == 3) then
          match readVL next with
          | .error e => return ⟨out.reverse, some e⟩
          | .ok (account, _) =>
            if account.size != 20 then return ⟨out.reverse, some "invalid AccountID length"⟩
            out := (if field == 1 then "Account" else "Destination",
              .str (← base58CheckEncode 0 account)) :: out
        else if typ == 6 && (field == 1 || field == 8) then
          out := (if field == 1 then "Amount" else "Fee", ← amountJSON raw) :: out
        c := finish
  return ⟨out.reverse, some "transaction parser work limit"⟩

structure TransactionObservation where
  observedAtUnixMs : Nat
  peerIdentity : String
  peerEndpoint : String
  transactionHash : String
  rawHex : String
  decoded : DecodedTransaction
  peerReportedStatus : Nat
  peerReceiveTimestamp : Option Nat
  deferred : Option Bool
  deriving Inhabited

def TransactionObservation.toJson (o : TransactionObservation) : Json :=
  Json.mkObj [("record_type", .str "transaction_observation"), ("observed_at_unix_ms", Lean.toJson o.observedAtUnixMs),
    ("peer_identity", .str o.peerIdentity), ("peer_endpoint", .str o.peerEndpoint),
    ("transaction_hash", .str o.transactionHash), ("raw_hex", .str o.rawHex),
    ("fields", Json.mkObj o.decoded.fields),
    ("decoding_status", .str (if o.decoded.error.isSome then "partial" else "complete")),
    ("decoding_error", Lean.toJson o.decoded.error), ("peer_reported_status", Lean.toJson o.peerReportedStatus),
    ("peer_receive_timestamp", Lean.toJson o.peerReceiveTimestamp), ("deferred", Lean.toJson o.deferred),
    ("confirmation", .str "unknown"), ("signature_verification", .str "unknown")]

def observe (peer endpoint : String) (tx : TransactionEnvelope) : IO TransactionObservation := do
  let time ← Std.Time.Timestamp.now
  let hash ← Native.sha512Half ((byteArray [0x54, 0x58, 0x4e, 0]) ++ tx.raw)
  return ⟨time.toMillisecondsSinceUnixEpoch.toInt.toNat, peer, endpoint, hex hash,
    hex tx.raw, ← decodeFields tx.raw, tx.status, tx.receiveTimestamp, tx.deferred⟩

end LeanXRPL
