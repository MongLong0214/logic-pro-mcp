@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// #1420 — record_sequence switches the control bar's display mode to Beats for its seek and puts
// the original mode back, only while the same window and popup still show the mode it set. The
// titles are the en-US Logic 12.4 menu, read 2026-10-25. Like Logic, the fake attaches the menu on
// AXShowMenu, detaches it when an item is pressed or the menu is cancelled, and shows a Logic
// window at the popup-menu layer while it is attached.
private final class DisplayModeState: @unchecked Sendable {
    var calls: [(id: Int, action: String)] = []
    var previous: String?
    var lagReads = 0
    var menuAttached = false
    var foreignPopupWindow = false
}

private struct DisplayModeFixture {
    let builder = FakeAXRuntimeBuilder()
    let window: AXUIElement
    let popup: AXUIElement
    let menu: AXUIElement
    let items: [String: AXUIElement]
    let state = DisplayModeState()

    init(current: String? = "Beats & Project",
         titles: [String] = ["Beats & Project", "Beats", "Time & Project", "Time"]) {
        window = builder.element(142_002)
        builder.setAttribute(window, kAXTitleAttribute as String, "Untitled - Tracks")
        popup = builder.element(142_000)
        menu = builder.element(142_001)
        builder.setAttribute(popup, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXDescriptionAttribute as String, "Display Mode")
        if let current { builder.setAttribute(popup, kAXValueAttribute as String, current) }
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setActionNames(menu, [kAXCancelAction as String])
        var items: [String: AXUIElement] = [:]
        var ordered: [AXUIElement] = []
        for (offset, title) in titles.enumerated() {
            let item = builder.element(142_010 + offset)
            builder.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
            builder.setAttribute(item, kAXTitleAttribute as String, title)
            items[title] = item
            ordered.append(item)
        }
        self.items = items
        builder.setChildren(menu, ordered)
    }

    /// `pressChangesValue`: whether pressing a mode item changes the popup's value.
    /// `lagReads`: how many reads of the value still return the previous mode after a press, as
    /// Logic 12.4 does (measured 2026-10-26). `menuCloses`: whether pressing an item closes the
    /// menu; `cancelCloses`: whether AXCancel does.
    func runtime(pressChangesValue: Bool = true, lagReads: Int = 0,
                 menuCloses: Bool = true, cancelCloses: Bool = true) -> AXLogicProElements.Runtime {
        let builder = builder, popup = popup, menu = menu, state = state
        let ax = builder.makeAXRuntime(
            attributeValueHandler: { element, attribute in
                guard attribute == kAXValueAttribute as String, CFEqual(element, popup),
                      state.lagReads > 0, let previous = state.previous else { return nil }
                state.lagReads -= 1
                return .some(previous as NSString)
            },
            childrenHandler: { element in
                CFEqual(element, popup) ? (state.menuAttached ? [menu] : []) : nil
            },
            setAttributeHandler: nil, performActionHandler: { element, action in
                state.calls.append((builder.elementID(element), action))
                if action == kAXShowMenuAction as String, CFEqual(element, popup) {
                    state.menuAttached = true
                } else if action == kAXCancelAction as String, CFEqual(element, menu), cancelCloses {
                    state.menuAttached = false
                } else if action == kAXPressAction as String,
                          let title = builder.attributeValue(element, kAXTitleAttribute as String) as? String {
                    if pressChangesValue {
                        state.previous = builder.attributeValue(popup, kAXValueAttribute as String) as? String
                        state.lagReads = lagReads
                        builder.setAttribute(popup, kAXValueAttribute as String, title)
                    }
                    if menuCloses { state.menuAttached = false }
                }
                return true
            })
        return AXLogicProElements.Runtime(
            logicProPID: { 4242 }, ax: ax,
            executeAppleScript: { _ in Issue.record("native script prohibited"); return .error("inert") },
            onScreenWindowList: {
                let count = (state.menuAttached ? 1 : 0) + (state.foreignPopupWindow ? 1 : 0)
                return (0..<count).map { index in
                    [kCGWindowOwnerPID as String: 4242,
                     kCGWindowNumber as String: 142_200 + index,
                     kCGWindowLayer as String: Int(CGWindowLevelForKey(.popUpMenuWindow))]
                }
            },
            postPopupMenuEscape: { Issue.record("native escape prohibited") })
    }

    var value: String? { builder.attributeValue(popup, kAXValueAttribute as String) as? String }
    func id(_ title: String) -> Int { builder.elementID(items[title]!) }
    func actions(_ action: String) -> [Int] { state.calls.filter { $0.action == action }.map(\.id) }

    func select(_ runtime: AXLogicProElements.Runtime,
                timing: ControlBarDisplayMode.Timing = .immediate) -> ControlBarDisplayMode.Switch {
        ControlBarDisplayMode.selectBeats(in: popup, window: window, runtime: runtime, timing: timing)
    }

    func restore(_ lease: ControlBarDisplayMode.Lease, _ runtime: AXLogicProElements.Runtime,
                 window: AXUIElement? = nil, popup: AXUIElement?? = nil,
                 timing: ControlBarDisplayMode.Timing = .immediate) -> ControlBarDisplayMode.Restore {
        ControlBarDisplayMode.restore(lease, window: window ?? self.window, popup: popup ?? self.popup,
                                      runtime: runtime, timing: timing)
    }

