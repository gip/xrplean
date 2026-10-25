import LeanXRPL.StateTree
import Lean.Data.Json

open Lean LeanXRPL

private def walk (repo : StateTree.Repository) (fuel : Nat) (path : Array Nat)
    (root : StateTree.Hash) : IO (Array Json) := do
  if root.isZero then return #[]
  match fuel with
  | 0 => throw <| IO.userError "state view exceeds radix depth"
  | fuel+1 =>
    match ← repo.load root with
    | .leaf key data =>
      unless keyHasPath key.bytes path do throw <| IO.userError "state view leaf path mismatch"
      return #[Json.mkObj [("index",.str (hex key.bytes)),("data",.str (hex data))]]
    | .inner children =>
      let mut result := #[]
      for i in [:16] do result := result ++ (← walk repo fuel (path.push i) children.toArray[i]!)
      return result

def main (args : List String) : IO UInt32 := do
  try
    let [source,root] := args | throw <| IO.userError "usage: state_view_probe SOURCES.json ROOT"
    let paths ← IO.ofExcept ((Json.parse (← IO.FS.readFile source)).bind Json.getArr?)
    let mut stores := #[]
    try
      for path in paths do stores := stores.push (← NodeStore.openReadOnly (← IO.ofExcept path.getStr?) 1099511627776)
      let some first := stores[0]? | throw <| IO.userError "empty state view"
      let repo ← StateTree.Repository.readOnly first 134217728 stores[1]?
      let root ← IO.ofExcept (StateTree.Hash.ofBytes (← IO.ofExcept (unhex root)))
      let result ← walk repo 65 #[] root
      IO.println (toJson result).compress
    finally stores.forM NodeStore.dispose
    return 0
  catch error =>
    (← IO.getStderr).putStrLn error.toString
    return 1
