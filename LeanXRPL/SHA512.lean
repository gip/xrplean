import Std

namespace LeanXRPL.SHA512

/- Pure SHA-512 (FIPS 180-4), with arithmetic in Nat modulo 2^64.
   No FFI, native_decide, opaque crypto primitive, or hashing axiom. -/
def modulus : Nat := 18446744073709551616
def mask : Nat := 18446744073709551615
def word (n : Nat) : Nat := n % modulus
def land (a b : Nat) := Nat.land a b
def xor (a b : Nat) := Nat.xor a b
def rotr (x n : Nat) : Nat := x / 2^n + (x % 2^n) * 2^(64-n)
def small0 (x : Nat) := xor (xor (rotr x 1) (rotr x 8)) (x / 128)
def small1 (x : Nat) := xor (xor (rotr x 19) (rotr x 61)) (x / 64)
def big0 (x : Nat) := xor (xor (rotr x 28) (rotr x 34)) (rotr x 39)
def big1 (x : Nat) := xor (xor (rotr x 14) (rotr x 18)) (rotr x 41)
def choose (x y z : Nat) := xor (land x y) (land (mask-x) z)
def majority (x y z : Nat) := xor (xor (land x y) (land x z)) (land y z)

def constants : Array Nat := #[
  0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
  0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
  0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
  0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
  0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
  0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
  0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
  0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
  0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
  0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
  0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
  0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
  0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
  0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
  0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
  0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
  0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
  0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
  0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
  0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817]

structure State where
  a : Nat
  b : Nat
  c : Nat
  d : Nat
  e : Nat
  f : Nat
  g : Nat
  h : Nat
  deriving DecidableEq, Repr, Inhabited

def initial : State := ⟨0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
  0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1, 0x510e527fade682d1,
  0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179⟩

def round (s : State) (k w : Nat) : State :=
  let t1 := word (s.h + big1 s.e + choose s.e s.f s.g + k + w)
  let t2 := word (big0 s.a + majority s.a s.b s.c)
  ⟨word (t1+t2), s.a, s.b, s.c, word (s.d+t1), s.e, s.f, s.g⟩

def add (s t : State) : State :=
  ⟨word (s.a+t.a), word (s.b+t.b), word (s.c+t.c), word (s.d+t.d),
   word (s.e+t.e), word (s.f+t.f), word (s.g+t.g), word (s.h+t.h)⟩

def checkRounds (states : Array State) (words : Array Nat) : Bool :=
  states.size == 81 && words.size == 80 &&
  (List.range 80).all (fun i => decide (round states[i]! constants[i]! words[i]! = states[i+1]!))

def checkRoundList : List State → List Nat → List Nat → Bool
  | [_], [], [] => true
  | s::t::states, k::ks, w::ws => decide (round s k w = t) && checkRoundList (t::states) ks ws
  | _, _, _ => false

def readWord (bytes : List Nat) : Nat := bytes.take 8 |>.foldl (fun n b => n*256+b) 0
def readWords : Nat → List Nat → List Nat
  | 0, _ => []
  | n+1, bytes => readWord bytes :: readWords n (bytes.drop 8)

def extendWords : Nat → List Nat → List Nat
  | 0, _ => []
  | n+1, ws =>
    let w := word (small1 ws[14]! + ws[9]! + small0 ws[1]! + ws[0]!)
    w :: extendWords n (ws.tail ++ [w])

def runRounds : State → List Nat → List Nat → State
  | s, k::ks, w::ws => runRounds (round s k w) ks ws
  | s, _, _ => s

def compress (s : State) (bytes : List Nat) : State :=
  let w := readWords 16 bytes
  add s (runRounds s constants.toList (w ++ extendWords 64 w))

def bytesBE (n size : Nat) : List Nat :=
  (List.range size).map (fun i => (n / 256^(size-1-i)) % 256)

def pad (bytes : List Nat) : List Nat :=
  bytes ++ [128] ++ (List.replicate ((239-bytes.length%128)%128) 0) ++ bytesBE (bytes.length*8) 16

def digestBlocks : Nat → List Nat → State → State
  | 0, _, s => s
  | n+1, bytes, s => digestBlocks n (bytes.drop 128) (compress s (bytes.take 128))

def digest (bytes : List Nat) : State :=
  let padded := pad bytes
  digestBlocks (padded.length/128) padded initial

/-- XRPL SHA-512Half is the first 256 bits of SHA-512, not SHA-512/256. -/
def half (bytes : List Nat) : Nat :=
  let s := digest bytes
  ((s.a*modulus+s.b)*modulus+s.c)*modulus+s.d

end LeanXRPL.SHA512
