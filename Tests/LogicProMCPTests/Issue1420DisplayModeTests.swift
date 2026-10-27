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
    let app: AXUIElement
    let window: AXUIElement
    let foreignWindow: AXUIElement
    let controlBar: AXUIElement
    let popup: AXUIElement
    let menu: AXUIElement
    let items: [String: AXUIElement]
    let actions = DisplayModeActions()

    init(current: String? = "Beats & Project",
         selected: String? = nil,
         document: String = "file:///tmp/DisplayModeFixture.logicx",
         titles: [String] = ["Beats & Project", "Beats", "Time & Project", "Time"]) {
        app = builder.element(142_003)
        window = builder.element(142_002)
        foreignWindow = builder.element(142_004)
        controlBar = builder.element(142_005)
        let transport = builder.element(142_006)
        builder.setRole(window, kAXWindowRole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, "Untitled - Tracks")
        builder.setAttribute(window, kAXDocumentAttribute as String, document)
        builder.setRole(foreignWindow, kAXWindowRole as String)
        builder.setAttribute(foreignWindow, kAXTitleAttribute as String, "Other - Tracks")
        builder.setAttribute(foreignWindow, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setRole(controlBar, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        builder.setRole(transport, kAXCheckBoxRole as String)
        builder.setChildren(transport, [])
        popup = builder.element(142_000)
        menu = builder.element(142_001)
        builder.setAttribute(popup, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXDescriptionAttribute as String, "Display Mode")
        builder.setActionNames(popup, [kAXShowMenuAction as String])
        if let current { builder.setAttribute(popup, kAXValueAttribute as String, current) }
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setActionNames(menu, [kAXCancelAction as String])
        var items: [String: AXUIElement] = [:]
        var ordered: [AXUIElement] = []
        for (offset, title) in titles.enumerated() {
            let item = builder.element(142_010 + offset)
            builder.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
            builder.setAttribute(item, kAXTitleAttribute as String, title)
            builder.setAttribute(item, kAXEnabledAttribute as String, true)
            builder.setActionNames(item, [kAXPressAction as String])
            if title == (selected ?? current) {
                builder.setAttribute(item, "AXMenuItemMarkChar", "✓")
            }
            items[title] = item
            ordered.append(item)
        }
        self.items = items
        builder.setChildren(menu, ordered)
        builder.setChildren(popup, [])
        builder.setChildren(controlBar, [transport, popup])
        builder.setChildren(window, [controlBar])
        builder.setChildren(foreignWindow, [])
    }

    /// `lagReads`: how many reads of the popup's value still return the previous mode after a
    /// press, as Logic 12.4 does (measured 2026-10-26).
    func runtime(
        pressChangesValue: Bool = true,
        lagReads: Int = 0,
        failingPressTitle: String? = nil,
        unreadableTitle: String? = nil,
        failingCancel: Bool = false,
        cancelKeepsMenuOpen: Bool = false,
        falseShowMenuAfterOpening: Bool = false,
        falsePressAfterEffectTitle: String? = nil,
        ineffectivePressTitle: String? = nil,
        pressKeepsMenuOpenTitle: String? = nil,
        closeMenuOnUnchangedPress: Bool = false,
        projectChangeOnShowMenu: String? = nil,
        projectChangeOnPressTitle: String? = nil,
        mainWindowChangeOnPressTitle: String? = nil,
        mainWindowChangeOnCancel: Bool = false
    ) -> AXHelpers.Runtime {
        let builder = builder, app = app, window = window, foreignWindow = foreignWindow
        let popup = popup, menu = menu, actions = actions, items = items
        let lag = DisplayModeLag()
        return builder.makeAXRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard attribute == kAXValueAttribute as String, CFEqual(element, popup),
                      lag.remaining > 0, let previous = lag.previous else { return nil }
                lag.remaining -= 1
                return .some(previous as NSString)
            },
            attributeValueResultHandler: { element, attribute in
                guard attribute == kAXTitleAttribute as String,
                      let unreadableTitle,
                      let unreadable = items[unreadableTitle], CFEqual(element, unreadable) else { return nil }
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil, performActionHandler: { element, action in
                actions.calls.append((builder.elementID(element), action))
                if action == kAXShowMenuAction as String, CFEqual(element, popup) {
                    builder.setChildren(popup, [menu])
                    if let projectChangeOnShowMenu {
                        builder.setAttribute(window, kAXDocumentAttribute as String, projectChangeOnShowMenu)
                    }
                    return !falseShowMenuAfterOpening
                }
                if action == kAXCancelAction as String, CFEqual(element, menu) {
                    if failingCancel { return false }
                    if !cancelKeepsMenuOpen { builder.setChildren(popup, []) }
                    if mainWindowChangeOnCancel {
                        builder.setAttribute(app, kAXMainWindowAttribute as String, foreignWindow)
                    }
                    return true
                }
                if action == kAXPressAction as String,
                   let failingPressTitle,
                   let failed = items[failingPressTitle], CFEqual(element, failed) {
                    return false
                }
                if action == kAXPressAction as String,
                   let ineffectivePressTitle,
                   let ineffective = items[ineffectivePressTitle], CFEqual(element, ineffective) {
                    builder.setChildren(popup, [])
                    return true
                }
                if action == kAXPressAction as String, !pressChangesValue,
                   closeMenuOnUnchangedPress {
                    builder.setChildren(popup, [])
                    return true
                }
                if action == kAXPressAction as String, pressChangesValue,
                   let title = builder.attributeValue(element, kAXTitleAttribute as String) as? String {
                    lag.previous = builder.attributeValue(popup, kAXValueAttribute as String) as? String
                    lag.remaining = lagReads
                    builder.setAttribute(popup, kAXValueAttribute as String, title)
                    for (candidate, item) in items {
                        if candidate == title {
                            builder.setAttribute(item, "AXMenuItemMarkChar", "✓")
                        } else {
                            builder.removeAttribute(item, "AXMenuItemMarkChar")
                        }
                    }
                    if title == projectChangeOnPressTitle {
                        builder.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
                    }
                    if title == mainWindowChangeOnPressTitle {
                        builder.setAttribute(app, kAXMainWindowAttribute as String, foreignWindow)
                    }
                    if title != pressKeepsMenuOpenTitle { builder.setChildren(popup, []) }
                    if title == falsePressAfterEffectTitle { return false }
                }
                return true
            })
    }

    func logicRuntime(_ ax: AXHelpers.Runtime) -> AXLogicProElements.Runtime {
        .init(logicProPID: { 4242 }, ax: ax,
              executeAppleScript: { _ in .error("display-mode fixture forbids scripts") })
    }

    var value: String? { builder.attributeValue(popup, kAXValueAttribute as String) as? String }
    func id(_ title: String) -> Int { builder.elementID(items[title]!) }

    func selectMenuItem(_ title: String) {
        for (candidate, item) in items {
            if candidate == title {
                builder.setAttribute(item, "AXMenuItemMarkChar", "✓")
            } else {
                builder.removeAttribute(item, "AXMenuItemMarkChar")
            }
        }
    }

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
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
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

@Test func testDisplayModeSwitchRetainsLeaseForAnAcknowledgedUnverifiedPress() {
    let fixture = DisplayModeFixture()
    switch fixture.select(fixture.runtime(pressChangesValue: false)) {
    case .unsettled(let lease?, let reason):
        #expect(lease.original == "Beats & Project")
        #expect(reason == "display_mode_change_unverified")
    default:
        Issue.record("An acknowledged but unverified action must retain its inverse")
    }
    #expect(fixture.value == "Beats & Project")
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count == 1)
}

