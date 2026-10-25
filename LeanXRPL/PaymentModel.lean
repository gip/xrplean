import Std

namespace LeanXRPL.PaymentModel

/-- Canonical field code and exact serialized value. Hashing and interpretation
are unnecessary for proving that every unpermitted field survives unchanged. -/
abbrev SerializedField := Nat × List UInt8

def fieldFrame (fields : List SerializedField) (allowed : List Nat) : List SerializedField :=
  fields.filter (fun f => decide (f.1 ∉ allowed))

def checkFrame (before after : List SerializedField) (allowed : List Nat) : Bool :=
  decide (fieldFrame before allowed = fieldFrame after allowed)

theorem checkFrame_sound {before after : List SerializedField} {allowed : List Nat}
    (h : checkFrame before after allowed = true) :
    fieldFrame before allowed = fieldFrame after allowed := of_decide_eq_true h

theorem unchanged_field {before after : List SerializedField} {allowed : List Nat}
    (h : checkFrame before after allowed = true) (field : SerializedField)
    (present : field ∈ before) (notAllowed : field.1 ∉ allowed) : field ∈ after := by
  have member : field ∈ fieldFrame before allowed := by
    simp [fieldFrame, present, notAllowed]
  rw [checkFrame_sound h] at member
  exact (List.mem_filter.mp member).1

theorem no_unpermitted_fields_added {before after : List SerializedField} {allowed : List Nat}
    (h : checkFrame before after allowed = true) (field : SerializedField)
    (present : field ∈ after) (notAllowed : field.1 ∉ allowed) : field ∈ before := by
  have reverse : checkFrame after before allowed = true := by
    apply decide_eq_true
    exact (checkFrame_sound h).symm
  exact unchanged_field reverse field present notAllowed

theorem frame_composition {before middle after : List SerializedField} {allowed : List Nat}
    (first : checkFrame before middle allowed = true)
    (second : checkFrame middle after allowed = true) : checkFrame before after allowed = true := by
  apply decide_eq_true
  exact (checkFrame_sound first).trans (checkFrame_sound second)

/-- Different transactions may permit different fields. A field outside both
permission sets is preserved through their composition. -/
theorem unchanged_field_composition {before middle after : List SerializedField}
    {firstAllowed secondAllowed : List Nat}
    (first : checkFrame before middle firstAllowed = true)
    (second : checkFrame middle after secondAllowed = true)
    (field : SerializedField) (present : field ∈ before)
    (notAllowed : field.1 ∉ firstAllowed ++ secondAllowed) : field ∈ after := by
  simp only [List.mem_append, not_or] at notAllowed
  exact unchanged_field second field (unchanged_field first field present notAllowed.1) notAllowed.2

inductive Kind where
  | xrp | token | feeOnly
  deriving DecidableEq, Repr

/-- Exact normalized facts. IOU units are 10^-96; XRP units are drops.
The parser checks identity, complete field frames, and history against blobs.
Those checks remain an explicitly separate parsing/cryptography trust boundary. -/
structure Facts where
  kind : Kind
  amount : Int
  fee : Int
  sourceXrpBefore : Int
  sourceXrpAfter : Int
  destinationXrpBefore : Int := 0
  destinationXrpAfter : Int := 0
  sourceTokenBefore : Int := 0
  sourceTokenAfter : Int := 0
  destinationTokenBefore : Int := 0
  destinationTokenAfter : Int := 0
  destinationLimit : Int := 0
  sendMax : Int := 0
  sequenceBefore : Nat
  sequenceAfter : Nat
  transactionSequence : Nat
  identityOK : Bool
  frameOK : Bool
  historyOK : Bool
  deliveryOK : Bool
  deriving Repr

