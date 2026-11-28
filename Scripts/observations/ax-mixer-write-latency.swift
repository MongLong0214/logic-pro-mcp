// Reverify for docs/observations/2026-11-29-logic13-association-coverage.json
// usage: swift Scripts/observations/ax-mixer-write-latency.swift <substring of the fixture copy path> <iterations> <light|load>
import ApplicationServices
import AppKit
import Foundation
// axlate <docSubstring> <iterations> <light|load> [pollSleepMs]
// Measures how long Logic takes to apply a Mixer AXSelectedChildren write. Aborts (exit 3) before any write
// unless the main window's AXDocument contains <docSubstring>. Each iteration writes a different strip, polls until
// header/selected child/focus land (or 10 s), then writes the original strip back and polls the same way.
// "load" additionally walks the whole main window (depth 32, scrollbars) between polls, the way the product's census does.
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as AnyObject? : nil }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, "AXChildren") as? [AXUIElement]) ?? [] }
func str(_ e: AXUIElement, _ a: String) -> String { attr(e, a).map { "\($0)" } ?? "" }
func names(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyAttributeNames(e, &n); return (n as? [String]) ?? [] }
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
let args = CommandLine.arguments
let docSub = args[1], iterations = Int(args[2])!, loadMode = args[3] == "load"
let pollSleep = args.count > 4 ? Double(args[4])! : 0
let railMode = args.count > 5 && args[5] == "rail"
let pollWindow = args.count > 6 ? Double(args[6])! : 10000
let app = AXUIElementCreateApplication(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.logic10" }!.processIdentifier)
func mainWindow() -> AXUIElement? { ((attr(app, "AXWindows") as? [AXUIElement]) ?? []).first { str($0, "AXMain") == "1" } }
guard let win = mainWindow(), str(win, "AXDocument").contains(docSub) else { print("{\"abort\":\"front document is not the fixture copy: \(mainWindow().map { str($0, "AXDocument") } ?? "none")\"}"); exit(3) }
var rail: AXUIElement?; var mixers: [AXUIElement] = []
func find(_ e: AXUIElement, _ d: Int) {
  if d > 16 { return }
  let role = str(e, "AXRole")
  if rail == nil && role == "AXGroup" {
    let k = kids(e)
    if !k.isEmpty && k.allSatisfy({ str($0, "AXRole") == "AXLayoutItem" && kids($0).contains { str($0, "AXRole") == "AXRadioButton" } }) { rail = e; return }
  }
  if role == "AXLayoutArea" && !kids(e).isEmpty && kids(e).allSatisfy({ str($0, "AXRole") == "AXLayoutItem" }) && names(e).contains("AXSelectedChildren") { mixers.append(e) }
  for c in kids(e) { find(c, d + 1) }
}
find(win, 0)
guard let rail, let mixer = mixers.max(by: { kids($0).count < kids($1).count }) else { print("{\"abort\":\"rail/mixer not found\"}"); exit(2) }
let headers = kids(rail), strips = kids(mixer)
func headerSel() -> Int { var sel = -1; for (i, h) in headers.enumerated() where str(h, "AXSelected") == "1" { sel = sel == -1 ? i : -2 }; return sel }
func mixerSel() -> Int { let s = (attr(mixer, "AXSelectedChildren") as? [AXUIElement]) ?? []; if s.count != 1 { return -2 }; return strips.firstIndex { CFEqual($0, s[0]) } ?? -3 }
func focusIdx() -> Int { guard let f = attr(app, "AXFocusedUIElement") else { return -1 }; return strips.firstIndex { CFEqual($0, f as! AXUIElement) } ?? -3 }
func census() { var n = 0; func walk(_ e: AXUIElement, _ d: Int) { if d > 32 { return }; if str(e, "AXRole") == "AXScrollBar" { n += 1 }; for c in kids(e) { walk(c, d + 1) } }; walk(win, 0) }
struct Landing { var write: Double; var header: Double?; var child: Double?; var focus: Double?; var polls: Int; var rc: Int32; var settledAll: Double?; var timeout: Bool }
func doWrite(_ target: Int, timeoutMs: Double = pollWindow) -> Landing {
  guard str(mainWindow() ?? win, "AXDocument").contains(docSub) else { print("{\"abort\":\"front document changed\"}"); exit(4) }
  let t0 = now()
  let rc = railMode ? AXUIElementSetAttributeValue(rail, "AXSelectedChildren" as CFString, [headers[target]] as CFArray) : AXUIElementSetAttributeValue(mixer, "AXSelectedChildren" as CFString, [strips[target]] as CFArray)
  let t1 = now()
  var l = Landing(write: t1 - t0, header: nil, child: nil, focus: nil, polls: 0, rc: rc.rawValue, settledAll: nil, timeout: false)
  while now() - t1 < timeoutMs {
    if loadMode { census() }
    let h = headerSel(), c = mixerSel(), f = focusIdx(); let t = now() - t1; l.polls += 1
    if l.header == nil && h == target { l.header = t }
    if l.child == nil && c == target { l.child = t }
    if l.focus == nil && f == target { l.focus = t }
    if l.header != nil && l.child != nil && l.focus != nil { l.settledAll = t; return l }
    if l.header != nil && l.child != nil && t > max(l.header!, l.child!) + 1500 { return l }   // focus may stay on the rail
    if pollSleep > 0 { Thread.sleep(forTimeInterval: pollSleep / 1000) }
  }
  l.timeout = true; return l
}
func js(_ l: Landing, _ extra: [String: Any]) -> String {
  var d: [String: Any] = ["write_ms": l.write, "polls": l.polls, "rc": Int(l.rc), "timeout": l.timeout]
  if let v = l.header { d["header_ms"] = v }; if let v = l.child { d["child_ms"] = v }; if let v = l.focus { d["focus_ms"] = v }
  for (k, v) in extra { d[k] = v }
  return String(data: try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), encoding: .utf8)!
}
let startH = headerSel(), startM = mixerSel()
print("{\"start\":{\"header\":\(startH),\"mixer\":\(startM),\"focus\":\(focusIdx()),\"headers\":\(headers.count),\"strips\":\(strips.count),\"load\":\(loadMode)}}")
guard startH >= 0, startH == startM else { print("{\"abort\":\"start state not a single reciprocal selection\"}"); exit(5) }
let origin = startH
for it in 0..<iterations {
  let others = (0..<headers.count).filter { $0 != origin }
  let target = others[it % others.count]
  let a = doWrite(target)
  print("{\"iter\":\(it),\"dir\":\"challenge\",\"target\":\(target),\"landing\":\(js(a, [:]))}")
  let b = doWrite(origin)
  print("{\"iter\":\(it),\"dir\":\"restore\",\"target\":\(origin),\"landing\":\(js(b, [:]))}")
  if headerSel() != origin || mixerSel() != origin { print("{\"final\":\"NOT_RESTORED\",\"header\":\(headerSel()),\"mixer\":\(mixerSel())}"); exit(6) }
  Thread.sleep(forTimeInterval: 0.3)
}
print("{\"final\":\"restored\",\"header\":\(headerSel()),\"mixer\":\(mixerSel())}")
