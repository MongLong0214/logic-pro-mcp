import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #202: several command tokens are recognised by the dispatchers but are
/// deliberately NOT part of the production MCP contract. They used to return a
/// generic `not_implemented` State C, which a complete-surface harness could not
/// tell apart from a real malfunction. They now return a single,
/// machine-classifiable `command_not_exposed` shape (`not_exposed:true`,
/// `supported:false`) the harness can mark as expected — while the workflow
/// census continues to exclude them (catalog-level consistency).
@Suite("Issue202 surface consistency — not-exposed commands")
struct Issue202SurfaceConsistencyTests {
    private func obj(_ r: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(sharedToolText(r))
    }

    private func mixer(_ command: String) async -> CallTool.Result {
        await MixerDispatcher.handle(command: command, params: [:], router: ChannelRouter(), cache: StateCache())
    }

    private func track(_ command: String) async -> CallTool.Result {
        await TrackDispatcher.handle(command: command, params: [:], router: ChannelRouter(), cache: StateCache())
    }

    @Test("every not-exposed command returns one machine-classifiable command_not_exposed shape")
    func notExposedCommandsAreClassifiable() async {
        let cases: [(operation: String, result: CallTool.Result)] = [
            ("mixer.set_send", await mixer("set_send")),
            ("mixer.set_output", await mixer("set_output")),
            ("mixer.set_input", await mixer("set_input")),
            ("mixer.toggle_eq", await mixer("toggle_eq")),
            ("mixer.reset_strip", await mixer("reset_strip")),
            ("mixer.bypass_plugin", await mixer("bypass_plugin")),
            ("track.set_color", await track("set_color")),
        ]
        for (operation, result) in cases {
            #expect(result.isError!, "\(operation) must be a State C error")
            let o = obj(result)
            #expect(o?["error"] as? String == "command_not_exposed", "\(operation) should report command_not_exposed")
            #expect((o?["not_exposed"] as? Bool)!, "\(operation) must carry not_exposed:true")
            #expect((o?["supported"] as? Bool)! == false, "\(operation) must carry supported:false")
            #expect(o?["operation"] as? String == operation)
            #expect((o?["success"] as? Bool)! == false)
            // The census stub-detection phrase must be preserved in the hint.
            let hint = (o?["hint"] as? String)!
            #expect(hint.contains("not exposed in the production MCP contract"))
        }
    }

    @Test("command_not_exposed is a distinct, terminal, classifiable code")
    func commandNotExposedIsTerminal() {
        #expect(HonestContract.FailureError.commandNotExposed.rawValue == "command_not_exposed")
        #expect(HonestContract.terminalErrorCodes.contains("command_not_exposed"))
        // Distinct from the generic `not_implemented` (surface-absent) code so a
        // harness can tell "intentionally not exposed" from "genuinely missing".
        #expect(HonestContract.FailureError.commandNotExposed.rawValue != HonestContract.FailureError.notImplemented.rawValue)
    }
}
