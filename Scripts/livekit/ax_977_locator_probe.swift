// Raw AX readings for #977 (Scripts/livekit/live_977_locale_locators.py). Everything is located
// STRUCTURALLY, never by a label, so a label the product gets wrong cannot hide the element:
//   mixer_areas    containers holding AXLayoutItem children (channel strips)
//   occupied_slots AXGroups whose direct children are exactly [AXCheckBox, AXButton, AXButton]
//   dialogs        AXDialog windows, with their direct AXCheckBox/AXButton children
// Actions: `press-open` presses the first occupied slot's first AXButton (its open control);
//          `close-editors` presses the close button of every AXDialog that exposes one.
import ApplicationServices
import AppKit
import Foundation

func attr<T>(_ e: AXUIElement, _ a: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v as? T
}
func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) ?? [] }
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) ?? "?" }
func row(_ e: AXUIElement, path: String) -> [String: Any] {
    var r: [String: Any] = ["role": role(e), "path": path]
    for (key, a) in [("description", kAXDescriptionAttribute), ("title", kAXTitleAttribute),
                     ("help", kAXHelpAttribute), ("identifier", kAXIdentifierAttribute)] {
        if let s: String = attr(e, a as String) { r[key] = s }
    }
    if let sub: String = attr(e, kAXSubroleAttribute) { r["subrole"] = sub }
    return r
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    print("{\"error\":\"logic not running\"}"); exit(1)
}
let action = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let root = AXUIElementCreateApplication(app.processIdentifier)
let windows: [AXUIElement] = attr(root, kAXWindowsAttribute) ?? []

var menubar: [String] = []
if let bar: AXUIElement = attr(root, kAXMenuBarAttribute) {
    menubar = kids(bar).prefix(8).compactMap { attr($0, kAXTitleAttribute) as String? }
}

var mixerAreas: [[String: Any]] = []
var slots: [(AXUIElement, [String: Any])] = []
func walk(_ e: AXUIElement, _ depth: Int, _ path: String) {
    guard depth <= 14 else { return }
    let children = kids(e)
    let r = role(e)
    let here = path + "/" + r
    let items = children.filter { role($0) == "AXLayoutItem" }.count
    if items > 0 {
        var m = row(e, path: here)
        m["layout_items"] = items
        mixerAreas.append(m)
    }
    if r == "AXGroup", children.map(role) == ["AXCheckBox", "AXButton", "AXButton"] {
        var s = row(e, path: here)
        s["children"] = children.map { row($0, path: here + "/" + role($0)) }
        slots.append((e, s))
    }
    for c in children { walk(c, depth + 1, here) }
}
var dialogs: [[String: Any]] = []
var closeButtons: [AXUIElement] = []
for w in windows {
    let sub: String? = attr(w, kAXSubroleAttribute)
    if sub == "AXStandardWindow" { walk(w, 0, "") }
    guard sub == "AXDialog" else { continue }
    var d = row(w, path: "/AXWindow")
    let close: AXUIElement? = attr(w, kAXCloseButtonAttribute)
    d["has_close_button"] = close != nil
    if let close { closeButtons.append(close) }
    d["children"] = kids(w).filter { ["AXCheckBox", "AXButton"].contains(role($0)) }
        .map { row($0, path: "/AXWindow/" + role($0)) }
    dialogs.append(d)
}

var acted: [String: Any] = [:]
if action == "press-open", let slot = slots.first?.0,
   let open = kids(slot).first(where: { role($0) == "AXButton" }) {
    acted["pressed"] = row(open, path: "open")
    acted["status"] = AXUIElementPerformAction(open, kAXPressAction as CFString).rawValue
}
if action == "close-editors" {
    acted["closed"] = closeButtons.map { AXUIElementPerformAction($0, kAXPressAction as CFString).rawValue }
}

let out: [String: Any] = [
    "trusted": AXIsProcessTrusted(),
    "apple_languages": (UserDefaults(suiteName: "com.apple.logic10")?.array(forKey: "AppleLanguages") as? [String]) ?? [],
    "menubar": menubar,
    "mixer_areas": mixerAreas,
    "occupied_slots": slots.map { $0.1 },
    "dialogs": dialogs,
    "action": action,
    "acted": acted,
]
let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
