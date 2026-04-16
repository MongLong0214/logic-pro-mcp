#!/usr/bin/env swift
// Press the AXPopUpButton at (670, 304) — the actual Setting dropdown — and
// dump its menu children + lazy-populated submenus.

import ApplicationServices
import Cocoa
import Foundation

func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: AnyObject?
    let r = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard r == .success, let v = value else { return nil }
    return v as? T
}

func getApp(bundleId: String) -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func findFirstDescendant(_ e: AXUIElement, role: String, depth: Int = 0, max: Int = 8) -> AXUIElement? {
    if depth > max { return nil }
    let r: String = attr(e, kAXRoleAttribute as String) ?? ""
    if r == role {
        // Filter for the Setting dropdown — value contains "프리셋" or "Preset" or "Default"
        let v: String = attr(e, kAXValueAttribute as String) ?? ""
        if v.contains("프리셋") || v.contains("Preset") || v.contains("Default") {
            return e
        }
    }
    let children: [AXUIElement] = attr(e, kAXChildrenAttribute as String) ?? []
    for c in children {
        if let f = findFirstDescendant(c, role: role, depth: depth + 1, max: max) { return f }
    }
    return nil
}

func findPluginWindow(in app: AXUIElement) -> AXUIElement? {
    let windows: [AXUIElement] = attr(app, kAXWindowsAttribute as String) ?? []
    for w in windows {
        let title: String = attr(w, kAXTitleAttribute as String) ?? ""
        if title.contains(".logicx") { continue }
        // Has a popup with "프리셋" or "Preset" value?
        if findFirstDescendant(w, role: kAXPopUpButtonRole as String) != nil { return w }
    }
    return windows.first
}

guard let logic = getApp(bundleId: "com.apple.logic10") else { print("ERROR: Logic not running"); exit(1) }
guard let win = findPluginWindow(in: logic) else { print("ERROR: No plugin window"); exit(1) }
let title: String = attr(win, kAXTitleAttribute as String) ?? "?"
print("Plugin window: \(title)")

guard let popup = findFirstDescendant(win, role: kAXPopUpButtonRole as String) else {
    print("ERROR: No Setting popup found")
    exit(1)
}
let popupVal: String = attr(popup, kAXValueAttribute as String) ?? "?"
let popupHelp: String = attr(popup, kAXHelpAttribute as String) ?? ""
print("Setting popup value: \(popupVal)  help: \(popupHelp)")

print("\n--- AXPress on Setting popup ---")
let pressResult = AXUIElementPerformAction(popup, kAXPressAction as CFString)
print("AXPress result = \(pressResult.rawValue) (.success=0)")

Thread.sleep(forTimeInterval: 0.5)

// After press, the menu should appear as a child of the popup or as a separate AXMenu in the window
let popupChildren: [AXUIElement] = attr(popup, kAXChildrenAttribute as String) ?? []
print("\nPopup direct children after press: \(popupChildren.count)")

// Search for AXMenu in the window
func findMenu(_ e: AXUIElement, depth: Int = 0, max: Int = 8) -> AXUIElement? {
    if depth > max { return nil }
    let r: String = attr(e, kAXRoleAttribute as String) ?? ""
    if r == kAXMenuRole as String {
        // Filter — Setting menu typically has many items
        let kids: [AXUIElement] = attr(e, kAXChildrenAttribute as String) ?? []
        if kids.count >= 3 { return e }
    }
    let children: [AXUIElement] = attr(e, kAXChildrenAttribute as String) ?? []
    for c in children {
        if let f = findMenu(c, depth: depth + 1, max: max) { return f }
    }
    return nil
}

// Re-fetch app root since menu appears as top-level
guard let menu = findMenu(logic) ?? findMenu(win) else {
    print("ERROR: No AXMenu appeared after AXPress")
    exit(1)
}
let menuKids: [AXUIElement] = attr(menu, kAXChildrenAttribute as String) ?? []
print("\nSetting menu children: \(menuKids.count) items")

// Probe each top-level item: AXPress and check for submenu
print("\n--- Per-item submenu probe ---")
var hierarchicalCount = 0
var leafCount = 0
for (idx, item) in menuKids.prefix(40).enumerated() {
    let name: String = attr(item, kAXTitleAttribute as String) ?? attr(item, kAXValueAttribute as String) ?? "?"
    let role: String = attr(item, kAXRoleAttribute as String) ?? "?"
    if role == "AXMenuItem" {
        let pressR = AXUIElementPerformAction(item, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.2)
        let kids: [AXUIElement] = attr(item, kAXChildrenAttribute as String) ?? []
        let sub = kids.first { (attr($0, kAXRoleAttribute as String) as String?) == kAXMenuRole as String }
        if let sub = sub {
            let subKids: [AXUIElement] = attr(sub, kAXChildrenAttribute as String) ?? []
            hierarchicalCount += 1
            print("  Item[\(idx)] '\(name)' (press=\(pressR.rawValue)) → SUBMENU with \(subKids.count) children")
        } else {
            leafCount += 1
            if idx < 8 { print("  Item[\(idx)] '\(name)' (press=\(pressR.rawValue)) → leaf/action") }
        }
    } else {
        if idx < 5 { print("  Item[\(idx)] role=\(role) name='\(name)' (skip)") }
    }
}
print("\nSUMMARY: \(hierarchicalCount) hierarchical, \(leafCount) leaf/action items in top-level Setting menu")

// Dismiss menu by pressing Escape (AX way: cancel)
print("\n--- Press Escape to dismiss ---")
let cancelResult = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
print("Cancel result = \(cancelResult.rawValue)")
