@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #1016 — logic_mixer.insert_plugin presses the slot, which opens Logic's plug-in menu, and then
// may refuse (the root menu was never found, or the leaf is not offered on this strip). The refusal
// used to post a blind Escape and return as though the screen were clean. These tests drive the
// refusal through the production cleanup with the window server replaced by a fixture: the raw
// window list is what CoreGraphics would hand back, so the owner and layer filters are exercised,
// and the Escape the cleanup falls back to is recorded instead of typed into the frontmost app.

private let logicPID: pid_t = 4242
/// The popup-menu layer measured on the live failure: one Logic-owned window at layer 101.
private let measuredPopupMenuLayer = 101

private func window(owner: pid_t, layer: Int) -> [String: Any] {
    [
        kCGWindowOwnerPID as String: NSNumber(value: owner),
        kCGWindowLayer as String: NSNumber(value: layer),
    ]
}

/// The window server as the cleanup sees it. `popupsCloseOnEscape` models a menu Escape closes;
/// otherwise the popup stays whatever is posted.
private final class FakeWindowServer: @unchecked Sendable {
    enum Behaviour { case popupsCloseOnEscape, popupsStay, unreadable, unreadableOnceThenNoPopup, noPopup }
    private let lock = NSLock()
    private let behaviour: Behaviour
    private let baseWindows: [[String: Any]]
    private var escapes = 0
    private var reads = 0

    init(_ behaviour: Behaviour) {
        self.behaviour = behaviour
        // Present in every readable case: Logic's own ordinary window and another process's popup,
        // neither of which is Logic's popup menu.
        baseWindows = [window(owner: logicPID, layer: 0), window(owner: 999, layer: measuredPopupMenuLayer)]
    }

    var escapeCount: Int { lock.withLock { escapes } }
    var readCount: Int { lock.withLock { reads } }

    func windowList() -> [[String: Any]]? {
        lock.withLock {
            reads += 1
            switch behaviour {
            case .unreadable:
                return nil
            case .unreadableOnceThenNoPopup:
                return reads == 1 ? nil : baseWindows
            case .noPopup:
                return baseWindows
            case .popupsStay:
                return baseWindows + [window(owner: logicPID, layer: measuredPopupMenuLayer)]
            case .popupsCloseOnEscape:
                return escapes == 0
                    ? baseWindows + [window(owner: logicPID, layer: measuredPopupMenuLayer)]
                    : baseWindows
            }
        }
    }

    func postEscape() { lock.withLock { escapes += 1 } }
}

enum Issue1016Refusal: CaseIterable, Sendable {
    case rootMenuNotFound, leafNotOffered

    var outcome: AccessibilityChannel.MenuSelectionOutcome {
        switch self {
        case .rootMenuNotFound:
            return .rootMenuNotFound
        case .leafNotOffered:
            return .noPathWalked([.leafMissing(wanted: "Stereo", offered: ["Mono"])])
        }
    }

    var label: String {
        switch self {
        case .rootMenuNotFound: return "root_menu_not_found"
        case .leafNotOffered: return "leaf_not_offered_by_this_strip"
        }
    }
}

private struct RefusalRun {
    let envelope: [String: Any]
    let slotPressed: Bool
    /// Whether AXCancel was performed on the fixture's open menu; false when the fixture has none.
    let menuCancelled: Bool
}

