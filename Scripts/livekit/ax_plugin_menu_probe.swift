#!/usr/bin/env swift
// Raw Accessibility API witness for the #301, #306, and #369 live harnesses.
//
// System Events is deliberately not used for AXDescription here. It synthesises a description from
// AXRoleDescription when AXDescription is nil, which would turn #306's observed "no slider
// descriptions" into a false positive. This helper reports the raw AX attributes and performs only
// the named, reversible presses its Python harness requests.

import AppKit
import ApplicationServices
import Foundation

typealias JSON = [String: Any]

func attr<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

func role(_ element: AXUIElement) -> String {
    attr(element, kAXRoleAttribute as String) ?? ""
}

func description(_ element: AXUIElement) -> String {
    attr(element, kAXDescriptionAttribute as String) ?? ""
}

func title(_ element: AXUIElement) -> String {
    attr(element, kAXTitleAttribute as String) ?? ""
}

func valueDescription(_ element: AXUIElement) -> String {
    attr(element, kAXValueDescriptionAttribute as String) ?? ""
}

func textValue(_ element: AXUIElement) -> String {
    attr(element, kAXValueAttribute as String) ?? ""
}

func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    guard let value: NSNumber = attr(element, attribute) else { return nil }
    return value.boolValue
}

func scalarValue(_ element: AXUIElement, _ attribute: String) -> Any? {
    if let value: String = attr(element, attribute) { return value }
    if let value: NSNumber = attr(element, attribute) {
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
        return value.doubleValue
    }
    return nil
}

func valueIsSettable(_ element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            == .success else {
        return false
    }
    return settable.boolValue
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute as String) ?? []
}

func descendants(_ root: AXUIElement, _ depth: Int = 18) -> [AXUIElement] {
    var result: [AXUIElement] = []
    func visit(_ element: AXUIElement, _ remaining: Int) {
        result.append(element)
        guard remaining > 0 else { return }
        for child in children(element) { visit(child, remaining - 1) }
    }
    visit(root, depth)
    return result
}

func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
    CFEqual(lhs, rhs)
}

func snapshot(_ element: AXUIElement) -> JSON {
    var out: JSON = [
        "role": role(element),
        "description": description(element),
        "title": title(element),
        "value_description": valueDescription(element),
        "value_settable": valueIsSettable(element),
    ]
    out["enabled"] = boolAttribute(element, kAXEnabledAttribute as String) ?? NSNull()
    out["value"] = scalarValue(element, kAXValueAttribute as String) ?? NSNull()
    return out
}

func elementName(_ element: AXUIElement) -> String {
    let fromTitle = title(element)
    return fromTitle.isEmpty ? description(element) : fromTitle
}

func emit(_ body: JSON) {
    guard JSONSerialization.isValidJSONObject(body),
          let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        print("{\"error\":\"could not encode probe result\"}")
        return
    }
    print(string)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    emit(["error": "usage: ax_plugin_menu_probe.swift <mode> <json-config>"])
    exit(2)
}

let mode = arguments[1]
let configData = Data(arguments[2].utf8)
let config = ((try? JSONSerialization.jsonObject(with: configData)) as? JSON) ?? [:]

func configuredString(_ key: String) -> String {
    config[key] as? String ?? ""
}

func configuredStrings(_ key: String) -> [String] {
    config[key] as? [String] ?? []
}

guard let logic = NSWorkspace.shared.runningApplications.first(
    where: { $0.bundleIdentifier == "com.apple.logic10" }
) else {
    emit(["error": "Logic Pro is not running"])
    exit(3)
}

let app = AXUIElementCreateApplication(logic.processIdentifier)

func windows() -> [AXUIElement] {
    attr(app, kAXWindowsAttribute as String) ?? []
}

func newWindows(since before: [AXUIElement]) -> [AXUIElement] {
    windows().filter { candidate in !before.contains(where: { same($0, candidate) }) }
}

func press(_ element: AXUIElement, _ action: String = kAXPressAction as String) -> Int {
    Int(AXUIElementPerformAction(element, action as CFString).rawValue)
}

func closeWindow(_ window: AXUIElement, closeLabel: String) -> JSON {
    let buttons = descendants(window).filter {
        role($0) == "AXButton" && description($0) == closeLabel
    }
    var result: JSON = [
        "close_button_candidates": buttons.map(snapshot),
        "pressed": false,
        "press_status": NSNull(),
    ]
    if buttons.count == 1 {
        result["pressed"] = true
        result["press_status"] = press(buttons[0])
        usleep(700_000)
    }
    result["window_still_present"] = windows().contains(where: { same($0, window) })
    return result
}

func pluginSlots(named name: String) -> [AXUIElement] {
    windows().flatMap { window in
        descendants(window).filter { role($0) == "AXGroup" && description($0) == name }
    }
}

