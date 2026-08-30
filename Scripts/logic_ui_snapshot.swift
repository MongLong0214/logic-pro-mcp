#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

struct Snapshot: Encodable {
    let frontmost_app: String?
    let frontmost_bundle_id: String?
    let logic_window_names: [String]
    let logic_menu_items: [String]
    let blocking_dialog_present: Bool
    let error: String?
}

enum AXRead<Value> {
    case value(Value)
    case absent
    case failed(AXError)

    var value: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}

// A successful empty attribute and a failed AX request are different facts. The latter cannot
// establish that no dialog blocks the caller, so isBlockingDialogWindow and its window-list caller
// fail closed on `.failed`. The snapshot can distinguish the two at this API boundary; where it
// cannot (a successful value of an unexpected type), that is recorded as `.absent`, not disguised
// as a successful Boolean or child list.
func axAttribute<T>(_ element: AXUIElement, _ attribute: String) -> AXRead<T> {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return .failed(result) }
    guard let value else { return .absent }
    guard let typed = value as? T else { return .absent }
    return .value(typed)
}

func title(of element: AXUIElement) -> AXRead<String> {
    switch axAttribute(element, kAXTitleAttribute as String) as AXRead<String> {
    case .value(let raw):
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .absent : .value(trimmed)
    case .absent:
        return .absent
    case .failed(let error):
        return .failed(error)
    }
}

func role(of element: AXUIElement) -> AXRead<String> {
    axAttribute(element, kAXRoleAttribute as String)
}

func subrole(of element: AXUIElement) -> AXRead<String> {
    axAttribute(element, kAXSubroleAttribute as String)
}

func descriptionText(of element: AXUIElement) -> AXRead<String> {
    axAttribute(element, kAXDescriptionAttribute as String)
}

func children(of element: AXUIElement) -> AXRead<[AXUIElement]> {
    axAttribute(element, kAXChildrenAttribute as String)
}

func isKeyboardLayoutOverlayWindow(_ element: AXUIElement) -> Bool? {
    switch title(of: element) {
    case .value:
        return false
    case .absent:
        break
    case .failed:
        return nil
    }

    let child: AXUIElement
    switch children(of: element) {
    case .value(let elementChildren):
        guard elementChildren.count == 1, let onlyChild = elementChildren.first else { return false }
        child = onlyChild
    case .absent:
        return false
    case .failed:
        return nil
    }

    switch role(of: child) {
    case .value(let childRole):
        guard childRole == kAXButtonRole as String else { return false }
    case .absent:
        return false
    case .failed:
        return nil
    }
    switch descriptionText(of: child) {
    case .value(let description):
        return description.hasPrefix("com.apple.keylayout.")
    case .absent:
        return false
    case .failed:
        return nil
    }
}

func isBlockingDialogWindow(_ element: AXUIElement) -> Bool {
    // Measured today on Logic 12.x (ko):
    //
    // window                          AX subrole  AXModal  CGWindowLayer
    // Logic alert (audio interface)   AXDialog    true     8
    // Plug-in window "Studio Grand"    AXDialog    false    3
    // Arrange window                  AXStandard  false    0
    // Go To Position                  AXFloating  true     3
    //
    // AXModal is modality, unlike AXDialog's window class. A true AXModal blocks regardless of
    // subrole, which admits Go To Position without classifying the modeless plug-in AXDialog above.
    // Dialog/SystemDialog remains an additional alert admission path only when AXModal is a
    // successful-but-absent optional attribute. A failed AX read is not absence: every failed read
    // in this predicate (including subrole and the keyboard-overlay exclusion) means blocking.
    let windowSubrole = subrole(of: element)
    let modal = axAttribute(element, kAXModalAttribute as String) as AXRead<Bool>
    if case .failed = windowSubrole { return true }
    if case .failed = modal { return true }

    let isAlertSubrole: Bool
    switch windowSubrole {
    case .value(let value):
        isAlertSubrole = value == kAXDialogSubrole as String || value == kAXSystemDialogSubrole as String
    case .absent:
        isAlertSubrole = false
    case .failed:
        return true
    }

    let admitsBlocking: Bool
    switch modal {
    case .value(true):
        admitsBlocking = true
    case .value(false):
        admitsBlocking = false
    case .absent:
        admitsBlocking = isAlertSubrole
    case .failed:
        return true
    }
    guard admitsBlocking else { return false }

    // Do not turn the keyboard-layout overlay into a dialog. If its identifying reads fail, the
    // answer is unknown rather than harmless, so fail closed just as the AXModal read does.
    switch isKeyboardLayoutOverlayWindow(element) {
    case true:
        return false
    case false:
        return true
    case nil:
        return true
    }
}

let logicProKnownBundleIDs = ["com.apple.logic10", "com.apple.mobilelogic"]

func resolveLogicApp() -> NSRunningApplication? {
    let env = ProcessInfo.processInfo.environment
    if let forced = env["LOGIC_PRO_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !forced.isEmpty {
        return NSRunningApplication.runningApplications(withBundleIdentifier: forced).first
    }
    if let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
       logicProKnownBundleIDs.contains(frontmostID),
       let app = NSRunningApplication.runningApplications(withBundleIdentifier: frontmostID).first {
        return app
    }
    for bundleID in logicProKnownBundleIDs {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
    }
    return nil
}

let frontmost = NSWorkspace.shared.frontmostApplication
let logicApp = resolveLogicApp()

var error: String?
var windowNames: [String] = []
var menuItems: [String] = []
var blockingDialogPresent = false

if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) {
    error = "accessibility_not_trusted"
    // With no AX permission the window-list predicate never ran, so false would pretend a clean
    // blocker set. This boolean cannot distinguish a blocking dialog from an unreadable list; the
    // accompanying error is the distinction available to the Python caller.
    blockingDialogPresent = true
} else if let logicApp {
    let appElement = AXUIElementCreateApplication(logicApp.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 2.5)

    switch axAttribute(appElement, kAXWindowsAttribute as String) as AXRead<[AXUIElement]> {
    case .value(let windows):
        windowNames = windows.compactMap { title(of: $0).value }
        blockingDialogPresent = windows.contains(where: isBlockingDialogWindow)
    case .absent:
        // AX reported no usable window list. That is not a successful empty list for this gate.
        blockingDialogPresent = true
        error = "logic_windows_unavailable"
    case .failed(let status):
        blockingDialogPresent = true
        error = "logic_windows_unreadable_\(status.rawValue)"
    }

    switch axAttribute(appElement, kAXMenuBarAttribute as String) as AXRead<AXUIElement> {
    case .value(let menuBar):
        switch children(of: menuBar) {
        case .value(let menuBarChildren):
            menuItems = menuBarChildren.compactMap { title(of: $0).value }
        case .absent:
            if error == nil { error = "logic_menu_bar_children_unavailable" }
        case .failed(let status):
            if error == nil { error = "logic_menu_bar_children_unreadable_\(status.rawValue)" }
        }
    case .absent:
        if error == nil { error = "logic_menu_bar_unavailable" }
    case .failed(let status):
        if error == nil { error = "logic_menu_bar_unreadable_\(status.rawValue)" }
    }
} else {
    error = "logic_not_running"
}

let snapshot = Snapshot(
    frontmost_app: frontmost?.localizedName,
    frontmost_bundle_id: frontmost?.bundleIdentifier,
    logic_window_names: windowNames,
    logic_menu_items: menuItems,
    blocking_dialog_present: blockingDialogPresent,
    error: error
)

let data = try JSONEncoder().encode(snapshot)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
