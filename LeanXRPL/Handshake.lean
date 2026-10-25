import Lean.Data.Json
import Std.Time
import LeanXRPL.Encoding
import LeanXRPL.Peer

namespace LeanXRPL

structure HttpResponse where
  status : Nat
  headers : List (String × String)
  tail : ByteArray
  deriving Inhabited

def HttpResponse.header (r : HttpResponse) (name : String) : String :=
  ((r.headers.find? (fun p => p.1 == name.toLower)).map Prod.snd).getD ""

/-- Bounded header parse; the tail includes already-received overlay bytes. -/
def parseHttp (bytes : ByteArray) (allowRepeated := false) : ParseResult (Option HttpResponse) := do
  let mut endPos : Option Nat := none
  for i in [:min bytes.size 32772] do
    if i+3 < bytes.size && bytes[i]! == 13 && bytes[i+1]! == 10 &&
        bytes[i+2]! == 13 && bytes[i+3]! == 10 then
      endPos := some (i+4)
      break
  let some headerEnd := endPos | do
    if bytes.size > 32768 then throw "HTTP header too large"
    return none
  if headerEnd > 32768 then throw "HTTP header too large"
  let some text := String.fromUTF8? (bytes.extract 0 (headerEnd-4)) | throw "invalid HTTP text"
  let lines := text.splitOn "\r\n"
  let first := lines.head!
  let words := first.splitOn " "
  if words.head! != "HTTP/1.1" && words.head! != "HTTP/1.0" then throw "invalid HTTP version"
  let some status := words[1]?.bind String.toNat? | throw "invalid HTTP status"
  let mut headers := []
  for line in lines.tail do
    let parts := line.splitOn ":"
    if parts.length < 2 then throw "invalid HTTP header"
    let name := parts.head!.toLower
    if name.isEmpty || name.toList.any (fun c => !(c.isAlphanum || c == '-')) then
      throw "invalid HTTP header name"
    if headers.any (fun p => p.1 == name) &&
        (!allowRepeated || name == "content-length" || name == "transfer-encoding" || name == "content-encoding") then
      throw "duplicate HTTP header"
    headers := (name, (String.intercalate ":" parts.tail).trimAscii.toString) :: headers
  return some ⟨status, headers, bytes.extract headerEnd bytes.size⟩

def sessionDigest (localFinished peerFinished : ByteArray) : IO ByteArray := do
  if localFinished.size < 12 || peerFinished.size < 12 then throw <| IO.userError "short TLS Finished"
  let a ← Native.sha512 localFinished
  let b ← Native.sha512 peerFinished
  let mixed := ByteArray.mk (a.data.zipWith (fun x y => x ^^^ y) b.data)
  if mixed.data.all (· == 0) then throw <| IO.userError "identical TLS Finished messages"
  Native.sha512Half mixed

def networkTime : IO Nat := do
  return (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.toInt.toNat - 946684800

def makeUpgrade (key : Native.NodeKey) (digest : ByteArray) (host : String)
    (networkID : Nat) : IO ByteArray := do
  let pub ← base58CheckEncode 28 (← Native.keyPublic key)
  let sig ← Native.keySign key digest
  let cookie := (← Native.random 8).data.foldl (fun n b => n*256+b.toNat) 0
  return (String.intercalate "\r\n" ["GET / HTTP/1.1", s!"Host: {host}",
    "User-Agent: leanxrpl/0.1", "Upgrade: XRPL/2.1, XRPL/2.2", "Connection: Upgrade",
    "Connect-As: Peer", "Crawl: private", "X-Protocol-Ctl:", s!"Network-ID: {networkID}",
    s!"Network-Time: {← networkTime}", s!"Public-Key: {pub}",
    s!"Session-Signature: {base64Encode sig}", s!"Instance-Cookie: {cookie}", "", ""]).toUTF8

def verifyUpgrade (r : HttpResponse) (digest : ByteArray) (selfPublic : ByteArray)
    (networkID now : Nat) (remote : Std.Net.IPAddr) : IO String := do
  if r.status != 101 then throw <| IO.userError s!"HTTP upgrade rejected: {r.status}"
  let protocol := r.header "upgrade"
  if protocol != "XRPL/2.1" && protocol != "XRPL/2.2" then
    throw <| IO.userError s!"unsupported negotiated protocol: {protocol}"
  if !((r.header "connection").toLower.splitOn ",").any (fun v => v.trimAscii == "upgrade") ||
      (r.header "connect-as").toLower != "peer" then throw <| IO.userError "invalid peer upgrade"
  if !(r.header "x-protocol-ctl").isEmpty then throw <| IO.userError "unsolicited protocol features"
  let nid := r.header "network-id"
  if !nid.isEmpty then
    if nid.toNat? != some networkID then throw <| IO.userError "peer network mismatch"
  else if networkID != 0 then throw <| IO.userError "peer omitted non-Mainnet network ID"
  let time := r.header "network-time"
  if !time.isEmpty then
    let some time := time.toNat? | throw <| IO.userError "invalid network time"
    if (Int.ofNat time - Int.ofNat now).natAbs > 20 then throw <| IO.userError "peer clock mismatch"
  let localIP := r.header "local-ip"
  if !localIP.isEmpty then
    let e : Endpoint := ⟨localIP, 1, false⟩
    let some ip := endpointIP e | throw <| IO.userError "invalid peer Local-IP"
    if publicIP remote && ip != remote then throw <| IO.userError "peer Local-IP mismatch"
  let pubString := r.header "public-key"
  let pub ← base58CheckDecode 28 pubString
  if pub.size != 33 || (pub[0]! != 2 && pub[0]! != 3) || pub == selfPublic then
    throw <| IO.userError "invalid or self node public key"
  let signature ← IO.ofExcept (base64Decode (r.header "session-signature"))
  if !(← Native.verify pub digest signature) then throw <| IO.userError "peer session signature failed"
  return pubString

def parseRedirects (body : ByteArray) : ParseResult (Array Endpoint) := do
  let text ← match String.fromUTF8? body with | some s => pure s | none => throw "invalid redirect text"
  let json ← Lean.Json.parse text
  let ips ← (← json.getObjVal? "peer-ips").getArr?
  let mut out := #[]
  for item in ips[:min ips.size 256] do
    if let .ok s := item.getStr? then
      if let .ok e := parseEndpoint s then
        if admissibleDiscovered e then out := out.push e
  return out

end LeanXRPL
