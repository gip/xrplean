import LeanXRPL.SHA512

/-! A kernel-reducible SHA-512Half prototype.

The reference implementation stays unchanged. This implementation keeps its
padding, byte decoding, constants, and word operations, but streams the expanded
message schedule through a fixed sixteen-word window instead of indexing and
copying lists. It also removes intermediate reductions that the final word
reductions subsume. The intermediate list-based functions below support the
proof; `compress` executes the fixed-window path.

`half_eq` proves equivalence for every `List Nat`, with no byte-range or length
assumptions. Concrete results can be computed with `decide +kernel` and then
transferred to the reference definition using that theorem. No native evaluation,
external cryptography, unsafe replacement, or hashing axiom is used. -/
namespace LeanXRPL.SHA512Fast

open SHA512 (State constants initial modulus small0 small1 big0 big1)

-- Keep the reference word operations; the speedup comes from the schedule layout.
def word (n : Nat) : Nat := n % modulus

@[simp] theorem word_eq (n : Nat) : word n = SHA512.word n := rfl

def round (s : State) (k w : Nat) : State :=
  let t1 := s.h + big1 s.e + SHA512.choose s.e s.f s.g + k + w
  let t2 := big0 s.a + SHA512.majority s.a s.b s.c
  ⟨word (t1+t2), s.a, s.b, s.c, word (s.d+t1), s.e, s.f, s.g⟩

@[simp] theorem round_eq (s : State) (k w : Nat) : round s k w = SHA512.round s k w := by
  simp only [round, word_eq, SHA512.round, SHA512.word]
  congr 1 <;> simp only [Nat.add_mod, Nat.mod_mod]

def add (s t : State) : State :=
  ⟨word (s.a+t.a), word (s.b+t.b), word (s.c+t.c), word (s.d+t.d),
   word (s.e+t.e), word (s.f+t.f), word (s.g+t.g), word (s.h+t.h)⟩

@[simp] theorem add_eq (s t : State) : add s t = SHA512.add s t := by
  simp only [add, word_eq, SHA512.add]

def extendWords : Nat → List Nat → List Nat
  | 0, _ => []
  | n+1, ws =>
    let w := word (small1 ws[14]! + ws[9]! + small0 ws[1]! + ws[0]!)
    w :: extendWords n (ws.tail ++ [w])

@[simp] theorem extendWords_eq (n : Nat) (ws : List Nat) :
    extendWords n ws = SHA512.extendWords n ws := by
  induction n generalizing ws with
  | zero => rfl
  | succ n ih => simp only [extendWords, SHA512.extendWords, word_eq, ih]

def runRounds : State → List Nat → List Nat → State
  | s, k::ks, w::ws => runRounds (round s k w) ks ws
  | s, _, _ => s

@[simp] theorem runRounds_eq (s : State) (ks ws : List Nat) :
    runRounds s ks ws = SHA512.runRounds s ks ws := by
  induction ks generalizing s ws with
  | nil => rfl
  | cons k ks ih =>
    cases ws with
    | nil => rfl
    | cons w ws => simp only [runRounds, SHA512.runRounds, round_eq, ih]

/-- Generate each expanded word immediately before its compression round. -/
def scheduleRounds : State → List Nat → List Nat → State
  | s, [], _ => s
  | s, k::ks, ws =>
    let w := word (small1 ws[14]! + ws[9]! + small0 ws[1]! + ws[0]!)
    scheduleRounds (round s k w) ks (ws.tail ++ [w])

theorem scheduleRounds_eq (s : State) (ks ws : List Nat) :
    scheduleRounds s ks ws = runRounds s ks (extendWords ks.length ws) := by
  induction ks generalizing s ws with
  | nil => rfl
  | cons k ks ih =>
    unfold scheduleRounds
    rw [ih]
    rfl

