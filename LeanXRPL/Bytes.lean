import Std

namespace LeanXRPL

abbrev ParseResult := Except String

/-- A cursor carries the invariant used by every bounded read. -/
structure Cursor where
  bytes : ByteArray
  pos : Nat := 0
  valid : pos ≤ bytes.size := by omega

def Cursor.remaining (c : Cursor) : Nat := c.bytes.size - c.pos

def Cursor.take (c : Cursor) (n : Nat) : ParseResult (ByteArray × Cursor) :=
  if h : c.pos + n ≤ c.bytes.size then
    .ok (c.bytes.extract c.pos (c.pos + n), ⟨c.bytes, c.pos + n, h⟩)
  else .error s!"truncated input at {c.pos}: need {n} bytes"

theorem Cursor.take_bounds {c : Cursor} {n : Nat} {b : ByteArray} {next : Cursor}
    (_h : c.take n = .ok (b, next)) : next.pos ≤ next.bytes.size := next.valid

theorem Cursor.take_progress {c : Cursor} {n : Nat} {b : ByteArray} {next : Cursor}
    (h : c.take n = .ok (b, next)) : next.pos = c.pos + n := by
  unfold Cursor.take at h
  split at h
  · cases h; rfl
  · contradiction

theorem Cursor.take_strict_progress {c : Cursor} {n : Nat} {b : ByteArray} {next : Cursor}
    (h : c.take n = .ok (b, next)) (positive : 0 < n) : c.pos < next.pos := by
  have step := Cursor.take_progress h
  omega

def Cursor.byte (c : Cursor) : ParseResult (UInt8 × Cursor) := do
  let (b, c) ← c.take 1
  return (b[0]!, c)

def Cursor.uint (c : Cursor) (n : Nat) : ParseResult (Nat × Cursor) := do
  let (b, next) ← c.take n
  return (b.data.foldl (fun a v => a * 256 + v.toNat) 0, next)

def byteArray (xs : List UInt8) : ByteArray := ⟨xs.toArray⟩

def uintBytes (n width : Nat) : ByteArray := Id.run do
  let mut out := ByteArray.empty
  for i in [:width] do
    out := out.push ((n / 256 ^ (width - i - 1) % 256).toUInt8)
  return out

def hex (b : ByteArray) : String := Id.run do
  let digits := "0123456789ABCDEF".toList.toArray
  let mut out := ""
  for v in b.data do
    out := out.push digits[v.toNat / 16]!
    out := out.push digits[v.toNat % 16]!
  return out

def unhex (s : String) : ParseResult ByteArray := do
  let chars := s.toList.toArray
  if chars.size % 2 != 0 then throw "odd hex length"
  let val (c : Char) : ParseResult Nat :=
    if c ≥ '0' && c ≤ '9' then .ok (c.toNat - '0'.toNat)
    else if c ≥ 'a' && c ≤ 'f' then .ok (c.toNat - 'a'.toNat + 10)
    else if c ≥ 'A' && c ≤ 'F' then .ok (c.toNat - 'A'.toNat + 10)
    else .error "invalid hex"
  let mut out := ByteArray.empty
  for i in [:chars.size / 2] do
    out := out.push ((← val chars[i*2]!) * 16 + (← val chars[i*2+1]!)).toUInt8
  return out

end LeanXRPL
