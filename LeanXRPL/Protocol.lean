import LeanXRPL.Bytes

namespace LeanXRPL

structure Frame where
  messageType : Nat
  payload : ByteArray
  deriving Inhabited

def maxFrameSize := 67108863

/-- Returns complete messages plus a bounded incomplete tail. -/
def parseFrames (bytes : ByteArray) : ParseResult (Array Frame × ByteArray) := do
  let mut c : Cursor := ⟨bytes, 0, by omega⟩
  let mut out := #[]
  for _ in [:bytes.size / 6 + 1] do
    if c.remaining < 6 then return (out, bytes.extract c.pos bytes.size)
    let (len, next) ← c.uint 4
    if len ≥ 2^26 then throw "compressed frame or reserved header bits"
    if len == 0 || len > maxFrameSize then throw "invalid overlay frame size"
    let (typ, next) ← next.uint 2
    if next.remaining < len then return (out, bytes.extract c.pos bytes.size)
    let (body, next) ← next.take len
    out := out.push ⟨typ, body⟩
    c := next
  return (out, ByteArray.empty)

inductive ProtoValue where
  | varint (value : Nat)
  | bytes (value : ByteArray)
  | fixed (value : ByteArray)
  deriving Inhabited

structure ProtoField where
  number : Nat
  value : ProtoValue
  deriving Inhabited

def readVarint (c : Cursor) : ParseResult (Nat × Cursor) := do
  let mut c := c
  let mut n := 0
  for i in [:10] do
    let (b, next) ← c.byte
    if i == 9 && b.toNat > 1 then throw "protobuf varint overflow"
    n := n + (b.toNat % 128) * 2^(7*i)
    c := next
    if b.toNat < 128 then return (n, c)
  throw "unterminated protobuf varint"

def parseProto (b : ByteArray) : ParseResult (Array ProtoField) := do
  let mut c : Cursor := ⟨b, 0, by omega⟩
  let mut out := #[]
  for _ in [:b.size] do
    if c.remaining == 0 then return out
    if out.size ≥ 65536 then throw "protobuf field count limit exceeded"
    let (tag, next) ← readVarint c
    if tag / 8 == 0 || tag / 8 > 536870911 then throw "invalid protobuf field number"
    let (value, next) ← match tag % 8 with
      | 0 => do
        let (n, next) ← readVarint next
        pure (ProtoValue.varint n, next)
      | 1 => do
        let (v, next) ← next.take 8
        pure (ProtoValue.fixed v, next)
      | 2 => do
        let (len, next) ← readVarint next
        let (v, next) ← next.take len
        pure (ProtoValue.bytes v, next)
      | 5 => do
        let (v, next) ← next.take 4
        pure (ProtoValue.fixed v, next)
      | _ => throw "unsupported protobuf wire type"
    out := out.push ⟨tag/8, value⟩
    c := next
  if c.remaining == 0 then return out else throw "protobuf parser did not finish"

def protoNat (fs : Array ProtoField) (n : Nat) : Option Nat :=
  (fs.toList.reverse.findSome? fun f => if f.number == n then
    match f.value with | .varint v => some v | _ => none else none)

def protoBytes (fs : Array ProtoField) (n : Nat) : Option ByteArray :=
  (fs.toList.reverse.findSome? fun f => if f.number == n then
    match f.value with | .bytes v => some v | _ => none else none)

def encodeVarint (n : Nat) : ByteArray := Id.run do
  let mut n := n
  let mut out := ByteArray.empty
  for _ in [:10] do
    if n < 128 then return out.push n.toUInt8
    out := out.push (n%128+128).toUInt8
    n := n/128
  return out

def encodeProtoNat (field value : Nat) : ByteArray := encodeVarint (field*8) ++ encodeVarint value
def encodeProtoBytes (field : Nat) (b : ByteArray) : ByteArray :=
  encodeVarint (field*8+2) ++ encodeVarint b.size ++ b

structure TransactionEnvelope where
  raw : ByteArray
  status : Nat
  receiveTimestamp : Option Nat
  deferred : Option Bool
  deriving Inhabited

def decodeTransaction (b : ByteArray) : ParseResult TransactionEnvelope := do
  let fs ← parseProto b
  let some raw := protoBytes fs 1 | throw "missing rawTransaction"
  let some status := protoNat fs 2 | throw "missing transaction status"
  if raw.size == 0 || status < 1 || status > 8 then throw "invalid transaction envelope"
  return ⟨raw, status, protoNat fs 3, (protoNat fs 4).map (· != 0)⟩

def decodeTransactions (f : Frame) : ParseResult (Array TransactionEnvelope) := do
  if f.messageType == 30 then return #[← decodeTransaction f.payload]
  if f.messageType == 64 then
    let fs ← parseProto f.payload
    let mut out := #[]
    for field in fs do
      if field.number == 1 then
        match field.value with
        | .bytes b => out := out.push (← decodeTransaction b)
        | _ => throw "wrong wire type for batched transaction"
    return out
  return #[]

