#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

struct Request: Decodable {
    let windowMarkers: [String]
    let buttonLabels: [String]
}

struct Response: Encodable {
    let ok: Bool
    let reason: String?
}

func emit(_ response: Response) {
    let data = try! JSONEncoder().encode(response)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func attribute<T>(_ element: AXUIElement, _ attributeName: String) -> T? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attributeName as CFString, &value)
    guard result == .success else { return nil }
    return value as? T
}

func stringAttribute(_ element: AXUIElement, _ attributeName: String) -> String {
    let value: String? = attribute(element, attributeName)
    return value ?? ""
}

func children(of element: AXUIElement) -> [AXUIElement] {
    let value: [AXUIElement]? = attribute(element, kAXChildrenAttribute as String)
    return value ?? []
}

func containsMarker(_ value: String, markers: [String]) -> Bool {
    let haystack = value.lowercased()
    return markers.contains { haystack.contains($0.lowercased()) }
}

func buttonMatches(_ element: AXUIElement, labels: [String]) -> Bool {
    let role = stringAttribute(element, kAXRoleAttribute as String)
    guard role == kAXButtonRole as String else { return false }
    let candidates = [
        stringAttribute(element, kAXTitleAttribute as String),
        stringAttribute(element, kAXDescriptionAttribute as String),
        stringAttribute(element, kAXValueAttribute as String),
    ]
    return candidates.contains { candidate in
        labels.contains { $0 == candidate }
    }
}

func findButton(in element: AXUIElement, labels: [String], depth: Int = 0) -> AXUIElement? {
    if depth > 8 { return nil }
    if buttonMatches(element, labels: labels) {
        return element
    }
    for child in children(of: element) {
        if let found = findButton(in: child, labels: labels, depth: depth + 1) {
            return found
        }
    }
    return nil
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try? JSONDecoder().decode(Request.self, from: input) else {
    emit(Response(ok: false, reason: "invalid_request"))
    exit(1)
}

guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) else {
    emit(Response(ok: false, reason: "accessibility_not_trusted"))
    exit(2)
}

guard let logicApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    emit(Response(ok: false, reason: "logic_not_running"))
    exit(3)
}

logicApp.activate()
let appElement = AXUIElementCreateApplication(logicApp.processIdentifier)
AXUIElementSetMessagingTimeout(appElement, 2.5)
let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute as String) ?? []

for window in windows {
    let title = stringAttribute(window, kAXTitleAttribute as String)
    guard containsMarker(title, markers: request.windowMarkers) else { continue }
    guard let button = findButton(in: window, labels: request.buttonLabels) else {
        emit(Response(ok: false, reason: "missing_button"))
        exit(4)
    }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    if result == .success {
        emit(Response(ok: true, reason: nil))
        exit(0)
    }
    emit(Response(ok: false, reason: "press_failed_\(result.rawValue)"))
    exit(5)
}

emit(Response(ok: false, reason: "missing_window"))
exit(6)
