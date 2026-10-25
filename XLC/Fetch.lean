import XL.Http

namespace XLC.Fetch
open Lean XL

private def tenths (n : Nat) : String := s!"{n/10}.{n%10}"

private def lines (p : Json) : String × String × String := Id.run do
  let phase := optString p "phase"
  let amount := if phase == "complete" then 1000 else min 999 (optNat p "keyspace_permille")
  let filled := amount*24/1000
  let bar := String.ofList (List.replicate filled '=') ++
    (if filled < 24 then ">" ++ String.ofList (List.replicate (23-filled) ' ') else "")
  let label := match phase with
    | "checking_node" => "checking xrpld"
    | "fetching_ledger" => "fetching ledger"
    | "resuming" => "resuming saved state"
    | "downloading" => "downloading"
    | "building" => "building SHAMap"
    | "checking_root" => "checking root"
    | "complete" => "stored"
    | "peer_connecting" => "connecting to configured xrpld peer"
    | "peer_resuming" => "resuming saved peer checkpoint"
    | "peer_downloading" => "acquiring authenticated tree"
    | "rpc_fallback" => s!"falling back to ledger_data: {optString p "last_error"}"
    | "rpc_retry" => s!"RPC retry {optNat p "retry_attempt"} in {tenths (optNat p "retry_delay_ms"/100)}s: {optString p "last_error"}"
    | _ => phase
  let elapsed := optNat p "elapsed_ms"
  let entries := optNat p "entries"
  let peer := optString p "transport" == "peer"
  let extent := if peer && phase != "complete" then "tree size unknown" else s!"{tenths amount}% keyspace"
  let units := if peer then s!"{optNat p "nodes"} nodes | {optNat p "pending"} pending" else s!"{optNat p "pages"} pages"
  let timing := if peer then s!"peer {tenths (optNat p "peer_ms"/100)}s" else s!"RPC {tenths (optNat p "rpc_ms"/100)}s"
  let saved := if peer && (p.getObjVal? "resumed").toOption == some (.bool true) then
    s!" | {optNat p "checkpoint_entries"} saved at resume" else ""
  let rate := if peer then optNat p "run_entries"*1000/(max 1 (optNat p "run_elapsed_ms"))
    else entries*1000/(max 1 elapsed)
  let clock := if peer then s!"{elapsed/1000}s this run" else s!"{elapsed/1000}s"
  return (s!"Ledger {optNat p "ledger_index"} ({optNat p "ledger_number" 1}/{optNat p "ledgers_total" 1}) [{bar}] {extent}",
    s!"{entries} entries{saved} | {units} | {tenths (optNat p "state_bytes"*10/1048576)} MiB | {clock} | {rate}/s",
    s!"{timing} | local {tenths (optNat p "local_ms"/100)}s | {label}")

/-- Progress goes to stderr; the caller prints only the final JSON result to stdout. -/
def run (url : String) (body : Json) (route : String := "/fetch/stream") : IO Json := do
  let stderr ← IO.getStderr
  let tty ← stderr.isTty
  let activeLine ← IO.mkRef false
  let lastPrinted ← IO.mkRef (none : Option Nat)
  let printedEntries ← IO.mkRef false
  let result ← IO.mkRef (none : Option Json)
  try
    Http.streamRequest (url ++ route) body fun event => do
      match optString event "event" with
      | "progress" =>
        let now ← IO.monoMsNow
        let phase := optString event "phase"
        let important := phase == "checking_root" || phase == "complete" || phase == "peer_resuming" || phase == "rpc_retry" || phase == "rpc_fallback"
        let last ← lastPrinted.get
        let firstEntries := optNat event "entries" > 0 && !(← printedEntries.get)
        if tty || last.isNone || important || firstEntries || now-last.getD 0 ≥ 1000 then
          let (heading,details,timing) := lines event
          if tty then
            if ← activeLine.get then stderr.putStr "\r\x1b[2A"
            stderr.putStr ("\r\x1b[2K" ++ heading ++ "\n\r\x1b[2K" ++ details ++ "\n\r\x1b[2K" ++ timing)
            activeLine.set true
            if phase == "complete" then stderr.putStr "\n"; activeLine.set false
          else stderr.putStrLn (heading ++ " | " ++ details ++ " | " ++ timing)
          stderr.flush
          lastPrinted.set (some now)
          if optNat event "entries" > 0 then printedEntries.set true
      | "result" =>
        require (← result.get).isNone "duplicate fetch result"
        result.set (some (← get event "data"))
      | "error" => throw <| IO.userError (← string event "error")
      | _ =>
        throw <| IO.userError s!"XLB progress endpoint unavailable: {event.compress}. Restart XLB with the rebuilt executable, or use --no-progress."
    let some data ← result.get | throw <| IO.userError "fetch stream ended without a final result"
    return data
  finally
    if ← activeLine.get then stderr.putStr "\n"; stderr.flush

end XLC.Fetch
