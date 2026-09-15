import AppKit
import ApplicationServices

// #448 — is there ANY key command that moves a track's position in the track list?
//
// The reorder half of #448 says anchor-based reorder is drag-only, and drag means screen
// coordinates, which this project does not do. That leaves one route unmeasured: a key command.
// The Track menu was censused before and offers only `Sort Tracks by`; `Edit > Move` is entirely
// region operations. This asks the remaining question against the full assignment list.
//
// The census opens the Key Commands window, reads every row, and closes it again. It is read-only
// with respect to the assignments: nothing is typed into the search field and no assignment is
// changed, because a probe that edits the thing it measures is not a measurement.
//
// A census that found nothing is worthless if it could not find anything, so four commands that
// certainly exist are looked up in the same pass and all four must be present. `Sort Tracks` is
// NOT one of them: it is a submenu parent rather than a command, and it is absent from the list —
// which is a fact about the list, not a failure of the probe.

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

guard let app = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    print("no Logic")
    exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

func windows() -> [AXUIElement] {
    (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
}
func keyCommandWindow() -> AXUIElement? {
    windows().first { str($0, kAXTitleAttribute as String).hasPrefix("Key Command Assignments") }
}

// ── open it, by menu title only — no coordinates ──────────────────────────────────────────────
let openedByUs = keyCommandWindow() == nil
if openedByUs {
    guard let bar = attr(ax, kAXMenuBarAttribute as String) else { print("no menu bar"); exit(1) }
    var target: AXUIElement?
    // Both spellings, because the application menu-bar item is NOT spelled the same everywhere:
    // measured 2026-09-15 across the four navigation-free censuses, en-US and ja-JP read
    // `Logic Pro` with U+0020 while ko-KR and de-DE read `Logic\u{00A0}Pro` with a non-breaking
    // space. Matching only the first made this census find no menu bar on half the locales and
    // report "no menu bar" — a message about structure for a problem about one character.
    // (The System Events PROCESS name is a different string and IS plain: measured the same day,
    // `every process whose name is "Logic Pro"` returns 1 on this Korean host.)
    let appMenuTitles = ["Logic Pro", "Logic\u{00A0}Pro"]
    for m in kids(bar as! AXUIElement)
    where appMenuTitles.contains(str(m, kAXTitleAttribute as String)) {
        for sub in kids(m) {
            for item in kids(sub)
            where str(item, kAXTitleAttribute as String).lowercased().contains("key command") {
                for s in kids(item) {
                    for c in kids(s)
                    where str(c, kAXTitleAttribute as String).hasPrefix("Edit Assignments") {
                        target = c
                    }
                }
            }
        }
    }
    guard let target else { print("no Edit Assignments menu item"); exit(1) }
    AXUIElementPerformAction(target, kAXPressAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(3.0))
}
guard let w = keyCommandWindow() else { print("the Key Commands window did not open"); exit(1) }

func descend(_ e: AXUIElement, _ role: String, _ d: Int) -> [AXUIElement] {
    if d > 10 { return [] }
    var out: [AXUIElement] = []
    if str(e, kAXRoleAttribute as String) == role { out.append(e) }
    for c in kids(e) { out += descend(c, role, d + 1) }
    return out
}
/// A row's command name: the first non-empty description/title/value under it.
func rowName(_ r: AXUIElement) -> String {
    for c in kids(r) {
        for t in kids(c) {
            let d = str(t, kAXDescriptionAttribute as String)
            if !d.isEmpty { return d }
            let ti = str(t, kAXTitleAttribute as String)
            if !ti.isEmpty { return ti }
            if let v = attr(t, kAXValueAttribute as String) as? String, !v.isEmpty { return v }
        }
        let d = str(c, kAXDescriptionAttribute as String)
        if !d.isEmpty { return d }
        if let v = attr(c, kAXValueAttribute as String) as? String, !v.isEmpty { return v }
    }
    return ""
}

let names = descend(w, kAXRowRole as String, 0).map(rowName).filter { !$0.isEmpty }
print("commands=\(names.count)")

let controls = ["Rename Track", "Delete Track", "New Track", "Toggle Track Freeze"]
var controlsFound = 0
for probe in controls {
    let n = names.filter { $0.localizedCaseInsensitiveContains(probe) }.count
    if n > 0 { controlsFound += 1 }
    print("control \(probe)=\(n)")
}

// The subject: a command that moves a TRACK, as opposed to automation, a marquee selection, a
// take, a region, or a selection extent. Those five are what every near-match turned out to be,
// so they are excluded by name and the remainder is printed in full for a reader to judge.
let excluded = ["automation", "marquee", "take", "comp", "region", "selection", "cell"]
let candidates = names.filter { n in
    let l = n.lowercased()
    guard l.contains("track") else { return false }
    guard l.contains("move") || l.contains(" up") || l.contains(" down")
            || l.contains("order") || l.contains("shuffle") || l.contains("swap") else { return false }
    return !excluded.contains { l.contains($0) }
}
for c in candidates { print("candidate: \(c)") }
print("controlsFound=\(controlsFound) of \(controls.count) trackMoveCandidates=\(candidates.count)")

if openedByUs, let btn = attr(w, kAXCloseButtonAttribute as String) {
    AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
}
print("windowClosed=\(keyCommandWindow() == nil)")
