// Read the Event pane's table header the way the product reads it, and report every cell.
//
//   ./ax_event_list_header_cells   ->  {"ok":true,"headerCells":[{"role":"AXButton","subrole":"AXSortButton","title":"Position",…}],…}
//
// `EventListReadbackCollector.readHeaders` takes the table's `AXHeader`, keeps the children whose
// subrole is `AXSortButton`, and matches their `AXTitle` against a locale label set. This walks the
// same path from outside, so a coverage claim in `docs/locale/ui-labels.json` can name the role and
// the attribute the product actually uses rather than a role that merely happened to carry the
// string somewhere else.
//
// It also reports `AXColumns` and `AXRows` counts, because `AXColumnTitles` is unsupported on this
// table — it answers -25205 — and a reader that went looking for the titles there would find
// nothing and could not tell that from an empty table.
//
// WHAT IT CANNOT RULE OUT: which LEVEL the Event List is showing. Logic uses a six-column schema
// for the region list and an eight-column one for a region's events, and this reports whichever is
// on screen. The caller decides which it wanted; this only says what was there.

import AppKit
import ApplicationServices
import Foundation
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }; return v }
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
// Children, counting the reads that FAILED rather than collapsing them into "there are none".
// A failed child read contributes nothing and looks exactly like an element with no children;
// `noValue` and `attributeUnsupported` are real answers and are not counted.
var childReadFailures = 0
func kids(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    if err == .success { return (v as? [AXUIElement]) ?? [] }
    if err == .noValue || err == .attributeUnsupported { return [] }
    childReadFailures += 1
    return []
}
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) }
func emit(_ o: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!); exit(0) }
guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "").contains("logic") }) else { emit(["ok": false, "error": "no logic"]) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
let ws: [AXUIElement] = (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
guard let w = ws.first(where: { str($0, kAXSubroleAttribute as String) != "AXDialog" }) ?? ws.first else { emit(["ok": false, "error": "no window"]) }
// The Event pane's table: the one whose ancestor group carries the Event tab's label. The spellings
// are `AXLocalePolicy.eventListTab`'s canonical and variants, measured rather than translated —
// the collector could not START outside English until #712 replaced this same literal, and a probe
// that hardcodes `Event` reproduces the bug it is meant to observe around.
let EVENT_PANE_LABELS: Set<String> = ["event", "\u{C774}\u{BCA4}\u{D2B8}", "\u{30A4}\u{30D9}\u{30F3}\u{30C8}"]
var tables: [AXUIElement] = []
func find(_ e: AXUIElement, _ d: Int, _ underEvent: Bool) {
    guard d <= 16 else { return }
    for c in kids(e) {
        let label = str(c, kAXDescriptionAttribute as String)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isEvent = underEvent || EVENT_PANE_LABELS.contains(label)
        if isEvent, role(c) == kAXTableRole as String { tables.append(c) }
        find(c, d + 1, isEvent)
    }
}
find(w, 1, false)
guard let table = tables.first else { emit(["ok": false, "error": "no table under the Event pane"]) }
guard let hv = attr(table, kAXHeaderAttribute as String) else { emit(["ok": false, "error": "table has no AXHeader"]) }
let header = hv as! AXUIElement
let children = kids(header)
var rows: [[String: Any]] = []
for c in children {
    rows.append([
        "role": role(c),
        "subrole": str(c, kAXSubroleAttribute as String),
        "title": str(c, kAXTitleAttribute as String),
        "description": str(c, kAXDescriptionAttribute as String),
        "value": str(c, kAXValueAttribute as String),
        // The instrument states WHERE it looked, so a reader of this file does not have to infer
        // it from the record that cites it. `check-locale-labels-json.py` refuses a row that
        // cannot say which surface it came from whenever a label scopes its evidence, and a row
        // tagged after the fact would not be a reading any more.
        "surface": "editor.event_list",
        "path": "AXWindow > AXGroup[Event] > AXScrollArea > AXTable > AXHeader",
    ])
}
let cols = (attr(table, "AXColumns") as? [AXUIElement]) ?? []
emit([
    "ok": true,
    "tablesUnderEventPane": tables.count,
    "headerRole": role(header),
    "headerChildren": children.count,
    "columns": cols.count,
    "rows": (attr(table, "AXRows") as? [AXUIElement])?.count ?? -1,
    "headerCells": rows,
    "childReadFailures": childReadFailures,
])
