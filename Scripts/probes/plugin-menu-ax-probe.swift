#!/usr/bin/env swift
// T0 spike — probe Logic Pro 12 plugin-window Setting menu for AX accessibility.
//
// Answers PRD §12 OQ-1 (8 questions):
//   Q1. Does AXPress open Setting menu on ES2 / Alchemy / DMD?
//   Q2. Does AXPress on submenu AXMenuItem populate its children?
//   Q3. Empirical submenuOpenDelayMs floor on slowest (Alchemy)?
//   Q4. Leaf-click auto-dismiss behavior?
//   Q5. AXIdentifier / AXDescription / AXTitle format for plugin windows?
//   Q6. Plugin-window appear within 2000 ms via slot double-click?
//   Q7. Stable AXRole of Setting dropdown?
//   Q8. Third-party AU Setting menu behavior?
//
// Usage:
//   swift Scripts/plugin-menu-ax-probe.swift
//   (requires Logic Pro running with ES2 loaded on track 0, plugin window open)
//
// Output: indented AX attribute dump to stdout + Q1-Q8 answers.

import ApplicationServices
import AudioToolbox
import Cocoa
import CoreGraphics
import Foundation

// MARK: - AX helpers

func getApp(bundleId: String) -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

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

func describe(_ element: AXUIElement) -> String {
    let role: String = attr(element, kAXRoleAttribute as String) ?? "?"
    let desc: String = attr(element, kAXDescriptionAttribute as String) ?? ""
    let title: String = attr(element, kAXTitleAttribute as String) ?? ""
    let ident: String = attr(element, kAXIdentifierAttribute as String) ?? ""
    let value: String = attr(element, kAXValueAttribute as String) ?? ""
    let tail = [
        ident.isEmpty ? "" : "id=\(ident)",
        desc.isEmpty ? "" : "desc=\(desc)",
        title.isEmpty ? "" : "title=\(title)",
        value.isEmpty ? "" : "val=\(value)"
    ].filter { !$0.isEmpty }.joined(separator: " | ")
    return tail.isEmpty ? role : "\(role)  [\(tail)]"
}

func findDescendants(_ element: AXUIElement, role: String, depth: Int = 0, max: Int = 10) -> [AXUIElement] {
    if depth > max { return [] }
    let r: String = attr(element, kAXRoleAttribute as String) ?? ""
    var out: [AXUIElement] = []
    if r == role { out.append(element) }
    let children: [AXUIElement] = attr(element, kAXChildrenAttribute as String) ?? []
    for c in children {
        out += findDescendants(c, role: role, depth: depth + 1, max: max)
    }
    return out
}

func findPluginWindow(in app: AXUIElement) -> AXUIElement? {
    let windows: [AXUIElement] = attr(app, kAXWindowsAttribute as String) ?? []
    // A plugin window typically has at least one AXMenuButton in its header area
    for w in windows {
        let buttons = findDescendants(w, role: kAXMenuButtonRole as String)
        if !buttons.isEmpty {
            let title: String = attr(w, kAXTitleAttribute as String) ?? ""
            // Heuristic: skip main project window (title often contains .logicx path)
            if title.contains(".logicx") { continue }
            return w
        }
    }
    return windows.first
}

func dumpAttributes(_ element: AXUIElement, indent: Int = 0) {
    let pad = String(repeating: "  ", count: indent)
    let names = attrNames(element)
    print("\(pad)\(describe(element)) — \(names.count) attributes")
    for n in names {
        var value: AnyObject?
        let r = AXUIElementCopyAttributeValue(element, n as CFString, &value)
        guard r == .success, let v = value else {
            print("\(pad)  \(n) = <nil/err>")
            continue
        }
        if let arr = v as? [Any] {
            let types = arr.prefix(5).map { "\(type(of: $0))" }.joined(separator: ",")
            print("\(pad)  \(n) = Array[\(arr.count)]  types=[\(types)]")
        } else {
            let preview = String(describing: v).prefix(140)
            print("\(pad)  \(n) = \(preview)")
        }
    }
}

// MARK: - OQ-1 probing

func probeQ1_AXPressOpensMenu(dropdown: AXUIElement) -> String {
    let result = AXUIElementPerformAction(dropdown, kAXPressAction as CFString)
    if result == .success {
        Thread.sleep(forTimeInterval: 0.3)
        let children: [AXUIElement] = attr(dropdown, kAXChildrenAttribute as String) ?? []
        let menuFound = children.contains { (attr($0, kAXRoleAttribute as String) as String?) == (kAXMenuRole as String) }
        return "AXPress result=.success; AXMenu child appeared=\(menuFound)"
    }
    return "AXPress result=\(result.rawValue) (non-success)"
}

