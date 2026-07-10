import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue #256 native Bounce menu")
struct Issue256BounceMenuTests {
    final class Probe: @unchecked Sendable {
        var called = false
        var script = ""
    }

    private func object(_ result: ChannelResult) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
    }

    @Test("menu click is verified by Bounce dialog readback")
    func verifiedDialogOpen() async throws {
        let probe = Probe()
        let result = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: { true },
            executeScript: { script in
                probe.called = true
                probe.script = script
                return .success(#"{"result":"BOUNCE_DIALOG_OPENED"}"#)
            }
        )

        let json = try object(result)
        #expect(result.isSuccess)
        #expect((json["verified"] as? Bool)!)
        #expect(json["via"] as? String == "file-menu")
        #expect((json["dialog_opened"] as? Bool)!)
        #expect(!((json["bounce_fired"] as? Bool)!))
        #expect(probe.called)
        #expect(probe.script.contains("\"Project or Section…\""))
        #expect(probe.script.contains("\"프로젝트 또는 섹션…\""))
        #expect(!probe.script.contains("menu item 1"))
        #expect(probe.script.contains("BOUNCE_DIALOG_OPENED"))
    }

    @Test("System Events denial fails before opening the menu")
    func permissionDenied() async throws {
        let probe = Probe()
        let result = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: { false },
            executeScript: { _ in
                probe.called = true
                return .success("unexpected")
            }
        )

        let json = try object(result)
        #expect(!result.isSuccess)
        #expect(json["error"] as? String == "system_events_automation_denied")
        #expect(!((json["write_attempted"] as? Bool)!))
        #expect(!probe.called)
    }

    @Test("missing native menu item returns a targeted terminal failure")
    func menuItemMissing() async throws {
        let result = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: { true },
            executeScript: { _ in .success(#"{"result":"BOUNCE_MENU_ITEM_NOT_FOUND"}"#) }
        )

        let json = try object(result)
        #expect(!result.isSuccess)
        #expect(json["error"] as? String == "element_not_found")
        #expect(json["failure_stage"] as? String == "locate_bounce_menu_item")
    }

    @Test("menu click without a dialog fails closed")
    func dialogMissing() async throws {
        let result = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: { true },
            executeScript: { _ in .success(#"{"result":"BOUNCE_DIALOG_NOT_FOUND"}"#) }
        )

        let json = try object(result)
        #expect(!result.isSuccess)
        #expect(json["error"] as? String == "dialog_not_found")
        #expect(json["failure_stage"] as? String == "verify_bounce_dialog")
        #expect((json["write_attempted"] as? Bool)!)
    }
}
