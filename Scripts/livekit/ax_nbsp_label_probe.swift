// Raw AX witness for #993 and #1004: which space character a running Logic draws in a label.
//
// `Logic Pro` and `Audio Units` in some locales, and the German `Installieren …`, are rows Apple
// ships with U+00A0 (no-break space). A LabelSet compares exactly, so a member holding one spelling
// does not match the other. Whether Logic DRAWS the row's character or an ordinary space can only be
// read off the running application, so this prints every title it reads together with its Unicode
// scalars, and never a judgement. The harness that drives it decides what the reading means.
//
// It aims at nothing by a word of its own. Every label it looks for arrives on the command line as
// JSON, from the Python harness, which takes them from `AXLocalePolicy` or from Apple's bundle.
//
//   swiftc -O ax_nbsp_label_probe.swift -o nbsp_probe
//   ./nbsp_probe windows
//   ./nbsp_probe open-menus
//   ./nbsp_probe press-menu-path '{"path":[["Logic Pro"],["Control Surfaces"],["Setup…"]]}'
//   ./nbsp_probe press-and-read '{"role":"AXMenuButton","attribute":"AXDescription","equals":["New"],"min_height":0,"index":0}'
//   ./nbsp_probe candidates '{"role":"AXButton","attribute":"AXDescription","contains":["audio"]}'
//   ./nbsp_probe watch-windows '{"seconds":60,"interval_ms":40,"contains":["Logic"]}'
//   ./nbsp_probe cancel-menus
//   ./nbsp_probe press '{"role":"AXButton","attribute":"AXTitle","equals":["Export"],"depth":4}'
//   ./nbsp_probe press-default          (the one sheet or AXDialog's own default button)
//   ./nbsp_probe set-sheet-field '{"value":"/path/"}'
//   ./nbsp_probe close-window '{"title":["Control Surface Setup"]}'
//   ./nbsp_probe cancel-bounce          (Command-period, only while Logic is frontmost)
//
// An AXPress on a popup can return kAXErrorCannotComplete and still open the menu, so the press
// status is printed and nothing is judged by it: the menus are read back afterwards.
import AppKit
import ApplicationServices
import Foundation

