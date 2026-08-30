// Read the AXValue of every button and checkbox below ONE named control-bar AXGroup.
//
//   ./ax_control_bar_control_values '["control bar", "localized control-bar name"]'
//
// The caller supplies the label family from AXLocalePolicy through `E.label_set`; this probe does
// not carry a second, guessed localization table.  It refuses a missing or ambiguous group, a
// failed AXValue read, an unnamed/duplicate control, or zero controls.  Any of those states would
// make a `description -> AXValue` map incomplete, and an incomplete map is not evidence that no
// transport control changed.
import AppKit
import ApplicationServices
import Foundation

enum ProbeError: Error, CustomStringConvertible {
    case message(String)
    case ax(attribute: String, code: AXError)

    var description: String {
        switch self {
        case let .message(message): return message
        case let .ax(attribute, code): return "AX read \(attribute) failed: \(code.rawValue)"
        }
    }
}

func emit(_ body: [String: Any]) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard result == .success, let value else { throw ProbeError.ax(attribute: name, code: result) }
    return value
}

func string(_ element: AXUIElement, _ name: String) throws -> String {
    guard let value = try attribute(element, name) as? String else {
        throw ProbeError.message("\(name) is not a string")
    }
    return value
}

func children(_ element: AXUIElement) throws -> [AXUIElement] {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    // AX reports a leaf as `noValue`, which means zero descendants, not a failed tree read.
    if result == .noValue { return [] }
    guard result == .success, let value, let children = value as? [AXUIElement] else {
        throw ProbeError.ax(attribute: kAXChildrenAttribute as String, code: result)
    }
    return children
}

func optionalString(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func jsonValue(_ raw: CFTypeRef) -> Any? {
    if let number = raw as? NSNumber { return number }
    if let text = raw as? String { return text }
    return nil
}

let labels: [String]
do {
    let raw = CommandLine.arguments.dropFirst().first ?? ""
    guard let data = raw.data(using: .utf8),
          let decoded = try JSONSerialization.jsonObject(with: data) as? [String] else {
        throw ProbeError.message("expected one JSON array of control-bar labels")
    }
    labels = decoded.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !labels.isEmpty else { throw ProbeError.message("control-bar label family is empty") }
} catch {
    emit(["ok": false, "error": String(describing: error)])
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else {
    emit(["ok": false, "error": "Logic is not running"])
}

do {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    let mainWindow = try attribute(application, kAXMainWindowAttribute as String) as! AXUIElement
    var groups: [AXUIElement] = []

    func findControlBars(_ element: AXUIElement, depth: Int = 0) throws {
        guard depth <= 24 else { throw ProbeError.message("control-bar walk exceeded depth limit") }
        for child in try children(element) {
            if try string(child, kAXRoleAttribute as String) == (kAXGroupRole as String),
               let description = optionalString(child, kAXDescriptionAttribute as String),
               labels.contains(where: { $0.caseInsensitiveCompare(description) == .orderedSame }) {
                groups.append(child)
            }
            try findControlBars(child, depth: depth + 1)
        }
    }

    try findControlBars(mainWindow)

    // Measured 2026-08-30: Logic nests a control-bar AXGroup inside another AXGroup carrying the
    // SAME description, so a description match alone returns two. They are not two control bars —
    // one contains the other. Keep the OUTERMOST, defined structurally as the candidate that has no
    // other candidate above it. That is a containment test, not a choice by tree order, and if two
    // genuinely disjoint control bars ever appear this still refuses rather than picking one.
    var outermost: [AXUIElement] = []
    for candidate in groups {
        var enclosed = false
        for other in groups where !CFEqual(candidate, other) {
            var walker = candidate
            var hops = 0
            while hops < 24, let raw = try? attribute(walker, kAXParentAttribute as String),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let parent = raw as! AXUIElement
                if CFEqual(parent, other) { enclosed = true; break }
                walker = parent
                hops += 1
            }
            if enclosed { break }
        }
        if !enclosed { outermost.append(candidate) }
    }
    groups = outermost
    guard groups.count == 1 else {
        throw ProbeError.message("control-bar AXGroup candidates=\(groups.count) after removing nested ones")
    }
    let controlBar = groups[0]
    let controlBarDescription = try string(controlBar, kAXDescriptionAttribute as String)
    var values: [String: Any] = [:]

    func readControls(_ element: AXUIElement, depth: Int = 0) throws {
        guard depth <= 24 else { throw ProbeError.message("control-bar control walk exceeded depth limit") }
        for child in try children(element) {
            let role = try string(child, kAXRoleAttribute as String)
            if role == (kAXCheckBoxRole as String) || role == (kAXButtonRole as String) {
                let description = try string(child, kAXDescriptionAttribute as String)
                guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProbeError.message("\(role) has no AXDescription")
                }
                guard values[description] == nil else {
                    throw ProbeError.message("duplicate control AXDescription: \(description)")
                }
                guard let value = jsonValue(try attribute(child, kAXValueAttribute as String)) else {
                    throw ProbeError.message("\(role) \(description) has a non-JSON AXValue")
                }
                values[description] = value
            }
            try readControls(child, depth: depth + 1)
        }
    }

    try readControls(controlBar)
    guard !values.isEmpty else { throw ProbeError.message("control bar has zero buttons and checkboxes") }
    emit(["ok": true, "control_bar": controlBarDescription, "controls": values,
          "control_count": values.count])
} catch {
    emit(["ok": false, "error": String(describing: error)])
}
