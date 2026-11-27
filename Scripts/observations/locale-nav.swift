// Navigate to ONE surface of Logic, read it, and put it back. The navigation half of a locale census.
//
//   ./locale-nav spec.json            -> stdout: one JSON object (see `Result`)
//   ./locale-nav --windows            -> stdout: the window set, as the restore check sees it
//
// A navigation census is a write-adjacent act: it opens a sheet, a dialog, a window or a menu so that
// the strings only that surface carries can be read. So this program is built around the way back.
//
//   * It records the window set BEFORE. Every window and sheet is a (role, subrole, title) triple.
//   * It performs exactly ONE opening action named by the spec: a menu item found by its AX path or by its
//     key equivalent, or an element found by role and one exact attribute. Never a coordinate. Never a
//     typed character. It presses no OK, Save, Delete, Create, Import or Export: the only buttons it ever
//     presses are the ones that close what it opened (the window's AXCancelButton, else its AXCloseButton).
//   * It reads what appeared: every window or sheet that was not in the baseline, and every open menu.
//   * It closes what it opened, then reads the window set AGAIN and says whether it equals the baseline.
//     `restored: false` is the one answer a caller must stop on.
//
// Reading goes through the same Row shape as `locale-census.swift`, so a navigation census files through
// the same records code. It reads and closes; it does not decide what a string means.
import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) ?? "?" }

struct Row: Encodable {
    let surface: String
    let path: String
    let role: String
    let subrole: String?
    let title: String?
    let description: String?
    let help: String?
    let value: String?
    let identifier: String?
    let enabled: Bool?
}

struct WindowKey: Encodable, Hashable {
    let role: String
    let subrole: String
    let title: String
}

struct Result: Encodable {
    let opened: Bool
    let restored: Bool
    let error: String?
    let before: [WindowKey]
    let after: [WindowKey]
    let appeared: [WindowKey]
    let closed_by: [String]
    let census: [Row]
}

func stepLabel(_ k: AXUIElement) -> String {
    if let d = str(k, kAXDescriptionAttribute as String), !d.isEmpty { return "[\(String(d.prefix(28)))]" }
    if let i = str(k, kAXIdentifierAttribute as String), !i.isEmpty { return "{\(String(i.prefix(28)))}" }
    return ""
}

var rows: [Row] = []
func record(_ e: AXUIElement, surface: String, path: String) {
    let title = str(e, kAXTitleAttribute as String)
    let desc = str(e, kAXDescriptionAttribute as String)
    let help = str(e, kAXHelpAttribute as String)
    let value = attr(e, kAXValueAttribute as String).flatMap { $0 as? String }
    let ident = str(e, kAXIdentifierAttribute as String)
    if title != nil || desc != nil || help != nil || value != nil || ident != nil {
        rows.append(Row(surface: surface, path: path, role: role(e),
                        subrole: str(e, kAXSubroleAttribute as String),
                        title: title, description: desc, help: help, value: value, identifier: ident,
                        enabled: attr(e, kAXEnabledAttribute as String) as? Bool))
    }
}

/// A list of files is the USER's content, not Logic's: the sidebar and the browser of a Save or Open panel
/// name folders and projects on this machine. The element is recorded (it has a role and a label) and nothing
/// inside it is read, so a census of a panel carries Logic's strings and never a directory listing.
let contentRoles: Set<String> = ["AXOutline", "AXTable", "AXBrowser"]

func walk(_ e: AXUIElement, surface: String, path: String, depth: Int, maxDepth: Int) {
    if depth > maxDepth { return }
    if contentRoles.contains(role(e)) { return }
    for k in kids(e) {
        let r = role(k)
        // A menu item's own label is its title; everything else is named by description or identifier.
        let label = (r == "AXMenuItem" || r == "AXMenuBarItem") ? (str(k, kAXTitleAttribute as String).map { "[\($0)]" } ?? "") : stepLabel(k)
        let p = "\(path)/\(r)\(label)"
        record(k, surface: surface, path: p)
        walk(k, surface: surface, path: p, depth: depth + 1, maxDepth: maxDepth)
    }
}

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.logic10" }) else {
    FileHandle.standardError.write("Logic Pro is not running\n".data(using: .utf8)!); exit(2)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