def Common (f : Facts) : Prop :=
  f.identityOK = true ∧ f.frameOK = true ∧ f.historyOK = true ∧ f.deliveryOK = true ∧
  0 ≤ f.fee ∧ 0 ≤ f.sourceXrpAfter ∧
  f.sequenceBefore = f.transactionSequence ∧ f.sequenceAfter = f.sequenceBefore + 1

def Rules (f : Facts) : Prop :=
  match f.kind with
  | .xrp =>
    0 < f.amount ∧ 0 ≤ f.destinationXrpBefore ∧
    f.sourceXrpAfter + f.amount + f.fee = f.sourceXrpBefore ∧
    f.destinationXrpAfter = f.destinationXrpBefore + f.amount
  | .token =>
    0 < f.amount ∧ f.amount ≤ f.sendMax ∧
    f.sourceXrpAfter + f.fee = f.sourceXrpBefore ∧
    f.amount ≤ f.sourceTokenBefore ∧ 0 ≤ f.destinationTokenBefore ∧
    f.sourceTokenAfter = f.sourceTokenBefore - f.amount ∧
    f.destinationTokenAfter = f.destinationTokenBefore + f.amount ∧
    f.destinationTokenAfter ≤ f.destinationLimit
  | .feeOnly => f.sourceXrpAfter + f.fee = f.sourceXrpBefore

def Valid (f : Facts) : Prop := Common f ∧ Rules f

instance (f : Facts) : Decidable (Common f) := inferInstanceAs (Decidable (_ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _))
instance (f : Facts) : Decidable (Rules f) := by unfold Rules; cases f.kind <;> infer_instance
instance (f : Facts) : Decidable (Valid f) := inferInstanceAs (Decidable (Common f ∧ Rules f))

def check (f : Facts) : Bool := decide (Valid f)

theorem check_sound {f : Facts} (h : check f = true) : Valid f := of_decide_eq_true h

def xrpDelta (f : Facts) : Int :=
  f.sourceXrpAfter - f.sourceXrpBefore +
    (match f.kind with
    | .xrp => f.destinationXrpAfter - f.destinationXrpBefore
    | _ => 0)

theorem fee_accounting {f : Facts} (h : Valid f) : xrpDelta f + f.fee = 0 := by
  obtain ⟨common, rules⟩ := h
  cases kind : f.kind <;> simp [Rules, kind] at rules <;> simp [xrpDelta, kind] <;> omega

theorem source_funded {f : Facts} (h : Valid f) :
    (match f.kind with | .xrp => f.amount + f.fee | _ => f.fee) ≤ f.sourceXrpBefore := by
  obtain ⟨common, rules⟩ := h
  simp [Common] at common
  cases kind : f.kind <;> simp [Rules, kind] at rules <;> simp <;> omega

theorem token_conservation {f : Facts} (h : Valid f) (kind : f.kind = .token) :
    f.sourceTokenAfter + f.destinationTokenAfter =
      f.sourceTokenBefore + f.destinationTokenBefore := by
  have rules := h.2
  simp [Rules, kind] at rules
  omega

theorem token_no_overdraft {f : Facts} (h : Valid f) (kind : f.kind = .token) :
    0 ≤ f.sourceTokenAfter := by
  have rules := h.2
  simp [Rules, kind] at rules
  omega

theorem sequence_consumed {f : Facts} (h : Valid f) :
    f.sequenceAfter = f.transactionSequence + 1 := by
  have common := h.1
  simp [Common] at common
  omega

theorem xrp_recipient_nonnegative {f : Facts} (h : Valid f) (kind : f.kind = .xrp) :
    0 ≤ f.destinationXrpAfter := by
  have rules := h.2
  simp [Rules, kind] at rules
  omega

theorem token_recipient_within_limit {f : Facts} (h : Valid f) (kind : f.kind = .token) :
    0 ≤ f.destinationTokenAfter ∧ f.destinationTokenAfter ≤ f.destinationLimit := by
  have rules := h.2
  simp [Rules, kind] at rules
  omega

end LeanXRPL.PaymentModel