func openPlugin(slotName: String, openLabel: String,
                beforePress: ((AXUIElement) -> Void)? = nil) -> (JSON, AXUIElement?, AXUIElement?) {
    let slots = pluginSlots(named: slotName)
    var result: JSON = [
        "slot_count": slots.count,
        "slots": slots.map(snapshot),
        "open_button_candidates": [],
        "pressed_children": [],
        "open_press_status": NSNull(),
        "opened_windows": [],
    ]
    guard slots.count == 1 else { return (result, nil, nil) }

    let slot = slots[0]
    // The caller can take a negative-control reading before this helper mutates anything. In #301
    // that is the bypass value: reading it after the Open press would not catch an Open path that
    // toggled it and toggled it back before the witness looked.
    beforePress?(slot)
    let buttons = children(slot).filter {
        role($0) == "AXButton" && description($0) == openLabel
    }
    result["slot_children"] = children(slot).map(snapshot)
    result["open_button_candidates"] = buttons.map(snapshot)
    guard buttons.count == 1 else { return (result, slot, nil) }

    let before = windows()
    result["pressed_children"] = [snapshot(buttons[0])]
    result["open_press_status"] = press(buttons[0])
    usleep(1_400_000)
    let opened = newWindows(since: before)
    result["opened_windows"] = opened.map(snapshot)
    return (result, slot, opened.count == 1 ? opened[0] : nil)
}

func bandCheckboxes(in group: AXUIElement) -> [JSON] {
    descendants(group).filter { role($0) == "AXCheckBox" }.map(snapshot)
}

func sliders(in root: AXUIElement) -> [JSON] {
    descendants(root).filter { role($0) == "AXSlider" }.map(snapshot)
}

func rowCensus(in root: AXUIElement) -> [JSON] {
    descendants(root).filter { role($0) == "AXRow" }.map { row in
        let cells = descendants(row, 6).filter { role($0) == "AXCell" }
        let cellData: [JSON] = cells.map { cell in
            let staticTexts = descendants(cell, 6).filter { role($0) == "AXStaticText" }
            let controls = descendants(cell, 6).filter {
                ["AXSlider", "AXRadioButton", "AXPopUpButton"].contains(role($0))
            }
            return [
                "static_texts": staticTexts.map { textValue($0).isEmpty ? elementName($0) : textValue($0) },
                "control_roles": controls.map(role),
            ]
        }
        return ["cells": cellData]
    }
}

func menuItems(for button: AXUIElement) -> [AXUIElement] {
    let nearby = descendants(button, 8).filter { role($0) == "AXMenuItem" }
    if !nearby.isEmpty { return nearby }
    return descendants(app, 10).filter { role($0) == "AXMenuItem" }
}

func selectView(in window: AXUIElement, viewLabels: [String], wanted: String) -> JSON {
    let buttons = descendants(window).filter {
        role($0) == "AXMenuButton" && viewLabels.contains(description($0))
    }
    var result: JSON = [
        "button_candidates": buttons.map(snapshot),
        "items": [],
        "item_candidates": [],
        "pressed": false,
        "show_menu_status": NSNull(),
        "press_status": NSNull(),
    ]
    guard buttons.count == 1 else { return result }

    result["show_menu_status"] = press(buttons[0], kAXShowMenuAction as String)
    usleep(700_000)
    let items = menuItems(for: buttons[0])
    let selected = items.filter { elementName($0) == wanted }
    result["items"] = items.map(snapshot)
    result["item_candidates"] = selected.map(snapshot)
    guard selected.count == 1 else { return result }

    result["pressed"] = true
    result["press_status"] = press(selected[0])
    usleep(1_300_000)
    return result
}

