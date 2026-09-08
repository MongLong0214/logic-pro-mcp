// Ask ONE question about #766: within the radius `inferTrackType` searches, does any attribute
// of a track header differ by track type — or does the header carry no type signal at all?
//
//   ./ax_track_type_signal_census   ->  {"ok":true,"headers":[…],"sharedByAllHeaders":[…],…}
//
// The issue measured the CLASSIFIER's answer (always `.audio`) and the four token counts it
// derives. That shows the classifier is wrong; it does not show that no better signal exists.
// This walks the same subtree and reports every attribute value, partitioned into what every
// header carries (chrome — cannot discriminate anything) and what only some carry (the only
// place a type signal could be). A field that appears on all N headers is disqualified as a
// discriminator no matter what it says.
//
// WHAT IT CANNOT RULE OUT: signals OUTSIDE the header subtree at depth 4 — the channel strip,
// the mixer, the track icon image data, the project file. A silent result here means "not in
// this radius", never "nowhere". It also reads whatever the project currently holds: if every
// open track is the same type, identical attributes prove nothing.
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
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) }
func emit(_ o: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]),
                 encoding: .utf8)!)
    exit(0)
}

let LAYOUT = kAXLayoutItemRole as String

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
        for c in kids(e) {
            if role(c) == wanted { out.append(c) }
            walk(c, d + 1)
        }
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

// Same locator order the product uses, so the subtree censused is the subtree classified.
var container: AXUIElement?
var step = "NONE"
if let a = findFirst(window, role: kAXListRole as String, identifier: "Track Headers", maxDepth: 30) {
    container = a; step = "list:Track Headers"
} else if let a = findFirst(window, role: kAXScrollAreaRole as String, identifier: "Tracks", maxDepth: 30) {
    container = a; step = "scrollArea:Tracks"
} else {
    for g in findAll(window, role: kAXGroupRole as String, maxDepth: 8) {
        let sel: [AXUIElement] = (attr(g, kAXSelectedChildrenAttribute as String) as? [AXUIElement]) ?? []
        if kids(g).contains(where: { role($0) == LAYOUT }), !sel.isEmpty {
            container = g; step = "group:structural"; break
        }
    }
}
guard let container else { emit(["ok": false, "error": "track header container not located"]) }

let headers = kids(container).filter { role($0) == LAYOUT }
guard !headers.isEmpty else { emit(["ok": false, "error": "container has no AXLayoutItem rows", "step": step]) }

// Depth counted the way `inferTrackType` counts it: the header itself is depth 0, its children 1.
let ATTRS = [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXHelpAttribute,
             kAXValueAttribute, kAXRoleDescriptionAttribute, kAXSubroleAttribute].map { $0 as String }

struct Field: Hashable { let attr: String; let value: String }

func fields(of e: AXUIElement, depth: Int, into out: inout [(Int, String, Field)]) {
    guard depth <= 4 else { return }
    let r = role(e)
    for a in ATTRS {
        let v = str(e, a)
        if !v.isEmpty { out.append((depth, r, Field(attr: a, value: v))) }
    }
    for c in kids(e) { fields(of: c, depth: depth + 1, into: &out) }
}

var perHeader: [[(Int, String, Field)]] = []
for h in headers {
    var out: [(Int, String, Field)] = []
    fields(of: h, depth: 0, into: &out)
    perHeader.append(out)
}

let sets: [Set<Field>] = perHeader.map { Set($0.map(\.2)) }
let sharedByAll = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }

func render(_ f: Field) -> String { "\(f.attr)=\(f.value)" }

var headerReports: [[String: Any]] = []
for (i, h) in headers.enumerated() {
    let unique = sets[i].subtracting(sharedByAll)
    headerReports.append([
        "index": i,
        "headerDescription": str(h, kAXDescriptionAttribute as String),
        "headerTitle": str(h, kAXTitleAttribute as String),
        "fieldCount": sets[i].count,
        "notSharedByAllHeaders": unique.map(render).sorted(),
    ])
}

emit([
    "ok": true,
    "step": step,
    "headerCount": headers.count,
    "sharedByAllHeadersCount": sharedByAll.count,
    "sharedByAllHeaders": sharedByAll.map(render).sorted(),
    "headers": headerReports,
])