@Test func testDisplayModeSwitchRetainsLeaseForAFalseAcknowledgementWithStaleValue() {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime(
        lagReads: 100,
        falsePressAfterEffectTitle: "Beats")

    switch fixture.select(runtime) {
    case .unsettled(let lease?, let reason):
        #expect(lease.original == "Beats & Project")
        #expect(reason == "display_mode_change_unverified")
    default:
        Issue.record("A false acknowledgement with an unverified effect must retain its inverse")
    }
    #expect(fixture.value == "Beats")
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.map(\.id)
        == [fixture.id("Beats")])
}

@Test func testDisplayModeRestoreIsANoOpWhenTheModeAlreadyMatches() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Beats & Project")
    fixture.selectMenuItem("Beats & Project")
    let before = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count == before)
}

// #1420 cleanup boundaries: a changed or foreign popup, a different window or project, and a mode
// the user chose after the switch are all left alone and reported.
@Test(arguments: ["foreign_popup", "popup_gone", "other_window", "project_renamed", "user_changed_mode"])
func testDisplayModeRestoreActsOnlyWhileTheLeaseHolds(_ mode: String) throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    let before = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count
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
        fixture.selectMenuItem("Time & Project")
        expected = "display_mode_changed_since_switch"
    }
    #expect(ControlBarDisplayMode.restore(lease, window: window, popup: popup, runtime: runtime)
        == .refused(expected))
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count == before)
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

