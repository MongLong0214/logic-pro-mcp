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

/// The element's frame, or nil when either half is unreadable.
///
/// Both halves. Position without size describes a point, and a band derived from a point is a
/// band of zero area that every comparison reads as "nothing changed" — the failure #780 is about,
/// arrived at by a different route.
func frame(_ element: AXUIElement) -> (x: Int, y: Int, w: Int, h: Int)? {
    guard let positionValue = attr(element, kAXPositionAttribute as String),
          let sizeValue = attr(element, kAXSizeAttribute as String) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    // swiftlint:disable:next force_cast
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
          // swiftlint:disable:next force_cast
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return (Int(point.x), Int(point.y), Int(size.width), Int(size.height))
}

/// The arrange window's frame, so every frame below can be reported in WINDOW coordinates.
///
/// AX reports screen coordinates and `Evidence.visual` takes window ones — it clips what it is
/// given against the window's width and height. Handing it a screen rectangle on a second display
/// or a window that is not at the origin aims the comparison somewhere else entirely, and the
/// receipt cannot show it: a rectangle records where it looked, never what was there.
/// `ax_control_bar_band.swift` already subtracts the window origin for exactly this reason; doing
/// it here keeps one converter rather than two that can disagree.
/// The window that CONTAINS a given element, by walking its AXParent chain.
///
/// Not "the first standard window". Raised by review 2026-09-05: `Evidence.shot` picks a
/// CoreGraphics window by the arrange TITLE, and this tool picked the first standard window in AX
/// order. With two standard windows on screen those need not be the same window, so the emitted
/// coordinates could be relative to one while declaring `window-relative` — and a declared
/// coordinate space that can be wrong is worse than none, because a reader trusts it.
///
/// Walking up from the track-content group ties the origin to the window the regions are actually
/// in, which is the window the harness captured or the run has bigger problems than an offset.
func windowContaining(_ element: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<24 {
        guard let node = current else { return nil }
        if (attr(node, kAXRoleAttribute as String) as? String) == (kAXWindowRole as String) {
            return node
        }
        current = attr(node, kAXParentAttribute as String) as! AXUIElement?
    }
    return nil
}

func describe(_ item: AXUIElement, index: Int, origin: (x: Int, y: Int)?) -> String {
    let name = attr(item, kAXDescriptionAttribute as String) as? String
    let selected = (attr(item, kAXSelectedAttribute as String) as? NSNumber)?.boolValue
    var x = "null", y = "null", w = "null", h = "null"
    if let f = frame(item) {
        // `y` keeps its screen-relative meaning ONLY when no window origin was resolved, which is
        // also when no caller should be deriving a band. When the origin is known every component
        // is window-relative, which is the space `visual()` and `shot()` work in.
        x = "\(f.x - (origin?.x ?? 0))"
        y = "\(f.y - (origin?.y ?? 0))"
        w = "\(f.w)"
        h = "\(f.h)"
    }
    return """
    {"index":\(index),"name":\(jsonString(name)),"help":\(jsonString(help(item))),\
    "selected":\(selected.map { $0 ? "true" : "false" } ?? "null"),\
    "x":\(x),"y":\(y),"w":\(w),"h":\(h)}
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

let contentWindow = windowContaining(content)
let windowFrame = contentWindow.flatMap(frame)
let windowTitle = contentWindow.flatMap { attr($0, kAXTitleAttribute as String) as? String }
let origin = windowFrame.map { (x: $0.x, y: $0.y) }
let items = regionItems(content)
let listing = items.enumerated()
    .map { describe($0.element, index: $0.offset, origin: origin) }
    .joined(separator: ",")
let selected = items.enumerated()
    .filter { (attr($0.element, kAXSelectedAttribute as String) as? NSNumber)?.boolValue == true }
    .map(\.offset)
// `coordinateSpace` is stated rather than assumed. A caller that derives a band from these numbers
// has to know which space they are in, and a run whose window origin could not be read must be
// able to refuse instead of quietly building a band in the wrong one.
let space = windowFrame == nil ? "screen-absolute" : "window-relative"
let windowJSON = windowFrame.map { "{\"x\":\($0.x),\"y\":\($0.y),\"w\":\($0.w),\"h\":\($0.h)}" }
    ?? "null"
// The window's TITLE travels with the coordinates so a caller can check the origin it subtracted
// belongs to the window it captured. Emitting the space without the identity was the gap: the
// payload said `window-relative` and could not say WHICH window.
print("""
{"regions":[\(listing)],"selected":[\(selected.map(String.init).joined(separator: ","))],\
"coordinateSpace":"\(space)","window":\(windowJSON),"windowTitle":\(jsonString(windowTitle))}
""")
