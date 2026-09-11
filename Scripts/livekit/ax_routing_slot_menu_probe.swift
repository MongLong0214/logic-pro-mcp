// Do the channel-strip routing slots open a menu, and can a destination be chosen by name?
//
// The 2026-09-09 record said these slots "answer a press with success and do nothing". That reading
// watched the SLOT'S OWN VALUE, which an AXPress never changes: the press opens a menu. This probe
// watches for the menu, and then selects a destination and reads the slot back.
//
// It restores what it changes. `--select` is opt-in precisely because it mutates a real project;
// without it the probe reads only.
//
// `No Output` was rejected as this probe's test destination. It is a legitimate choice that leaves
// the strip with NO menu to
// open afterwards, so a probe using it would measure its own test value and report a wall --
// which is exactly how the non-reproducibility in this repository's first attempt arose.
//
//   swiftc -O ax_routing_slot_menu_probe.swift -o probe && ./probe [--mute-labels A B] [--select <title>]
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func text(_ element: AXUIElement, _ name: String) -> String { (attribute(element, name) as? String) ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    print("inconclusive: Logic Pro is not running")
    exit(2)
}
app.activate()
usleep(900_000)
print("frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")")
let application = AXUIElementCreateApplication(app.processIdentifier)

func sweep() -> [AXUIElement] {
    var all: [AXUIElement] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        if depth > 13 { return }
        all.append(element)
        for child in children(element) { walk(child, depth + 1) }
    }
    for window in (attribute(application, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] { walk(window, 0) }
    return all
}
func openMenus() -> [AXUIElement] { sweep().filter { text($0, kAXRoleAttribute as String) == "AXMenu" } }
func escape() {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(700_000)
}
let slotPrefix = "Output slot"
func outputSlot() -> AXUIElement? { sweep().first { text($0, kAXHelpAttribute as String).hasPrefix(slotPrefix) } }

guard let slot = outputSlot() else { print("inconclusive: no \(slotPrefix) in the tree"); exit(2) }
let originalDestination = text(slot, kAXDescriptionAttribute as String)
print("slot destination: \(originalDestination)")

// THE POSITIVE CONTROL: a track-header Mute must move before any silence below counts as a reading.
// The spelling comes from the caller, parsed out of `AXLocalePolicy.trackMuteButton`, which carries
// `음소거` and `ミュート` as well. An English literal here would lose the control on a Japanese Logic
// and the run would then report a wall it had no instrument to see.
let muteLabels: [String] = {
    guard let index = CommandLine.arguments.firstIndex(of: "--mute-labels") else { return ["Mute"] }
    let rest = CommandLine.arguments.dropFirst(index + 1).prefix { !$0.hasPrefix("--") }
    return rest.isEmpty ? ["Mute"] : Array(rest)
}()
if let mute = sweep().first(where: {
    text($0, kAXRoleAttribute as String) == "AXCheckBox" && muteLabels.contains(text($0, kAXDescriptionAttribute as String))
}) {
    _ = AXUIElementSetAttributeValue(mute, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(400_000)
    let before = attribute(mute, kAXValueAttribute as String) as? Int
    _ = AXUIElementPerformAction(mute, kAXPressAction as CFString)
    usleep(700_000)
    let during = attribute(mute, kAXValueAttribute as String) as? Int
    _ = AXUIElementPerformAction(mute, kAXPressAction as CFString)
    usleep(700_000)
    let after = attribute(mute, kAXValueAttribute as String) as? Int
    print("control mute moved: \((before != during && before == after) ? 1 : 0)")
} else {
    print("control mute moved: 0")
}

let pressRC = AXUIElementPerformAction(slot, kAXPressAction as CFString)
usleep(1_200_000)
let menus = openMenus()
print("press rc: \(pressRC.rawValue)")
print("menus opened: \(menus.count)")

var enabledTitles: [String] = []
var selectable: [String: AXUIElement] = [:]
var duplicated: Set<String> = []
for menu in menus {
    for item in children(menu) where text(item, kAXRoleAttribute as String) == "AXMenuItem" {
        guard (attribute(item, kAXEnabledAttribute as String) as? Bool) == true else { continue }
        let title = text(item, kAXTitleAttribute as String)
        guard !title.isEmpty else { continue }
        enabledTitles.append(title)
        if selectable.updateValue(item, forKey: title) != nil { duplicated.insert(title) }
    }
}
print("enabled titled items: \(enabledTitles.count)")
print("distinct titles: \(Set(enabledTitles).count)")
print("titles appearing more than once: \(duplicated.count)")

let wantedIndex = CommandLine.arguments.firstIndex(of: "--select")
guard let index = wantedIndex, index + 1 < CommandLine.arguments.count else {
    escape()
    print("menus after escape: \(openMenus().count)")
    print("selected: skipped")
    exit(0)
}
let wanted = CommandLine.arguments[index + 1]
guard !duplicated.contains(wanted), let item = selectable[wanted] else {
    escape()
    print("menus after escape: \(openMenus().count)")
    print("selected: refused — '\(wanted)' is absent or duplicated, and a pick would be a guess")
    exit(3)
}
_ = AXUIElementPerformAction(item, kAXPressAction as CFString)
usleep(1_800_000)
if !openMenus().isEmpty { escape() }
let newDestination = outputSlot().map { text($0, kAXDescriptionAttribute as String) } ?? ""
print("destination after select: \(newDestination)")
print("readback changed: \((newDestination != originalDestination) ? 1 : 0)")
print("selected: \(wanted)")
print("restore with: Edit > Undo Change Output in Channel Strip")
