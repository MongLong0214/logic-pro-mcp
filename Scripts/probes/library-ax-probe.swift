#!/usr/bin/env swift
// T0 spike — probe Logic Pro 12 AXBrowser for passive tree-exposing attributes.
//
// Usage:
//   swift Scripts/library-ax-probe.swift          (with Logic Pro open, Library visible)
//
// Output: indented tree of every AX attribute on the Library AXBrowser and its
// first-level children. Used to decide GO-PASSIVE vs GO-CLICK-BASED for T2.

import ApplicationServices
import Cocoa
import Foundation

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
    let value: String = attr(element, kAXValueAttribute as String) ?? ""
    let tail = [desc, title, value].filter { !$0.isEmpty }.joined(separator: " | ")
    return tail.isEmpty ? role : "\(role)  [\(tail)]"
}

func findDescendant(
    _ element: AXUIElement, role: String, desc: String? = nil, depth: Int, max: Int = 12
) -> AXUIElement? {
    if depth > max { return nil }
    let r: String = attr(element, kAXRoleAttribute as String) ?? ""
    let d: String = attr(element, kAXDescriptionAttribute as String) ?? ""
    if r == role && (desc == nil || d == desc) { return element }
    let children: [AXUIElement] = attr(element, kAXChildrenAttribute as String) ?? []
    for c in children {
        if let f = findDescendant(c, role: role, desc: desc, depth: depth + 1, max: max) { return f }
    }
    return nil
}

func findBrowsers(_ element: AXUIElement, depth: Int = 0, max: Int = 12) -> [AXUIElement] {
    if depth > max { return [] }
    let r: String = attr(element, kAXRoleAttribute as String) ?? ""
    var results: [AXUIElement] = []
    if r == (kAXBrowserRole as String) { results.append(element) }
    let children: [AXUIElement] = attr(element, kAXChildrenAttribute as String) ?? []
    for c in children {
        results += findBrowsers(c, depth: depth + 1, max: max)
    }
    return results
}

func dumpAttributes(_ element: AXUIElement, indent: Int = 0, printValues: Bool = true) {
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

// --- main ---

guard let logic = getApp(bundleId: "com.apple.logic10") else {
    print("ERROR: Logic Pro not running")
    exit(1)
}

var mainWin: AnyObject?
AXUIElementCopyAttributeValue(logic, kAXMainWindowAttribute as CFString, &mainWin)
guard let window = mainWin else {
    print("ERROR: No main window. Open a project in Logic Pro.")
    exit(1)
}
let win = window as! AXUIElement

let browsers = findBrowsers(win)
print("Found \(browsers.count) AXBrowser element(s) in Logic main window.")
guard !browsers.isEmpty else {
    print("No AXBrowser found. Is Library panel open (⌘L)?")
    exit(1)
}

// Try to pick the Library browser specifically
var library: AXUIElement? = nil
for b in browsers {
    let d: String = attr(b, kAXDescriptionAttribute as String) ?? ""
    if d == "라이브러리" || d.lowercased() == "library" {
        library = b; break
    }
}
let target = library ?? browsers.first!

print("\n==================== AXBrowser attributes ====================\n")
dumpAttributes(target)

print("\n==================== Browser children (1 level) ====================\n")
let kids: [AXUIElement] = attr(target, kAXChildrenAttribute as String) ?? []
for (i, k) in kids.enumerated() {
    print("\n-- child[\(i)]")
    dumpAttributes(k, indent: 1)
}

print("\n==================== Grandchildren of child[0] ====================\n")
if let first = kids.first {
    let sub: [AXUIElement] = attr(first, kAXChildrenAttribute as String) ?? []
    for (i, s) in sub.prefix(10).enumerated() {
        print("\n-- child[0].sub[\(i)]")
        dumpAttributes(s, indent: 2)
    }
}

print("\n==================== Done ====================")