// The popup's AXValue can lag behind the menu. A write lease is based on the menu's unique
// checkmark, not on the stale convenience value, or cleanup can restore the wrong mode.
@Test func testDisplayModeSwitchLeasesTheCheckedModeRatherThanAStalePopupValue() throws {
    let fixture = DisplayModeFixture(current: "Beats & Project", selected: "Time & Project")
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    #expect(lease.original == "Time & Project")
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
    #expect(fixture.value == "Time & Project")
}

// A later user choice is likewise proved by the menu checkmark. A stale "Beats" AXValue must not
// authorize overwriting that choice with the lease's original mode.
@Test func testDisplayModeRestoreRefusesAUserCheckedModeWhenPopupValueStillSaysBeats() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    fixture.selectMenuItem("Time & Project")
    let before = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .refused("display_mode_changed_since_switch"))
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count == before)
}

@Test func testDisplayModeRestoreRefusesTheSameWindowAfterItsProjectChanges() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, "file:///tmp/Other.logicx")
    let before = fixture.actions.calls.count
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .refused("display_mode_project_changed"))
    #expect(fixture.actions.calls.count == before)
}

@Test func testDisplayModeSwitchDoesNotTrustAStaleBeatsPopupValue() throws {
    let fixture = DisplayModeFixture(current: "Beats", selected: "Time & Project")
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    #expect(lease.original == "Time & Project")
    #expect(fixture.value == "Beats")
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
    #expect(fixture.value == "Time & Project")
}

@Test func testDisplayModeSwitchRefusesWhenItsCheckedInverseIsDisabled() {
    let fixture = DisplayModeFixture()
    fixture.builder.setAttribute(fixture.items["Beats & Project"]!, kAXEnabledAttribute as String, false)
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_beats_item_not_pressed"))
    #expect(fixture.value == "Beats & Project")
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
}

@Test func testDisplayModeRestoreRefusesAProjectChangeDuringMenuObservation() throws {
    let fixture = DisplayModeFixture()
    let lease = try fixture.lease(fixture.runtime())
    let runtime = fixture.runtime(projectChangeOnShowMenu: "file:///tmp/Other.logicx")
    let before = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .refused("display_mode_project_changed"))
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count == before)
}

@Test func testDisplayModeRestoreRefusesAProjectChangeDuringFinalSettlement() throws {
    let fixture = DisplayModeFixture()
    let lease = try fixture.lease(fixture.runtime())
    let runtime = fixture.runtime(projectChangeOnPressTitle: "Beats & Project")
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .refused("display_mode_project_changed"))
}

@Test(arguments: ["cancel_failed", "menu_stayed_open"])
func testDisplayModeNoOpRestoreRequiresVerifiedMenuClosure(_ fault: String) throws {
    let fixture = DisplayModeFixture()
    let lease = try fixture.lease(fixture.runtime())
    fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Beats & Project")
    fixture.selectMenuItem("Beats & Project")
    let runtime = fixture.runtime(
        failingCancel: fault == "cancel_failed",
        cancelKeepsMenuOpen: fault == "menu_stayed_open"
    )
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .refused("display_mode_menu_not_closed"))
}

// The popup supplied at restore entry can be detached or replaced while its owned menu action is
// settling. A successful leaf press or Cancel is not enough: the same popup must still belong to
// the main window's control bar at the final readback.
@Test(arguments: ["write", "no_op"])
func testDisplayModeRestoreRequiresFinalControlOwnership(_ mode: String) throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    if mode == "no_op" {
        fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Beats & Project")
        fixture.selectMenuItem("Beats & Project")
    }
    let foreign = fixture.builder.element(142_090)
    let pressCountAtEntry = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count
    let cancelCountAtEntry = fixture.actions.calls.filter { $0.action == kAXCancelAction as String }.count

    #expect(ControlBarDisplayMode.restore(
        lease, window: fixture.window, popup: fixture.popup, runtime: runtime,
        currentOwner: {
            let presses = fixture.actions.calls.filter { $0.action == kAXPressAction as String }.count
            let cancels = fixture.actions.calls.filter { $0.action == kAXCancelAction as String }.count
            let popup = presses > pressCountAtEntry || cancels > cancelCountAtEntry ? foreign : fixture.popup
            return (fixture.window, popup)
        }) == .refused("display_mode_popup_changed"))
}

