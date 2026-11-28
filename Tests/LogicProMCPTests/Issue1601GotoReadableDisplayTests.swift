import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #1601: measured live on Logic Pro 13.0 (7801), the default Beats & Project display reads the
/// playhead as two components ("9.1", bar and beat). goto_bar and goto_position asked for four
/// ("9.1.1.1") and answered State B readback_unavailable although the playhead had moved.
@Suite("Issue1601 goto verifies at the precision the display shows")
struct Issue1601GotoReadableDisplayTests {
    private static func state(_ value: String) -> ChannelResult {
        var state = TransportState()
        state.position = value
        let all = TransportPositionComponent.allCases
        state.positionReadback = TransportPositionReadback(
            value: value,
            observedComponents: Array(all.prefix(value.split(separator: ".").count))
        )
        state.lastUpdated = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return .success(String(decoding: (try? encoder.encode(state)) ?? Data(), as: UTF8.self))
    }

    private actor Stub: Channel {
        nonisolated let id: ChannelID = .accessibility
        let reads: [String]
        private var index = 0
        init(reads: [String]) { self.reads = reads }
        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> ChannelHealth { .healthy(detail: "stub") }
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            switch operation {
            case "transport.goto_position":
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: ["requested": params["position"] ?? "", "via": "dialog"]
                ))
            case "transport.get_state":
                let read = reads[min(index, reads.count - 1)]
                index += 1
                return Issue1601GotoReadableDisplayTests.state(read)
            default: return .error("unexpected: \(operation)")
            }
        }
    }

    private func run(_ reads: [String], bar: Int? = nil, position: String? = nil, navigate: Bool = false)
        async throws -> [String: Any]
    {
        let router = ChannelRouter()
        await router.register(Stub(reads: reads))
        let result: CallTool.Result
        if navigate {
            result = await NavigateDispatcher.handle(
                command: "goto_bar", params: ["bar": .int(bar ?? 1)], router: router, cache: StateCache()
            )
        } else if let position {
            result = await TransportDispatcher.handle(
                command: "goto_position", params: ["position": .string(position)],
                router: router, cache: StateCache()
            )
        } else {
            result = await TransportDispatcher.handle(
                command: "goto_position", params: ["bar": .int(bar ?? 1)], router: router, cache: StateCache()
            )
        }
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test("goto_bar is State A when bar and beat read back as requested")
    func gotoBarVerifiesAtBarBeat() async throws {
        let o = try await run(["12.4", "9.1"], bar: 9, navigate: true)
        #expect(o["state"] as? String == "A")
        #expect(o["verified"] as? Bool == true)
        #expect(o["observed"] as? String == "9.1")
        #expect(o["unobserved_position_components"] as? [String] == ["subdivision", "tick"])
        #expect(o["verified_precision"] as? String == "bar.beat")
    }

    @Test("goto_position bar.beat boundary is State A at bar.beat precision")
    func gotoPositionBeatBoundary() async throws {
        let o = try await run(["9.1", "5.2"], position: "5.2.1.1")
        #expect(o["state"] as? String == "A")
        #expect(o["observed"] as? String == "5.2")
    }

    @Test("a sub-beat request is State B because the display cannot show it")
    func subBeatIsHonestStateB() async throws {
        let o = try await run(["9.1", "5.2"], position: "5.2.3.50")
        #expect(o["state"] as? String == "B")
        #expect(o["reason"] as? String == "readback_unavailable")
        #expect(o["verified"] as? Bool == false)
    }

    @Test("a different bar and beat is State C")
    func differentPositionIsStateC() async throws {
        let o = try await run(["12.4", "7.1"], bar: 9, navigate: true)
        #expect(o["state"] as? String == "C")
        #expect(o["error"] as? String == "readback_mismatch")
    }

    @Test("a playhead that already read the request cannot show this call moved it")
    func noObservedEffectStaysStateB() async throws {
        let o = try await run(["9.1", "9.1"], bar: 9, navigate: true)
        #expect(o["state"] as? String == "B")
        #expect(o["verification_withheld"] as? String == "observed_effect_unavailable")
    }

    @Test("the dialog script carries no fixed waits that guard no transition")
    func scriptHasNoRedundantFixedWaits() {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 9)
        #expect(!script.contains("delay 0.2"))
        let typing = script.components(separatedBy: "keystroke \"a\" using command down")
        #expect(typing.count == 2)
        #expect(!(typing.last ?? "").prefix(40).contains("delay"))
        #expect(script.contains("dialogPostReturnState does not start with \"OPEN\""))
    }
}
