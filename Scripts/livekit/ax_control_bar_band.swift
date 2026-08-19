// A NAMED region of the arrange window, in window coordinates, emitted as JSON with the name it
// matched — so a caller can state what the band IS, not only where it is.
//
//   ./ax_control_bar_band "<AXDescription>" [--role R] [--min-width N] [--min-height N]
//
// An AXDescription is NOT unique. Measured on this window: "Control Bar" matches two elements,
// "Library" four, "Event" three. The first version walked depth-first and returned whichever it
// reached first, which is first-match dressed as identity — the same defect this file exists to
// remove from the harnesses. It now REFUSES when more than one element survives the filters and
// prints all of them, so the caller adds a discriminator it can state out loud rather than
// inheriting one from tree order.
//
// A band written as coordinates is not defined by its content: the top-left 240x28 of the arrange
// window is the track-name column with the Mixer closed and a column of mixer strips with it open,
// and mixer strips carry level meters and selection highlights that move on their own. A negative
// visual assertion over that is a coin flip.
//
// An earlier attempt at this (closed unmerged) took "the first AXLayoutItem with a text-field child"
// and returned its grandparent, which is the INSPECTOR channel strip — it reported 366,527 235x522
// with a parent described "Mixer". The rail is identified by AXDescription and by nothing else:
// measured 2026-08-19, every container of AXLayoutItem rows in the arrange window also exposes
// AXSelectedChildren, so that structure does not separate them either.
//
//     AXLayoutArea "Mixer"              366,527   235x522
//     AXLayoutArea "Tracks time ruler"  928,124   977x38
//     AXGroup      "Tracks header"      603,116   325x295   <- the rail
//
// An unrecognised description emits nothing, which a caller must treat as a failed precondition
// rather than a reason to fall back to a rectangle.
import ApplicationServices
import AppKit
import Foundation

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func frame(_ e: AXUIElement) -> (Int, Int, Int, Int)? {
    guard let pv = attr(e, kAXPositionAttribute as String),
          let sv = attr(e, kAXSizeAttribute as String) else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return (Int(p.x), Int(p.y), Int(s.width), Int(s.height))
}
func emit(_ o: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
                 encoding: .utf8)!)
    exit(0)
}

// The default region. An argument overrides it, and the match is always the EXACT AXDescription —
// widening to a substring or a structural guess is what made the earlier attempt return the
// Inspector. Whatever is passed, the emitted `description` is read back off the element that was
// found, so the caller names what was measured rather than what was requested.
//
// Three different regions of the document view were tried as a negative control and all three
// failed the same way: quiet at rest, different after the run. Bisected, the last one differed in
// EVERY vertical slice — the arrange view scrolls when a modal takes and returns focus, so no part
// of the document is invariant across a refusal. The two earlier attempts (full-width top strip,
// then the leftmost column) each failed for a narrower version of the same reason.
//
// The claim a refusal that writes nothing CAN keep is that it did not touch the transport. The
// control bar is chrome rather than document, so it does not scroll with the arrange, and its clock
// only advances while the transport is running — which the quiet probe checks before this is used.
let argv = CommandLine.arguments
let wanted = argv.count > 1 && !argv[1].isEmpty ? argv[1] : "Control Bar"
func flag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), argv.count > i + 1 else { return nil }
    return argv[i + 1]
}
let wantRole = flag("--role")
let minWidth = Int(flag("--min-width") ?? "0") ?? 0
let minHeight = Int(flag("--min-height") ?? "0") ?? 0

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else { emit(["error": "logic not running"]) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
guard let win = ((attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []).first(where: {
    str($0, kAXSubroleAttribute as String) == (kAXStandardWindowSubrole as String)
}), let wf = frame(win) else { emit(["error": "no standard window"]) }

var hits: [AXUIElement] = []
func walk(_ e: AXUIElement, _ d: Int) {
    guard d <= 18 else { return }
    for c in kids(e) {
        if str(c, kAXDescriptionAttribute as String) == wanted,
           let f = frame(c),
           f.2 >= minWidth, f.3 >= minHeight,
           wantRole == nil || str(c, kAXRoleAttribute as String) == wantRole {
            hits.append(c)
        }
        walk(c, d + 1)
    }
}
walk(win, 0)

func describeHit(_ e: AXUIElement) -> [String: Any] {
    let f = frame(e) ?? (0, 0, 0, 0)
    return ["role": str(e, kAXRoleAttribute as String),
            "band": [f.0 - wf.0, f.1 - wf.1, f.2, f.3]]
}
if hits.count > 1 {
    emit(["error": "AXDescription is ambiguous — add --role / --min-width / --min-height",
          "wanted": wanted, "matches": hits.map(describeHit),
          "window": str(win, kAXTitleAttribute as String)])
}
guard let r = hits.first, let rf = frame(r) else {
    emit(["error": "no element with that exact AXDescription",
          "wanted": wanted,
          "window": str(win, kAXTitleAttribute as String)])
}
// `candidates` on the SUCCESS path, not only in the ambiguity error. Refusing when there are two
// is half the job; the other half is that "there was exactly one" reaches the record. Otherwise a
// later reader still cannot tell a discriminator from tree order — which is the whole defect.
emit([
    "window": str(win, kAXTitleAttribute as String),
    "description": str(r, kAXDescriptionAttribute as String),
    "role": str(r, kAXRoleAttribute as String),
    "candidates": hits.count,
    "band": [rf.0 - wf.0, rf.1 - wf.1, rf.2, rf.3],
])
