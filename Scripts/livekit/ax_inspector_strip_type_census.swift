// #766, second half: the track header carries no type signal — does the INSPECTOR channel strip?
//
//   ./ax_inspector_strip_type_census  ->  {"ok":true,"tracks":[{"name":…,"slots":[…]},…]}
//
// Selects each track header in turn and reads the left inspector channel strip that follows the
// selection, reporting which SLOTS the strip exposes. A slot is a property of the strip Logic
// built for that track, not prose about what a control does, so unlike the header help it can
// differ by kind.
//
// It restores the original selection before exiting, including on the paths that emit early.
//
// WHAT IT CANNOT RULE OUT: that the strip it read belongs to the track it selected. The strip is
// identified only by the inspector's "Left inspector channel strip" help and by following the
// selection, so this waits for the strip's own name to agree with the header's before reading and
// reports `settled:false` when it never does. A false agreement — two tracks with the same name —
// is not detectable here, which is why the name is reported alongside every row.
import AppKit
import ApplicationServices
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

/// Children, with "the read failed" kept apart from "there are none".
///
/// Collapsing both to `[]` is how an absence claim passes on an element nobody could read: a strip
/// whose child list is unreadable reports no slots, is classified `neither`, and the clause "NO
/// strip shows both slots" stays green over a strip that might show both. Found by review
/// 2026-09-08.
func kidsOrNil(_ e: AXUIElement) -> [AXUIElement]? {
    attr(e, kAXChildrenAttribute as String) as? [AXUIElement]
}
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) }

let LAYOUT = kAXLayoutItemRole as String
var container: AXUIElement?
var originalSelection: [AXUIElement] = []

func restoreSelection() {
    guard let container, !originalSelection.isEmpty else { return }
    AXUIElementSetAttributeValue(container, kAXSelectedChildrenAttribute as CFString,
                                 originalSelection as CFArray)
}
func emit(_ o: [String: Any]) -> Never {
    restoreSelection()
    print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]),
                 encoding: .utf8)!)
    exit(0)
}

func findFirst(_ root: AXUIElement, role wanted: String, identifier: String, maxDepth: Int) -> AXUIElement? {
    var found: AXUIElement?
    func walk(_ e: AXUIElement, _ d: Int) {
        guard d <= maxDepth, found == nil else { return }
        for c in kids(e) {
            if found != nil { return }
            if role(c) == wanted, str(c, kAXIdentifierAttribute as String) == identifier { found = c; return }
            walk(c, d + 1)
        }
    }
    walk(root, 1)
    return found
}
func findAll(_ root: AXUIElement, role wanted: String, maxDepth: Int) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        guard d <= maxDepth else { return }
        for c in kids(e) { if role(c) == wanted { out.append(c) }; walk(c, d + 1) }
    }
    walk(root, 1)
    return out
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else { emit(["ok": false, "error": "logic not running"]) }
let axApp = AXUIElementCreateApplication(app.processIdentifier)
let windows: [AXUIElement] = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { str($0, kAXSubroleAttribute as String) != "AXDialog" })
        ?? windows.first
else { emit(["ok": false, "error": "no window"]) }

if let a = findFirst(window, role: kAXListRole as String, identifier: "Track Headers", maxDepth: 30) {
    container = a
} else {
    for g in findAll(window, role: kAXGroupRole as String, maxDepth: 8) {
        let sel: [AXUIElement] = (attr(g, kAXSelectedChildrenAttribute as String) as? [AXUIElement]) ?? []
        if kids(g).contains(where: { role($0) == LAYOUT }), !sel.isEmpty { container = g; break }
    }
}
guard let container else { emit(["ok": false, "error": "track header container not located"]) }
originalSelection = (attr(container, kAXSelectedChildrenAttribute as String) as? [AXUIElement]) ?? []

let headers = kids(container).filter { role($0) == LAYOUT }
guard !headers.isEmpty else { emit(["ok": false, "error": "no track headers"]) }

// The strip is found by its own help sentence, re-read each time: the inspector rebuilds it.
func leftStrip() -> AXUIElement? {
    for item in findAll(window, role: LAYOUT, maxDepth: 8)
    where str(item, kAXHelpAttribute as String).hasPrefix("Left inspector channel strip") {
        return item
    }
    return nil
}

func quoted(_ s: String) -> String {
    guard let a = s.firstIndex(of: "\u{201C}"), let b = s.lastIndex(of: "\u{201D}"), a < b else { return s }
    return String(s[s.index(after: a)..<b])
}

var rows: [[String: Any]] = []
for header in headers {
    let name = quoted(str(header, kAXDescriptionAttribute as String))
    AXUIElementSetAttributeValue(container, kAXSelectedChildrenAttribute as CFString, [header] as CFArray)

    // Settle on the strip's OWN name, not on a timer: the inspector names the strip it rebuilt.
    var settled = false
    var polls = 0
    var strip: AXUIElement?
    while polls < 60 {
        polls += 1
        strip = leftStrip()
        if let s = strip, str(s, kAXDescriptionAttribute as String) == name { settled = true; break }
        usleep(50_000)
    }

    var slots: [String] = []
    var stripName = ""
    var childrenReadable = false
    if let s = strip {
        stripName = str(s, kAXDescriptionAttribute as String)
        guard let children = kidsOrNil(s) else {
            rows.append([
                "header": name, "stripName": stripName, "settled": settled, "polls": polls,
                "slots": [] as [String], "childrenReadable": false,
            ])
            continue
        }
        childrenReadable = true
        for c in children {
            let help = str(c, kAXHelpAttribute as String)
            guard let dot = help.firstIndex(of: ".") else { continue }
            let kind = String(help[help.startIndex..<dot])   // "MIDI Effect slot", "Input slot", …
            if kind.lowercased().contains("slot") { slots.append(kind) }
        }
    }
    rows.append([
        "header": name,
        "stripName": stripName,
        "settled": settled,
        "polls": polls,
        "slots": slots.sorted(),
        "childrenReadable": childrenReadable,
    ])
}

emit(["ok": true, "trackCount": headers.count, "tracks": rows])
