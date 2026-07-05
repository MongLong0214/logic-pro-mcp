import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #139 regression: when a track-mutation command runs in an OCCLUDED or
/// unhealthy AX session (a plugin/modal window has focus, the channel-strip
/// checkbox is unreachable, or its post-write read-back attribute is not
/// exposed), the mutation MUST fail closed to an honest State B / State C
/// (`verified:false`) and surface it as an error — it must NEVER report a
/// false State A (`verified:true`) for a write it could not confirm landed.
///
/// #139 is ENVIRONMENTAL: the server is correct. This suite LOCKS that
/// fail-closed contract for `track.set_mute` / `set_solo` / `set_arm` at the
/// dispatcher boundary so a future refactor of `trackToggleResultIsVerified`
/// can never silently regress an occluded session into a fabricated success.
///
/// Distinct from the existing coverage:
///   • Issue106TrackToggleLocatorTests exercises the AX *locator*, not the
///     dispatcher's verified-gate envelope.
///   • DispatcherTests covers `create_*` / `rename` State B; this suite is the
///     mute/solo/arm toggle path under the *occluded* (`readback_unavailable`)
///     and *dialog-not-found* (State C) signatures specifically.
@Suite("Issue139 track-mutation occlusion honesty")
struct Issue139TrackMutationOcclusionHonestTests {

    /// Accessibility channel double that scripts a fixed `ChannelResult` per
    /// operation, simulating a single live AX channel whose post-write
    /// read-back is unavailable / mismatched because the session is occluded.
    /// Registered as `.accessibility` because `track.set_mute|set_solo|set_arm`
    /// route to Accessibility first (see `ChannelRouter.routingTable`).
    private actor OccludedToggleChannel: Channel {
        nonisolated let id: ChannelID
        let results: [String: ChannelResult]
        var executedOps: [(String, [String: String])] = []

        init(id: ChannelID, results: [String: ChannelResult]) {
            self.id = id
            self.results = results
        }

        func start() async throws {}
        func stop() async {}

        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            executedOps.append((operation, params))
            return results[operation] ?? .error("unexpected operation: \(operation)")
        }

        func operations() -> [(String, [String: String])] {
            executedOps
        }

        func healthCheck() async -> ChannelHealth {
            // The channel itself is reachable — occlusion shows up in the
            // *result* (read-back unavailable / dialog never appeared), not in
            // an unhealthy channel. This is exactly the #139 shape: a healthy
            // path that still cannot CONFIRM the write landed.
            .healthy(detail: "occluded toggle double")
        }
    }

    private func toggleCommand(
        _ command: String,
        operation: String,
        result: ChannelResult
    ) async -> CallTool.Result {
        let router = ChannelRouter()
        let ax = OccludedToggleChannel(id: .accessibility, results: [operation: result])
        await router.register(ax)
        return await TrackDispatcher.handle(
            command: command,
            params: ["index": .int(2), "enabled": .bool(true)],
            router: router,
            cache: StateCache()
        )
    }

    // MARK: - State B (occluded read-back) must NOT become a false State A

    @Test("create_instrument refuses while a blocking Logic dialog is present")
    func createInstrumentRefusesBlockingDialogBeforeRouting() async throws {
        let router = ChannelRouter()
        let ax = OccludedToggleChannel(
            id: .accessibility,
            results: ["track.create_instrument": .success("should not execute")]
        )
        await router.register(ax)

        let result = await TrackDispatcher.handle(
            command: "create_instrument",
            params: [:],
            router: router,
            cache: StateCache(),
            dialogPresent: { true }
        )

        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(json["error"] as? String == "unsupported_state")
        #expect(json["operation"] as? String == "track.create_instrument")
        #expect(json["failure_stage"] as? String == "preflight_blocking_dialog")
        #expect((json["blocking_dialog_present"] as? Bool)!)
        #expect(!((json["write_attempted"] as? Bool)!))
        #expect(await ax.operations().isEmpty)
    }

    @Test("mute under occluded read-back fails closed to State B, not a false State A")
    func muteOccludedStateB() async throws {
        let stateB = ChannelResult.success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["track": 2, "requested": true, "observed": NSNull()]
        ))
        let result = await toggleCommand("mute", operation: "track.set_mute", result: stateB)

        // swift-testing footgun: Optional<Bool> must be force-unwrapped, never
        // `== true` / `?? false` (those are DEAD always-pass assertions).
        let isError = try #require(result.isError)
        #expect(isError) // occluded read-back must surface as an error
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        // The envelope must carry the honest, unverified contract verbatim.
        let verified = try #require(json["verified"] as? Bool)
        #expect(!verified) // verified:false — NOT a fabricated State A
        #expect(json["reason"] as? String == "readback_unavailable")
        // A false State A would set verified:true with no reason — guard both.
        #expect(json["reason"] != nil)
    }

    @Test("solo under occluded read-back fails closed to State B, not a false State A")
    func soloOccludedStateB() async throws {
        let stateB = ChannelResult.success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["track": 2, "requested": true, "observed": NSNull()]
        ))
        let result = await toggleCommand("solo", operation: "track.set_solo", result: stateB)

        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        let verified = try #require(json["verified"] as? Bool)
        #expect(!verified)
        #expect(json["reason"] as? String == "readback_unavailable")
    }

    @Test("arm under occluded read-back fails closed to State B, not a false State A")
    func armOccludedStateB() async throws {
        let stateB = ChannelResult.success(HonestContract.encodeStateB(
            reason: .readbackMismatch,
            extras: ["track": 2, "requested": true, "observed": false]
        ))
        let result = await toggleCommand("arm", operation: "track.set_arm", result: stateB)

        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        let verified = try #require(json["verified"] as? Bool)
        #expect(!verified)
        // read-back returned a value that disagrees with the request — the
        // textbook "write fired but landed somewhere we can't trust" signature.
        #expect(json["reason"] as? String == "readback_mismatch")
    }

    // MARK: - State C (occluded — control/dialog never reachable) is terminal

    @Test("mute under a hard occluded failure surfaces State C, never a success")
    func muteOccludedStateC() async throws {
        // `dialog_not_found` is the canonical occluded-session State C: the
        // control/sheet the write needed never appeared, so no side effect
        // happened and the op fails closed hard.
        let stateC = ChannelResult.error(HonestContract.encodeStateC(
            error: .dialogNotFound,
            hint: "track-header mute checkbox unreachable: plugin window has focus"
        ))
        let result = await toggleCommand("mute", operation: "track.set_mute", result: stateC)

        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        // State C carries success:false and an error code — and crucially does
        // NOT carry verified:true.
        let success = try #require(json["success"] as? Bool)
        #expect(!success)
        #expect(json["error"] as? String == "dialog_not_found")
        // v1 State C omits `verified` entirely (absent = not verified), so bind
        // absent-as-false rather than force-unwrapping a key that isn't there.
        let verified = (json["verified"] as? Bool) ?? false
        #expect(!verified)
    }

    // MARK: - Positive control — the gate is meaningful, not vacuous

    @Test("a genuinely verified mute (State A) still succeeds — gate is not over-broad")
    func muteVerifiedStateAStillSucceeds() async throws {
        let stateA = ChannelResult.success(HonestContract.encodeStateA(
            extras: ["track": 2, "requested": true, "observed": true]
        ))
        let result = await toggleCommand("mute", operation: "track.set_mute", result: stateA)

        let isError = try #require(result.isError)
        #expect(!isError) // a confirmed write must NOT be downgraded to an error
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        let verified = try #require(json["verified"] as? Bool)
        #expect(verified) // honest State A round-trips intact
    }
}