    func lease(_ runtime: AXLogicProElements.Runtime) throws -> ControlBarDisplayMode.Lease {
        guard case .switched(let lease) = select(runtime) else {
            throw DisplayModeFixtureError.notSwitched
        }
        return lease
    }
}

private enum DisplayModeFixtureError: Error { case notSwitched }

@Test func testDisplayModeSwitchSelectsBeatsAndRestoresTheOriginal() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    #expect(lease.original == "Beats & Project")
    #expect(lease.windowTitle == "Untitled - Tracks")
    #expect(fixture.value == "Beats")
    #expect(!fixture.state.menuAttached)
    #expect(fixture.restore(lease, runtime) == .restored)
    #expect(fixture.value == "Beats & Project")
    #expect(!fixture.state.menuAttached)
    #expect(fixture.actions(kAXPressAction as String) == [fixture.id("Beats"), fixture.id("Beats & Project")])
    #expect(fixture.actions(kAXCancelAction as String).isEmpty)
}

@Test func testDisplayModeSwitchLeavesBeatsAlone() {
    let fixture = DisplayModeFixture(current: "Beats")
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_already_beats"))
    #expect(fixture.state.calls.isEmpty)
}

@Test func testDisplayModeSwitchRefusesAnUnreadableMode() {
    let fixture = DisplayModeFixture(current: nil)
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_unreadable"))
    #expect(fixture.state.calls.isEmpty)
}

@Test func testDisplayModeSwitchCancelsTheMenuWithoutABeatsItem() {
    let fixture = DisplayModeFixture(titles: ["Beats & Project", "Time & Project"])
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_beats_item_not_pressed"))
    #expect(fixture.value == "Beats & Project")
    #expect(!fixture.state.menuAttached)
    #expect(fixture.state.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
}

@Test func testDisplayModeSwitchReportsAPressThatChangedNothing() {
    let fixture = DisplayModeFixture()
    #expect(fixture.select(fixture.runtime(pressChangesValue: false)) == .unavailable("display_mode_did_not_change"))
    #expect(fixture.value == "Beats & Project")
    #expect(fixture.actions(kAXPressAction as String).count == 1)
}

@Test func testDisplayModeRestoreIsANoOpWhenTheModeAlreadyMatches() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Beats & Project")
    let before = fixture.state.calls.count
    #expect(fixture.restore(lease, runtime) == .restored)
    #expect(fixture.state.calls.count == before)
}

// #1420 cleanup boundaries: a changed or foreign popup, a different window or project, and a mode
// the user chose after the switch are all left alone and reported.
@Test(arguments: ["foreign_popup", "popup_gone", "other_window", "project_renamed", "user_changed_mode"])
func testDisplayModeRestoreActsOnlyWhileTheLeaseHolds(_ mode: String) throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    let before = fixture.state.calls.count
    var window = fixture.window
    var popup: AXUIElement? = fixture.popup
    let expected: String
    switch mode {
    case "foreign_popup":
        popup = fixture.builder.element(142_050)
        expected = "display_mode_popup_changed"
    case "popup_gone":
        popup = nil
        expected = "display_mode_popup_changed"
    case "other_window":
        window = fixture.builder.element(142_051)
        fixture.builder.setAttribute(window, kAXTitleAttribute as String, "Untitled - Tracks")
        expected = "display_mode_window_changed"
    case "project_renamed":
        fixture.builder.setAttribute(fixture.window, kAXTitleAttribute as String, "Other - Tracks")
        expected = "display_mode_window_changed"
    default:
        fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Time & Project")
        expected = "display_mode_changed_since_switch"
    }
    #expect(fixture.restore(lease, runtime, window: window, popup: .some(popup)) == .refused(expected))
    #expect(fixture.state.calls.count == before)
}

// Live on Logic 12.4 the popup still read the previous mode right after the press while the switch
// went through; deciding on that first read reported "did not change" and left Beats selected.
@Test func testDisplayModeSwitchAndRestoreWaitForTheLaggingPopupValue() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime(lagReads: 3)
    let waits = ControlBarDisplayMode.Timing(pollInterval: 0)
    guard case .switched(let lease) = fixture.select(runtime, timing: waits) else {
        Issue.record("the switch did not wait for the lagging value"); return
    }
    #expect(lease.original == "Beats & Project")
    #expect(fixture.restore(lease, runtime, timing: waits) == .restored)
    #expect(fixture.value == "Beats & Project")
}

// As Quantize's owned cleanup: a menu still open after the press is cancelled only because it is
// the menu this press opened, and a menu that will not close, or another Logic popup on screen,
// is reported rather than assumed closed.
@Test(arguments: ["cancel_closes", "never_closes", "foreign_popup_window"])
func testDisplayModeSwitchCertifiesItsMenuClosed(_ mode: String) {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime(menuCloses: mode == "foreign_popup_window", cancelCloses: mode == "cancel_closes")
    if mode == "foreign_popup_window" { fixture.state.foreignPopupWindow = true }
    let result = fixture.select(runtime)
    if mode == "cancel_closes" {
        guard case .switched = result else { Issue.record("expected a switch, got \(result)"); return }
        #expect(!fixture.state.menuAttached)
        #expect(fixture.actions(kAXCancelAction as String) == [fixture.builder.elementID(fixture.menu)])
    } else {
        #expect(result == .unavailable("display_mode_menu_not_closed"))
        if mode == "foreign_popup_window" {
            // The foreign menu is not ours: nothing is cancelled.
            #expect(fixture.actions(kAXCancelAction as String).isEmpty)
        }
    }
}
