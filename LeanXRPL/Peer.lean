import Std.Net
import LeanXRPL.Protocol

namespace LeanXRPL
open Std.Net

structure Endpoint where
  host : String
  port : UInt16
  explicit : Bool := false
  deriving Inhabited, BEq

def Endpoint.toString (e : Endpoint) : String :=
  (if e.host.contains ':' then s!"[{e.host}]" else e.host) ++ s!":{e.port}"
instance : ToString Endpoint := ⟨Endpoint.toString⟩

def parseEndpoint (s : String) (explicit := false) : ParseResult Endpoint := do
  let (host, port) ← if s.startsWith "[" then
      match (s.drop 1).toString.splitOn "]:" with
      | [h, p] => pure (h, p)
      | _ => throw "invalid bracketed endpoint"
    else match s.splitOn ":" with
      | [h, p] => pure (h, p)
      | _ => throw "expected host:port (bracket IPv6)"
  if host.isEmpty || host.length > 253 || host.toList.any (fun c => c.isWhitespace || c.toNat < 33) then
    throw "invalid endpoint host"
  let some port := port.toNat? | throw "invalid endpoint port"
  if port == 0 || port > 65535 then throw "endpoint port out of range"
  return ⟨host.toLower, port.toUInt16, explicit⟩

/-- Conservative public-unicast filter, including mapped IPv4 and documentation ranges. -/
def publicIP : IPAddr → Bool
  | .v4 a =>
    let x := a.octets[0].toNat
    let y := a.octets[1].toNat
    let z := a.octets[2].toNat
    !(x == 0 || x == 10 || x == 127 || x ≥ 224 ||
      x == 169 && y == 254 || x == 172 && y ≥ 16 && y ≤ 31 ||
      x == 192 && (y == 168 || y == 0 || y == 2) ||
      x == 100 && y ≥ 64 && y ≤ 127 || x == 198 && (y == 18 || y == 19) ||
      x == 198 && y == 51 && z == 100 || x == 203 && y == 0 && z == 113)
  | .v6 a =>
    let first := a.segments[0].toNat
    first ≥ 0x2000 && first < 0x4000 &&
      !(first == 0x2001 && (a.segments[1].toNat < 0x200 || a.segments[1].toNat == 0xdb8)) &&
      first != 0x2002 && !(first == 0x3fff && a.segments[1].toNat < 0x1000)

def endpointIP (e : Endpoint) : Option IPAddr :=
  match IPv4Addr.ofString e.host with
  | some a => some (.v4 a)
  | none => (IPv6Addr.ofString e.host).map IPAddr.v6

def admissibleDiscovered (e : Endpoint) : Bool :=
  (endpointIP e).any publicIP

def decodeEndpoints (b : ByteArray) (remote : Option IPAddr := none) : ParseResult (Array Endpoint) := do
  let fs ← parseProto b
  if protoNat fs 1 != some 2 then throw "unsupported endpoint message version"
  let mut out := #[]
  for f in fs do
    if f.number == 3 && out.size < 256 then
      match f.value with
      | .bytes value =>
        let item ← parseProto value
        let some raw := protoBytes item 1 | throw "endpoint missing address"
        let some hops := protoNat item 2 | throw "endpoint missing hops"
        if hops ≤ 6 then
          if let .ok e := parseEndpoint (String.fromUTF8! raw) then
            -- A hop-zero advertisement names the connected peer, even when its host is unspecified.
            let e := if hops == 0 then
              (remote.map (fun ip => { e with host := toString ip })).getD e
              else e
            if admissibleDiscovered e then out := out.push e
      | _ => throw "invalid endpoint wire type"
  return out

def defaultSeeds : Array Endpoint := #[
  ⟨"r.ripple.com", 51235, false⟩,
  ⟨"sahyadri.isrdc.in", 51235, false⟩,
  ⟨"hubs.xrpkuwait.com", 51235, false⟩,
  ⟨"hub.xrpl-commons.org", 51235, false⟩]

structure Candidate where
  endpoint : Endpoint
  failures : Nat := 0
  retryAt : Nat := 0
  busy : Bool := false
  deriving Inhabited

structure PeerPool where
  candidates : Array Candidate := #[]
  identities : Array String := #[]
  connecting : Nat := 0
  active : Nat := 0
  deriving Inhabited

def PeerPool.add (p : PeerPool) (e : Endpoint) : PeerPool :=
  if p.candidates.any (fun c => c.endpoint.host == e.host && c.endpoint.port == e.port) then p
  else if p.candidates.size < 256 then { p with candidates := p.candidates.push ⟨e, 0, 0, false⟩ }
  else
    -- Retire repeatedly failing discovered candidates without changing any active worker's index.
    let victim := p.candidates.findIdx? (fun c => !c.busy && !c.endpoint.explicit && c.failures ≥ 3)
    match victim with
    | some i => { p with candidates := p.candidates.set! i ⟨e, 0, 0, false⟩ }
    | none => p

def retryDelay (failures jitter : Nat) : Nat :=
  min 300000 (1000 * 2^(min failures 9)) + jitter % 1000

end LeanXRPL
