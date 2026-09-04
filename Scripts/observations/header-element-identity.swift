import AppKit
import ApplicationServices
import Foundation
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }; return v
}
func s(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { s(e, kAXRoleAttribute as String) }
func headers() -> [AXUIElement] {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "").contains("logic") })
    else { return [] }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    let wins: [AXUIElement] = (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    guard let w = wins.first else { return [] }
    var found: AXUIElement?
    func walk(_ e: AXUIElement, _ d: Int) {
        guard d <= 8, found == nil else { return }
        for c in kids(e) {
            if found != nil { return }
            if role(c) == (kAXGroupRole as String),
               s(c, kAXDescriptionAttribute as String).trimmingCharacters(in: .whitespaces) == "트랙 헤더" { found = c; return }
            walk(c, d + 1)
        }
    }
    walk(w, 1)
    guard let g = found else { return [] }
    return kids(g).filter { role($0) == (kAXLayoutItemRole as String) }
}
let before = headers()
print("BEFORE:")
for (i, h) in before.enumerated() { print("  [\(i)] «\(s(h, kAXDescriptionAttribute as String))»") }
// Sort by creation date through Logic's own menu.
let script = """
tell application "System Events" to tell process "Logic Pro" to click menu item "생성일" of menu 1 of menu item "트랙을 다음으로 정렬" of menu 1 of menu bar item "트랙" of menu bar 1
"""
var err: NSDictionary?
NSAppleScript(source: script)?.executeAndReturnError(&err)
Thread.sleep(forTimeInterval: 2.0)
let after = headers()
print("AFTER:")
for (i, h) in after.enumerated() { print("  [\(i)] «\(s(h, kAXDescriptionAttribute as String))»") }
print("IDENTITY MAP (after index -> before index by CFEqual):")
for (i, h) in after.enumerated() {
    let j = before.firstIndex(where: { CFEqual($0, h) })
    print("  after[\(i)] -> before[\(j.map(String.init) ?? "NO MATCH")]")
}
