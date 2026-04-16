#!/usr/bin/env swift
// Detective probe — dump ALL interactive elements in the focused plugin window
// to identify which element is the real Setting dropdown.

import ApplicationServices
import Cocoa
import Foundation

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: AnyObject?
    let r = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard r == .success, let v = value else { return nil }
    return v as? T
}

func attrNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success,
          let arr = names as? [String] else { return [] }
    return arr
}

func getApp(bundleId: String) -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func findPluginWindow(in app: AXUIElement) -> AXUIElement? {
    let windows: [AXUIElement] = attr(app, kAXWindowsAttribute as String) ?? []
    for w in windows {
        let title: String = attr(w, kAXTitleAttribute as String) ?? ""
        if title.contains(".logicx") { continue }
        // Heuristic: plugin window has at least one menu button or popup
        let hasInteractive = walk(w, depth: 0, max: 6) { e in
            let r: String = attr(e, kAXRoleAttribute as String) ?? ""
            return r == kAXMenuButtonRole as String || r == kAXPopUpButtonRole as String
        }
        if hasInteractive { return w }
    }
    return windows.first
}

func walk(_ e: AXUIElement, depth: Int, max: Int, predicate: (AXUIElement) -> Bool) -> Bool {
    if depth > max { return false }
    if predicate(e) { return true }
    let children: [AXUIElement] = attr(e, kAXChildrenAttribute as String) ?? []
    return children.contains { walk($0, depth: depth + 1, max: max, predicate: predicate) }
}

func dumpInteractive(_ e: AXUIElement, depth: Int = 0, max: Int = 8) {
    if depth > max { return }
    let role: String = attr(e, kAXRoleAttribute as String) ?? "?"
    // Filter to common interactive roles
    let interestingRoles: Set<String> = [
        kAXMenuButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXButtonRole as String,
        kAXStaticTextRole as String,
        kAXTextFieldRole as String,
        "AXLayoutItem",
        "AXImage",
    ]
    if interestingRoles.contains(role) {
        let title: String = attr(e, kAXTitleAttribute as String) ?? ""
        let desc: String = attr(e, kAXDescriptionAttribute as String) ?? ""
        let value: String = attr(e, kAXValueAttribute as String) ?? ""
        let help: String = attr(e, kAXHelpAttribute as String) ?? ""
        let identifier: String = attr(e, kAXIdentifierAttribute as String) ?? ""
        var posStr = "?"
        if let pv: AXValue = attr(e, kAXPositionAttribute as String) {
            var p = CGPoint.zero
            if AXValueGetValue(pv, .cgPoint, &p) { posStr = "(\(Int(p.x)),\(Int(p.y)))" }
        }
        var sizeStr = "?"
        if let sv: AXValue = attr(e, kAXSizeAttribute as String) {
            var s = CGSize.zero
            if AXValueGetValue(sv, .cgSize, &s) { sizeStr = "\(Int(s.width))×\(Int(s.height))" }
        }
        let parts = [
            title.isEmpty ? "" : "title=\(title)",
            desc.isEmpty ? "" : "desc=\(desc)",
            value.isEmpty ? "" : "val=\(value)",
            help.isEmpty ? "" : "help=\(help)",
            identifier.isEmpty ? "" : "id=\(identifier)",
        ].filter { !$0.isEmpty }.joined(separator: " | ")
        let pad = String(repeating: "  ", count: depth)
        print("\(pad)[\(role)] @ \(posStr) \(sizeStr) — \(parts)")
    }
    let children: [AXUIElement] = attr(e, kAXChildrenAttribute as String) ?? []
    for c in children { dumpInteractive(c, depth: depth + 1, max: max) }
}

guard let logic = getApp(bundleId: "com.apple.logic10") else {
    print("ERROR: Logic Pro not running")
    exit(1)
}
guard let pluginWin = findPluginWindow(in: logic) else {
    print("ERROR: No suitable window")
    exit(1)
}
let title: String = attr(pluginWin, kAXTitleAttribute as String) ?? "<nil>"
print("=== Plugin window AXTitle: \(title) ===")
print("=== Window full attribute names: \(attrNames(pluginWin)) ===")
print("")
print("=== Interactive elements (AXMenuButton, AXPopUpButton, AXButton, AXStaticText, AXTextField, AXLayoutItem) ===")
dumpInteractive(pluginWin)
