import Foundation
import MCP
import Testing
@testable import LogicProMCP

// These witnesses establish explicit command registration/routing only. No server
// or native channel starts; mock envelopes do not prove capture or UI restoration.
@Suite("#1118 explicit marker capture reaches its dedicated route", .serialized)
struct Issue1118MarkerCaptureReachabilityTests {
    @Test func publicCaptureReachesTheRouterWithoutStartingNativeChannels() async throws {
        let handlers = await LogicProServer(pollerRuntime: .fastTest).makeHandlers()
        let result = await handlers.callTool(.init(
            name: "logic_navigate",
            arguments: ["command": .string("capture_markers"), "params": .object([:])]
        ))
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let failed = try #require(result.isError)
        #expect(failed)
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "channels_exhausted")
        #expect(body["operation"] as? String == "nav.capture_markers")
    }

    @Test(arguments: ["A", "C"])
    func dispatcherForwardsOneCaptureHopAndPreservesItsEnvelope(state: String) async throws {
        let envelope = state == "A"
            ? HonestContract.encodeStateA(extras: [
                "operation": "nav.capture_markers", "capture_fixture": "routing-only",
            ])
            : HonestContract.encodeStateC(error: .readbackUnavailable,
                hint: "routing-only capture refusal", extras: [
                    "operation": "nav.capture_markers", "capture_fixture": "routing-only",
                ])
        let channel = MockChannel(
            id: .accessibility,
            failWith: state == "C" ? envelope : nil,
            successEnvelope: state == "A" ? envelope : nil
        )
        let router = ChannelRouter()
        await router.register(channel)
        let result = await NavigateDispatcher.handle(
            command: "capture_markers", params: [:], router: router, cache: StateCache()
        )
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let calls = await channel.executedOps
        #expect(calls.count == 1)
        #expect(calls.first?.0 == "nav.capture_markers")
        #expect(calls.first?.1 == [:])
        #expect(body["state"] as? String == state)
        #expect(body["operation"] as? String == "nav.capture_markers")
        #expect(body["capture_fixture"] as? String == "routing-only")
        let failed = result.isError ?? false
        if state == "C" {
            #expect(failed)
        } else {
            #expect(!failed)
        }
    }
}
