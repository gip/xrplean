import LeanXRPL.StateTree

namespace LeanXRPL.StateIngest
open Lean

def string (j : Json) (field : String) : IO String := IO.ofExcept ((j.getObjVal? field).bind Json.getStr?)
def nat (j : Json) (field : String) : IO Nat := IO.ofExcept ((j.getObjVal? field).bind Json.getNat?)
def array (j : Json) (field : String) : IO (Array Json) := IO.ofExcept ((j.getObjVal? field).bind Json.getArr?)
def hash (j : Json) (field : String) : IO ByteArray := do
  let bytes ← IO.ofExcept (unhex (← string j field))
  unless bytes.size == 32 do throw <| IO.userError s!"invalid {field}"
  return bytes
private def image (j : Json) (field : String) : IO (Option ByteArray) := do
  let v ← IO.ofExcept (j.getObjVal? field)
  if v == .null then return none
  let bytes ← IO.ofExcept (unhex (← string v "blob"))
  unless bytes.size ≥ 12 && bytes.size ≤ 2097152-33 do throw <| IO.userError "state image size limit"
  return some bytes
private def changes (j : Json) : IO (Array StateTree.Change) := do
  (← array j "changes").mapM fun c => do
    let key ← IO.ofExcept (StateTree.ObjectID.ofBytes (← hash c "key"))
    let before ← image c "before"
    let after ← image c "after"
    let op ← string c "operation"
    unless (op == "insert" && before.isNone && after.isSome) ||
      (op == "modify" && before.isSome && after.isSome) ||
      (op == "delete" && before.isSome && after.isNone) do
      throw <| IO.userError "state change operation/images disagree"
    return ⟨key,before,after⟩

structure Export where
  sequence : Nat
  hash : ByteArray
  parentHash : ByteArray
  parentRoot : StateTree.Hash
  root : StateTree.Hash
  network : Nat
  changes : Array StateTree.Change
  payload : String

/-- Opaque object replay, independent of transaction-rule/proof coverage. -/
def decode (j : Json) (network : Nat) : IO Export := do
  unless (← nat j "schema_version") == 1 && (← string j "stage") == "accepted" do
    throw <| IO.userError "unsupported export schema/stage"
  let sequence ← nat j "ledger_index"
  unless sequence > 0 && sequence ≤ 4294967295 && (← nat j "network_id") == network do
    throw <| IO.userError "export sequence/network mismatch"
  let hash ← hash j "ledger_hash"
  let parentHash ← StateIngest.hash j "parent_ledger_hash"
  let parentRoot ← IO.ofExcept (StateTree.Hash.ofBytes (← StateIngest.hash j "parent_state_root"))
  let root ← IO.ofExcept (StateTree.Hash.ofBytes (← StateIngest.hash j "state_root"))
  let pre ← changes (Json.mkObj [("changes",← IO.ofExcept (j.getObjVal? "pre_transaction_changes"))])
  let txs ← (← array j "transactions").mapM fun tx => do
    let index ← nat tx "TransactionIndex"
    let id ← StateIngest.hash tx "hash"
    let raw ← IO.ofExcept (unhex (← string tx "transaction_blob"))
    unless raw.size > 0 && raw.size ≤ 1048576 && (← Native.sha512Half (hashPrefix "TXN" ++ raw)) == id do
      throw <| IO.userError "export transaction ID mismatch"
    discard <| IO.ofExcept (unhex (← string tx "metadata_blob"))
    return (index, id, ← changes tx)
  let txs := txs.qsort (fun a b => a.1 < b.1)
  let mut all := pre
  let mut seen : Std.HashSet ByteArray := {}
  for i in [:txs.size] do
    let (index,id,cs) := txs[i]!
    unless index == i && !seen.contains id do throw <| IO.userError "export transaction order/duplicate mismatch"
    seen := seen.insert id
    all := all ++ cs
  all := all ++ (← changes (Json.mkObj [("changes",← IO.ofExcept (j.getObjVal? "post_transaction_changes"))]))
  return ⟨sequence,hash,parentHash,parentRoot,root,network,all,j.compress⟩

end LeanXRPL.StateIngest
