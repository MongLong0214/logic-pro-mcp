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
// Which slot to look at. The default is the Output slot this probe was written for; `--slot-prefix`
// aims the same instrument at the Send and Group slots, which the 2026-09-11 record read but never
// opened. The prefix is a HELP-text prefix and is supplied by the caller from `AXLocalePolicy`, the
// same way the Mute spelling below is — a literal here would make the probe English-only, which is
// the defect its own comment warns about two paragraphs down.
let slotPrefix: String = {
    guard let index = CommandLine.arguments.firstIndex(of: "--slot-prefix"),
          index + 1 < CommandLine.arguments.count,
          !CommandLine.arguments[index + 1].hasPrefix("--") else { return "Output slot" }
    return CommandLine.arguments[index + 1]
}()
/// Which slot carrying the prefix to act on. `first` is the default and was fine while a strip
/// showed ONE send slot; once a send is assigned Logic opens further empty ones, and `first` then
/// answers about whichever the tree happens to order first. `--slot-index N` aims at a named one,
/// so "which slot holds the assignment" is a question this probe can ask instead of assume.
let slotIndex: Int = {
    guard let index = CommandLine.arguments.firstIndex(of: "--slot-index"),
          index + 1 < CommandLine.arguments.count,
          let value = Int(CommandLine.arguments[index + 1]) else { return 0 }
    return value
}()

/// `--assigned` aims at the send slot that actually HOLDS the assignment.
///
/// Which one that is cannot be answered by the slots alone: every send slot reads `send button`
/// with an empty value, and once one is assigned the strip opens further empty ones. What DOES
/// distinguish it is the Send Level control, which exists only while a send is assigned — so the
/// assigned slot is the `send button` immediately preceding the `send knob` in tree order.
///
/// This mattered: reading `first` after an assignment reported the no-send entry still marked, and
/// the strip had grown from one slot to three, so that reading was about an EMPTY slot.
let wantAssignedSlot = CommandLine.arguments.contains("--assigned")

func assignedSendSlot() -> AXUIElement? {
    var previousSlot: AXUIElement?
    for element in sweep() {
        let description = text(element, kAXDescriptionAttribute as String)
        if description == "send knob" { return previousSlot }
        if text(element, kAXHelpAttribute as String).hasPrefix(slotPrefix) { previousSlot = element }
    }
    return nil
}

func outputSlot() -> AXUIElement? {
    if wantAssignedSlot { return assignedSendSlot() }
    let matching = sweep().filter { text($0, kAXHelpAttribute as String).hasPrefix(slotPrefix) }
    guard slotIndex >= 0, slotIndex < matching.count else { return nil }
    return matching[slotIndex]
}

/// Every slot whose help text carries the prefix, not only the first. A strip has ONE output and
/// several sends, so a Send measurement that looked at `first` would report one send and say
/// nothing about whether the rest behave alike.
func allSlots() -> [AXUIElement] { sweep().filter { text($0, kAXHelpAttribute as String).hasPrefix(slotPrefix) } }

// `--dump-slots` lists EVERY slot carrying the prefix, with the three attributes that could name a
// destination. A strip has one output and several sends, and after a send is assigned Logic opens a
// further empty one — so reading `first` alone cannot tell an assignment that did not land from one
// that landed on an element this probe was not looking at.
if CommandLine.arguments.contains("--dump-slots") {
    for (index, element) in allSlots().enumerated() {
        print("slot[\(index)] desc=\(text(element, kAXDescriptionAttribute as String))"
            + " | value=\((attribute(element, kAXValueAttribute as String) as? String) ?? "")"
            + " | help=\(String(text(element, kAXHelpAttribute as String).prefix(40)))")
    }
}

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
// `--marks` reports which items the MENU ITSELF marks as chosen.
//
// The 2026-09-12 record established that a send assignment lands and is not named back at the
// source: every slot still reads `send button` with an empty value, and the only element naming the
// destination is the receiving strip's input. That record listed the menu's own mark as untried.
// It is the one candidate that sidesteps the identity problem this ADR is blocked on — the checked
// entry is read from the SAME menu the write used, so it needs no mapping between `Bus 1` on the
// strip and `Sum 1` in the menu.
//
// Printed for every item, enabled or not, because an item Logic disables can still be the one it
// marks, and a filter that assumed otherwise would report the absence of a mark that is there.
if CommandLine.arguments.contains("--marks") {
    var marked = 0
    for menu in menus {
        for item in children(menu) where text(item, kAXRoleAttribute as String) == "AXMenuItem" {
            let mark = text(item, kAXMenuItemMarkCharAttribute as String)
            guard !mark.isEmpty else { continue }
            marked += 1
            print("marked: \(text(item, kAXTitleAttribute as String)) mark=\(mark)")
        }
    }
    print("marked items: \(marked)")
}

// `--print-titles N` dumps what the menu offers. Choosing a destination for `--select` by guessing
// its spelling is how a probe ends up measuring its own test value; this prints what is there.
if let titlesIndex = CommandLine.arguments.firstIndex(of: "--print-titles") {
    let limit = titlesIndex + 1 < CommandLine.arguments.count
        ? Int(CommandLine.arguments[titlesIndex + 1]) ?? 20 : 20
    for title in enabledTitles.prefix(limit) { print("title: \(title)") }
}

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
