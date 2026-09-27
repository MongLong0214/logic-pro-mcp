// Dump one Mixer strip's Accessibility subtree, pre-order, every element: role, role description,
// description, help, title, value, value description, position and size.
//
// The Mixer is the element with the most AXLayoutItem children (the Inspector's area has two).
// `--strip N` picks strip N among them, `--depth D` bounds the walk below the strip (default 20).
// Reads only: it presses nothing, focuses nothing, activates nothing.
//
//   swift ax_mixer_strip_dump.swift --strip 1 [--depth 20] [--probe-index]
//
// Written for #291 R1 on 2026-09-27 to read what an ASSIGNED send slot is: the 2026-09-13 record had
// taken the empty button before the knob for it. docs/observations/2026-09-27-an-assigned-send-is-
// a-group-named-by-its-destination-beside-its-knob.json holds its first dumps.
//
// `--probe-index` also prints, for each element whose help is non-empty, the `--slot-index`
// ax_routing_slot_menu_probe.swift would need with `--slot-prefix <that help>`: the element's
// position among every element of Logic's windows, pre-order, depth <= 13, whose help has that
// prefix -- the probe's own sweep.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (status, value)
}
func rendered(_ element: AXUIElement, _ name: String) -> String {
    let (status, value) = attribute(element, name)
    guard status == .success else { return "<\(status.rawValue)>" }
    guard let value else { return "<nil>" }
    if let text = value as? String { return text.replacingOccurrences(of: "\n", with: "\\n") }
    if let number = value as? NSNumber { return "#\(number)" }
    if CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        var point = CGPoint.zero, size = CGSize.zero
        if AXValueGetValue(axValue, .cgPoint, &point) { return "(\(Int(point.x)),\(Int(point.y)))" }
        if AXValueGetValue(axValue, .cgSize, &size) { return "\(Int(size.width))x\(Int(size.height))" }
    }
    return "<\(CFCopyTypeIDDescription(CFGetTypeID(value)) as String? ?? "?")>"
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String).1 as? [AXUIElement]) ?? []
}
func text(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name).1 as? String) ?? ""
}
func value(of flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    print("inconclusive: Logic Pro is not running"); exit(2)
}
let application = AXUIElementCreateApplication(app.processIdentifier)
let windows = (attribute(application, kAXWindowsAttribute as String).1 as? [AXUIElement]) ?? []

// The probe's sweep, verbatim in shape: every window, pre-order, depth <= 13.
var sweep: [AXUIElement] = []
func walk(_ element: AXUIElement, _ depth: Int) {
    if depth > 13 { return }
    sweep.append(element)
    for child in children(element) { walk(child, depth + 1) }
}
for window in windows { walk(window, 0) }

// The Mixer: the element with the most AXLayoutItem children, searched deeper than the sweep.
var best: (AXUIElement, Int)?
func find(_ element: AXUIElement, _ depth: Int) {
    if depth > 16 { return }
    let kids = children(element)
    let items = kids.filter { text($0, kAXRoleAttribute as String) == "AXLayoutItem" }.count
    if items > (best?.1 ?? 0) { best = (element, items) }
    for kid in kids { find(kid, depth + 1) }
}
for window in windows { find(window, 0) }
guard let (mixer, count) = best else { print("inconclusive: no AXLayoutItem container"); exit(2) }
let strips = children(mixer).filter { text($0, kAXRoleAttribute as String) == "AXLayoutItem" }
print("mixer strips: \(count)")
let stripIndex = Int(value(of: "--strip") ?? "0") ?? 0
let maxDepth = Int(value(of: "--depth") ?? "20") ?? 20
guard stripIndex >= 0, stripIndex < strips.count else { print("inconclusive: no strip \(stripIndex)"); exit(2) }
let wantProbeIndex = CommandLine.arguments.contains("--probe-index")

var order = 0
func dump(_ element: AXUIElement, _ depth: Int, _ path: [Int]) {
    if depth > maxDepth { return }
    let help = rendered(element, kAXHelpAttribute as String)
    var line = "[\(order)] path=\(path.map(String.init).joined(separator: "."))"
        + " | role=\(rendered(element, kAXRoleAttribute as String))"
        + " | roledesc=\(rendered(element, kAXRoleDescriptionAttribute as String))"
        + " | desc=\(rendered(element, kAXDescriptionAttribute as String))"
        + " | help=\(help)"
        + " | title=\(rendered(element, kAXTitleAttribute as String))"
        + " | value=\(rendered(element, kAXValueAttribute as String))"
        + " | valuedesc=\(rendered(element, "AXValueDescription"))"
        + " | pos=\(rendered(element, kAXPositionAttribute as String))"
        + " | size=\(rendered(element, kAXSizeAttribute as String))"
    if wantProbeIndex, !help.hasPrefix("<") {
        let matching = sweep.filter { text($0, kAXHelpAttribute as String).hasPrefix(help) }
        if let at = matching.firstIndex(where: { CFEqual($0, element) }) {
            line += " | probe-index=\(at)/\(matching.count)"
        }
    }
    print(line)
    order += 1
    for (index, child) in children(element).enumerated() { dump(child, depth + 1, path + [index]) }
}
dump(strips[stripIndex], 0, [stripIndex])
