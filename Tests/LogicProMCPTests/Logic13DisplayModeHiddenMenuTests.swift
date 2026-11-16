@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Logic Pro 13.0 (7801, Korean) control-bar display-mode popup, measured 2026-11-16 in the Aqua
// session (impl-logic13/B12-dmprobe-showpress.stdout, B13-menuat.stdout, B14-menuparent.stdout):
// AXShowMenu opens the menu (CG layer 101 at 1077,98 234x355) whose AXParent is the popup, but the
// popup's AXChildren stays empty. A hit-test at 1096,124 lands on the "비트" item inside the AXMenu.
// AXCancel on the menu closes it (CG layer gone); afterwards the held menu element still answers
// role AXMenu while the same hit-test lands on an AXGroup. No AX element is read from a running Logic.
private final class HiddenMenuState: @unchecked Sendable {
    var open = false
    var actions: [String] = []
}

private struct HiddenMenuFixture {
    let b = FakeAXRuntimeBuilder()
    let app: AXUIElement, window: AXUIElement, popup: AXUIElement, menu: AXUIElement, background: AXUIElement
    let items: [String: AXUIElement]
    let state = HiddenMenuState()
    static let titles = ["비트 및 프로젝트", "비트 및 시간", "비트", "박자"]

    init() {
        app = b.element(4242); window = b.element(143_002); popup = b.element(143_000)
        menu = b.element(143_001); background = b.element(143_003)
        b.setRole(window, kAXWindowRole as String)
        b.setAttribute(window, kAXTitleAttribute as String, "NativeLogic13-9995.logicx - 트랙")
        b.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/NativeLogic13-9995.logicx")
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setRole(popup, kAXPopUpButtonRole as String)
        b.setAttribute(popup, kAXDescriptionAttribute as String, "표시 모드")
        b.setAttribute(popup, kAXValueAttribute as String, "비트 및 프로젝트")
        b.setAttribute(popup, kAXPositionAttribute as String, axPoint(1076, 56))
        b.setAttribute(popup, kAXSizeAttribute as String, axSize(16, 48))
        b.setActionNames(popup, [kAXShowMenuAction as String, kAXPressAction as String])
        b.setChildren(popup, [])
        b.setRole(menu, kAXMenuRole as String)
        b.setAttribute(menu, kAXParentAttribute as String, popup)
        b.setActionNames(menu, [kAXCancelAction as String])
        b.setRole(background, kAXGroupRole as String)
        var items: [String: AXUIElement] = [:]
        var ordered: [AXUIElement] = []
        for (offset, title) in Self.titles.enumerated() {
            let item = b.element(143_010 + offset)
            b.setRole(item, kAXMenuItemRole as String)
            b.setAttribute(item, kAXTitleAttribute as String, title)
            b.setAttribute(item, kAXEnabledAttribute as String, true)
            b.setAttribute(item, kAXParentAttribute as String, menu)
            b.setActionNames(item, [kAXPressAction as String])
            if offset == 0 { b.setAttribute(item, "AXMenuItemMarkChar", "✓") }
            items[title] = item; ordered.append(item)
        }
        self.items = items
        b.setChildren(menu, ordered)
        b.setChildren(window, [popup])
    }

    func runtime(hitTestReadable: Bool = true) -> AXHelpers.Runtime {
        let b = b, popup = popup, menu = menu, background = background, items = items, state = state
        return b.makeAXRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: { element, action in
            state.actions.append(action)
            if CFEqual(element, popup), action == (kAXShowMenuAction as String) { state.open = true; return true }
            if CFEqual(element, menu), action == (kAXCancelAction as String) { state.open = false; return true }
            if action == (kAXPressAction as String), let title = b.attributeValue(element, kAXTitleAttribute as String) as? String {
                b.setAttribute(popup, kAXValueAttribute as String, title)
                for (candidate, item) in items {
                    if candidate == title { b.setAttribute(item, "AXMenuItemMarkChar", "✓") }
                    else { b.removeAttribute(item, "AXMenuItemMarkChar") }
                }
                state.open = false
                return true
            }
            return false
        }, elementAtPosition: { _, point in
            guard hitTestReadable else { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
            let inMenu = point.x >= 1077 && point.x <= 1311 && point.y >= 98 && point.y <= 453
            return .success(state.open && inMenu ? items["비트"] : background)
        })
    }
}

@Test func logic13HiddenDisplayModeMenuSwitchesToBeatsAndLeavesNoMenu() {
    let f = HiddenMenuFixture()
    let runtime = f.runtime()
    let result = ControlBarDisplayMode.selectBeats(in: f.popup, window: f.window, runtime: runtime)
    guard case .switched(let lease) = result else {
        Issue.record("expected .switched, got \(result)"); return
    }
    #expect(lease.original == "비트 및 프로젝트")
    #expect(f.state.open == false)
    #expect(ControlBarDisplayMode.restore(lease, window: f.window, popup: f.popup, runtime: runtime) == .restored)
    #expect(f.state.open == false)
}

@Test func logic13HiddenMenuWithUnreadableHitTestIsNeverCalledAbsent() {
    // A hit-test that cannot read must not be read as "no menu": a menu that may be open is unsettled.
    let f = HiddenMenuFixture()
    let result = ControlBarDisplayMode.selectBeats(in: f.popup, window: f.window, runtime: f.runtime(hitTestReadable: false))
    if case .unavailable = result { Issue.record("unreadable hit-test reported as unavailable: \(result)") }
    if case .switched = result { Issue.record("unreadable hit-test switched: \(result)") }
}
