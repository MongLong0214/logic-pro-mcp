// Emit every string Logic's AX surface exposes, as JSON, for the surfaces that need NO navigation
// to reach: the menu bar and every menu under it (AX reads them without opening them), and the
// main window's tree. One line of JSON per element so a census of two locales can be diffed.
//
//   ./locale-census                      -> stdout: {"census":[...], "host":{...}}
//   ./locale-census --depth 10           -> window tree depth (default 8)
//
// It reads. It presses nothing, opens nothing, selects nothing. A census that changed the thing it
// was measuring would be measuring its own footprint.
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

struct Row: Encodable {
    let surface: String
    let path: String        // role chain from the root, e.g. "AXMenuBar/AXMenuBarItem[편집]/AXMenu/AXMenuItem"
    let role: String
    let subrole: String?
    let title: String?
    let description: String?
    let help: String?
    let value: String?
    let identifier: String?
    let enabled: Bool?
}

var rows: [Row] = []
let textAttrs = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute, kAXIdentifierAttribute].map { $0 as String }

func record(_ e: AXUIElement, surface: String, path: String) {
    let role = str(e, kAXRoleAttribute as String) ?? "?"
    let title = str(e, kAXTitleAttribute as String)
    let desc = str(e, kAXDescriptionAttribute as String)
    let help = str(e, kAXHelpAttribute as String)
    let value = attr(e, kAXValueAttribute as String).flatMap { $0 as? String }
    let ident = str(e, kAXIdentifierAttribute as String)
    let enabled = attr(e, kAXEnabledAttribute as String) as? Bool
    // Only elements that carry SOME string are worth a row; a bare group is structure, not a label.
    if title != nil || desc != nil || help != nil || value != nil || ident != nil {
        rows.append(Row(surface: surface, path: path, role: role,
                        subrole: str(e, kAXSubroleAttribute as String),
                        title: title, description: desc, help: help, value: value,
                        identifier: ident, enabled: enabled))
    }
}

func walkMenu(_ e: AXUIElement, path: String, depth: Int) {
    if depth > 6 { return }
    for k in kids(e) {
        let role = str(k, kAXRoleAttribute as String) ?? "?"
        let label = str(k, kAXTitleAttribute as String).map { "[\($0)]" } ?? ""
        let p = "\(path)/\(role)\(label)"
        record(k, surface: "arrange.menus", path: p)
        walkMenu(k, path: p, depth: depth + 1)
    }
}

func stepLabel(_ k: AXUIElement) -> String {
    // What this ancestor IS, for a classifier downstream: its description if it has one, else its
    // identifier. Kept short so a depth-8 path stays readable.
    if let d = str(k, kAXDescriptionAttribute as String), !d.isEmpty { return "[\(String(d.prefix(28)))]" }
    if let i = str(k, kAXIdentifierAttribute as String), !i.isEmpty { return "{\(String(i.prefix(28)))}" }
    return ""
}

func walkWindow(_ e: AXUIElement, path: String, depth: Int, maxDepth: Int) {
    if depth > maxDepth { return }
    for k in kids(e) {
        let role = str(k, kAXRoleAttribute as String) ?? "?"
        let p = "\(path)/\(role)\(stepLabel(k))"
        record(k, surface: "arrange.window", path: p)
        walkWindow(k, path: p, depth: depth + 1, maxDepth: maxDepth)
    }
}

let args = CommandLine.arguments
let maxDepth = args.firstIndex(of: "--depth").flatMap { Int(args[$0 + 1]) } ?? 8
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.logic10" }) else {
    FileHandle.standardError.write("Logic Pro is not running\n".data(using: .utf8)!); exit(2)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

// 1. menu bar and every menu — reachable in any locale without a single label
var barTitles: [String] = []
if let bar = attr(ax, kAXMenuBarAttribute as String) {
    let barEl = bar as! AXUIElement
    for item in kids(barEl) {
        let title = str(item, kAXTitleAttribute as String)
        if let t = title { barTitles.append(t) }
        let label = title.map { "[\($0)]" } ?? ""
        let p = "AXMenuBar/AXMenuBarItem\(label)"
        record(item, surface: "arrange.menus", path: p)
        walkMenu(item, path: p, depth: 0)
    }
}
// 2. the main window's tree
if let wins = attr(ax, kAXWindowsAttribute as String) as? [AXUIElement],
   let main = wins.first(where: { str($0, kAXSubroleAttribute as String) == (kAXStandardWindowSubrole as String) }) {
    let title = str(main, kAXTitleAttribute as String).map { "[\($0)]" } ?? ""
    record(main, surface: "arrange.window", path: "AXWindow\(title)")
    walkWindow(main, path: "AXWindow\(title)", depth: 0, maxDepth: maxDepth)
}

// host block, measured — never typed
func plist(_ path: String) -> [String: Any] {
    (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: Any]) ?? [:]
}
let lp = plist("/Applications/Logic Pro.app/Contents/Info.plist")
let os = plist("/System/Library/CoreServices/SystemVersion.plist")
// Collected directly in the bar loop: a path filter on "/AXMenu" also matched "AXMenuBarItem".
let menuTitles = barTitles
let locale: String = menuTitles.contains("편집") ? "ko-KR" : menuTitles.contains("編集") ? "ja-JP" : menuTitles.contains("Edit") ? "en-US" : "unknown"
struct Out: Encodable {
    let host: [String: String]
    let menu_bar: [String]
    let census: [Row]
}
let out = Out(host: ["app": "Logic Pro",
                     "version": lp["CFBundleShortVersionString"] as? String ?? "?",
                     "build": lp["CFBundleVersion"] as? String ?? "?",
                     "locale": locale,
                     "os": "macOS \(os["ProductVersion"] as? String ?? "?") (\(os["ProductBuildVersion"] as? String ?? "?"))"],
              menu_bar: menuTitles, census: rows)
let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
print(String(data: try! enc.encode(out), encoding: .utf8)!)