@Test(arguments: ["write", "no_op"])
func testDisplayModePublicRestoreRenewsTheCurrentWindowAfterItsAction(_ mode: String) throws {
    let fixture = DisplayModeFixture()
    let lease = try fixture.lease(fixture.runtime())
    if mode == "no_op" {
        fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Beats & Project")
        fixture.selectMenuItem("Beats & Project")
    }
    let ax = fixture.runtime(
        mainWindowChangeOnPressTitle: mode == "write" ? "Beats & Project" : nil,
        mainWindowChangeOnCancel: mode == "no_op")
    #expect(ControlBarDisplayMode.restore(lease, runtime: fixture.logicRuntime(ax))
        == .refused("display_mode_window_changed"))
}

@Test func testDisplayModeSwitchRetainsRestorationWhenPressReportsFailureAfterChangingMode() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime(falsePressAfterEffectTitle: "Beats")
    let lease: ControlBarDisplayMode.Lease
    switch fixture.select(runtime) {
    case .switched(let held): lease = held
    case .unavailable(let reason):
        Issue.record("A changed display mode lost its restoration lease: \(reason)")
        return
    case .unsettled(_, let reason):
        Issue.record("A changed display mode did not settle: \(reason)")
        return
    }
    #expect(fixture.value == "Beats")
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
}

@Test func testDisplayModePublicSwitchRefusesAChangedCurrentWindow() {
    let fixture = DisplayModeFixture()
    let ax = fixture.runtime(mainWindowChangeOnPressTitle: "Beats")
    switch ControlBarDisplayMode.selectBeats(runtime: fixture.logicRuntime(ax)) {
    case .unsettled(let lease?, let reason):
        #expect(lease.original == "Beats & Project")
        #expect(reason == "display_mode_window_changed")
    default:
        Issue.record("A changed display mode must retain its lease when current-window custody is lost")
    }
}

@Test func testDisplayModeSwitchDoesNotAdoptAPreexistingMenu() {
    let fixture = DisplayModeFixture()
    fixture.builder.setChildren(fixture.popup, [fixture.menu])

    #expect(fixture.select(fixture.runtime())
        == .unsettled(nil, "display_mode_menu_already_open"))
    #expect(fixture.actions.calls.isEmpty)
    #expect(fixture.builder.makeAXRuntime().children(fixture.popup).contains {
        CFEqual($0, fixture.menu)
    })
}

@Test func testDisplayModeRestoreDoesNotAdoptAPreexistingMenu() throws {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime()
    let lease = try fixture.lease(runtime)
    fixture.builder.setChildren(fixture.popup, [fixture.menu])
    let actionCount = fixture.actions.calls.count

    #expect(ControlBarDisplayMode.restore(
        lease, window: fixture.window, popup: fixture.popup, runtime: runtime
    ) == .refused("display_mode_menu_already_open"))
    #expect(fixture.actions.calls.count == actionCount)
    #expect(fixture.value == "Beats")
}

@Test func testDisplayModeNoChangeReturnsItsUnconsumedInverseToTheCaller() {
    let fixture = DisplayModeFixture()
    let ax = fixture.runtime(
        pressChangesValue: false,
        closeMenuOnUnchangedPress: true)

    switch ControlBarDisplayMode.selectBeats(runtime: fixture.logicRuntime(ax)) {
    case .unsettled(let lease?, let reason):
        #expect(lease.original == "Beats & Project")
        #expect(reason == "display_mode_change_unverified")
    default:
        Issue.record("An ambiguous display-mode action must return its sole unconsumed inverse")
    }
    #expect(fixture.actions.calls.map(\.action) == [
        kAXShowMenuAction as String, kAXPressAction as String,
    ])
}

@Test func testDisplayModeFalseShowCleanupRenewsTheCurrentWindow() {
    let fixture = DisplayModeFixture()
    let ax = fixture.runtime(
        falseShowMenuAfterOpening: true,
        mainWindowChangeOnCancel: true)

    #expect(ControlBarDisplayMode.selectBeats(runtime: fixture.logicRuntime(ax))
        == .unsettled(nil, "display_mode_window_changed"))
    #expect(fixture.actions.calls.map(\.action)
        == [kAXShowMenuAction as String, kAXCancelAction as String])
}

@Test func testDisplayModeRestoreRequiresFreshCheckedOriginalAfterInverse() throws {
    let fixture = DisplayModeFixture()
    let lease = try fixture.lease(fixture.runtime())
    // AXValue is already stale at the desired value while the menu still proves Beats is active.
    fixture.builder.setAttribute(fixture.popup, kAXValueAttribute as String, "Beats & Project")
    let runtime = fixture.runtime(ineffectivePressTitle: "Beats & Project")

    #expect(ControlBarDisplayMode.restore(
        lease, window: fixture.window, popup: fixture.popup, runtime: runtime
    ) == .refused("display_mode_not_restored"))
    #expect(fixture.actions.calls.filter { $0.action == kAXPressAction as String }.map(\.id)
        == [fixture.id("Beats"), fixture.id("Beats & Project")])
    #expect(fixture.builder.makeAXRuntime().children(fixture.popup).isEmpty)
}

