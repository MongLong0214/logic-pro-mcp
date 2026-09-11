#!/usr/bin/env swift
// #864 — what Logic's Edit menu says about its undo stack, and how an entry can be IDENTIFIED.
//
// Read-only. It opens the Edit menu, reads every entry's title, enabled state and keyboard
// shortcut, and closes the menu again. Nothing is pressed, so the undo stack is not touched.
//
// The question it answers is narrow and load-bearing: the wording of the Undo entry is BOTH
// localized and state-dependent, so it cannot be the identity of the row. The shortcut can.

import AppKit
import ApplicationServices
import Foundation

func children(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
          let a = v as? [AXUIElement] else { return [] }
    return a
}

func str(_ e: AXUIElement, _ a: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v as? String
}

func num(_ e: AXUIElement, _ a: String) -> Int? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return (v as? NSNumber)?.intValue
}

func flag(_ e: AXUIElement, _ a: String) -> Bool? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return (v as? NSNumber)?.boolValue
}

func emit(_ obj: [String: Any]) {
    let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").lowercased().contains("logic")
}) else {
    emit(["outcome": "logic_not_running"])
    exit(2)
}
app.activate()
Thread.sleep(forTimeInterval: 1.0)

let ax = AXUIElementCreateApplication(app.processIdentifier)
var menuBarRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
      let menuBar = menuBarRef else {
    emit(["outcome": "no_menu_bar"])
    exit(2)
}

// The Edit menu's own spelling, MEASURED rather than translated. Logic localizes its menu-bar
// titles independently of the host locale, so each candidate is tried and the one that answers is
// reported — a run on another build says which spelling it found rather than assuming.
let editNames = ["Edit", "편집", "編集"]
var barItem: AXUIElement?
var barName = ""
for candidate in editNames {
    if let found = children(menuBar as! AXUIElement).first(where: {
        str($0, kAXTitleAttribute as String) == candidate
    }) {
        barItem = found
        barName = candidate
        break
    }
}
guard let barItem else {
    emit(["outcome": "edit_menu_not_found", "spellings_tried": editNames])
    exit(1)
}

// OPEN IT. The suffix of the Undo entry is only populated while the menu is open; reading it closed
// returns the bare word. That asymmetry is one of this record's findings, so both reads are taken.
let closedTitles = children(barItem).flatMap { children($0) }.compactMap {
    str($0, kAXTitleAttribute as String)
}
let opened = AXUIElementPerformAction(barItem, kAXPressAction as CFString) == .success
Thread.sleep(forTimeInterval: 0.6)

var rows: [[String: Any]] = []
for menu in children(barItem) {
    for item in children(menu) {
        guard let title = str(item, kAXTitleAttribute as String) else { continue }
        rows.append([
            "title": title,
            "enabled": flag(item, kAXEnabledAttribute as String) as Any,
            "cmd_char": str(item, "AXMenuItemCmdChar") ?? "",
            "cmd_modifiers": num(item, "AXMenuItemCmdModifiers") as Any,
        ])
        if rows.count >= 8 { break }
    }
    if !rows.isEmpty { break }
}

// Close it again. A menu left open wedges Logic for every later run.
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.4)

// Rows whose shortcut is the undo/redo pair: cmd char Z with modifier mask 0 and 1. The mask's
// bit 0 is shift, so these are ⌘Z and ⇧⌘Z; any other mask on the same character is a different
// command that merely shares the letter.
func rowsWithShortcut(_ mods: Int) -> [[String: Any]] {
    rows.filter {
        ($0["cmd_char"] as? String)?.uppercased() == "Z" && ($0["cmd_modifiers"] as? Int) == mods
    }
}

emit([
    "outcome": "read",
    "edit_menu_spelling": barName,
    "menu_opened": opened,
    "titles_while_closed": Array(closedTitles.prefix(8)),
    "entries": rows,
    "rows_matching_cmd_z_no_modifier": rowsWithShortcut(0).count,
    "rows_matching_shift_cmd_z": rowsWithShortcut(1).count,
    "titles_prefixed_undo": rows.compactMap { ($0["title"] as? String) }
        .filter { $0.hasPrefix("Undo") }.count,
    "titles_containing_undo": rows.compactMap { ($0["title"] as? String) }
        .filter { $0.contains("Undo") || $0.contains("실행 취소") }.count,
])