/// `withOpenMenu` puts one AX menu under the application, as the slot press leaves it, so the AX
/// half of the cleanup has something to cancel.
private func runRefusedInsert(
    _ refusal: Issue1016Refusal,
    server: FakeWindowServer,
    withOpenMenu: Bool = false
) async throws -> RefusalRun {
    let b = FakeAXRuntimeBuilder()
    let app = b.element(1016_0)
    let openMenu = b.element(1016_5)
    if withOpenMenu {
        b.setAttribute(openMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setActionNames(openMenu, [kAXCancelAction as String])
        b.setChildren(app, [openMenu])
    }
    let mainWindow = b.element(1016_1)
    let mixer = b.element(1016_2)
    let strip = b.element(1016_3)
    let slot = b.element(1016_4)
    b.setAttribute(app, kAXMainWindowAttribute as String, mainWindow)
    b.setChildren(mainWindow, [mixer])
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    b.setChildren(mixer, [strip])
    b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(strip, [slot])
    b.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(slot, kAXDescriptionAttribute as String, "Audio Plugin")
    b.setAttribute(slot, kAXHelpAttribute as String, "Audio effect slot. Insert an audio effect.")

    let base = b.makeLogicRuntime(pid: logicPID, appElement: app)
    let runtime = AXLogicProElements.Runtime(
        logicProPID: base.logicProPID,
        ax: base.ax,
        executeAppleScript: base.executeAppleScript,
        executeAppleScriptWithTimeout: base.executeAppleScriptWithTimeout,
        onScreenWindowList: { server.windowList() },
        postPopupMenuEscape: { server.postEscape() }
    )
    let result = await AccessibilityChannel.defaultInsertPlugin(
        params: ["track": "0", "slot": "0", "plugin_name": "Gain"],
        runtime: runtime,
        selectPlugin: { _, _, _, _ in refusal.outcome },
        rollback: {
            Issue.record("a refusal before any leaf was pressed must not roll back")
            return false
        }
    )
    let data = try #require(result.message.data(using: .utf8))
    let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let slotPressed = b.actionCalls.contains {
        $0.elementID == b.elementID(slot) && $0.action == kAXPressAction as String
    }
    let menuCancelled = withOpenMenu && b.actionCalls.contains {
        $0.elementID == b.elementID(openMenu) && $0.action == kAXCancelAction as String
    }
    return RefusalRun(envelope: envelope, slotPressed: slotPressed, menuCancelled: menuCancelled)
}

@Test(arguments: Issue1016Refusal.allCases)
func issue1016RefusalReportsAMenuThatEscapeClosedAsDismissed(_ refusal: Issue1016Refusal) async throws {
    let server = FakeWindowServer(.popupsCloseOnEscape)
    let run = try await runRefusedInsert(refusal, server: server)

    #expect(run.slotPressed)
    #expect(run.envelope["state"] as? String == "C")
    #expect(run.envelope["menu_failure"] as? String == refusal.label)
    #expect(run.envelope["plugin_popup_menu_state"] as? String == "dismissed")
    #expect(server.escapeCount == 1)
    #expect(run.envelope["recovery_hint"] == nil)
}

@Test(arguments: Issue1016Refusal.allCases)
func issue1016RefusalReportsAMenuThatStayedOpenWithItsCount(_ refusal: Issue1016Refusal) async throws {
    let server = FakeWindowServer(.popupsStay)
    let run = try await runRefusedInsert(refusal, server: server)

    #expect(run.slotPressed)
    #expect(run.envelope["state"] as? String == "C")
    #expect(run.envelope["menu_failure"] as? String == refusal.label)
    #expect(run.envelope["plugin_popup_menu_state"] as? String == "could_not_be_dismissed")
    let initial = try #require(run.envelope["plugin_popup_menu_initial_window_count"] as? Int)
    let remaining = try #require(run.envelope["plugin_popup_menu_remaining_window_count"] as? Int)
    // One Logic-owned popup-level window in the fixture; the other process's popup and Logic's
    // layer-0 window are not counted.
    #expect(initial == 1)
    #expect(remaining == 1)
    #expect(server.escapeCount == 1)
    let hint = try #require(run.envelope["recovery_hint"] as? String)
    #expect(hint.contains("Escape"))
}

@Test(arguments: Issue1016Refusal.allCases)
func issue1016RefusalDoesNotReadAnUnreadableWindowListAsClean(_ refusal: Issue1016Refusal) async throws {
    let server = FakeWindowServer(.unreadable)
    let run = try await runRefusedInsert(refusal, server: server, withOpenMenu: true)

    #expect(run.slotPressed)
    #expect(run.envelope["state"] as? String == "C")
    #expect(run.envelope["plugin_popup_menu_state"] as? String == "window_count_unavailable")
    // The unread count does not stop the AX cancel, which is aimed by AX role, not by the count,
    // and the list is read again after it.
    #expect(run.menuCancelled)
    #expect(server.readCount >= 2)
    // Unknown is not a reason to type: no reading counted a popup, and an Escape goes to focus.
    #expect(server.escapeCount == 0)
    let hint = try #require(run.envelope["recovery_hint"] as? String)
    #expect(hint.contains("Escape"))
}

@Test(arguments: Issue1016Refusal.allCases)
func issue1016RefusalCancelsItsMenuWhenOnlyTheFirstReadFails(_ refusal: Issue1016Refusal) async throws {
    let server = FakeWindowServer(.unreadableOnceThenNoPopup)
    let run = try await runRefusedInsert(refusal, server: server, withOpenMenu: true)

    #expect(run.envelope["state"] as? String == "C")
    #expect(run.menuCancelled)
    // The reading after the cancel answers, and it shows no popup.
    #expect(run.envelope["plugin_popup_menu_state"] as? String == "dismissed")
    #expect(server.escapeCount == 0)
    #expect(run.envelope["recovery_hint"] == nil)
}

@Test(arguments: Issue1016Refusal.allCases)
func issue1016UnreadFirstCountWithNothingToCancelIsNotReportedAsDismissed(
    _ refusal: Issue1016Refusal
) async throws {
    let server = FakeWindowServer(.unreadableOnceThenNoPopup)
    let run = try await runRefusedInsert(refusal, server: server)

    // Nothing was cancelled and nothing typed; the one reading that answered saw no popup.
    #expect(run.envelope["plugin_popup_menu_state"] as? String == "no_popup_observed")
    #expect(server.escapeCount == 0)
}

@Test(arguments: Issue1016Refusal.allCases)
func issue1016RefusalWithNoPopupOnScreenPostsNothing(_ refusal: Issue1016Refusal) async throws {
    let server = FakeWindowServer(.noPopup)
    let run = try await runRefusedInsert(refusal, server: server)

    #expect(run.slotPressed)
    #expect(run.envelope["state"] as? String == "C")
    #expect(run.envelope["plugin_popup_menu_state"] as? String == "no_popup_observed")
    #expect(server.readCount >= 1)
    #expect(server.escapeCount == 0)
    #expect(run.envelope["recovery_hint"] == nil)
}

// Limit, not endorsement: the live #1016 capture also showed a Logic-owned window at layer 102.
// The popup count is defined as `CGWindowLevelForKey(.popUpMenuWindow)` exactly, so such a window
// is not counted and a refusal over it reports no popup. Widening that level is a separate change.
@Test func issue1016LayerOneHundredTwoIsNotCountedAsAPopupMenu() async throws {
    let b = FakeAXRuntimeBuilder()
    let base = b.makeLogicRuntime(pid: logicPID)
    let runtime = AXLogicProElements.Runtime(
        logicProPID: base.logicProPID,
        ax: base.ax,
        onScreenWindowList: { [window(owner: logicPID, layer: 102)] },
        postPopupMenuEscape: { Issue.record("no popup was counted, so nothing may be typed") }
    )
    let outcome = AccessibilityChannel.livePluginPopupMenuCleaner(runtime)
    #expect(outcome == .noPopupObserved)
}
