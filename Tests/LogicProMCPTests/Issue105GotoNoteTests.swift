import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #105: a verified goto_position/goto_bar must not ship the stale
/// "resulting playhead not read back" note — `finalizeGotoPositionResult`
/// performs an authoritative transport-state read-back and gates `verified`
/// on it, so the note (from the dialog keystroke channel) would contradict the
/// verdict. Also locks the faithful verified-vs-mismatch behavior.
@Suite("Issue105 goto note + verification")
struct Issue105GotoNoteTests {
    private actor StubTransportChannel: Channel {
        nonisolated let id: ChannelID = .accessibility
        let gotoResult: ChannelResult
        let readbackPosition: String
        init(gotoResult: ChannelResult, readbackPosition: String) {
            self.gotoResult = gotoResult
            self.readbackPosition = readbackPosition
        }
        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> ChannelHealth { .healthy(detail: "stub") }
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            switch operation {
            case "transport.goto_position": return gotoResult
            case "transport.get_state":
                // Encode a real TransportState with the SAME .iso8601 strategy
                // the dispatcher decodes with. A hand-written date carrying
                // fractional seconds (".000Z") fails strict .iso8601 decoding on
                // the CI Foundation, which made `liveTransportState` return nil
                // and the verdict fall back to the un-stripped State B.
                var state = TransportState()
                state.position = readbackPosition
                state.lastUpdated = Date(timeIntervalSince1970: 0)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return .success(String(decoding: (try? encoder.encode(state)) ?? Data(), as: UTF8.self))
            default: return .error("unexpected: \(operation)")
            }
        }
    }

    private func text(_ r: CallTool.Result) -> String {
        sharedToolText(r)
    }
    private func obj(_ r: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(text(r))
    }

    /// The dialog channel's real State B output, including the historical note.
    private func notedDialogStateB(bar: Int) -> ChannelResult {
        .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "requested": "\(bar).1.1.1",
                "via": "dialog",
                "note": "AppleScript dialog OK confirms keystroke send; resulting playhead not read back",
            ]
        ))
    }

    @Test("verified goto_position drops the contradictory readback note")
    func verifiedHasNoStaleNote() async throws {
        let router = ChannelRouter()
        await router.register(StubTransportChannel(gotoResult: notedDialogStateB(bar: 1), readbackPosition: "1.1.1.1"))
        let result = await TransportDispatcher.handle(
            command: "goto_position", params: ["bar": .int(1)], router: router, cache: StateCache()
        )
        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
        let o = try #require(obj(result))
        #expect((o["verified"] as? Bool)!)
        #expect(o["verification_source"] as? String == "transport_state")
        #expect(o["observed"] as? String == "1.1.1.1")
        #expect(o["note"] == nil, "verified envelope must not carry a 'not read back' note")
        #expect(!text(result).contains("not read back"))
    }

    @Test("goto_bar shares the same verified, note-free contract")
    func gotoBarNoteFree() async throws {
        let router = ChannelRouter()
        await router.register(StubTransportChannel(gotoResult: notedDialogStateB(bar: 17), readbackPosition: "17.1.1.1"))
        let result = await NavigateDispatcher.handle(
            command: "goto_bar", params: ["bar": .int(17)], router: router, cache: StateCache()
        )
        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
        let o = try #require(obj(result))
        #expect((o["verified"] as? Bool)!)
        #expect(!text(result).contains("not read back"))
    }

    @Test("mismatched readback fails closed as unverified State B")
    func mismatchFailsClosed() async throws {
        let router = ChannelRouter()
        // Requested bar 1 but the playhead landed at 1.2.1.1 (the #105 symptom).
        await router.register(StubTransportChannel(gotoResult: notedDialogStateB(bar: 1), readbackPosition: "1.2.1.1"))
        let result = await TransportDispatcher.handle(
            command: "goto_position", params: ["bar": .int(1)], router: router, cache: StateCache()
        )
        let o = try #require(obj(result))
        #expect(!((o["verified"] as? Bool)!))
        #expect(o["observed"] as? String == "1.2.1.1")
        let resultIsError = result.isError ?? false
        #expect(resultIsError)
    }
}