structure Ping where
  pong : Bool
  seq : Option Nat
  deriving Inhabited

def decodePing (b : ByteArray) : ParseResult Ping := do
  let fs ← parseProto b
  let some typ := protoNat fs 1 | throw "missing ping type"
  if typ > 1 then throw "invalid ping type"
  let seq := protoNat fs 2
  if seq.any (· > 4294967295) then throw "ping sequence overflow"
  return ⟨typ == 1, seq⟩

/-- The only overlay messages the session can produce. -/
inductive OutboundControl where
  | ping (seq : UInt32)
  | pong (seq : Option UInt32)
  deriving Inhabited

def OutboundControl.frame (a : OutboundControl) : Frame :=
  let (typ, seq) := match a with
    | .ping s => (0, some s)
    | .pong s => (1, s)
  ⟨3, encodeProtoNat 1 typ ++ (seq.map (fun s => encodeProtoNat 2 s.toNat)).getD ByteArray.empty⟩

def OutboundControl.encode (a : OutboundControl) : ByteArray :=
  let f := a.frame
  uintBytes f.payload.size 4 ++ uintBytes f.messageType 2 ++ f.payload

theorem OutboundControl.only_ping_type (a : OutboundControl) : a.frame.messageType = 3 := by
  cases a <;> rfl

/-- Observers may acquire ledger headers and authenticated trees, never submit,
relay, or send consensus/validation messages. -/
inductive OutboundAction where
  | control (action : OutboundControl)
  | ledgerBase (hash : ByteArray)
  | transactionNodes (hash : ByteArray) (nodeIDs : Array ByteArray)
  | stateNodes (hash : ByteArray) (sequence : Nat) (nodeIDs : Array ByteArray) (depth : Nat)
  | stateObjects (hash : ByteArray) (sequence : Nat) (nodes : Array (ByteArray × ByteArray))
  deriving Inhabited

def OutboundAction.frame : OutboundAction → Frame
  | .control action => action.frame
  | .ledgerBase hash => ⟨31, encodeProtoNat 1 0 ++ encodeProtoBytes 3 hash⟩
  | .transactionNodes hash ids => ⟨31, encodeProtoNat 1 1 ++ encodeProtoBytes 3 hash ++
      ids.foldl (fun b id => b ++ encodeProtoBytes 5 id) ByteArray.empty ++ encodeProtoNat 8 2⟩
  | .stateNodes hash sequence ids depth => ⟨31, encodeProtoNat 1 2 ++ encodeProtoBytes 3 hash ++
      encodeProtoNat 4 sequence ++ ids.foldl (fun b id => b ++ encodeProtoBytes 5 id) ByteArray.empty ++
      encodeProtoNat 7 0 ++ encodeProtoNat 8 depth⟩
  | .stateObjects hash sequence nodes => ⟨42, encodeProtoNat 1 4 ++ encodeProtoNat 2 1 ++
      encodeProtoBytes 4 hash ++ nodes.foldl (fun b (id, h) => b ++ encodeProtoBytes 6
        (encodeProtoBytes 1 h ++ encodeProtoBytes 2 id ++ encodeProtoNat 5 sequence)) ByteArray.empty⟩

def OutboundAction.encode (action : OutboundAction) : ByteArray :=
  let f := action.frame
  uintBytes f.payload.size 4 ++ uintBytes f.messageType 2 ++ f.payload

theorem OutboundAction.read_only (a : OutboundAction) :
    a.frame.messageType = 3 ∨ a.frame.messageType = 31 ∨ a.frame.messageType = 42 := by
  cases a with
  | control c => exact Or.inl c.only_ping_type
  | ledgerBase _ => exact Or.inr (Or.inl rfl)
  | transactionNodes _ _ => exact Or.inr (Or.inl rfl)
  | stateNodes _ _ _ _ => exact Or.inr (Or.inl rfl)
  | stateObjects _ _ _ => exact Or.inr (Or.inr rfl)

structure SessionState where
  pendingPing : Option UInt32 := none
  deriving Inhabited

def SessionState.onPing (s : SessionState) (p : Ping) : SessionState × Array OutboundControl :=
  if p.pong then
    ({ pendingPing := if p.seq == s.pendingPing.map UInt32.toNat then none else s.pendingPing }, #[])
  else (s, #[.pong (p.seq.map Nat.toUInt32)])

def SessionState.onTimer (s : SessionState) (seq : UInt32) : ParseResult (SessionState × Array OutboundControl) :=
  if s.pendingPing.isSome then .error "ping timeout"
  else .ok (⟨some seq⟩, #[.ping seq])

theorem SessionState.outbound_restricted (actions : Array OutboundControl) :
    ∀ a ∈ actions, a.frame.messageType = 3 := by
  intro a _
  exact a.only_ping_type

end LeanXRPL