theorem runRounds_append (s : State) (ks ws tailK tailW : List Nat)
    (h : ks.length = ws.length) :
    runRounds s (ks ++ tailK) (ws ++ tailW) =
      runRounds (runRounds s ks ws) tailK tailW := by
  induction ks generalizing s ws with
  | nil =>
    have hw : ws = [] := List.eq_nil_of_length_eq_zero h.symm
    subst ws
    rfl
  | cons k ks ih =>
    cases ws with
    | nil => simp at h
    | cons w ws =>
      change runRounds (round s k w) (ks ++ tailK) (ws ++ tailW) =
        runRounds (runRounds (round s k w) ks ws) tailK tailW
      exact ih _ _ (by simpa using h)

theorem readWords_length (n : Nat) (bytes : List Nat) :
    (SHA512.readWords n bytes).length = n := by
  induction n generalizing bytes with
  | zero => rfl
  | succ n ih => simp only [SHA512.readWords, List.length_cons, ih]

/-- Carry the eight registers directly, avoiding projections from intermediate states. -/
def runRegisters : List Nat → List Nat → Nat → Nat → Nat → Nat → Nat → Nat → Nat → Nat → State
  | k::ks, w::ws, a, b, c, d, e, f, g, h =>
    let t1 := h + big1 e + SHA512.choose e f g + k + w
    let t2 := big0 a + SHA512.majority a b c
    runRegisters ks ws (word (t1+t2)) a b c (word (d+t1)) e f g
  | _, _, a, b, c, d, e, f, g, h => ⟨a,b,c,d,e,f,g,h⟩

theorem runRegisters_eq (ks ws : List Nat) (a b c d e f g h : Nat) :
    runRegisters ks ws a b c d e f g h = runRounds ⟨a,b,c,d,e,f,g,h⟩ ks ws := by
  induction ks generalizing ws a b c d e f g h with
  | nil => rfl
  | cons k ks ih =>
    cases ws with
    | nil => rfl
    | cons w ws =>
      unfold runRegisters runRounds
      exact ih _ _ _ _ _ _ _ _ _

/-- A fixed-width message-schedule window. -/
structure Window where
  w0 : Nat
  w1 : Nat
  w2 : Nat
  w3 : Nat
  w4 : Nat
  w5 : Nat
  w6 : Nat
  w7 : Nat
  w8 : Nat
  w9 : Nat
  w10 : Nat
  w11 : Nat
  w12 : Nat
  w13 : Nat
  w14 : Nat
  w15 : Nat

namespace Window

def words (w : Window) : List Nat :=
  [w.w0,w.w1,w.w2,w.w3,w.w4,w.w5,w.w6,w.w7,w.w8,w.w9,w.w10,w.w11,w.w12,w.w13,w.w14,w.w15]
def next (w : Window) : Nat := word (small1 w.w14 + w.w9 + small0 w.w1 + w.w0)
def advance (w : Window) : Window :=
  ⟨w.w1,w.w2,w.w3,w.w4,w.w5,w.w6,w.w7,w.w8,w.w9,w.w10,w.w11,w.w12,w.w13,w.w14,w.w15,w.next⟩
/-- `compress` supplies exactly sixteen words; `ofList_words` discharges that invariant. -/
def ofList : List Nat → Window
  | [w0,w1,w2,w3,w4,w5,w6,w7,w8,w9,w10,w11,w12,w13,w14,w15] =>
    ⟨w0,w1,w2,w3,w4,w5,w6,w7,w8,w9,w10,w11,w12,w13,w14,w15⟩
  | _ => ⟨0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0⟩

