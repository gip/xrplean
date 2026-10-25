import LeanXRPL.Bytes
import LeanXRPL.Native

namespace LeanXRPL

def base64Alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray
def rippleAlphabet := "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz".toList.toArray

def base64Encode (b : ByteArray) : String := Id.run do
  let mut out := ""
  for i in [: (b.size + 2) / 3] do
    let p := i * 3
    let a := b[p]!.toNat
    let c := if p+1 < b.size then b[p+1]!.toNat else 0
    let d := if p+2 < b.size then b[p+2]!.toNat else 0
    out := out.push base64Alphabet[a / 4]!
    out := out.push base64Alphabet[(a % 4)*16 + c/16]!
    out := out.push (if p+1 < b.size then base64Alphabet[(c%16)*4+d/64]! else '=')
    out := out.push (if p+2 < b.size then base64Alphabet[d%64]! else '=')
  return out

def base64Decode (s : String) : ParseResult ByteArray := do
  if s.length % 4 != 0 then throw "invalid base64 length"
  let a := s.toList.toArray
  let val (c : Char) : ParseResult Nat :=
    match base64Alphabet.toList.idxOf? c with
    | some n => .ok n
    | none => .error "invalid base64 character"
  let mut out := ByteArray.empty
  for i in [:a.size / 4] do
    let p := 4*i
    let x ← val a[p]!
    let y ← val a[p+1]!
    let last := p + 4 == a.size
    let c := a[p+2]!
    let d := a[p+3]!
    if c == '=' then
      if !last || d != '=' || y % 16 != 0 then throw "invalid base64 padding"
      out := out.push (x*4+y/16).toUInt8
    else
      let z ← val c
      out := out.push (x*4+y/16).toUInt8
      out := out.push ((y%16)*16+z/4).toUInt8
      if d == '=' then
        if !last || z % 4 != 0 then throw "invalid base64 padding"
      else
        let t ← val d
        out := out.push ((z%4)*64+t).toUInt8
  return out

private def encodeNat58 (fuel n : Nat) (out : List Char) : List Char :=
  match fuel with
  | 0 => out
  | fuel+1 => if n == 0 then out else encodeNat58 fuel (n/58) (rippleAlphabet[n%58]! :: out)

def base58Encode (b : ByteArray) : String :=
  let zeros := b.data.toList.takeWhile (· == 0) |>.length
  let n := b.data.foldl (fun n v => n*256 + v.toNat) 0
  String.ofList (List.replicate zeros 'r' ++ encodeNat58 (b.size*2+1) n [])

private def encodeNat256 (fuel n : Nat) (out : List UInt8) : List UInt8 :=
  match fuel with
  | 0 => out
  | fuel+1 => if n == 0 then out else encodeNat256 fuel (n/256) (n.toUInt8 :: out)

def base58Decode (s : String) : ParseResult ByteArray := do
  if s.length > 128 then throw "base58 input too long"
  let mut n := 0
  for c in s.toList do
    let some i := rippleAlphabet.toList.idxOf? c | throw "invalid XRPL base58"
    n := n*58+i
  let zeros := s.toList.takeWhile (· == 'r') |>.length
  return byteArray (List.replicate zeros 0 ++ encodeNat256 s.length n [])

def base58CheckEncode (version : UInt8) (payload : ByteArray) : IO String := do
  let body := (byteArray [version]) ++ payload
  let check ← Native.sha256 (← Native.sha256 body)
  return base58Encode (body ++ check.extract 0 4)

def base58CheckDecode (version : UInt8) (s : String) : IO ByteArray := do
  let b ← IO.ofExcept (base58Decode s)
  if b.size < 5 || b[0]! != version then throw <| IO.userError "wrong base58 token version"
  let body := b.extract 0 (b.size-4)
  let check ← Native.sha256 (← Native.sha256 body)
  if b.extract (b.size-4) b.size != check.extract 0 4 then
    throw <| IO.userError "base58 checksum mismatch"
  return body.extract 1 body.size

end LeanXRPL
