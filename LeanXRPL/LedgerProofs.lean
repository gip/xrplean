import LeanXRPL.PaymentModel

namespace LeanXRPL.LedgerProofs

/-- The state threaded through a ledger must be the preceding step's output.
Pre/post system changes can be represented as steps too. The relation must be
instantiated with independently verified rules for *every* included step. -/
inductive Execution {State Transaction : Type} (step : State → Transaction → State → Prop) :
    State → List Transaction → State → Prop where
  | nil (state) : Execution step state [] state
  | cons {before middle after tx rest} : step before tx middle →
      Execution step middle rest after → Execution step before (tx :: rest) after

theorem preserves_invariant {State Transaction : Type}
    {step : State → Transaction → State → Prop} (invariant : State → Prop)
    (preserves : ∀ before tx after, step before tx after → invariant before → invariant after)
    {before after transactions} (execution : Execution step before transactions after)
    (initial : invariant before) : invariant after := by
  induction execution with
  | nil => exact initial
  | cons h _ ih => exact ih (preserves _ _ _ h initial)

/-- XRP mass includes all modeled XRP containers, not only AccountRoot balances. -/
theorem xrp_accounting {State Transaction : Type}
    {step : State → Transaction → State → Prop}
    (totalXrp : State → Int) (burned : Transaction → Int)
    (accounting : ∀ before tx after, step before tx after →
      totalXrp after + burned tx = totalXrp before)
    {before after transactions} (execution : Execution step before transactions after) :
    totalXrp after + (transactions.map burned).sum = totalXrp before := by
  induction execution with
  | nil => simp
  | cons h _ ih =>
    have := accounting _ _ _ h
    simp only [List.map_cons, List.sum_cons]
    omega

theorem xrp_never_created {State Transaction : Type}
    {step : State → Transaction → State → Prop}
    (totalXrp : State → Int) (burned : Transaction → Int)
    (accounting : ∀ before tx after, step before tx after →
      totalXrp after + burned tx = totalXrp before)
    {before after transactions} (execution : Execution step before transactions after)
    (nonnegative : ∀ tx ∈ transactions, 0 ≤ burned tx) : totalXrp after ≤ totalXrp before := by
  induction execution with
  | nil => exact Int.le_refl _
  | @cons _ _ _ tx _ h _ ih =>
    have head := accounting _ _ _ h
    have fee := nonnegative tx (by simp)
    have tail := ih (fun tx member => nonnegative tx (by simp [member]))
    omega

/-- A useful aggregate certificate for a list of supported Payments. This alone
does not imply that skipped transactions or system changes are correct. -/
theorem payment_accounting (facts : List PaymentModel.Facts)
    (valid : ∀ f ∈ facts, PaymentModel.Valid f) :
    (facts.map PaymentModel.xrpDelta).sum + (facts.map (·.fee)).sum = 0 := by
  induction facts with
  | nil => simp
  | cons f fs ih =>
    have head := PaymentModel.fee_accounting (valid f (by simp))
    have tail := ih (fun item member => valid item (by simp [member]))
    simp only [List.map_cons, List.sum_cons]
    omega

end LeanXRPL.LedgerProofs
