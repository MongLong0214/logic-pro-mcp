import AppKit
import ApplicationServices

// #291 — do the inspector's routing slots DO anything when pressed?
//
// The first version of this probe only read `AXEnabled` and the advertised action list, and the
// record built on it asserted a refused press. A press that is never attempted is not a refusal
// that was observed, and this project has measured repeatedly that in this application a return
// code and a settability claim are not evidence of an effect. So the press happens here, and what
// is reported is the OBSERVED DIFFERENCE across it.
//
// A press that changes nothing is only evidence if the instrument could have seen a change, so
// every run also presses the MUTE button of the same strip and requires it to move. Without that,
// a probe aimed at the wrong element, a stale reference, or a signature that reads nothing useful
// all print exactly what a wall prints. The control mutates the project for about a second and
// presses again to restore; if it does not come back the run fails loudly rather than leaving a
// muted track behind.
//
// The observable is deliberately narrow. Counting the application's menus was tried on the insert
// slots and is not usable: the baseline drifts on its own (60 -> 65 with nothing pressed), so a
// change of one proves nothing. Menus are therefore listed BY TITLE and compared as a set.

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

guard let app = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    print("no Logic")
    exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
var wins: CFTypeRef?
AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wins)

func findStrip(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if d > 8 { return nil }
    if str(e, kAXRoleAttribute as String) == (kAXLayoutItemRole as String),
       str(e, kAXHelpAttribute as String).lowercased().hasPrefix("left inspector channel strip") {
        return e
    }
    for c in kids(e) { if let f = findStrip(c, d + 1) { return f } }
    return nil
}
var strip: AXUIElement?
for w in (wins as? [AXUIElement]) ?? [] { if let f = findStrip(w, 0) { strip = f; break } }
guard let strip else {
    print("no left inspector channel strip")
    exit(1)
}

/// What a press would have to change to have done anything visible at this element.
///
/// `AXValue` is stringified with `String(describing:)` rather than cast to `String`, because the
/// value that proves the control works ("off" -> "on") happens to be a string and a numeric one
/// would have been invisible to a cast. A signature that can only see one type is a signature that
/// reports "nothing changed" for the wrong reason.
func signature(_ e: AXUIElement) -> String {
    let value = attr(e, kAXValueAttribute as String).map { String(describing: $0) } ?? "nil"
    return "desc=\(str(e, kAXDescriptionAttribute as String))|value=\(value)"
        + "|children=\(kids(e).count)|stripChildren=\(kids(strip).count)"
}

/// Menus the application is showing, BY TITLE. A routing popup appearing here by name would be
/// unmistakable, and a reader can see for themselves that it did not.
func openMenuTitles() -> Set<String> {
    Set(kids(ax).filter { str($0, kAXRoleAttribute as String) == (kAXMenuRole as String) }
        .map { str($0, kAXTitleAttribute as String) })
}

/// Press one element and report what moved. Returns the observed difference.
@discardableResult
func press(_ e: AXUIElement, label: String) -> (rc: Int32, changed: Bool, appeared: [String]) {
    let before = signature(e)
    let menusBefore = openMenuTitles()
    let rc = AXUIElementPerformAction(e, kAXPressAction as CFString)
    // The press is asynchronous even when it returns .success; give the app a moment to put a
    // popup up before deciding it did not.
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let after = signature(e)
    let appeared = openMenuTitles().subtracting(menusBefore).sorted()
    print("  \(label): rc=\(rc.rawValue) changed=\(before != after) menusAppeared=\(appeared)")
    print("    before \(before)")
    print("    after  \(after)")
    if !appeared.isEmpty {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?
            .postToPid(app.processIdentifier)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?
            .postToPid(app.processIdentifier)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    return (rc.rawValue, before != after, appeared)
}

// ── the control ───────────────────────────────────────────────────────────────────────────────
// Same strip, same instrument, a button whose press is known to work. If this does not move, the
// run says nothing about the routing slots.
var controlMoved = false
if let mute = kids(strip).first(where: {
    str($0, kAXHelpAttribute as String).hasPrefix("Mute button")
}) {
    print("CONTROL Mute button")
    let out = press(mute, label: "press")
    controlMoved = out.changed
    let back = press(mute, label: "restore")
    if !back.changed {
        print("CONTROL FAIL: the mute press did not come back — leaving the project changed")
        exit(2)
    }
} else {
    print("CONTROL FAIL: no mute button on the strip to validate the instrument with")
    exit(2)
}
print("controlMoved=\(controlMoved)")

// ── the subjects ──────────────────────────────────────────────────────────────────────────────
var pressed = 0
var moved = 0
for c in kids(strip) {
    let help = str(c, kAXHelpAttribute as String)
    guard help.hasPrefix("Send slot") || help.hasPrefix("Output slot")
            || help.hasPrefix("Input slot") else { continue }
    var acts: CFArray?
    let s = AXUIElementCopyActionNames(c, &acts)
    let names = (acts as? [String]) ?? []
    let enabled = (attr(c, kAXEnabledAttribute as String) as? Bool).map(String.init) ?? "nil"
    print("\(help.prefix(11)) role=\(str(c, kAXRoleAttribute as String)) "
          + "enabled=\(enabled) actionsStatus=\(s.rawValue) actions=\(names)")
    guard names.contains(kAXPressAction as String) else {
        print("  press: NOT ADVERTISED — nothing to attempt")
        continue
    }
    let out = press(c, label: "press")
    pressed += 1
    if out.changed || !out.appeared.isEmpty { moved += 1 }
}
print("pressesAttempted=\(pressed) slotsThatMoved=\(moved)")