/// Every window and every sheet hanging from one, as a sorted list of triples.
func windowSet() -> [WindowKey] {
    var keys: [WindowKey] = []
    for w in (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
        keys.append(WindowKey(role: role(w), subrole: str(w, kAXSubroleAttribute as String) ?? "",
                              title: str(w, kAXTitleAttribute as String) ?? ""))
        for k in kids(w) where role(k) == "AXSheet" {
            keys.append(WindowKey(role: "AXSheet", subrole: str(k, kAXSubroleAttribute as String) ?? "",
                                  title: str(k, kAXTitleAttribute as String) ?? ""))
        }
    }
    return keys.sorted { ($0.role, $0.subrole, $0.title) < ($1.role, $1.subrole, $1.title) }
}

/// The open surfaces: every window, and every sheet on one, as AX elements.
func surfaces() -> [(AXUIElement, WindowKey)] {
    var found: [(AXUIElement, WindowKey)] = []
    for w in (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
        found.append((w, WindowKey(role: role(w), subrole: str(w, kAXSubroleAttribute as String) ?? "",
                                   title: str(w, kAXTitleAttribute as String) ?? "")))
        for k in kids(w) where role(k) == "AXSheet" {
            found.append((k, WindowKey(role: "AXSheet", subrole: str(k, kAXSubroleAttribute as String) ?? "",
                                       title: str(k, kAXTitleAttribute as String) ?? "")))
        }
    }
    return found
}

