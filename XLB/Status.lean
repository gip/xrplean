import XL.Rpc
import Std.Time.DateTime.Timestamp

namespace XLB.Status
open Lean LeanXRPL XL Std.Async

/-- Observations are shared by all bundles and expire five seconds after completion. -/
abbrev Cache := Std.Mutex (Option (Nat × Json))

def new : IO Cache := Std.Mutex.new none

private def optionalString (j : Json) (key : String) : Json :=
  match (j.getObjVal? key).bind Json.getStr? with
  | .ok value => str value
  | .error _ => .null

private def probe (c : Config) (stop : IO.Ref Bool) : IO Json := do
  let start ← IO.monoMsNow
  let mut fields := [("reachable",.bool false),("server_state",.null),("build_version",.null),
    ("complete_ledgers",.null),("validated_ledger",.null),("network_id",.null),
    ("network_compatible",.null),("error",.null)]
  try
    let response ← (Rpc.observe c (obj [("method",str "server_info"),
      ("params",toJson #[obj [("api_version",toJson (2:Nat))]])]) stop).block
    fields := ("reachable",.bool true)::fields.filter (·.1 != "reachable")
    let result ← get response "result"
    require (optString result "status" == "success" && !(result.getObjVal? "error").isOk)
      "xrpld server_info did not return success"
    let info ← get result "info"
    discard <| IO.ofExcept info.getObj?
    let reported := (info.getObjVal? "network_id")
    let (network, compatible) ← match reported with
      | .error _ => pure (Json.null, c.network == 0)
      | .ok value => do
        let some n := value.getNat?.toOption
          | throw <| IO.userError "malformed xrpld network_id"
        require (n ≤ 4294967295) "malformed xrpld network_id"
        pure (toJson n, n == c.network)
    let validated ← match info.getObjVal? "validated_ledger" with
      | .error _ => pure Json.null
      | .ok value => do
        let seq ← nat value "seq"
        index seq
        pure (obj [("seq",toJson seq),("hash",optionalString value "hash")])
    fields := [("reachable",.bool true),("server_state",optionalString info "server_state"),
      ("build_version",optionalString info "build_version"),("complete_ledgers",optionalString info "complete_ledgers"),
      ("validated_ledger",validated),("network_id",network),("network_compatible",.bool compatible),
      ("error",if compatible then .null else str "xrpld network does not match XLB configuration")]
  catch error =>
    fields := ("error",str error.toString)::fields.filter (·.1 != "error")
  let observed ← Std.Time.Timestamp.now
  return obj [("service",str "XLB"),("network_id",toJson c.network),
    ("xrpld",obj (("latency_ms",toJson ((← IO.monoMsNow)-start))::
      ("observed_at_unix",str (toString observed))::fields))]

def getStatus (cache : Cache) (c : Config) (stop : IO.Ref Bool) : IO Json :=
  cache.atomically do
    if let some (savedAt, value) ← get then
      if (← IO.monoMsNow)-savedAt < 5000 then return value
    let value ← probe c stop
    set (some (← IO.monoMsNow, value))
    return value

end XLB.Status
