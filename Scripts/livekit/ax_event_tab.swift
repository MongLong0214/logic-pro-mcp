// A driver-side way to read and set which List Editors tab Logic is showing.
//
// `--probe-event-list` REFUSES when the Event tab is not already selected: it observes, and the
// whole reason a release binary is allowed to reach that path is that it performs no AX action.
// Selecting the tab is therefore the driver's job — and the driver could not do it. System Events
// cannot see these tabs at all: `every radio button of window 1 whose description is "Event"`
// returns 0, a `whose` filter over `entire contents` is not a valid specifier (-1700), and an
// explicit walk of `entire contents` finds no such element. Measured on Logic 12.3 while the pane
// was open and the probe was reading its rows.
//
//   swiftc -O ax_event_tab.swift -o ax_event_tab
//   ./ax_event_tab                 -> {"tabs":[{"description":"Event","selected":true}, …]}
//   ./ax_event_tab select Event    -> the same, plus "pressed", AFTER re-reading
//
// The reported `selected` is always a fresh read taken after any press, never the press's return
// code. `ax_region_select.swift` records why: on this build an AXSelected write returned .success
// throughout while doing the opposite of what it claimed. Return codes are not observations.

import AppKit
import ApplicationServices
import Foundation

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func role(_ element: AXUIElement) -> String {
    (attr(element, kAXRoleAttribute as String) as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func describe(_ element: AXUIElement) -> String {
    (attr(element, kAXDescriptionAttribute as String) as? String) ?? ""
}

func isSelected(_ element: AXUIElement) -> Bool {
    ((attr(element, kAXValueAttribute as String) as? NSNumber)?.intValue ?? 0) == 1
}

/// Every radio button under `root`, by AXDescription. Depth-bounded rather than unbounded: the
/// tabs sit several groups deep and an unbounded walk of Logic's arrange window is slow enough
/// to change what it is measuring.
func radioButtons(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 16 else { return [] }
    var found: [AXUIElement] = []
    for child in children(root) {
        if role(child) == (kAXRadioButtonRole as String), !describe(child).isEmpty {
            found.append(child)
        }
        found.append(contentsOf: radioButtons(child, depth: depth + 1))
    }
    return found
}

func emit(_ object: [String: Any]) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(0)
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first
else { emit(["error": "Logic Pro is not running"]) }

let axApp = AXUIElementCreateApplication(app.processIdentifier)
guard let window = attr(axApp, kAXMainWindowAttribute as String) else {
    emit(["error": "Logic Pro has no main window"])
}
// swiftlint:disable:next force_cast
let mainWindow = window as! AXUIElement

var tabs = radioButtons(mainWindow)
var pressed: String? = nil

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "select" {
    let wanted = CommandLine.arguments[2]
    guard let target = tabs.first(where: { describe($0) == wanted }) else {
        emit(["error": "no radio button with description \(wanted)",
              "tabs": tabs.map { ["description": describe($0), "selected": isSelected($0)] }])
    }
    if !isSelected(target) {
        _ = AXUIElementPerformAction(target, kAXPressAction as CFString)
        pressed = wanted
        // Logic repaints the list asynchronously; re-read after it settles, not before.
        Thread.sleep(forTimeInterval: 1.0)
        tabs = radioButtons(mainWindow)
    }
}

var out: [String: Any] = [
    "tabs": tabs.map { ["description": describe($0), "selected": isSelected($0)] },
]
if let pressed { out["pressed"] = pressed }
emit(out)