func sleepFor(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

// MARK: finding what to press ----------------------------------------------------------------------------

/// A path like `AXMenuBar/AXMenuBarItem[Edit]/AXMenu/AXMenuItem[Undo]` split into (role, name?) steps.
/// A name may itself contain `/`, so the path is cut where a `]` is followed by `/AX` or the end.
func parsePath(_ path: String) -> [(String, String?)] {
    let pattern = try! NSRegularExpression(pattern: "(AX[A-Za-z]+)(?:\\[(.*?)\\](?=/AX|$))?")
    let ns = path as NSString
    return pattern.matches(in: path, range: NSRange(location: 0, length: ns.length)).map { m in
        let r = ns.substring(with: m.range(at: 1))
        let n = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
        return (r, n)
    }
}

func menuBarRoot() -> AXUIElement? { attr(ax, kAXMenuBarAttribute as String).map { $0 as! AXUIElement } }

/// Walk a menu path, opening each menu with a press as AX requires, and return the final item.
func resolveMenuPath(_ path: String) -> AXUIElement? {
    let steps = parsePath(path)
    guard steps.first?.0 == "AXMenuBar", var current = menuBarRoot() else { return nil }
    for (r, name) in steps.dropFirst() {
        let candidates: [AXUIElement]
        if r == "AXMenu" {
            candidates = kids(current).filter { role($0) == "AXMenu" }
        } else {
            candidates = kids(current).filter { role($0) == r && (name == nil || str($0, kAXTitleAttribute as String) == name) }
        }
        guard let next = candidates.first else { return nil }
        if r == "AXMenuBarItem" || r == "AXMenuItem" {
            // Opening the parent is what makes the child present itself in some Logic menus.
            if next != candidates.last || true { _ = AXUIElementPerformAction(next, kAXPressAction as CFString) }
            sleepFor(0.15)
        }
        current = next
    }
    return current
}

/// Find a menu item by its key equivalent: language-free, because `Save As…` is ⇧⌘S in every locale.
func findMenuItemByShortcut(char: String, mods: Int) -> AXUIElement? {
    func scan(_ e: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 5 { return nil }
        for k in kids(e) {
            if role(k) == "AXMenuItem",
               let c = str(k, "AXMenuItemCmdChar"), c.lowercased() == char.lowercased(),
               let m = attr(k, "AXMenuItemCmdModifiers") as? Int, m == mods { return k }
            if let hit = scan(k, depth: depth + 1) { return hit }
        }
        return nil
    }
    guard let bar = menuBarRoot() else { return nil }
    return scan(bar, depth: 0)
}

/// First element, in document order, of `role` whose `attribute` equals `equals`, below `scope`.
func findElement(role want: String, attribute: String, equals: String, scope: String?) -> AXUIElement? {
    func scan(_ e: AXUIElement, path: String, depth: Int) -> AXUIElement? {
        if depth > 12 { return nil }
        for k in kids(e) {
            let r = role(k)
            let p = "\(path)/\(r)\(stepLabel(k))"
            if r == want, (scope == nil || p.contains(scope!)), str(k, attribute) == equals { return k }
            if let hit = scan(k, path: p, depth: depth + 1) { return hit }
        }
        return nil
    }
    for w in (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] where str(w, kAXSubroleAttribute as String) == (kAXStandardWindowSubrole as String) {
        if let hit = scan(w, path: "AXWindow", depth: 0) { return hit }
    }
    return nil
}

// MARK: the spec --------------------------------------------------------------------------------------

struct Open: Decodable {
    let kind: String           // "menu-path" | "menu-shortcut" | "element"
    let path: String?
    let char: String?
    let mods: Int?
    let role: String?
    let attribute: String?
    let equals: String?
    let scope: String?
    let action: String?        // AX action for kind=element: "AXPress" (default) | "AXShowMenu"
}
struct Spec: Decodable {
    let surface: String
    let open: Open
    let settle: Double?
    let depth: Int?
    let expect: String?        // "window" (default) | "menu": what is expected to appear
    let keep: Bool?            // debugging only: leave what opened open (the caller then restores it)
}

func readNew(baseline: [WindowKey], surface: String, depth: Int) -> [WindowKey] {
    var appeared: [WindowKey] = []
    var remaining = baseline
    for (el, key) in surfaces() {
        if let i = remaining.firstIndex(of: key) { remaining.remove(at: i); continue }
        appeared.append(key)
        let title = key.title.isEmpty ? "" : "[\(key.title)]"
        let base = "\(key.role)\(title)"
        record(el, surface: surface, path: base)
        walk(el, surface: surface, path: base, depth: 0, maxDepth: depth)
    }
    return appeared
}

/// Read every open menu hanging from the app (a popup button's menu is not a window).
func readOpenMenus(surface: String, depth: Int) -> Bool {
    var any = false
    func scan(_ e: AXUIElement, path: String, level: Int) {
        if level > 14 { return }
        for k in kids(e) {
            let r = role(k)
            let label = (r == "AXMenuItem") ? (str(k, kAXTitleAttribute as String).map { "[\($0)]" } ?? "") : stepLabel(k)
            let p = "\(path)/\(r)\(label)"
            if r == "AXMenu" && !path.contains("AXMenuBar") {
                any = true
                record(k, surface: surface, path: p)
                walk(k, surface: surface, path: p, depth: 0, maxDepth: depth)
            } else {
                scan(k, path: p, level: level + 1)
            }
        }
    }
    for w in (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] { scan(w, path: "AXWindow", level: 0) }
    return any
}

/// The first descendant button whose AXIdentifier is `identifier` (a locale-free name AppKit assigns).
func findByIdentifier(_ root: AXUIElement, _ identifier: String) -> AXUIElement? {
    func scan(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
        if depth > 12 { return nil }
        for k in kids(e) {
            if role(k) == "AXButton", str(k, kAXIdentifierAttribute as String) == identifier { return k }
            if let hit = scan(k, depth + 1) { return hit }
        }
        return nil
    }
    return scan(root, 0)
}

/// Close what the action opened, by the only means that cannot commit anything.
func closeNew(baseline: [WindowKey]) -> [String] {
    var how: [String] = []
    // A menu first: AXCancel on it, then Escape through AX is not available, so cancel every open menu.
    func cancelMenus(_ e: AXUIElement, level: Int) {
        if level > 14 { return }
        for k in kids(e) {
            if role(k) == "AXMenu" { _ = AXUIElementPerformAction(k, kAXCancelAction as CFString); how.append("AXCancel(menu)") }
            cancelMenus(k, level: level + 1)
        }
    }
    for w in (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] { cancelMenus(w, level: 0) }
    sleepFor(0.4)
    for _ in 0..<4 {
        var remaining = baseline
        var target: (AXUIElement, WindowKey)?
        for (el, key) in surfaces().reversed() {
            if let i = remaining.firstIndex(of: key) { remaining.remove(at: i); continue }
            target = (el, key); break
        }
        guard let (el, key) = target else { break }
        // The surface's own cancel button (a sheet or dialog), else its window close button.
        if let cancel = attr(el, "AXCancelButton") {
            _ = AXUIElementPerformAction(cancel as! AXUIElement, kAXPressAction as CFString); how.append("AXCancelButton(\(key.role))")
        } else if let cancel = findByIdentifier(el, "CancelButton") {
            // A Cocoa panel (Save, Open) lists AXCancelButton among its attributes and returns no value for
            // it; the button is still there, named by the identifier AppKit gives it in every language.
            _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString); how.append("CancelButton(\(key.role))")
        } else if let close = attr(el, kAXCloseButtonAttribute as String) {
            _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString); how.append("AXCloseButton(\(key.role))")
        } else { how.append("no-closer(\(key.role))"); break }
        sleepFor(0.6)
    }
    return how
}

