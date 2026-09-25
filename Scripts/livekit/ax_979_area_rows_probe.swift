// #979: reads every element within two levels of each Logic window -- role, AXDescription, AXTitle,
// AXIdentifier -- plus each window's own title, so a harness can ask which strings-table row each
// area's description equals. A read that fails is kept with its raw AXError, so an element Logic
// would not describe is not mistaken for one without a description. Nothing is pressed or written.
import AppKit
import ApplicationServices

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    print("{\"error\":\"logic not running\"}")
    exit(2)
}
let root = AXUIElementCreateApplication(app.processIdentifier)

// -25205 (attribute unsupported) and -25212 (no value) are answers: the element has no such string.
// Every other status is a failed read and is recorded as one.
let answeredAbsent: Set<Int32> = [-25205, -25212]

func read(_ element: AXUIElement, _ attribute: String) -> (Any?, Int32) {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (value, status.rawValue)
}

func strings(_ element: AXUIElement, into row: inout [String: Any]) {
    for (key, attribute) in [("role", kAXRoleAttribute), ("description", kAXDescriptionAttribute),
                             ("title", kAXTitleAttribute), ("identifier", kAXIdentifierAttribute)] {
        let (value, status) = read(element, attribute)
        if let text = value as? String, !text.isEmpty {
            row[key] = text
        } else if status != 0 && !answeredAbsent.contains(status) {
            row[key + "_error"] = status
        }
    }
}

var windows: [[String: Any]] = []
func walk(_ element: AXUIElement, _ path: String, _ depth: Int, into rows: inout [[String: Any]]) {
    let (children, status) = read(element, kAXChildrenAttribute)
    guard let kids = children as? [AXUIElement] else {
        if status != 0 && !answeredAbsent.contains(status) {
            rows.append(["path": path, "children_error": status])
        }
        return
    }
    for (index, kid) in kids.enumerated() {
        var row: [String: Any] = ["depth": depth]
        strings(kid, into: &row)
        let childPath = path + "/" + ((row["role"] as? String) ?? "?") + "#\(index)"
        row["path"] = childPath
        rows.append(row)
        if depth < 2 { walk(kid, childPath, depth + 1, into: &rows) }
    }
}

let (list, listStatus) = read(root, kAXWindowsAttribute)
guard let wins = list as? [AXUIElement] else {
    print("{\"error\":\"windows read \(listStatus)\"}")
    exit(3)
}
for (index, window) in wins.enumerated() {
    var entry: [String: Any] = ["index": index]
    strings(window, into: &entry)
    var rows: [[String: Any]] = []
    walk(window, "AXWindow#\(index)", 1, into: &rows)
    entry["elements"] = rows
    windows.append(entry)
}
let out = try! JSONSerialization.data(withJSONObject: ["windows": windows], options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(out)
