// Census of the dialog or sheet Logic is showing right now: how it names itself, and every control
// a reconciler could press, with the text each control actually carries.
//
//   ./ax_sheet_census            ->  {"windows":[{"title":…,"description":…,"controls":[…]}]}
//
// This exists because a LabelSet with no entry for a locale is INVISIBLE from inside the product:
// the matcher simply never matches, the sheet stays open, and the failure reads as "the dialog did
// not respond" rather than "nobody ever read this dialog". #883 is exactly that shape — a German
// New Track sheet the reconciler cannot name, reported by an operator whose Logic blocked on it.
//
// A sheet is NOT fetched as a window attribute here. A first version asked the window for `AXSheets`
// and got nothing back while System Events reported one sheet on that same window — a read that is
// silently empty is worse than no read, so the sheet is left to the ordinary descendant walk, which
// found every control on it. `AXSheet` is simply one more node on the way down.
//
// It reads and never presses. A census that could click would be a census that can change the thing
// it is measuring, and the sheets this is aimed at are the ones that block a project when clicked
// wrong.
//
// WHAT IT CANNOT RULE OUT: it reports what AX exposes, so a control Logic draws without an AX node
// is absent here and absent to the product too — indistinguishable from this instrument alone. A
// tile that answers no title and no description is reported with its role and empty text rather
// than skipped, so that case stays visible instead of looking like it was not there.
import AppKit
import ApplicationServices
import Foundation

func attrRead(_ e: AXUIElement, _ a: String) -> (value: CFTypeRef?, error: AXError) {
    var v: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return (v, error)
}
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    let read = attrRead(e, a)
    return read.error == .success ? read.value : nil
}
/// `String(describing:)` on an AXError prints `AXError(rawValue: -25212)`, which tells a reader
/// nothing about whether the read failed or the element simply has no such value.
func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(e.rawValue))"
    }
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func bool(_ e: AXUIElement, _ a: String) -> Bool? { attr(e, a) as? Bool }

let interesting: Set<String> = [
    "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXStaticText",
    "AXTextField", "AXCell", "AXImage", "AXTabGroup", "AXRadioGroup", "AXMenuButton",
    // The sheet node itself, because how a sheet NAMES itself is the thing a classifier reads and
    // the thing #883 turned out to be about. Leaving it out would report every control on a sheet
    // that could not be identified at all.
    "AXSheet",
]

func controls(
    _ e: AXUIElement,
    depth: Int,
    into out: inout [[String: Any]],
    childReadFailures: inout [[String: Any]]
) {
    guard depth < 14 else { return }
    let role = str(e, kAXRoleAttribute as String) ?? "?"
    if interesting.contains(role) {
        var row: [String: Any] = ["role": role, "depth": depth]
        for (key, name) in [("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
                            ("value", kAXValueAttribute), ("help", kAXHelpAttribute)] {
            if let s = str(e, name as String), !s.isEmpty { row[key] = s }
        }
        if let enabled = bool(e, kAXEnabledAttribute as String) { row["enabled"] = enabled }
        if let selected = bool(e, kAXSelectedAttribute as String) { row["selected"] = selected }
        if row["title"] != nil || row["description"] != nil || row["value"] != nil
            || role == "AXButton" || role == "AXRadioButton" || role == "AXSheet" {
            out.append(row)
        }
    }
    let childRead = attrRead(e, kAXChildrenAttribute as String)
    // `.noValue` and `.attributeUnsupported` are not failures: they are how the API says this
    // element HAS no children. Recording them as failures was the first cut of this check and it
    // reported hundreds of them against a live Logic on the first run -- the same conflation of a
    // failed reading with an empty one, pointed the other way. Only an error meaning the read could
    // not be performed belongs in `child_read_failures`.
    let childlessButReadable: Set<AXError> = [.noValue, .attributeUnsupported]
    if childRead.error == .success, let children = childRead.value as? [AXUIElement] {
        for child in children {
            controls(
                child,
                depth: depth + 1,
                into: &out,
                childReadFailures: &childReadFailures
            )
        }
    } else if !childlessButReadable.contains(childRead.error) {
        childReadFailures.append([
            "attribute": kAXChildrenAttribute as String,
            "depth": depth,
            "role": role,
            "ax_error": childRead.error == .success
                ? "success_without_child_array"
                : axErrorName(childRead.error),
            "ax_error_code": childRead.error.rawValue,
        ])
    }
}

guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.logic10").first else {
    FileHandle.standardError.write(Data("Logic Pro is not running\n".utf8))
    exit(2)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
var windows: [[String: Any]] = []
let windowRead = attrRead(ax, kAXWindowsAttribute as String)
guard windowRead.error == .success else {
    let message = "Could not read AXWindows: \(axErrorName(windowRead.error)) "
        + "(code \(windowRead.error.rawValue))\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(3)
}
guard let applicationWindows = windowRead.value as? [AXUIElement] else {
    FileHandle.standardError.write(Data("AXWindows read succeeded but returned no window list\n".utf8))
    exit(3)
}
for window in applicationWindows {
    var rows: [[String: Any]] = []
    var childReadFailures: [[String: Any]] = []
    controls(window, depth: 0, into: &rows, childReadFailures: &childReadFailures)
    let entry: [String: Any] = [
        "role": str(window, kAXRoleAttribute as String) ?? "?",
        "subrole": str(window, kAXSubroleAttribute as String) ?? "",
        "title": str(window, kAXTitleAttribute as String) ?? "",
        "description": str(window, kAXDescriptionAttribute as String) ?? "",
        "modal": bool(window, "AXModal") ?? false,
        "controls": rows,
        "child_read_failures": childReadFailures,
    ]
    windows.append(entry)
}
let data = try JSONSerialization.data(
    withJSONObject: ["locale": Locale.current.identifier, "windows": windows],
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
