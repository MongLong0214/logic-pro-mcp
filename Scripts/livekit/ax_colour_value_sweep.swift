// #448 colour half: the 2026-09-08 census swept attribute NAMES. This sweeps VALUES.
import AppKit
import ApplicationServices

func raw(_ e: AXUIElement, _ a: String) -> (AXError, CFTypeRef?) {
    var v: CFTypeRef?; let s = AXUIElementCopyAttributeValue(e, a as CFString, &v); return (s, v)
}
func names(_ e: AXUIElement) -> [String] {
    var n: CFArray?; guard AXUIElementCopyAttributeNames(e, &n) == .success else { return [] }
    return (n as? [String]) ?? []
}
// An element that HAS no children is not a subtree that could not be read. Counting
// `noValue`/`attributeUnsupported` as unreadable reported 879 refused subtrees out of 1304
// elements, which would have made the whole sweep look inconclusive. Only a genuine failure counts.
enum Kids { case some([AXUIElement]); case none; case unreadable }
func kidsOrNil(_ e: AXUIElement) -> Kids {
    let (s, v) = raw(e, kAXChildrenAttribute as String)
    if s == .success { return .some((v as? [AXUIElement]) ?? []) }
    if s == .noValue || s == .attributeUnsupported { return .none }
    return .unreadable
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first
else { print("no logic"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var wins: CFTypeRef?; AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wins)

var visited = 0, unreadable = 0, colourValued = 0, axColorTyped = 0
var samples: [String] = []
let needles = ["color", "colour", "#", "rgb", "swatch", "palette"]

func walk(_ e: AXUIElement, _ d: Int) {
    if d > 16 { return }
    visited += 1
    for n in names(e) {
        let (s, v) = raw(e, n)
        guard s == .success, let v else { continue }
        // A real AXValue of colour type would be the strongest possible answer.
        let tid = CFGetTypeID(v)
        if tid == CGColor.typeID { axColorTyped += 1; samples.append("AXCOLOR \(n) on depth \(d)") }
        guard let str = v as? String, !str.isEmpty else { continue }
        let low = str.lowercased()
        if needles.contains(where: { low.contains($0) }) {
            colourValued += 1
            if samples.count < 12 { samples.append("\(n)=\(String(str.prefix(70)))") }
        }
    }
    switch kidsOrNil(e) {
    case .unreadable: unreadable += 1
    case .none: break
    case let .some(ks): for c in ks { walk(c, d + 1) }
    }
}
for w in (wins as? [AXUIElement]) ?? [] { walk(w, 0) }
print("elements visited        \(visited)")
print("child lists unreadable  \(unreadable)")
print("values mentioning colour \(colourValued)")
print("attributes of CGColor type \(axColorTyped)")
for s in samples { print("   ", s) }