typealias JSON = [String: Any]

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) ?? "" }
func size(_ e: AXUIElement) -> CGSize? {
    guard let v = attr(e, kAXSizeAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

/// The text and every scalar in it, so a no-break space cannot hide inside a printed string.
func scalars(_ text: String?) -> Any {
    guard let text else { return NSNull() }
    return text.unicodeScalars.map { String(format: "U+%04X", $0.value) }
}

func reading(_ e: AXUIElement) -> JSON {
    var out: JSON = ["role": role(e)]
    for (key, name) in [("title", kAXTitleAttribute as String), ("description", kAXDescriptionAttribute as String),
                        ("help", kAXHelpAttribute as String), ("subrole", kAXSubroleAttribute as String)] {
        let value = str(e, name)
        out[key] = value ?? NSNull()
        if key != "subrole" { out[key + "_scalars"] = scalars(value) }
    }
    out["enabled"] = (attr(e, kAXEnabledAttribute as String) as? Bool) ?? NSNull()
    return out
}

func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func argument() -> JSON {
    guard CommandLine.arguments.count > 2,
          let data = CommandLine.arguments[2].data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { return [:] }
    return obj
}

// Case-insensitive, like `LabelSet.matches`; whitespace is NOT folded, because that is the question.
// A spec may set `fold_nbsp` to find its WAY to the element being read -- a menu path whose German
// member holds U+00A0 where the menu may draw U+0020 -- and the reading itself is never folded.
var foldNBSP = false
func same(_ a: String?, _ b: String) -> Bool {
    guard var a else { return false }
    var b = b
    if foldNBSP {
        a = a.replacingOccurrences(of: "\u{00A0}", with: " ")
        b = b.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
    return a.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else {
    emit(["error": "Logic Pro is not running"]); exit(2)
}
let root = AXUIElementCreateApplication(app.processIdentifier)

func windows() -> [AXUIElement] { (attr(root, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] }

/// Every OUTERMOST AXMenu under the application, EXCEPT the menu bar's: those exist whether or not
/// anything is open, and would bury the one menu a press just opened. The walk stops at a menu, so a
/// plug-in menu's hundred submenus are not read as a hundred open menus.
func openMenus() -> [AXUIElement] {
    var menus: [AXUIElement] = []
    var frontier = kids(root).filter { role($0) != "AXMenuBar" }
    for _ in 0..<12 {
        var next: [AXUIElement] = []
        for e in frontier {
            if role(e) == "AXMenu" { menus.append(e); continue }
            next.append(contentsOf: kids(e))
        }
        if next.isEmpty { break }
        frontier = next
    }
    return menus
}

func menuReading(_ menu: AXUIElement) -> JSON {
    ["menu": reading(menu), "items": kids(menu).map(reading)]
}

func descendants(_ e: AXUIElement, depth: Int) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func walk(_ x: AXUIElement, _ d: Int) {
        out.append(x)
        if d >= depth { return }
        for c in kids(x) { walk(c, d + 1) }
    }
    walk(e, 0)
    return out
}

func matchesSpec(_ e: AXUIElement, _ spec: JSON) -> Bool {
    if let r = spec["role"] as? String, role(e) != r { return false }
    let name = (spec["attribute"] as? String) ?? (kAXDescriptionAttribute as String)
    let value = str(e, name)
    if let equals = spec["equals"] as? [String], !equals.contains(where: { same(value, $0) }) { return false }
    if let contains = spec["contains"] as? [String] {
        guard let value, contains.contains(where: { value.range(of: $0, options: .caseInsensitive) != nil }) else { return false }
    }
    if let excluding = spec["excluding"] as? [String], let value,
       excluding.contains(where: { value.range(of: $0, options: .caseInsensitive) != nil }) { return false }
    if let minHeight = spec["min_height"] as? Double, minHeight > 0 {
        guard let s = size(e), Double(s.height) >= minHeight else { return false }
    }
    return true
}

func candidates(_ spec: JSON) -> [AXUIElement] {
    let depth = (spec["depth"] as? Int) ?? 14
    return windows().flatMap { descendants($0, depth: depth) }.filter { matchesSpec($0, spec) }
}

func cancelMenus() -> [JSON] {
    openMenus().map { menu -> JSON in
        let rc = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        return ["menu": reading(menu), "cancel_rc": rc.rawValue]
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
foldNBSP = (argument()["fold_nbsp"] as? Bool) ?? false
switch mode {
case "windows":
    emit(["windows": windows().map(reading)])

case "open-menus":
    emit(["open_menus": openMenus().map(menuReading)])

case "cancel-menus":
    let cancelled = cancelMenus()
    usleep(300_000)
    emit(["cancelled": cancelled, "open_menus_after": openMenus().map(menuReading)])

case "candidates":
    emit(["candidates": candidates(argument()).map(reading)])

case "press-and-read":
    // Press the index-th element the spec names, then read the menu it opened. Logic hangs a popup
    // menu under the element or one of its nearest ancestors, so that is where it is looked for; walking the
    // whole application for it took over 40 s against a populated arrange window. The press status
    // is printed beside the reading and decides nothing. With `cancel`, the menu is cancelled and
    // the same place is read again, so a menu left open is reported rather than assumed shut.
    let spec = argument()
    let found = candidates(spec)
    let index = (spec["index"] as? Int) ?? 0
    var out: JSON = ["candidates": found.map(reading)]
    guard found.indices.contains(index) else { out["outcome"] = "no_candidate"; emit(out); exit(0) }
    let target = found[index]
    func menusNear() -> [AXUIElement] {
        var places = [target]
        var cursor = target
        for _ in 0..<6 {
            guard let parent = attr(cursor, kAXParentAttribute as String) else { break }
            cursor = parent as! AXUIElement
            places.append(cursor)
        }
        var menus: [AXUIElement] = []
        for place in places {
            for child in kids(place) where role(child) == "AXMenu" && !menus.contains(where: { CFEqual($0, child) }) {
                menus.append(child)
            }
        }
        return menus
    }
    out["menus_near_before"] = menusNear().count
    let action = (spec["action"] as? String) ?? (kAXPressAction as String)
    out["pressed"] = reading(target)
    out["press_rc"] = AXUIElementPerformAction(target, action as CFString).rawValue
    var menus: [AXUIElement] = []
    for _ in 0..<20 {
        usleep(150_000)
        menus = menusNear()
        if !menus.isEmpty { break }
    }
    out["open_menus_after"] = menus.map(menuReading)
    out["outcome"] = menus.isEmpty ? "no_menu_opened" : "read"
    if (spec["cancel"] as? Bool) == true {
        out["cancel_rc"] = menus.map { AXUIElementPerformAction($0, kAXCancelAction as CFString).rawValue }
        usleep(500_000)
        out["menus_open_after_cancel"] = menusNear().count
    }
    emit(out)

case "press":
    // Press the index-th element the spec names and report the status; the harness reads the effect.
    let spec = argument()
    let found = candidates(spec)
    let index = (spec["index"] as? Int) ?? 0
    guard found.indices.contains(index) else { emit(["outcome": "no_candidate", "candidates": found.map(reading)]); exit(0) }
    emit(["outcome": "pressed", "pressed": reading(found[index]), "candidates": found.count,
          "press_rc": AXUIElementPerformAction(found[index], kAXPressAction as CFString).rawValue])

case "press-menu-path":
    // Walk the APPLICATION menu bar by title, each step accepting any of the spellings given.
    // The first step is a menu-bar item; each later one is an item of the menu before it. The last
    // step may match more than one item -- ko-KR spells `Setup…` and `Settings…` identically -- so
    // each is pressed in turn until a window titled one of `expect_window` is up. A window the wrong
    // press put up is closed before the next, and only a window that was not there before.
    let spec = argument()
    let steps = (spec["path"] as? [[String]]) ?? []
    let expect = (spec["expect_window"] as? [String]) ?? []
    func expected() -> AXUIElement? {
        windows().first { w in expect.contains(where: { same(str(w, kAXTitleAttribute as String), $0) }) }
    }
    if !expect.isEmpty, expected() != nil { emit(["outcome": "already_open", "windows_after": windows().map(reading)]); exit(0) }
    var trail: [JSON] = []
    guard let bar = kids(root).first(where: { role($0) == "AXMenuBar" }) else {
        emit(["outcome": "no_menu_bar"]); exit(0)
    }
    var hits = [bar]
    for (i, names) in steps.enumerated() {
        let container = hits[0]
        let pool = i == 0 ? kids(container) : kids(container).flatMap { role($0) == "AXMenu" ? kids($0) : [$0] }
        hits = pool.filter { e in names.contains(where: { same(str(e, kAXTitleAttribute as String), $0) }) }
        trail.append(["step": i, "wanted": names, "hits": hits.map(reading)])
        let last = i == steps.count - 1
        guard hits.count == 1 || (last && !hits.isEmpty && !expect.isEmpty) else {
            emit(["outcome": "step_\(i)_hits_\(hits.count)", "trail": trail]); exit(0)
        }
    }
    var presses: [JSON] = []
    for item in hits {
        let before = Set(windows().compactMap { str($0, kAXTitleAttribute as String) })
        var press: JSON = ["item": reading(item), "press_rc": AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue]
        usleep(1_500_000)
        if expected() != nil { press["opened_expected"] = true; presses.append(press); break }
        if let stray = windows().first(where: { w in
            guard let t = str(w, kAXTitleAttribute as String), !before.contains(t) else { return false }
            let sub = str(w, kAXSubroleAttribute as String)
            return sub == "AXDialog" || sub == "AXFloatingWindow"
        }) {
            press["stray_window"] = reading(stray)
            if let close = attr(stray, kAXCloseButtonAttribute as String) {
                press["stray_close_rc"] = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString).rawValue
                usleep(600_000)
            }
        }
        presses.append(press)
        if expect.isEmpty { break }
    }
    let ok = expect.isEmpty || expected() != nil
    emit(["outcome": ok ? "pressed" : "expected_window_not_open", "trail": trail, "presses": presses,
          "windows_after": windows().map(reading)])

case "close-window":
    // Close the one window whose title equals a given spelling, and read back that it went.
    let names = (argument()["title"] as? [String]) ?? []
    let hits = windows().filter { w in names.contains(where: { same(str(w, kAXTitleAttribute as String), $0) }) }
    guard hits.count == 1, let close = attr(hits[0], kAXCloseButtonAttribute as String) else {
        emit(["outcome": "window_hits_\(hits.count)"]); exit(0)
    }
    let rc = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString).rawValue
    usleep(800_000)
    let still = windows().filter { w in names.contains(where: { same(str(w, kAXTitleAttribute as String), $0) }) }
    emit(["outcome": still.isEmpty ? "closed" : "still_open", "press_rc": rc])

case "sheets":
    // Every sheet on every window, and the default button each names.
    emit(["sheets": windows().flatMap { w in kids(w).filter { role($0) == "AXSheet" }.map { sheet -> JSON in
        var r = reading(sheet)
        r["window"] = str(w, kAXTitleAttribute as String) ?? NSNull()
        if let b = attr(sheet, kAXDefaultButtonAttribute as String) { r["default_button"] = reading(b as! AXUIElement) }
        return r
    } }])

case "press-default":
    // Press the default button of the ONE panel that is up -- a sheet on a window, or a window whose
    // subrole is AXDialog -- and read back what is up afterwards. The button is the one the panel
    // itself names as default, so no word is matched.
    func panels() -> [AXUIElement] {
        windows().flatMap { w -> [AXUIElement] in
            (str(w, kAXSubroleAttribute as String) == "AXDialog" ? [w] : []) + kids(w).filter { role($0) == "AXSheet" }
        }
    }
    let up = panels()
    guard up.count == 1, let b = attr(up[0], kAXDefaultButtonAttribute as String) else {
        emit(["outcome": "panels_\(up.count)_or_no_default_button", "panels": up.map(reading)]); exit(0)
    }
    let button = b as! AXUIElement
    var out: JSON = ["panel": reading(up[0]), "button": reading(button),
                     "panel_text": descendants(up[0], depth: 6).filter { role($0) == "AXStaticText" }
                        .compactMap { str($0, kAXValueAttribute as String) }.filter { !$0.isEmpty }]
    out["press_rc"] = AXUIElementPerformAction(button, kAXPressAction as CFString).rawValue
    usleep(800_000)
    out["panels_after"] = panels().map(reading)
    out["outcome"] = "pressed"
    emit(out)

case "set-sheet-field":
    // The export panel is a folder chooser with no attribute that sets its directory; its own
    // Go-to-Folder sheet does, and the harness opens that with a keystroke. This writes the sheet's
    // ONE text field and reads it back. Pressing Return is the harness's.
    let value = (argument()["value"] as? String) ?? ""
    let dialogs = windows().filter { str($0, kAXSubroleAttribute as String) == "AXDialog" }
    let fields = dialogs.flatMap { kids($0).filter { role($0) == "AXSheet" } }
        .flatMap { descendants($0, depth: 8).filter { role($0) == "AXTextField" } }
    guard fields.count == 1 else { emit(["outcome": "fields_\(fields.count)"]); exit(0) }
    let rc = AXUIElementSetAttributeValue(fields[0], kAXValueAttribute as CFString, value as CFTypeRef).rawValue
    emit(["outcome": "set", "set_rc": rc, "read_back": (str(fields[0], kAXValueAttribute as String) as Any?) ?? NSNull()])

case "cancel-bounce":
    // Logic's export progress window has no button; it says to press Command-period. Posted only
    // when Logic is frontmost, so the keystroke cannot land in another application.
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.logic10" else {
        emit(["outcome": "logic_not_frontmost",
              "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"]); exit(0)
    }
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 47, keyDown: down)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }
    emit(["outcome": "sent"])

case "watch-windows":
    // Poll the window list and keep every DISTINCT title that contains one of the given fragments,
    // with its scalars and how many polls saw it. A progress window can live for well under a
    // second, so this runs in the background while the harness starts the export.
    let spec = argument()
    let seconds = (spec["seconds"] as? Double) ?? 60
    let interval = UInt32(((spec["interval_ms"] as? Double) ?? 40) * 1000)
    let fragments = (spec["contains"] as? [String]) ?? []
    // Bounded by the clock, not by a poll count: while Logic bounces, one read of the window list
    // can take far longer than the interval, and a count-bounded watcher outlived its harness.
    let deadline = Date().addingTimeInterval(seconds)
    var seen: [String: JSON] = [:]
    var order: [String] = []
    var count = 0
    while Date() < deadline {
        count += 1
        for w in windows() {
            let r = reading(w)
            guard let title = r["title"] as? String,
                  fragments.isEmpty || fragments.contains(where: { f in
                      title.unicodeScalars.filter { $0.properties.isWhitespace == false }.map(String.init).joined()
                          .localizedCaseInsensitiveContains(f.unicodeScalars.filter { $0.properties.isWhitespace == false }.map(String.init).joined())
                  }) else { continue }
            let key = "\(r["subrole"] ?? "")|\(title.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))"
            if var prior = seen[key] {
                prior["polls_seen"] = (prior["polls_seen"] as! Int) + 1
                prior["last_poll"] = count
                seen[key] = prior
            } else {
                var fresh = r
                fresh["polls_seen"] = 1
                fresh["first_poll"] = count
                fresh["last_poll"] = count
                seen[key] = fresh
                order.append(key)
            }
        }
        usleep(interval)
    }
    emit(["polls": count, "interval_ms": Double(interval) / 1000, "titles": order.map { seen[$0]! }])

default:
    emit(["error": "usage: windows | open-menus | cancel-menus | sheets | candidates <json> | press <json> | press-and-read <json> | press-menu-path <json> | press-default | set-sheet-field <json> | close-window <json> | cancel-bounce | watch-windows <json>"])
    exit(2)
}
