// Turn "we looked and did not find it" into "this surface does not declare it".
//
//   ./ax_attribute_name_census            -> every attribute NAME reachable from the main window
//   ./ax_attribute_name_census color      -> plus which of them match a substring
//
// Most AX dead ends in this repository were argued rather than measured: an operation writes
// something, nothing reads it back, and the issue records "needs a definition of verified". That
// phrasing hides the real question, which is whether the surface exposes the attribute AT ALL.
// `AXUIElementCopyAttributeNames` answers it directly, and the answer is a list rather than a
// judgement.
//
// THE TWO COUNTS AT THE END ARE THE POINT. A sweep that reports nothing is worthless if the
// instrument was failing silently — an unaimed instrument's silence is not absence. So this counts
// the elements whose name call FAILED and the elements that answered with an EMPTY list, and both
// must be zero before a "not declared here" conclusion means anything.
//
// WHAT IT CANNOT RULE OUT: names, not values. A value can be carried inside `AXValue` or spelled
// into `AXDescription` as localised prose, and neither is visible to a name census. It also reads
// only the frontmost non-dialog window to depth 16 — another window, or a deeper subtree, is a
// different measurement.
import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
/// Children, counting the reads that FAILED rather than collapsing them into "there are none".
///
/// This census exists to report an ABSENCE, and an absence is only as good as the sweep behind it: a
/// subtree whose child list could not be read contributes no names, so a colour attribute living
/// inside it would be reported as not declared. Found by a merge-gate inventory 2026-09-08, which
/// noted the class was fixed in one probe and left in the others — the named instance, not the
/// property.
var childReadFailures = 0
var childReadErrors: [Int: Int] = [:]
func kids(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    if err == .success { return (v as? [AXUIElement]) ?? [] }
    // `noValue`/`attributeUnsupported` mean the element genuinely has no child list. Anything else
    // means the question could not be asked, which is not an answer.
    if err == .noValue || err == .attributeUnsupported { return [] }
    childReadFailures += 1
    childReadErrors[Int(err.rawValue), default: 0] += 1
    return []
}
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) }
func emit(_ o: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]),
                 encoding: .utf8)!)
    exit(0)
}

var nameCallFailures = 0
var emptyNameLists = 0
func names(_ e: AXUIElement) -> [String] {
    var n: CFArray?
    guard AXUIElementCopyAttributeNames(e, &n) == .success else { nameCallFailures += 1; return [] }
    let out = (n as? [String]) ?? []
    if out.isEmpty { emptyNameLists += 1 }
    return out
}

let needle = CommandLine.arguments.dropFirst().first?.lowercased()

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else { emit(["ok": false, "error": "logic not running"]) }
let axApp = AXUIElementCreateApplication(app.processIdentifier)
let windows: [AXUIElement] = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { str($0, kAXSubroleAttribute as String) != "AXDialog" })
        ?? windows.first
else { emit(["ok": false, "error": "no window"]) }

var wholeWindow = Set<String>()
var visited = 0
func sweep(_ e: AXUIElement, _ depth: Int) {
    guard depth <= 16 else { return }
    visited += 1
    for n in names(e) { wholeWindow.insert(n) }
    for c in kids(e) { sweep(c, depth + 1) }
}
sweep(window, 0)

// The track headers separately, at the depth the product's own readers use, because a name that
// exists somewhere in the window is not available to a reader that only walks a header.
let LAYOUT = kAXLayoutItemRole as String
var headerNames = Set<String>()
var headerCount = 0
func findContainer(_ root: AXUIElement, _ depth: Int) -> AXUIElement? {
    guard depth <= 8 else { return nil }
    for c in kids(root) {
        let sel: [AXUIElement] = (attr(c, kAXSelectedChildrenAttribute as String) as? [AXUIElement]) ?? []
        if role(c) == kAXGroupRole as String,
           kids(c).contains(where: { role($0) == LAYOUT }), !sel.isEmpty { return c }
        if let found = findContainer(c, depth + 1) { return found }
    }
    return nil
}
if let container = findContainer(window, 1) {
    let headers = kids(container).filter { role($0) == LAYOUT }
    headerCount = headers.count
    func headerSweep(_ e: AXUIElement, _ depth: Int) {
        guard depth <= 4 else { return }
        for n in names(e) { headerNames.insert(n) }
        for c in kids(e) { headerSweep(c, depth + 1) }
    }
    for h in headers { headerSweep(h, 0) }
}

var report: [String: Any] = [
    "ok": true,
    "windowTitle": str(window, kAXTitleAttribute as String),
    "elementsVisited": visited,
    "attributeNamesInWindow": wholeWindow.sorted(),
    "attributeNamesInWindowCount": wholeWindow.count,
    "trackHeaderCount": headerCount,
    "attributeNamesOnTrackHeaders": headerNames.sorted(),
    // Both must be zero, or the sweep did not read what it claims to have read.
    "nameCallFailures": nameCallFailures,
    "emptyNameLists": emptyNameLists,
    "childReadFailures": childReadFailures,
    "childReadErrors": childReadErrors.map { ["code": $0.key, "count": $0.value] },
]
if let needle {
    report["needle"] = needle
    report["matchesInWindow"] = wholeWindow.filter { $0.lowercased().contains(needle) }.sorted()
    report["matchesOnTrackHeaders"] = headerNames.filter { $0.lowercased().contains(needle) }.sorted()
}
emit(report)
