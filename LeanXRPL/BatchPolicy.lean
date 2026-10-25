import Std

/- A deliberately small unsigned Batch language. Serialization and the policy are
   pure and reducible by the kernel; no native cryptography enters these proofs. -/
namespace LeanXRPL.BatchPolicy

abbrev Bytes := List Nat
def maxDrops : Nat := 100000000000000000
def uint32 (n : Nat) : Prop := n > 0 ∧ n < 2^32
def account (bs : Bytes) : Prop := bs.length = 20 ∧ ∀ b ∈ bs, b < 256

structure Policy where
  network : Nat
  recipient : Bytes
  fee : Nat
  deriving Repr, DecidableEq

structure Payment where
  destination : Bytes
  amount : Nat
  sequence : Nat
  deriving Repr, DecidableEq

structure Batch where
  source : Bytes
  publicKey : Bytes
  sequence : Nat
  serviceSequence : Nat
  lastLedger : Nat
  networkFee : Nat
  payments : List Payment
  deriving Repr, DecidableEq

def paymentValid (p : Policy) (x : Payment) : Prop :=
  account x.destination ∧ x.destination ≠ p.recipient ∧
  0 < x.amount ∧ x.amount ≤ maxDrops ∧ uint32 x.sequence

def Valid (p : Policy) (b : Batch) : Prop :=
  p.network < 2^32 ∧ account p.recipient ∧ 0 < p.fee ∧ p.fee ≤ maxDrops ∧
  account b.source ∧ b.source ≠ p.recipient ∧
  b.publicKey.length = 33 ∧ (b.publicKey.head? = some 2 ∨ b.publicKey.head? = some 3) ∧
  (∀ n ∈ b.publicKey, n < 256) ∧
  uint32 b.sequence ∧ uint32 b.serviceSequence ∧ uint32 b.lastLedger ∧
  0 < b.networkFee ∧ b.networkFee ≤ maxDrops ∧
  1 ≤ b.payments.length ∧ b.payments.length ≤ 7 ∧
  (∀ x ∈ b.payments, paymentValid p x) ∧
  (b.sequence :: b.serviceSequence :: b.payments.map Payment.sequence).Nodup ∧
  b.networkFee + p.fee + (b.payments.map Payment.amount).sum ≤ maxDrops

instance (p : Policy) (x : Payment) : Decidable (paymentValid p x) := by
  unfold paymentValid account uint32
  infer_instance
instance (p : Policy) (b : Batch) : Decidable (Valid p b) := by
  unfold Valid uint32 account
  infer_instance

def be (n width : Nat) : Bytes :=
  (List.range width).map (fun i => n / 256^(width-1-i) % 256)
def amount (n : Nat) : Bytes := be (2^62+n) 8
def accountField (tag : Nat) (bs : Bytes) : Bytes := [tag,20] ++ bs

/-- Canonical XRPL field order. Every inner is an unsigned direct XRP Payment. -/
def serializePayment (source : Bytes) (x : Payment) : Bytes :=
  [0x12,0,0, 0x22] ++ be 0x40000000 4 ++ [0x24] ++ be x.sequence 4 ++
  [0x61] ++ amount x.amount ++ [0x68] ++ amount 0 ++ [0x73,0] ++
  accountField 0x81 source ++ accountField 0x83 x.destination

def servicePayment (p : Policy) (b : Batch) : Payment :=
  ⟨p.recipient, p.fee, b.serviceSequence⟩
def innerPayments (p : Policy) (b : Batch) : List Payment :=
  b.payments ++ [servicePayment p b]

/-- The only outer mode is tfAllOrNothing; the only array is RawTransactions.
    NetworkID is omitted for network IDs ≤ 1024, as required by XRPL. -/
def serialize (p : Policy) (b : Batch) : Bytes :=
  [0x12,0,71] ++ (if p.network > 1024 then [0x21] ++ be p.network 4 else []) ++
  [0x22] ++ be 0x10000 4 ++ [0x24] ++ be b.sequence 4 ++
  [0x20,0x1b] ++ be b.lastLedger 4 ++ [0x68] ++ amount b.networkFee ++
  [0x73,33] ++ b.publicKey ++ accountField 0x81 b.source ++ [0xf0,30] ++
  ((innerPayments p b).flatMap (fun x => [0xe0,34] ++ serializePayment b.source x ++ [0xe1])) ++ [0xf1]

def Certified (p : Policy) (b : Batch) (raw : Bytes) : Prop :=
  Valid p b ∧ raw = serialize p b
def check (p : Policy) (b : Batch) (raw : Bytes) : Bool :=
  decide (Valid p b) && decide (raw = serialize p b)

theorem check_sound {p : Policy} {b : Batch} {raw : Bytes}
    (h : check p b raw = true) : Certified p b raw := by
  simp only [check, Bool.and_eq_true, decide_eq_true_eq] at h
  exact h

theorem service_is_last (p : Policy) (b : Batch) :
    innerPayments p b = b.payments ++ [⟨p.recipient,p.fee,b.serviceSequence⟩] := rfl

theorem certified_bytes {p : Policy} {b : Batch} {raw : Bytes}
    (h : Certified p b raw) : raw = serialize p b := h.2

end LeanXRPL.BatchPolicy
