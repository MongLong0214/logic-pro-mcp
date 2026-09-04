// Measure whether a Controls-view AXPopUpButton can be actuated, by OBSERVED EFFECT.
//
// `LocatorFailure.popupUnmeasured` says selection "has not been measured, so no menu action is
// guessed". This probe measures it. It never reports a status as a result: every step is judged by
// re-reading AXValue afterwards, because on this application AXPress and AXValue-set both return
// success on controls that do not move (2026-09-02 for the sibling slider; 2026-09-03 for a sort
// menu leaf that recorded no undo entry).
//
//   ./popupprobe                 -> census only, mutates nothing
//   ./popupprobe --actuate       -> also tries to change the FIRST popup, then restores it
import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) }
func settable(_ e: AXUIElement, _ a: String) -> Bool {
    var b = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(e, a as CFString, &b) == .success else { return false }
    return b.boolValue
}
func emit(_ o: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]),
                 encoding: .utf8)!)
    exit(0)
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").contains("logic")
}) else { emit(["ok": false, "error": "logic not running"]) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
let windows: [AXUIElement] = (attr(ax, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []

// The plug-in editor is the window carrying exactly one AXTable of labelled rows.
func tables(in w: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        guard d <= 8 else { return }
        for c in kids(e) {
            if role(c) == (kAXTableRole as String) { out.append(c) }
            walk(c, d + 1)
        }
    }
    walk(w, 1)
    return out
}

var report: [String: Any] = ["ok": true]
var chosen: (AXUIElement, AXUIElement)?   // (window, table)
var windowSummaries: [[String: Any]] = []
for w in windows {
    let t = tables(in: w)
    windowSummaries.append(["title": str(w, kAXTitleAttribute as String), "tables": t.count])
    if t.count == 1, chosen == nil { chosen = (w, t[0]) }
}
report["windows"] = windowSummaries
guard let (_, table) = chosen else {
    report["error"] = "no window exposes exactly one AXTable — open a plug-in editor in Controls view"
    emit(report)
}

let rows = kids(table).filter { role($0) == (kAXRowRole as String) }
var popups: [[String: Any]] = []
var firstPopup: (AXUIElement, String)?
for r in rows {
    var label = ""
    var control: AXUIElement?
    for cell in kids(r) where role(cell) == (kAXCellRole as String) {
        for child in kids(cell) {
            let cr = role(child)
            if cr == (kAXStaticTextRole as String), label.isEmpty {
                label = str(child, kAXValueAttribute as String)
                if label.isEmpty { label = str(child, kAXTitleAttribute as String) }
            }
            if cr == (kAXPopUpButtonRole as String) { control = child }
        }
    }
    guard let popup = control else { continue }
    let value = str(popup, kAXValueAttribute as String)
    var actions: CFArray?
    AXUIElementCopyActionNames(popup, &actions)
    popups.append([
        "label": label,
        "value": value,
        "value_settable": settable(popup, kAXValueAttribute as String),
        "actions": (actions as? [String]) ?? [],
        "children_roles": kids(popup).map { role($0) },
    ])
    if firstPopup == nil { firstPopup = (popup, label) }
}
report["row_count"] = rows.count
report["popups"] = popups

guard CommandLine.arguments.contains("--actuate"), let (popup, label) = firstPopup else {
    report["actuated"] = false
    emit(report)
}

// Actuation, judged only by what AXValue says AFTERWARDS.
let before = str(popup, kAXValueAttribute as String)
var attempts: [[String: Any]] = []
func observe() -> String { str(popup, kAXValueAttribute as String) }

// 1. AXPress, then read the menu it may have opened.
let pressStatus = AXUIElementPerformAction(popup, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 0.4)
let menus = kids(popup).filter { role($0) == (kAXMenuRole as String) }
var menuItems: [String] = []
if let m = menus.first {
    menuItems = kids(m).map { str($0, kAXTitleAttribute as String) }
}
attempts.append([
    "step": "AXPress",
    "reported_status": pressStatus.rawValue,
    "menu_appeared": !menus.isEmpty,
    "menu_items": menuItems,
    "value_after": observe(),
])

// 2. If a menu opened, press a DIFFERENT item and re-read.
if let m = menus.first {
    let items = kids(m)
    if let target = items.first(where: { str($0, kAXTitleAttribute as String) != before && !str($0, kAXTitleAttribute as String).isEmpty }) {
        let wanted = str(target, kAXTitleAttribute as String)
        let st = AXUIElementPerformAction(target, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.5)
        let after = observe()
        attempts.append([
            "step": "AXPress menu item",
            "requested": wanted,
            "reported_status": st.rawValue,
            "value_after": after,
            "OBSERVED_CHANGE": after != before,
        ])
        // restore
        if after != before, let back = kids(m).first(where: { str($0, kAXTitleAttribute as String) == before }) {
            _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.3)
            _ = AXUIElementPerformAction(back, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.4)
            attempts.append(["step": "restore", "value_after": observe(), "restored": observe() == before])
        }
    } else {
        attempts.append(["step": "AXPress menu item", "skipped": "no item differs from the current value"])
    }
}
report["actuated"] = true
report["popup_label"] = label
report["value_before"] = before
report["attempts"] = attempts
emit(report)