@Test(arguments: ["cancel_failed", "menu_stayed_open"])
func testDisplayModeSwitchRetainsLeaseWhenChangedModeMenuDoesNotClose(_ fault: String) {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime(
        failingCancel: fault == "cancel_failed",
        cancelKeepsMenuOpen: fault == "menu_stayed_open",
        pressKeepsMenuOpenTitle: "Beats")

    switch fixture.select(runtime) {
    case .unsettled(let lease?, let reason):
        #expect(lease.original == "Beats & Project")
        #expect(reason == "display_mode_menu_not_closed")
    default:
        Issue.record("A changed mode with an open menu must be terminal and retain its inverse")
    }
    #expect(fixture.value == "Beats")
    #expect(!fixture.builder.makeAXRuntime().children(fixture.popup).isEmpty)
}

@Test func testDisplayModeSwitchCancelsAMenuOpenedByAFalseShowAcknowledgement() {
    let fixture = DisplayModeFixture()
    #expect(fixture.select(fixture.runtime(falseShowMenuAfterOpening: true))
        == .unavailable("display_mode_beats_item_not_pressed"))
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
    #expect(fixture.builder.makeAXRuntime().children(fixture.popup).isEmpty)
}

@Test(arguments: ["cancel_failed", "menu_stayed_open"])
func testDisplayModeSwitchTreatsAnUnclosedFalseShowEffectAsUnsettled(_ fault: String) {
    let fixture = DisplayModeFixture()
    let runtime = fixture.runtime(
        failingCancel: fault == "cancel_failed",
        cancelKeepsMenuOpen: fault == "menu_stayed_open",
        falseShowMenuAfterOpening: true)

    #expect(fixture.select(runtime) == .unsettled(nil, "display_mode_menu_not_closed"))
    #expect(fixture.actions.calls.map(\.action)
        == [kAXShowMenuAction as String, kAXCancelAction as String])
    #expect(!fixture.builder.makeAXRuntime().children(fixture.popup).isEmpty)
}

@Test func testDisplayModeRestoreCancelsAnInverseMenuThatDoesNotSelfClose() throws {
    let fixture = DisplayModeFixture()
    let lease = try fixture.lease(fixture.runtime())
    let runtime = fixture.runtime(pressKeepsMenuOpenTitle: "Beats & Project")
    #expect(ControlBarDisplayMode.restore(lease, window: fixture.window, popup: fixture.popup, runtime: runtime)
        == .restored)
    #expect(fixture.actions.calls.suffix(4).map(\.action) == [
        kAXPressAction as String, kAXCancelAction as String,
        kAXShowMenuAction as String, kAXCancelAction as String,
    ])
    #expect(fixture.builder.makeAXRuntime().children(fixture.popup).isEmpty)
}

@Test func testDisplayModeSwitchRefusesADisabledBeatsItemAndCancelsItsMenu() {
    let fixture = DisplayModeFixture()
    fixture.builder.setAttribute(fixture.items["Beats"]!, kAXEnabledAttribute as String, false)
    #expect(fixture.select(fixture.runtime()) == .unavailable("display_mode_beats_item_not_pressed"))
    #expect(fixture.value == "Beats & Project")
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
}

@Test func testDisplayModeSwitchCancelsItsMenuWhenTheOwnedLeafPressFails() {
    let fixture = DisplayModeFixture()
    switch fixture.select(fixture.runtime(failingPressTitle: "Beats")) {
    case .unsettled(let lease?, let reason):
        #expect(lease.original == "Beats & Project")
        #expect(reason == "display_mode_change_unverified")
    default:
        Issue.record("A failed leaf acknowledgement cannot prove that the action had no effect")
    }
    #expect(fixture.actions.calls.map(\.action) == [
        kAXShowMenuAction as String, kAXPressAction as String, kAXCancelAction as String,
    ])
}

@Test func testDisplayModeSwitchRefusesAnUnreadableCompetingMenuItem() {
    let fixture = DisplayModeFixture()
    #expect(fixture.select(fixture.runtime(unreadableTitle: "Time"))
        == .unavailable("display_mode_beats_item_not_pressed"))
    #expect(fixture.actions.calls.map(\.action) == [kAXShowMenuAction as String, kAXCancelAction as String])
}