func probeQ2_AXPressPopulatesSubmenu(menu: AXUIElement) -> String {
    let items: [AXUIElement] = attr(menu, kAXChildrenAttribute as String) ?? []
    var report: [String] = []
    report.append("Top menu has \(items.count) items. Probing each for lazy-populated submenu (NSMenuItem children only exist post-AXPress).")

    // Cocoa NSMenuItem submenus are lazily populated. Press each item and check
    // if children materialize with an AXMenu child.
    var found: Int? = nil
    for (idx, item) in items.enumerated() {
        let name: String = attr(item, kAXTitleAttribute as String) ?? (attr(item, kAXDescriptionAttribute as String) ?? "<?>")
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else { continue }
        Thread.sleep(forTimeInterval: 0.3)
        let post: [AXUIElement] = attr(item, kAXChildrenAttribute as String) ?? []
        let submenu = post.first(where: { (attr($0, kAXRoleAttribute as String) as String?) == (kAXMenuRole as String) })
        if let submenu = submenu {
            let subChildren: [AXUIElement] = attr(submenu, kAXChildrenAttribute as String) ?? []
            report.append("  Item[\(idx)] '\(name)' → submenu appeared with \(subChildren.count) children")
            // dismiss this submenu by pressing Escape equivalent (or just continue; first one is enough)
            if found == nil { found = subChildren.count }
            if found != nil && idx < 3 { continue } else { break }
        } else {
            // leaf or action item; first 3 reported for visibility
            if idx < 3 {
                report.append("  Item[\(idx)] '\(name)' → no submenu (leaf/action)")
            }
        }
    }
    if let count = found {
        report.append("VERDICT Q2: submenu population via AXPress WORKS. First observed child count: \(count)")
    } else {
        report.append("VERDICT Q2: No submenu populated. This plugin's Setting menu may be FLAT (all leaves), or AXPress fails to trigger lazy-populate.")
    }
    return report.joined(separator: "\n")
}

func probeQ5_WindowIdentityFormat(window: AXUIElement) -> String {
    let ident: String = attr(window, kAXIdentifierAttribute as String) ?? "<nil>"
    let desc: String = attr(window, kAXDescriptionAttribute as String) ?? "<nil>"
    let title: String = attr(window, kAXTitleAttribute as String) ?? "<nil>"
    return "AXIdentifier=\(ident) | AXDescription=\(desc) | AXTitle=\(title)"
}

func probeQ7_SettingDropdownRole(window: AXUIElement) -> String {
    let buttons = findDescendants(window, role: kAXMenuButtonRole as String)
    return "AXMenuButton count=\(buttons.count). First roles: \(buttons.prefix(3).map { (attr($0, kAXRoleAttribute as String) as String?) ?? "?" })"
}

// MARK: - main

print("=== F2 T0 Plugin Menu AX Probe ===")
print("Date: \(Date())")
print("")

guard let logic = getApp(bundleId: "com.apple.logic10") else {
    print("ERROR: Logic Pro (com.apple.logic10) not running. Open Logic Pro with an instrument track + plugin window.")
    exit(1)
}

print("Logic Pro AX app handle obtained.")

guard let pluginWin = findPluginWindow(in: logic) else {
    print("ERROR: No plugin window found. Open an instrument plugin (e.g. ES2) before running.")
    exit(1)
}

print("Plugin window located.")
print("")
print("--- Q5. Plugin-window identity format ---")
print(probeQ5_WindowIdentityFormat(window: pluginWin))
print("")

print("--- Q7. Setting-dropdown AXRole discovery ---")
print(probeQ7_SettingDropdownRole(window: pluginWin))
print("")

let dropdowns = findDescendants(pluginWin, role: kAXMenuButtonRole as String)
guard let dropdown = dropdowns.first else {
    print("ERROR: No AXMenuButton in plugin window. Third-party AU without Logic-managed header?")
    exit(1)
}

print("--- Q1. AXPress on Setting dropdown ---")
print(probeQ1_AXPressOpensMenu(dropdown: dropdown))
print("")

let menus: [AXUIElement] = attr(dropdown, kAXChildrenAttribute as String) ?? []
if let menu = menus.first(where: { (attr($0, kAXRoleAttribute as String) as String?) == (kAXMenuRole as String) }) {
    print("--- Q2. AXPress populates submenu children ---")
    print(probeQ2_AXPressPopulatesSubmenu(menu: menu))
    print("")

    print("--- Full Setting-menu attribute dump (depth 1) ---")
    dumpAttributes(menu)
}

print("")
print("=== GO/NO-GO verdict ===")
print("Manually review output above and fill docs/spikes/F2-T0-plugin-menu-probe-result.md.")
print("Verdict options: GO-AXPRESS | GO-CGEVENT | MIXED")