// MARK: main ------------------------------------------------------------------------------------------

let arguments = CommandLine.arguments
let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
if arguments.contains("--shortcuts") {
    // Every menu item that has a key equivalent, with the modifier bits AX reports for it.
    struct Shortcut: Encodable { let path: String; let char: String; let mods: Int }
    var found: [Shortcut] = []
    func scan(_ e: AXUIElement, path: String, depth: Int) {
        if depth > 6 { return }
        for k in kids(e) {
            let r = role(k)
            let p = "\(path)/\(r)" + ((r == "AXMenuItem" || r == "AXMenuBarItem") ? (str(k, kAXTitleAttribute as String).map { "[\($0)]" } ?? "") : "")
            if r == "AXMenuItem", let c = str(k, "AXMenuItemCmdChar"), !c.isEmpty {
                found.append(Shortcut(path: p, char: c, mods: (attr(k, "AXMenuItemCmdModifiers") as? Int) ?? -1))
            }
            scan(k, path: p, depth: depth + 1)
        }
    }
    if let bar = menuBarRoot() { scan(bar, path: "AXMenuBar", depth: 0) }
    print(String(data: try! enc.encode(found), encoding: .utf8)!)
    exit(0)
}
if arguments.contains("--windows") {
    print(String(data: try! enc.encode(windowSet()), encoding: .utf8)!)
    exit(0)
}
guard arguments.count > 1, let data = FileManager.default.contents(atPath: arguments[1]),
      let spec = try? JSONDecoder().decode(Spec.self, from: data) else {
    FileHandle.standardError.write("usage: locale-nav spec.json | --windows\n".data(using: .utf8)!); exit(2)
}

let before = windowSet()
var error: String? = nil
var appeared: [WindowKey] = []
var closedBy: [String] = []
var opened = false

var target: AXUIElement? = nil
switch spec.open.kind {
case "menu-path": target = spec.open.path.flatMap(resolveMenuPath)
case "menu-shortcut": target = spec.open.char.flatMap { findMenuItemByShortcut(char: $0, mods: spec.open.mods ?? 0) }
case "element": target = findElement(role: spec.open.role ?? "", attribute: spec.open.attribute ?? "", equals: spec.open.equals ?? "", scope: spec.open.scope)
default: error = "unknown open kind \(spec.open.kind)"
}
if target == nil && error == nil { error = "the element to open was not found (\(spec.open.kind))" }
if let t = target {
    let action = spec.open.action ?? kAXPressAction as String
    let result = AXUIElementPerformAction(t, action as CFString)
    if result != .success { error = "the opening action \(action) returned \(result.rawValue)" }
    sleepFor(spec.settle ?? 1.5)
    let depth = spec.depth ?? 10
    appeared = readNew(baseline: before, surface: spec.surface, depth: depth)
    let menu = readOpenMenus(surface: spec.surface, depth: depth)
    opened = !appeared.isEmpty || menu
    if !opened && error == nil { error = "nothing appeared after the opening action" }
}
closedBy = (spec.keep ?? false) ? ["kept open"] : closeNew(baseline: before)
sleepFor(0.8)
let after = windowSet()
let restored = (after == before)
let result = Result(opened: opened, restored: restored, error: error, before: before, after: after,
                    appeared: appeared, closed_by: closedBy, census: rows)
print(String(data: try! enc.encode(result), encoding: .utf8)!)
exit(restored ? 0 : 3)
