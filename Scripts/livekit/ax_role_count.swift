// Count the descendants of Logic's main window carrying a given AXRole, walking the tree from
// outside the product.
//
//   ./ax_role_count <AXRole> [--max-depth N]   ->  {"role":"AXButton","count":50,"maxDepth":10}
//
// This exists to be a SECOND opinion on `AXHelpers.censusDescendant`. A unit test can prove the
// counting rule against a tree the test built; nothing in the product can show the rule surviving
// Logic's real one, because the only thing that would check it is the code being checked.
//
// Deliberately matched on ROLE and nothing else. A LabelSet comparison would have the harness and
// the product reading the same locale table and agreeing for that reason — which is agreement
// about a shared input, not corroboration.
//
// WHAT IT CANNOT RULE OUT, said here rather than implied: both walkers call the same
// `AXUIElementCopyAttributeValue`, so a defect in the AX API itself, or in how a subtree answers
// `AXChildren`, moves both numbers together. What it does rule out is a defect in either walk —
// depth handling, whether a match is descended into, filtering — which is where the counting rule
// actually lives.
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
func emit(_ o: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
                 encoding: .utf8)!)
    exit(0)
}

let argv = CommandLine.arguments
let wantedRole = argv.count > 1 ? argv[1] : "AXButton"
let maxDepth: Int = {
    guard let i = argv.firstIndex(of: "--max-depth"), argv.count > i + 1 else { return 10 }
    return Int(argv[i + 1]) ?? 10
}()

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else { emit(["ok": false, "error": "logic not running"]) }

let ax = AXUIElementCreateApplication(app.processIdentifier)
// The MAIN window, which is what the product's probe searches. Taking the first standard window
// instead would compare two different subtrees and the disagreement would say nothing.
guard let main = attr(ax, kAXMainWindowAttribute as String) else {
    emit(["ok": false, "error": "no main window"])
}
let window = main as! AXUIElement

// Descends into matches, because the lookup this corroborates could have returned either a match or
// one nested inside it — it stops at the outer one only by virtue of returning it. Counting only
// the outermost would report a smaller number for the same tree and the comparison would fail for a
// reason that has nothing to do with the product.
var count = 0
func walk(_ e: AXUIElement, _ depth: Int) {
    guard depth > 0 else { return }
    for child in kids(e) {
        if str(child, kAXRoleAttribute as String) == wantedRole { count += 1 }
        walk(child, depth - 1)
    }
}
walk(window, maxDepth)

emit(["ok": true, "role": wantedRole, "count": count, "maxDepth": maxDepth,
      "window": str(window, kAXTitleAttribute as String)])
