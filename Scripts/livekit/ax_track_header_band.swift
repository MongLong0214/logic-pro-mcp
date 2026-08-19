// The arrange window's track-header rail, in window coordinates, emitted as JSON.
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

// Every measured AXDescription for the rail. Add by MEASUREMENT only — widening this to a substring
// or a structural guess is what made the earlier attempt return the Inspector.
let railDescriptions: Set<String> = ["Tracks header"]

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else { emit(["error": "logic not running"]) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
guard let win = ((attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []).first(where: {
    str($0, kAXSubroleAttribute as String) == (kAXStandardWindowSubrole as String)
}), let wf = frame(win) else { emit(["error": "no standard window"]) }

var rail: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) {
    guard d <= 18, rail == nil else { return }
    for c in kids(e) {
        if railDescriptions.contains(str(c, kAXDescriptionAttribute as String)) { rail = c; return }
        walk(c, d + 1)
        if rail != nil { return }
    }
}
walk(win, 0)

guard let r = rail, let rf = frame(r) else {
    emit(["error": "no element described as the track-header rail",
          "window": str(win, kAXTitleAttribute as String)])
}
emit([
    "window": str(win, kAXTitleAttribute as String),
    "description": str(r, kAXDescriptionAttribute as String),
    "band": [rf.0 - wf.0, rf.1 - wf.1, rf.2, rf.3],
])
