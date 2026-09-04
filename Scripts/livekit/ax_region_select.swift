// A product-independent way for a harness to put Logic's selection on a KNOWN region.
//
// `logic_edit.move_to_playhead` acts on whatever is selected. To prove it moved the right thing, a
// run has to establish the selection itself and be able to say what it selected — otherwise the
// operation's own envelope is the only witness to its own subject.
//
// This tool does not follow the product's addressing contract, and it does not need to: it reports
// exactly which region it acted on (Logic's own help string, which carries the bars) so the harness
// can hold the envelope against something it observed rather than against something it assumed.
//
//   swiftc -O ax_region_select.swift -o ax_region_select
//   ./ax_region_select                 -> {"regions":[{"index":0,"name":…,"help":…,"selected":…}, …],
//                                          "selected":[…]}
//
// READ-ONLY, and that is a finding rather than a simplification. An earlier version of this tool
// wrote `AXSelected` to put the selection on a chosen region. Measured on Logic 12.3, that write
// does not behave as a setter. This note used to say it ADDS; re-measured 2026-09-04, the sharper
// fact is that it TOGGLES — writing `true` to one region three times from an empty selection gives
// selected, deselected, selected. Adding is what that looks like when the target happened to be
// off, and toggling is also why a pass that wrote false on every other region left eighteen of them
// selected and the target NOT selected. The return codes were `.success` throughout.
//
// A toggle IS usable, but only from a pre-state you established and read back: the product's
// `region.select_last` empties the selection with Logic's own `Deselect All` first, and the clear
// is what makes one write land on exactly one region.
//
// So the harness does not drive the selection. It reads it, requires exactly one, and lets the
// product establish that one (an import leaves its new region selected). A witness that cannot
// write also cannot be accused of having caused what it reports.

import AppKit
import ApplicationServices
import Foundation

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func role(_ element: AXUIElement) -> String {
    (attr(element, kAXRoleAttribute as String) as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func help(_ element: AXUIElement) -> String {
    (attr(element, kAXHelpAttribute as String) as? String) ?? ""
}

/// The arrange window's track-content group — the same landmark `enumerateRegionItems` uses.
///
/// Scoping matters: walking the whole application picked up the Piano Roll's own region item and the
/// Inspector's, so the count moved between two calls seconds apart (23, then 40) and an index meant
/// different things each time. A witness whose index space is unstable is not a witness.
func trackContentGroup(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 16 else { return nil }
    for child in children(root) {
        if role(child) == (kAXGroupRole as String) {
            let description = (attr(child, kAXDescriptionAttribute as String) as? String) ?? ""
            // Measured live: Logic labels it "Tracks contents" on this build, not "Track Content".
            // Compared case- and space-insensitively against the same renderings AXLocalePolicy
            // carries, so a guess about the exact wording cannot silently return the wrong group.
            let normalized = description.lowercased().replacingOccurrences(of: " ", with: "")
            let isContent = (normalized.contains("track") && normalized.contains("content"))
                || (normalized.contains("트랙") && normalized.contains("콘텐츠"))
            if isContent {
                return child
            }
        }
        if let hit = trackContentGroup(child, depth: depth + 1) { return hit }
    }
    return nil
}

/// Every layout item whose help text names it a region, depth-first. The keyword is matched in the
/// English and Korean renderings Logic uses; a locale this does not cover yields an empty list,
/// which fails the harness's precondition rather than silently reporting nothing selected.
func regionItems(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 24 else { return [] }
    var found: [AXUIElement] = []
    for child in children(root) {
        if role(child) == (kAXLayoutItemRole as String) {
            let text = help(child)
            if text.contains("Region") || text.contains("region") || text.contains("리전") {
                found.append(child)
            }
        }
        found.append(contentsOf: regionItems(child, depth: depth + 1))
    }
    return found
}

func jsonString(_ value: String?) -> String {
    guard let value, let data = try? JSONSerialization.data(withJSONObject: [value]),
          let text = String(data: data, encoding: .utf8) else { return "null" }
    return String(text.dropFirst().dropLast())
}

func describe(_ item: AXUIElement, index: Int) -> String {
    let name = attr(item, kAXDescriptionAttribute as String) as? String
    let selected = (attr(item, kAXSelectedAttribute as String) as? NSNumber)?.boolValue
    var y = "null"
    if let raw = attr(item, kAXPositionAttribute as String) {
        var point = CGPoint.zero
        // swiftlint:disable:next force_cast
        if AXValueGetValue(raw as! AXValue, .cgPoint, &point) { y = "\(Int(point.y))" }
    }
    return """
    {"index":\(index),"name":\(jsonString(name)),"help":\(jsonString(help(item))),\
    "selected":\(selected.map { $0 ? "true" : "false" } ?? "null"),"y":\(y)}
    """
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.apple.logic10"
}) else {
    print("{\"error\":\"logic_not_running\"}")
    exit(2)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
guard let content = trackContentGroup(appElement) else {
    print("{\"error\":\"track_content_group_not_found\"}")
    exit(3)
}

let items = regionItems(content)
let listing = items.enumerated().map { describe($0.element, index: $0.offset) }.joined(separator: ",")
let selected = items.enumerated()
    .filter { (attr($0.element, kAXSelectedAttribute as String) as? NSNumber)?.boolValue == true }
    .map(\.offset)
print("""
{"regions":[\(listing)],"selected":[\(selected.map(String.init).joined(separator: ","))]}
""")
