import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// A read refused for a missing Mixer `target_ref` says it wrote nothing. The live gate files such
/// a refusal as an unmet fixture precondition only when the response states `write_attempted:false`;
/// measured on Logic 13 (the release binary), the refusal carried no such field, so the gate counted
/// it as a failure.
@Suite("Mixer read refusals state that nothing was written")
struct MixerReadRefusalStatesNoWriteTests {
    @Test(arguments: ["get_output_verified", "get_input_bus_verified", "get_send_destination_verified",
                      "get_send_bypass_verified"])
    func aReadWithoutATargetRefStatesNoWrite(command: String) async throws {
        let result = await MixerDispatcher.handle(
            command: command, params: [:], router: ChannelRouter(), cache: StateCache())
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "invalid_params")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
    }
}
