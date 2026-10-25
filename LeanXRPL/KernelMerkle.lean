import LeanXRPL.SHA512

namespace LeanXRPL.KernelMerkle

abbrev Hash := Nat
abbrev Bytes := List Nat

inductive Node where
  | leaf (key : Nat) (data : Bytes)
  | inner (children : List Hash)
  deriving DecidableEq, Repr

def payload : Node → Bytes
  | .leaf key data => [77,76,78,0] ++ data ++ SHA512.bytesBE key 32
  | .inner children => [77,73,78,0] ++ children.flatMap (fun h => SHA512.bytesBE h 32)

def nodeHash (node : Node) : Hash := SHA512.half (payload node)

/-- An unopened subtree retains its commitment. Editing an unopened subtree
fails; witnesses must expose every path that the export changes. -/
inductive Tree where
  | empty
  | opaque (hash : Hash)
  | leaf (key : Nat) (data : Bytes)
  | inner (children : List Tree)
  deriving Repr

instance : Inhabited Tree := ⟨.empty⟩

def Tree.isEmpty : Tree → Bool
  | .empty => true
  | _ => false

mutual
/-- Cryptographic authentication of a partial tree, using pure SHA-512Half. -/
inductive Rooted : Hash → Tree → Prop where
  | empty : Rooted 0 .empty
  | opaque (h : Hash) : Rooted h (.opaque h)
  | leaf {key data h} : nodeHash (.leaf key data) = h → Rooted h (.leaf key data)
  | inner {hashes children h} : hashes.length = 16 →
      ForestRooted hashes children → nodeHash (.inner hashes) = h →
      Rooted h (.inner children)

inductive ForestRooted : List Hash → List Tree → Prop where
  | nil : ForestRooted [] []
  | cons {h t hs ts} : Rooted h t → ForestRooted hs ts → ForestRooted (h::hs) (t::ts)
end

def digit (key depth : Nat) := key / 16^(63-depth) % 16

def lookup : Nat → Nat → Tree → Nat → Option (Option Bytes)
  | 0, _, _, _ => none
  | fuel+1, depth, tree, key =>
    match tree with
    | .empty => some none
    | .opaque _ => none
    | .leaf old data => some (if old == key then some data else none)
    | .inner children =>
      if depth < 64 && children.length == 16 then
        lookup fuel (depth+1) (children[digit key depth]!) key
      else none

/-- A deletion may collapse a unary branch only when its surviving subtree is
known to consist of one leaf. An unopened witness is never guessed. -/
def singleton : Nat → Tree → Option (Option Tree)
  | 0, _ => none
  | fuel+1, tree =>
    match tree with
    | .opaque _ => none
    | .empty => some none
    | .leaf key data => some (some (.leaf key data))
    | .inner children =>
      match children.filter (fun c => !c.isEmpty) with
      | [child] => singleton fuel child
      | _ => some none

def normalize (fuel depth : Nat) (children : List Tree) : Option Tree := do
  match children.filter (fun c => !c.isEmpty) with
  | [] => return .empty
  | [child] =>
    if depth == 0 then return .inner children
    if let some leaf ← singleton fuel child then return leaf
    return .inner children
  | _ => return .inner children

def edit : Nat → Nat → Tree → Nat → Option Bytes → Option Tree
  | 0, _, _, _, _ => none
  | fuel+1, depth, tree, key, after => do
    match tree with
    | .opaque _ => none
    | .empty =>
      let some data := after | none
      if depth == 0 then
        return .inner ((List.replicate 16 .empty).set (digit key depth) (.leaf key data))
      else return .leaf key data
    | .leaf old data =>
      if old == key then return after.map (.leaf key) |>.getD .empty
      let some _ := after | none
      if depth ≥ 64 then none else
        let children := (List.replicate 16 .empty).set (digit old depth) (.leaf old data)
        let position := digit key depth
        let child ← edit fuel (depth+1) children[position]! key after
        return .inner (children.set position child)
    | .inner children =>
      if depth ≥ 64 || children.length != 16 then none else
        let position := digit key depth
        let child ← edit fuel (depth+1) children[position]! key after
        let changed := children.set position child
        if after.isNone then normalize (fuel+1) depth changed else return .inner changed

structure Change where
  key : Nat
  before : Option Bytes
  after : Option Bytes
  deriving DecidableEq, Repr

def apply (tree : Tree) (change : Change) : Option Tree := do
  let actual ← lookup 65 0 tree change.key
  if actual != change.before || (change.before.isNone && change.after.isNone) then none
  else edit 65 0 tree change.key change.after

def replay : Tree → List Change → Option Tree
  | tree, [] => some tree
  | tree, change::rest => do replay (← apply tree change) rest

inductive Execution : Tree → List Change → Tree → Prop where
  | nil (tree) : Execution tree [] tree
  | cons {before middle after change rest} : apply before change = some middle →
      Execution middle rest after → Execution before (change::rest) after

theorem Execution.replay_eq {before changes after} (execution : Execution before changes after) :
    replay before changes = some after := by
  induction execution with
  | nil => rfl
  | cons step _ ih => simp only [replay, step]; exact ih

theorem Execution.append {before middle after xs ys}
    (first : Execution before xs middle) (second : Execution middle ys after) :
    Execution before (xs ++ ys) after := by
  induction first with
  | nil => exact second
  | cons step _ ih => exact .cons step (ih second)

/-- A concrete certificate authenticates both endpoint trees and checks every
ordered compare-and-apply change. No hashing oracle is a hypothesis. -/
def LedgerTransition (parent expected : Hash) (changes : List Change) : Prop :=
  ∃ before after, Rooted parent before ∧ replay before changes = some after ∧ Rooted expected after

theorem certify {parent expected before after changes}
    (parentProof : Rooted parent before) (steps : Execution before changes after)
    (finalProof : Rooted expected after) : LedgerTransition parent expected changes :=
  ⟨before, after, parentProof, steps.replay_eq, finalProof⟩

end LeanXRPL.KernelMerkle
