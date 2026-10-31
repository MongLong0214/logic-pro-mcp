import Foundation
import Testing
@testable import LogicProMCP

@Suite("Standalone Bounce terminal outcome")
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

    @Test("standalone Bounce refuses without opening UI and points to automated export")
    func standaloneBounceIsTerminal() async throws {
        let probe = Probe()
        let result = await AccessibilityChannel.openBounceDialogViaMenu(
            systemEventsAuthorized: {
                probe.called = true
                return true
            },
            executeScript: { script in
                probe.called = true
                probe.script = script
                return .success(#"{"result":"BOUNCE_DIALOG_OPENED"}"#)
            }
        )

        let json = try object(result)
        #expect(!result.isSuccess)
        #expect(json["error"] as? String == "unsupported_state")
        #expect(json["operation"] as? String == "project.bounce")
        #expect(json["failure_stage"] as? String == "standalone_bounce_unattended_unavailable")
        #expect(json["automated_alternative"] as? String == "logic_project.export_run")
        #expect(json["write_attempted"] as? Bool == false)
        #expect(json["terminal"] as? Bool == true)
        #expect(json["human_intervention_required"] as? Bool == false)
        #expect(json["human_intervention_requests"] as? Int == 0)
        #expect(json["human_dependent_transitions"] as? Int == 0)
        #expect(!probe.called)
        #expect(probe.script.isEmpty)
    }

}
