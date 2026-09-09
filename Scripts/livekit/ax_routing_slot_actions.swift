import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }; return v
}
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else { exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var wins: CFTypeRef?; AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wins)
func findStrip(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if d > 8 { return nil }
    if str(e, kAXRoleAttribute as String) == (kAXLayoutItemRole as String),
       str(e, kAXHelpAttribute as String).lowercased().hasPrefix("left inspector channel strip") { return e }
    for c in kids(e) { if let f = findStrip(c, d+1) { return f } }
    return nil
}
var strip: AXUIElement?
for w in (wins as? [AXUIElement]) ?? [] { if let f = findStrip(w, 0) { strip = f; break } }
guard let strip else { exit(1) }
for c in kids(strip) {
    let help = str(c, kAXHelpAttribute as String)
    guard help.hasPrefix("Send slot") || help.hasPrefix("Output slot") || help.hasPrefix("Input slot") else { continue }
    var acts: CFArray?
    let s = AXUIElementCopyActionNames(c, &acts)
    let names = (acts as? [String]) ?? []
    let enabled = (attr(c, kAXEnabledAttribute as String) as? Bool).map(String.init) ?? "nil"
    print("\(help.prefix(11)) role=\(str(c, kAXRoleAttribute as String)) enabled=\(enabled) actionsStatus=\(s.rawValue) actions=\(names)")
}
