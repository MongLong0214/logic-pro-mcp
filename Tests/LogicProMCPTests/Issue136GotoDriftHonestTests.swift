import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #136 ("goto_position reports success while readback drifts"): the server is
/// already correct — on a drifted read-back its payload is the Honest Contract
/// State B `{ success: true, verified: false, reason: "readback_mismatch",
/// requested, observed }` with `isError == true`. `success` is only the
/// dispatch-ack (the keystroke/AppleScript send returned OK); `verified:false`
/// is the authoritative read-back verdict. This suite LOCKS that split so the
/// op can never silently regress to a bare verified success when the playhead
/// lands somewhere other than requested.
///
/// Distinct from `Issue105GotoNoteTests.mismatchFailsClosed` (which drives the
/// `bar` entry path and focuses on the stale "not read back" note): here we
/// drive the `position` (bar.beat.sub.tick) entry path and pin the *full*
/// success/verified/reason/observed contract — the exact "success while
/// readback drifts" shape from the issue.
@Suite("Issue136 goto_position honest verified:false on drift")
struct Issue136GotoDriftHonestTests {
    /// Reusable stub: the goto write channel acks (dialog State B), and the
    /// transport read-back reports `readbackPosition`. Encoded with the same
    /// `.iso8601` date strategy `decodeJSONValue` decodes with, so the
    /// dispatcher's authoritative read-back actually parses.
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

    /// The dialog channel's real "keystroke sent; not read back" State B — the
    /// write side genuinely acked, so any later honest verdict must come from
    /// the dispatcher's own read-back, not this note.
    private func dispatchAckStateB(requested: String) -> ChannelResult {
        .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "requested": requested,
                "via": "dialog",
                "note": "AppleScript dialog OK confirms keystroke send; resulting playhead not read back",
            ]
        ))
    }

    @Test("position-entry drift: success ack but verified:false readback_mismatch, never a bare verified success")
    func positionDriftIsHonestNotBareSuccess() async throws {
        let router = ChannelRouter()
        // Requested bar 9 beat 1; the playhead drifted to bar 9 beat 2 — the
        // #136 symptom: the write "succeeded" but the readback disagrees.
        await router.register(StubTransportChannel(
            gotoResult: dispatchAckStateB(requested: "9.1.1.1"),
            readbackPosition: "9.2.1.1"
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("9.1.1.1")],
            router: router,
            cache: StateCache()
        )

        let o = try #require(obj(result), "goto_position must return a JSON envelope")

        // `success` is the dispatch-ack and MAY be true — that alone must never
        // be read as "the playhead is where you asked".
        let success = try #require(o["success"] as? Bool, "envelope must carry an explicit success flag")

        // The authoritative verdict. Force-unwrap (swift-testing footgun:
        // `== false` / `?? false` are DEAD on Optional<Bool>; only `!verified!`
        // can actually fail).
        let verified = o["verified"] as? Bool
        #expect(!(try #require(verified, "drifted goto_position must carry an explicit verified flag")),
                "drifted readback must report verified:false, NOT a bare success")

        // The honesty must be machine-readable, not just a flag flip.
        #expect(o["reason"] as? String == "readback_mismatch",
                "drifted goto_position must classify the State-B reason as readback_mismatch")
        #expect(o["requested"] as? String == "9.1.1.1")
        #expect(o["observed"] as? String == "9.2.1.1")
        #expect(o["observed"] as? String != o["requested"] as? String,
                "regression guard: observed and requested must actually differ on a drift")
        #expect(o["verification_source"] as? String == "transport_state",
                "verdict must be sourced from an authoritative transport read-back")

        // The MCP-level error bit must also be set so non-JSON-parsing callers
        // still see the failure.
        let resultIsError = result.isError ?? false
        #expect(resultIsError, "a drifted goto_position must surface isError == true")

        // Belt-and-suspenders: a bare verified-success payload would never carry
        // this combination. If success is reported, verified must NOT be.
        if success {
            #expect(!(try #require(verified)),
                    "#136 lock: success may be true only as a dispatch-ack — verified must be false on drift")
        }

        // Guard the stale note can't sneak back and masquerade as confirmation.
        #expect(!text(result).contains("not read back"))
    }

    @Test("control case: exact readback match is the only path to verified:true")
    func exactMatchIsVerifiedTrue() async throws {
        let router = ChannelRouter()
        await router.register(StubTransportChannel(
            gotoResult: dispatchAckStateB(requested: "9.1.1.1"),
            readbackPosition: "9.1.1.1"
        ))
        let result = await TransportDispatcher.handle(
            command: "goto_position",
            params: ["position": .string("9.1.1.1")],
            router: router,
            cache: StateCache()
        )

        let o = try #require(obj(result))
        let verified = o["verified"] as? Bool
        // The positive control: force-unwrap so a regression that drops the
        // verified flag (nil) or flips it (false) on an exact match FAILS here.
        #expect(try #require(verified, "matched goto_position must carry verified"),
                "exact readback match must verify true")
        #expect(o["observed"] as? String == "9.1.1.1")
        #expect(o["reason"] == nil, "a verified State-A envelope carries no uncertain reason")
        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
    }
}
