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

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func bool(_ e: AXUIElement, _ a: String) -> Bool? { attr(e, a) as? Bool }
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

let interesting: Set<String> = [
    "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXStaticText",
    "AXTextField", "AXCell", "AXImage", "AXTabGroup", "AXRadioGroup", "AXMenuButton",
    // The sheet node itself, because how a sheet NAMES itself is the thing a classifier reads and
    // the thing #883 turned out to be about. Leaving it out would report every control on a sheet
    // that could not be identified at all.
    "AXSheet",
]

func controls(_ e: AXUIElement, depth: Int, into out: inout [[String: Any]]) {
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
    for child in kids(e) { controls(child, depth: depth + 1, into: &out) }
}

guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.logic10").first else {
    FileHandle.standardError.write(Data("Logic Pro is not running\n".utf8))
    exit(2)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
var windows: [[String: Any]] = []
for window in (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
    var rows: [[String: Any]] = []
    controls(window, depth: 0, into: &rows)
    var entry: [String: Any] = [
        "role": str(window, kAXRoleAttribute as String) ?? "?",
        "subrole": str(window, kAXSubroleAttribute as String) ?? "",
        "title": str(window, kAXTitleAttribute as String) ?? "",
        "description": str(window, kAXDescriptionAttribute as String) ?? "",
        "modal": bool(window, "AXModal") ?? false,
        "controls": rows,
    ]
    windows.append(entry)
}
let data = try JSONSerialization.data(
    withJSONObject: ["locale": Locale.current.identifier, "windows": windows],
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
