@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #1420 — record_sequence switches the control bar's display mode to Beats for its seek and puts
// the original mode back, only while the same window and popup still show the mode it set. The
// titles are the en-US Logic 12.4 menu, read 2026-10-25.
private final class DisplayModeActions: @unchecked Sendable {
    var calls: [(id: Int, action: String)] = []
}

private final class DisplayModeLag: @unchecked Sendable {
    var previous: String?
    var remaining = 0
}

private struct DisplayModeFixture {
    let builder = FakeAXRuntimeBuilder()
    let window: AXUIElement
    let popup: AXUIElement
    let menu: AXUIElement
    let items: [String: AXUIElement]
    let actions = DisplayModeActions()

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
        builder.setChildren(popup, [menu])
    }

    /// `lagReads`: how many reads of the popup's value still return the previous mode after a
    /// press, as Logic 12.4 does (measured 2026-10-26).
    func runtime(pressChangesValue: Bool = true, lagReads: Int = 0) -> AXHelpers.Runtime {
        let builder = builder, popup = popup, actions = actions
        let lag = DisplayModeLag()
        return builder.makeAXRuntime(
            attributeValueHandler: { element, attribute in
                guard attribute == kAXValueAttribute as String, CFEqual(element, popup),
                      lag.remaining > 0, let previous = lag.previous else { return nil }
                lag.remaining -= 1
                return .some(previous as NSString)
            },
            setAttributeHandler: nil, performActionHandler: { element, action in
                actions.calls.append((builder.elementID(element), action))
                if action == kAXPressAction as String, pressChangesValue,
                   let title = builder.attributeValue(element, kAXTitleAttribute as String) as? String {
                    lag.previous = builder.attributeValue(popup, kAXValueAttribute as String) as? String
                    lag.remaining = lagReads
                    builder.setAttribute(popup, kAXValueAttribute as String, title)
                }
                return true
            })
    }

    var value: String? { builder.attributeValue(popup, kAXValueAttribute as String) as? String }
    func id(_ title: String) -> Int { builder.elementID(items[title]!) }

    func select(_ runtime: AXHelpers.Runtime) -> ControlBarDisplayMode.Switch {
        ControlBarDisplayMode.selectBeats(in: popup, window: window, runtime: runtime)
    }

    func lease(_ runtime: AXHelpers.Runtime) throws -> ControlBarDisplayMode.Lease {
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
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
    #expect(fixture.value == "Beats & Project")
    let presses = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.map(\.id)
    #expect(presses == [fixture.id("Beats"), fixture.id("Beats & Project")])
}

@Test func testDisplayModeSwitchLeavesBeatsAlone() {
    let fixture = DisplayModeFixture(current: "Beats")
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_already_beats"))
    #expect(fixture.actions.calls.isEmpty)
}

@Test func testDisplayModeSwitchRefusesAnUnreadableMode() {
    let fixture = DisplayModeFixture(current: nil)
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_unreadable"))
    #expect(fixture.actions.calls.isEmpty)
}

@Test func testDisplayModeSwitchCancelsTheMenuWithoutABeatsItem() {
    let fixture = DisplayModeFixture(titles: ["Beats & Project", "Time & Project"])
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_beats_item_not_pressed"))
    #expect(fixture.value == "Beats & Project")
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
}

@Test func testDisplayModeSwitchReportsAPressThatChangedNothing() {
    let fixture = DisplayModeFixture()
    #expect(fixture.select(fixture.runtime(pressChangesValue: false)) == .unavailable("display_mode_did_not_change"))
    #expect(fixture.value == "Beats & Project")
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count == 1)
}

@Test func testDisplayModeRestoreIsANoOpWhenTheModeAlreadyMatches() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Beats & Project")
    let before = fixture.actions.calls.count
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
    #expect(fixture.actions.calls.count == before)
}

// #1420 cleanup boundaries: a changed or foreign popup, a different window or project, and a mode
// the user chose after the switch are all left alone and reported.
@Test(arguments: ["foreign_popup", "popup_gone", "other_window", "project_renamed", "user_changed_mode"])
func testDisplayModeRestoreActsOnlyWhileTheLeaseHolds(_ mode: String) throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    let before = fixture.actions.calls.count
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
    #expect(ControlBarDisplayMode.restore(lease, window: window, popup: popup, runtime: runtime)
        == .refused(expected))
    #expect(fixture.actions.calls.count == before)
}

// Live on Logic 12.4 the popup still read the previous mode right after the press while the switch
// went through; deciding on that first read reported "did not change" and left Beats selected.
@Test func testDisplayModeSwitchAndRestoreWaitForTheLaggingPopupValue() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime(lagReads: 3)
    let lease = try fixture.lease(runtime)
    #expect(lease.original == "Beats & Project")
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
    #expect(fixture.value == "Beats & Project")
}
