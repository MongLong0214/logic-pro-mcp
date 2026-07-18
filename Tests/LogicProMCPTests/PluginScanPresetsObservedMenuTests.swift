@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Regression guard for the coord-removal feature-loss bug in
// `runLivePluginPresetScan` (plugin.scan_presets).
//
// LIVE ROOT CAUSE (verified against real Logic 12.3): the Setting AXPopUpButton
// returns a NON-ZERO AX status even when the action actually opens the menu
// (AXShowMenu → -25206 actionUnsupported; AXPress → -25204 cannotComplete WHILE
// ~141 AXMenuItems appear). The old loop gated the observed-menu poll on the
// performAction return code, so it skipped the poll and fail-closed with
// "Setting menu did not appear" — even though the menu was open. Unit fakes
// returned true, so they never caught it.
//
// These tests drive the fake `performAction` to return FALSE for the Setting
// popup (the exact live behavior) while the observed AX tree DOES expose the
// open AXMenu. The op MUST now scan the menu (success), not fail-closed.

/// Builds the AX tree `runLivePluginPresetScan` walks:
///   app
///     ├─ kAXWindows   = [pluginWindow]           (findFocusedPluginWindowAX)
///     │     pluginWindow ── Setting AXPopUpButton (value "Default Preset")
///     └─ kAXChildren  = [settingMenu?]           (findOpenSettingMenuAX)
///           settingMenu ── N AXMenuItem leaves
///
/// `menuIsOpen` models whether the menu actually surfaced in the tree; the
/// popup's `performAction` always returns FALSE, mirroring live Logic.
private struct ScanPresetsFixture {
    let runtime: AXLogicProElements.Runtime

    init(menuIsOpen: Bool, menuItemCount: Int = 5) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(1)
        let pluginWindow = b.element(2)
        let popup = b.element(3)
        let menu = b.element(4)

        // Plugin window: title has no ".logicx"; holds the Setting popup.
        b.setAttribute(pluginWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(pluginWindow, kAXTitleAttribute as String, "Compressor")
        b.setChildren(pluginWindow, [popup])

        // Setting popup: AXPopUpButton whose value matches settingPopupValue.
        b.setAttribute(popup, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
        b.setAttribute(popup, kAXValueAttribute as String, "Default Preset")

        b.setAttribute(app, kAXWindowsAttribute as String, [pluginWindow])

        if menuIsOpen {
            b.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
            var items: [AXUIElement] = []
            for i in 0..<menuItemCount {
                let item = b.element(100 + i)
                b.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
                b.setAttribute(item, kAXTitleAttribute as String, "Preset \(i)")
                items.append(item)
            }
            b.setChildren(menu, items)
            // The open menu appears as a top-level child of the app root.
            b.setChildren(app, [menu])
        } else {
            b.setChildren(app, [])
        }

        // The Setting popup's action ALWAYS returns false — the live bug.
        let popupKey = b.elementID(popup)
        runtime = b.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { [b] element, _ in
                b.elementID(element) != popupKey
            }
        )
    }
}

@Test func testScanPresetsSucceedsWhenPopupActionFailsButMenuObserved() async {
    // Live scenario: popup AXShowMenu/AXPress both return false, yet the menu is
    // open in the AX tree. The scan MUST trust the observed menu and succeed.
    let fixture = ScanPresetsFixture(menuIsOpen: true, menuItemCount: 6)
    let result = await AccessibilityChannel.runLivePluginPresetScan(
        runtime: fixture.runtime, settleMs: 0
    )
    #expect(result.isSuccess)
    #expect(result.message.contains("Preset 0"))
    #expect(result.message.contains("Preset 5"))
    #expect(!result.message.contains("Setting menu did not appear"))
}

@Test func testScanPresetsFailsClosedWhenActionFiresButNoMenuOpens() async {
    // Complement: popup action fires but NOTHING opens (no menu in the tree).
    // The fix must remain fail-closed — never fabricate a State-A success.
    let fixture = ScanPresetsFixture(menuIsOpen: false)
    let result = await AccessibilityChannel.runLivePluginPresetScan(
        runtime: fixture.runtime, settleMs: 0
    )
    #expect(!result.isSuccess)
    #expect(result.message.contains("Setting menu did not appear"))
}
