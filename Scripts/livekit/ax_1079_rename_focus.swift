// #1079: open an inline track rename in Logic and read where Logic's keyboard focus is.
//
// Measured 2026-10-02 on a Korean Logic 12.3: Track > Rename Track opens the selected track's name
// field only while the Tracks area holds the key focus; with the Marker List window key it does
// nothing visible. So `keymain` raises the arrange window and makes it main before the rename.
// Every Logic string this reads by arrives as an argument, from docs/locale/ui-labels.json through
// the Python probe, so nothing here is spelled for one language.
//
//   swiftc -O ax_1079_rename_focus.swift -o helper
//   ./helper focus
//   ./helper keymain <arrange-window-title-suffix>...
import AppKit
import ApplicationServices

guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10")
    .first?.processIdentifier else { print("{\"error\":\"logic is not running\"}"); exit(1) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// The focused element's role and subrole, or null when the focus does not read.
func focus() -> String {
    guard let value = attribute(app, kAXFocusedUIElementAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return "{\"role\":null}" }
    let element = value as! AXUIElement
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
    return "{\"role\":\"\(role)\",\"subrole\":\"\(subrole)\"}"
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "focus" {
case "keymain":
    let suffixes = arguments.dropFirst().map { $0.lowercased() }
    var raised = 0
    for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) {
        guard let title = (attribute(window, kAXTitleAttribute) as? String)?.lowercased(),
              suffixes.contains(where: { title.hasSuffix($0) }) else { continue }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        raised += 1
    }
    usleep(300_000)
    print("{\"raised\":\(raised),\"focus\":\(focus())}")
case "focusrail":
    // The Tracks header rail, named by the descriptions given (canon `trackHeadersDescription`), takes
    // the key focus; with it focused, Track > Rename Track opens the selected track's name field.
    let names = Set(arguments.dropFirst().map { $0.lowercased() })
    var rails: [AXUIElement] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        if depth > 12 || !rails.isEmpty { return }
        if let d = attribute(element, kAXDescriptionAttribute) as? String, names.contains(d.lowercased()) {
            rails.append(element); return
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(child, depth + 1) }
    }
    for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(window, 0) }
    let set = rails.first.map { AXUIElementSetAttributeValue($0, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue }
    usleep(200_000)
    print("{\"rails\":\(rails.count),\"set\":\(set.map(String.init) ?? "null"),\"focus\":\(focus())}")
default:
    print(focus())
}