theorem ofList_words (ws : List Nat) (h : ws.length = 16) : (ofList ws).words = ws := by
  rcases ws with _ | ⟨w0,ws⟩
  · simp at h
  rcases ws with _ | ⟨w1,ws⟩
  · simp at h
  rcases ws with _ | ⟨w2,ws⟩
  · simp at h
  rcases ws with _ | ⟨w3,ws⟩
  · simp at h
  rcases ws with _ | ⟨w4,ws⟩
  · simp at h
  rcases ws with _ | ⟨w5,ws⟩
  · simp at h
  rcases ws with _ | ⟨w6,ws⟩
  · simp at h
  rcases ws with _ | ⟨w7,ws⟩
  · simp at h
  rcases ws with _ | ⟨w8,ws⟩
  · simp at h
  rcases ws with _ | ⟨w9,ws⟩
  · simp at h
  rcases ws with _ | ⟨w10,ws⟩
  · simp at h
  rcases ws with _ | ⟨w11,ws⟩
  · simp at h
  rcases ws with _ | ⟨w12,ws⟩
  · simp at h
  rcases ws with _ | ⟨w13,ws⟩
  · simp at h
  rcases ws with _ | ⟨w14,ws⟩
  · simp at h
  rcases ws with _ | ⟨w15,ws⟩
  · simp at h
  have hz : ws = [] := List.eq_nil_of_length_eq_zero (by simpa using h)
  subst ws
  rfl

end Window

def runExpanded : State → List Nat → Window → State
  | s, [], _ => s
  | s, k::ks, w => runExpanded (round s k w.next) ks w.advance

theorem runExpanded_eq (s : State) (ks : List Nat) (w : Window) :
    runExpanded s ks w = scheduleRounds s ks w.words := by
  induction ks generalizing s w with
  | nil => rfl
  | cons k ks ih =>
    unfold runExpanded scheduleRounds
    rw [ih]
    rfl

def compress (s : State) (bytes : List Nat) : State :=
  let ws := SHA512.readWords 16 bytes
  let first := runRegisters (constants.toList.take 16) ws s.a s.b s.c s.d s.e s.f s.g s.h
  add s (runExpanded first (constants.toList.drop 16) (Window.ofList ws))

@[simp] theorem compress_eq (s : State) (bytes : List Nat) :
    compress s bytes = SHA512.compress s bytes := by
  have hlen : (constants.toList.take 16).length = (SHA512.readWords 16 bytes).length := by
    rw [readWords_length]
    decide +kernel
  have hdrop : (constants.toList.drop 16).length = 64 := by decide +kernel
  cases s
  simp only [compress, runRegisters_eq, runExpanded_eq,
    Window.ofList_words _ (readWords_length 16 bytes), scheduleRounds_eq, hdrop]
  rw [← runRounds_append _ _ _ _ _ hlen,
    List.take_append_drop, extendWords_eq, runRounds_eq, add_eq]
  rfl

def digestBlocks : Nat → List Nat → State → State
  | 0, _, s => s
  | n+1, bytes, s => digestBlocks n (bytes.drop 128) (compress s (bytes.take 128))

@[simp] theorem digestBlocks_eq (n : Nat) (bytes : List Nat) (s : State) :
    digestBlocks n bytes s = SHA512.digestBlocks n bytes s := by
  induction n generalizing bytes s with
  | zero => rfl
  | succ n ih =>
    unfold digestBlocks SHA512.digestBlocks
    apply Eq.trans (ih _ _)
    exact congrArg (SHA512.digestBlocks n (bytes.drop 128)) (compress_eq s (bytes.take 128))

def digest (bytes : List Nat) : State :=
  let padded := SHA512.pad bytes
  digestBlocks (padded.length/128) padded initial

@[simp] theorem digest_eq (bytes : List Nat) : digest bytes = SHA512.digest bytes := by
  simp only [digest, digestBlocks_eq, SHA512.digest]

def half (bytes : List Nat) : Nat :=
  let s := digest bytes
  ((s.a*modulus+s.b)*modulus+s.c)*modulus+s.d

/-- The optimized function equals the reference for every input. -/
theorem half_eq (bytes : List Nat) : half bytes = SHA512.half bytes := by
  simp only [half, digest_eq, SHA512.half]

end LeanXRPL.SHA512Fast