func runChannelEQ() {
    let slotName = configuredString("slot_label")
    let openLabel = configuredString("open_label")
    let closeLabel = configuredString("close_label")
    let bypassLabels = configuredStrings("bypass_labels")
    var result: JSON = ["frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
    var bypasses: [AXUIElement] = []
    var bypassBefore: Any = NSNull()
    let (openResult, slot, opened) = openPlugin(slotName: slotName, openLabel: openLabel) { slot in
        bypasses = children(slot).filter {
            role($0) == "AXCheckBox" && bypassLabels.contains(description($0))
        }
        if bypasses.count == 1 {
            bypassBefore = scalarValue(bypasses[0], kAXValueAttribute as String) ?? NSNull()
        }
    }
    result["open"] = openResult
    guard slot != nil else { emit(result); return }

    result["bypass_candidates"] = bypasses.map(snapshot)
    result["bypass_before"] = bypassBefore

    guard let opened else {
        result["bypass_after"] = bypasses.count == 1
            ? (scalarValue(bypasses[0], kAXValueAttribute as String) ?? NSNull()) : NSNull()
        emit(result)
        return
    }

    let groups = descendants(opened).filter { role($0) == "AXGroup" && description($0) == "EQ" }
    result["eq_group_count"] = groups.count
    result["band_checkboxes"] = groups.count == 1 ? bandCheckboxes(in: groups[0]) : []
    result["sliders"] = groups.count == 1 ? sliders(in: groups[0]) : []
    result["close"] = closeWindow(opened, closeLabel: closeLabel)
    result["bypass_after"] = bypasses.count == 1
        ? (scalarValue(bypasses[0], kAXValueAttribute as String) ?? NSNull()) : NSNull()
    emit(result)
}

func runPluginSlot() {
    let slots = pluginSlots(named: configuredString("slot_label"))
    var result: JSON = [
        "frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
        "slot_count": slots.count,
        "slots": slots.map(snapshot),
    ]
    result["slot_children"] = slots.count == 1 ? children(slots[0]).map(snapshot) : []
    emit(result)
}

func runCompressor() {
    let slotName = configuredString("slot_label")
    let openLabel = configuredString("open_label")
    let closeLabel = configuredString("close_label")
    let viewLabels = configuredStrings("view_labels")
    let controlsLabel = configuredString("controls_label")
    let editorLabel = configuredString("editor_label")
    var result: JSON = ["frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
    let (openResult, _, opened) = openPlugin(slotName: slotName, openLabel: openLabel)
    result["open"] = openResult
    guard let opened else { emit(result); return }

    result["native_editor_sliders"] = sliders(in: opened)
    let controlsSelection = selectView(in: opened, viewLabels: viewLabels, wanted: controlsLabel)
    result["controls_selection"] = controlsSelection
    result["controls_rows"] = rowCensus(in: opened)
    result["controls_sliders"] = sliders(in: opened)
    let editorSelection = selectView(in: opened, viewLabels: viewLabels, wanted: editorLabel)
    result["editor_selection"] = editorSelection
    result["editor_after_restore_sliders"] = sliders(in: opened)
    result["rows_after_restore"] = rowCensus(in: opened)
    result["close"] = closeWindow(opened, closeLabel: closeLabel)
    emit(result)
}

func path(_ elements: [AXUIElement]) -> [JSON] {
    elements.map(snapshot)
}

func oneMenuChild(of element: AXUIElement) -> [AXUIElement] {
    children(element).filter { role($0) == "AXMenu" }
}

func runExportMenu() {
    let fileLabels = configuredStrings("file_labels")
    let exportLabel = configuredString("export_label")
    let allTracksLabel = configuredString("all_tracks_label")
    let oneTrackLabel = configuredString("one_track_label")
    let openLabel = configuredString("open_label")
    var result: JSON = ["frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
    guard let menuBar: AXUIElement = attr(app, kAXMenuBarAttribute as String) else {
        result["error"] = "Logic has no AXMenuBar"
        emit(result)
        return
    }
    let fileItems = children(menuBar).filter {
        role($0) == "AXMenuBarItem" && fileLabels.contains(elementName($0))
    }
    result["file_candidates"] = fileItems.map(snapshot)
    guard fileItems.count == 1 else { emit(result); return }

    let menus = oneMenuChild(of: fileItems[0])
    result["file_menu_candidates"] = menus.map(snapshot)
    guard menus.count == 1 else { emit(result); return }

    let fileMenu = menus[0]
    let exportItems = children(fileMenu).filter {
        role($0) == "AXMenuItem" && elementName($0) == exportLabel
    }
    let openItems = children(fileMenu).filter {
        role($0) == "AXMenuItem" && elementName($0) == openLabel
    }
    result["export_candidates"] = exportItems.map(snapshot)
    result["open_candidates"] = openItems.map(snapshot)
    result["open_path"] = openItems.count == 1 ? path([fileItems[0], fileMenu, openItems[0]]) : []
    guard exportItems.count == 1 else { emit(result); return }

    let exportMenus = oneMenuChild(of: exportItems[0])
    result["export_menu_candidates"] = exportMenus.map(snapshot)
    guard exportMenus.count == 1 else { emit(result); return }

    let leaves = children(exportMenus[0]).filter { role($0) == "AXMenuItem" }
    let allTracks = leaves.filter { elementName($0) == allTracksLabel }
    let oneTrack = leaves.filter { elementName($0) == oneTrackLabel }
    result["all_tracks_candidates"] = allTracks.map(snapshot)
    result["one_track_candidates"] = oneTrack.map(snapshot)
    result["all_tracks_path"] = allTracks.count == 1
        ? path([fileItems[0], fileMenu, exportItems[0], exportMenus[0], allTracks[0]]) : []
    result["one_track_path"] = oneTrack.count == 1
        ? path([fileItems[0], fileMenu, exportItems[0], exportMenus[0], oneTrack[0]]) : []
    emit(result)
}

switch mode {
case "channel-eq": runChannelEQ()
case "compressor": runCompressor()
case "plugin-slot": runPluginSlot()
case "export-menu": runExportMenu()
default:
    emit(["error": "unknown mode: \(mode)"])
    exit(2)
}
