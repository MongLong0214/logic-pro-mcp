// Reads the Event pane's note-level table the way `EventListReadbackCollector` does — raw AX on the
// main window, never System Events. Emits one JSON object on stdout.
//
// Written as a witness rather than as AppleScript because a rule prototyped through System Events has
// twice failed to hold through the API the product uses: `description` there is synthesised from
// `AXRoleDescription`, and `entire contents` could not reach an element a raw walk found at depth 14.
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
func attrNames(_ e: AXUIElement) -> [String] {
    var arr: CFArray?
    guard AXUIElementCopyAttributeNames(e, &arr) == .success else { return [] }
    return (arr as? [String]) ?? []
}
func emit(_ o: [String: Any]) -> Never {
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    print(String(data: d, encoding: .utf8)!)
    exit(0)
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else { emit(["error": "logic not running"]) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
guard let win = ((attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []).first(where: {
    str($0, kAXSubroleAttribute as String) == (kAXStandardWindowSubrole as String)
}) else { emit(["error": "no standard window"]) }

var radios: [AXUIElement] = []
var tables: [AXUIElement] = []
func walk(_ e: AXUIElement, _ d: Int) {
    guard d <= 20 else { return }
    for c in kids(e) {
        let r = str(c, kAXRoleAttribute as String)
        if r == (kAXRadioButtonRole as String) { radios.append(c) }
        if r == (kAXTableRole as String) || r == (kAXOutlineRole as String) { tables.append(c) }
        walk(c, d + 1)
    }
}
walk(win, 0)

// `findEventTab`'s exact predicate.
let eventTabs = radios.filter {
    str($0, kAXDescriptionAttribute as String) == "Event"
        && str($0, kAXTitleAttribute as String).isEmpty
}

var out: [String: Any] = [
    "window": str(win, kAXTitleAttribute as String),
    "eventTabMatches": eventTabs.count,
    "tables": tables.count,
]

guard let table = tables.first(where: {
    ((attr($0, kAXColumnsAttribute as String) as? [AXUIElement])?.count ?? 0) == 8
}) else {
    out["columns"] = NSNull()
    emit(out)
}
out["columns"] = (attr(table, kAXColumnsAttribute as String) as? [AXUIElement])?.count ?? 0
if let header = attr(table, kAXHeaderAttribute as String) {
    out["sortTitles"] = kids(header as! AXUIElement)
        .filter { str($0, kAXSubroleAttribute as String) == "AXSortButton" }
        .map { str($0, kAXTitleAttribute as String) }
}
let rows = kids(table).filter { str($0, kAXRoleAttribute as String) == (kAXRowRole as String) }
out["rows"] = rows.count
out["cellChildCounts"] = rows.map { row in kids(row).map { kids($0).count } }

// Can a set flag be hiding in an attribute on the cell instead of in a child?
if let firstRow = rows.first {
    let flagCells = kids(firstRow).prefix(2)
    let valueBearing = flagCells.contains { cell in
        let names = Set(attrNames(cell))
        if names.contains(kAXValueAttribute as String) { return true }
        return !str(cell, kAXDescriptionAttribute as String).isEmpty
    }
    out["flagCellHasValueAttribute"] = valueBearing
    out["flagCellAttributeNames"] = flagCells.first.map(attrNames) ?? []
}
emit(out)
