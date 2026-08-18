// A minimal, product-independent actuator for the track-stack disclosure arrow.
//
// It exists because `osascript`'s System Events `perform action` is INERT against Logic's arrange
// window on this host — measured 2026-08-18: pressing the arrow reported success and moved nothing,
// and the same press on the Mute checkbox next to it also moved nothing, so the failure is the
// instrument rather than the control. Reads through System Events work fine; only actuation is dead.
//
// The harness needs an actuator that is not the code under test, so this is a direct
// `AXUIElementPerformAction` rather than a call into LogicProMCP. It takes no coordinates: the arrow
// is found by walking the accessibility tree for a disclosure triangle whose parent is a track
// header (`AXLayoutItem`).
//
//   swiftc -O ax_stack_arrow.swift -o ax_stack_arrow
//   ./ax_stack_arrow read     -> {"arrows":N,"value":0,"owner":"Absolute Zero"}
//   ./ax_stack_arrow press    -> {...,"press_status":0,"value_after":0}   (measured inert; see below)

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

/// Every disclosure triangle whose parent is a track header, depth-first from the app element.
func stackArrows(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 32 else { return [] }
    var found: [AXUIElement] = []
    for child in children(root) {
        if role(child) == (kAXDisclosureTriangleRole as String),
           let parent = attr(root, kAXRoleAttribute as String) as? String,
           parent == (kAXLayoutItemRole as String) {
            found.append(child)
        }
        found.append(contentsOf: stackArrows(child, depth: depth + 1))
    }
    return found
}

func intValue(_ element: AXUIElement) -> Int? {
    (attr(element, kAXValueAttribute as String) as? NSNumber)?.intValue
}

/// The name of the track whose header carries this arrow, so a harness can bind the arrow it reads
/// to the row it checks by IDENTITY rather than by both being "the first one".
func ownerTrackName(_ arrow: AXUIElement) -> String? {
    guard let header = attr(arrow, kAXParentAttribute as String) else { return nil }
    // swiftlint:disable:next force_cast
    let headerElement = header as! AXUIElement
    for child in children(headerElement) where role(child) == (kAXTextFieldRole as String) {
        if let name = attr(child, kAXDescriptionAttribute as String) as? String {
            return name
        }
    }
    return nil
}

func jsonString(_ value: String?) -> String {
    guard let value, let data = try? JSONSerialization.data(withJSONObject: [value]),
          let text = String(data: data, encoding: .utf8) else { return "null" }
    return String(text.dropFirst().dropLast())
}

let command = CommandLine.arguments.dropFirst().first ?? "read"
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.apple.logic10"
}) else {
    print("{\"error\":\"logic_not_running\"}")
    exit(2)
}

let arrows = stackArrows(AXUIElementCreateApplication(app.processIdentifier))
guard let arrow = arrows.first else {
    print("{\"arrows\":0,\"error\":\"no_stack_arrow\"}")
    exit(3)
}

let before = intValue(arrow)
if command == "press" {
    let status = AXUIElementPerformAction(arrow, kAXPressAction as CFString)
    // The return code is reported but never trusted: this repository has measured AX calls that
    // answer `.success` and change nothing. The value after the press is the only evidence.
    Thread.sleep(forTimeInterval: 1.2)
    let after = intValue(arrow)
    print("""
    {"arrows":\(arrows.count),"value":\(before.map(String.init) ?? "null"),\
    "owner":\(jsonString(ownerTrackName(arrow))),\
    "press_status":\(status.rawValue),"value_after":\(after.map(String.init) ?? "null")}
    """)
} else {
    print("""
    {"arrows":\(arrows.count),"value":\(before.map(String.init) ?? "null"),\
    "owner":\(jsonString(ownerTrackName(arrow)))}
    """)
}
