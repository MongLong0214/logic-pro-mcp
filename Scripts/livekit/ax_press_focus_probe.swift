// Does AXPress actuate an UNFOCUSED arrange track-header button?
//
// Measured 2026-09-11: no. Nineteen track-header `Mute` checkboxes are identical in every attribute
// a census reads -- role, description, AXEnabled, action names, value, ancestors, the sixteen
// attribute names -- and pressing them does not do the same thing. The only non-positional
// difference between one that actuates and one that does not is `AXFocused`.
//
// The failure signature of an unfocused press is `rc=0` and nothing changed, which is exactly the
// signature this repository has recorded elsewhere as "the press is refused". So this probe exists
// to keep the two apart.
//
// It carries its own positive control: a press that IS expected to land must land, or the run is
// reported inconclusive rather than as a finding. A silent instrument and a silent surface read the
// same, and that is how an earlier measurement in this repository went wrong.
//
//   swiftc -O ax_press_focus_probe.swift -o probe && ./probe <mute-label>...
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func text(_ element: AXUIElement, _ name: String) -> String { (attribute(element, name) as? String) ?? "" }
func flag(_ element: AXUIElement, _ name: String) -> Bool? { attribute(element, name) as? Bool }
func intValue(_ element: AXUIElement) -> Int? { attribute(element, kAXValueAttribute as String) as? Int }
func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    print("inconclusive: Logic Pro is not running")
    exit(2)
}
// Frontmost, and SAID SO. A non-key window answers AXPress with kAXErrorCannotComplete and changes
// nothing, which is a third way to produce the same signature.
app.activate()
usleep(900_000)
let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
print("frontmost: \(frontmost)")

let application = AXUIElementCreateApplication(app.processIdentifier)
var everything: [AXUIElement] = []
func walk(_ element: AXUIElement, _ depth: Int) {
    if depth > 13 { return }
    everything.append(element)
    for child in children(element) { walk(child, depth + 1) }
}
let windows = (attribute(application, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
for window in windows { walk(window, 0) }

// The label comes from the caller, not from this file. `AXLocalePolicy.trackMuteButton` carries
// `Mute` plus `음소거` and `ミュート`, and an English literal here would make the probe answer
// "no Mute buttons" on a Japanese Logic -- which reads as a finding rather than as a blind probe.
// `Scripts/observations/reverify-axpress-focus.sh` passes the set, parsed from the policy.
let muteLabels: [String] = {
    // Parse the FLAG, not "everything after argv[0]" -- the earlier spelling swallowed the other
    // options and would have matched an element described `--mute-labels`.
    guard let index = CommandLine.arguments.firstIndex(of: "--mute-labels") else { return ["Mute"] }
    let rest = CommandLine.arguments.dropFirst(index + 1).prefix { !$0.hasPrefix("--") }
    return rest.isEmpty ? ["Mute"] : Array(rest)
}()
print("mute labels: \(muteLabels.joined(separator: "|"))")
// Logic's track headers describe themselves with a help string that begins with this. Supplied by
// the caller for the same reason the Mute label is: it is localised.
let trackHeaderHelpPrefix: String = {
    guard let index = CommandLine.arguments.firstIndex(of: "--track-header-help-prefix"),
          index + 1 < CommandLine.arguments.count else { return "Track header" }
    return CommandLine.arguments[index + 1]
}()

let mutes = everything.filter { element in
    guard text(element, kAXRoleAttribute as String) == "AXCheckBox" else { return false }
    let description = text(element, kAXDescriptionAttribute as String)
    return muteLabels.contains(description)
}
print("mute buttons: \(mutes.count)")
print("focused mute buttons: \(mutes.filter { flag($0, kAXFocusedAttribute as String) == true }.count)")

// An element nobody has touched, that is not the focused one, AND that hangs under a track header.
// The label alone is not enough: `AXLocalePolicy.trackMuteButton` also matches the Inspector
// strip's Mute, and the product searches INSIDE a header (`AXLogicProElements+Tracks`). Measuring a
// different element class would make this reverify answer a question the record does not ask.
func parent(_ element: AXUIElement) -> AXUIElement? {
    attribute(element, kAXParentAttribute as String).map { $0 as! AXUIElement }
}
func underTrackHeader(_ element: AXUIElement) -> Bool {
    var cursor = parent(element)
    for _ in 0..<4 {
        guard let node = cursor else { return false }
        if text(node, kAXRoleAttribute as String) == "AXLayoutItem",
           text(node, kAXHelpAttribute as String).hasPrefix(trackHeaderHelpPrefix) {
            return true
        }
        cursor = parent(node)
    }
    return false
}
let headerMutes = mutes.filter(underTrackHeader)
print("mute buttons under a track header: \(headerMutes.count)")
guard let subject = headerMutes.first(where: { flag($0, kAXFocusedAttribute as String) != true && intValue($0) == 0 }) else {
    print("inconclusive: no unfocused, unmuted track-header Mute to test")
    exit(2)
}

let startValue = intValue(subject)
_ = AXUIElementPerformAction(subject, kAXPressAction as CFString)
usleep(1_200_000)
let afterUnfocused = intValue(subject)
let unfocusedActuated = (startValue != afterUnfocused)
print("unfocused press actuated: \(unfocusedActuated ? 1 : 0)")

let focusRC = AXUIElementSetAttributeValue(subject, kAXFocusedAttribute as CFString, kCFBooleanTrue)
usleep(700_000)
let focusTook = flag(subject, kAXFocusedAttribute as String) == true
print("focus set rc: \(focusRC.rawValue)")
print("focus took: \(focusTook ? 1 : 0)")

_ = AXUIElementPerformAction(subject, kAXPressAction as CFString)
usleep(1_200_000)
let afterFocused = intValue(subject)
let focusedActuated = (afterUnfocused != afterFocused)
// THE POSITIVE CONTROL. If this did not move, the instrument is silent and the zero above says
// nothing about focus.
print("focused press actuated: \(focusedActuated ? 1 : 0)")

// Leave the project as it was found. The restore presses RE-ASSERT FOCUS first: without it they
// depend on focus still being where this probe put it, which is the very thing under test, and a
// restore that relies on the claim cannot be trusted to undo a run that disproved it.
var restoreAttempts = 0
while intValue(subject) != startValue && restoreAttempts < 4 {
    _ = AXUIElementSetAttributeValue(subject, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(400_000)
    _ = AXUIElementPerformAction(subject, kAXPressAction as CFString)
    usleep(900_000)
    restoreAttempts += 1
}
let restored = intValue(subject) == startValue
print("restore attempts: \(restoreAttempts)")
print("restored: \(restored ? 1 : 0)")
// A left-muted project is not a reporting detail. Exiting non-zero here means no caller can reach a
// verdict without dealing with it, whatever else the run found.
if !restored {
    print("FAILED TO RESTORE: the subject is left at \(intValue(subject).map(String.init) ?? "nil"), started at \(startValue.map(String.init) ?? "nil")")
    exit(4)
}
