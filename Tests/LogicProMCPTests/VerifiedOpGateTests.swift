import Foundation
import MCP
import Testing
@testable import LogicProMCP

// T3 — R14: verified mutating ops are serialized server-wide (one in flight).
// A second concurrent verified op is refused with State C verified_op_in_progress
// (safe_to_retry:true). get_inventory (read-only) is NOT gated.

@Test func testVerifiedOpGateSerializesAcquisition() async {
    let gate = VerifiedOpGate()
    #expect(gate.tryAcquire(), "first acquire succeeds")
    #expect(!(gate.tryAcquire()), "second acquire is refused while held")
    gate.release()
    #expect(gate.tryAcquire(), "acquire succeeds again after release")
    gate.release()
}

// Keep the production-default witness and server-handler calls serial. Other suites inject gates.
@Suite(.serialized)
struct VerifiedOpGateSharedTests {

@Test func testPluginsDispatcherRefusesConcurrentVerifiedOp() async throws {
    // The production default: no gate is passed, so the dispatcher takes `.shared`. Hold it, issue a
    // verified op and confirm it is refused with verified_op_in_progress before touching AX. Every
    // other test passes a gate of its own, so nothing else takes `.shared` (#1104 supplementary review,
    // SUP-07); the test stops if it cannot acquire, and releases only what it acquired.
    try #require(VerifiedOpGate.shared.tryAcquire())
    defer { VerifiedOpGate.shared.release() }

    let router = ChannelRouter()
    let result = await PluginsDispatcher.handle(

        command: "set_param_verified",
        params: [
            "track": .int(0), "insert": .int(2), "plugin": .string("Gain"),
            "param": .string("gain_db"), "value": .double(-4.0), "unit": .string("dB"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string("/tmp/x.logicx"),
        ],
        router: router,
        cache: StateCache()
    )

    let obj = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(obj["error"] as? String == "verified_op_in_progress")
    #expect(obj["state"] as? String == "C")
    let retryable = try #require(obj["safe_to_retry"] as? Bool)
    let attempted = try #require(obj["write_attempted"] as? Bool)
    #expect(retryable)
    #expect(!attempted)
}

@Test func differentVerifiedCommandsContendWhileAChannelIsRunning() async throws {
    let gate = VerifiedOpGate()
    let router = ChannelRouter()
    let channel = HeldVerifiedChannel()
    await router.register(channel)
    let params: [String: Value] = [
        "track": .int(0), "insert": .int(0), "plugin": .string("Gain"), "param": .string("gain_db"),
        "value": .double(0), "unit": .string("dB"), "band": .string("Low Cut"),
        "parameter": .string("Frequency"), "mode": .string("duplicate_applyback"),
        "project_expected_path": .string("/tmp/x.logicx"), "expected_name": .string("Track 1"),
    ]
    let first = Task {
        await PluginsDispatcher.handle(verifiedGate: gate, command: "set_param_verified", params: params,
                                       router: router, cache: StateCache())
    }
    await channel.waitForEntry()
    for command in ["set_eq_band_verified", "insert_verified"] {
        let result = await PluginsDispatcher.handle(
            verifiedGate: gate, command: command, params: params, router: router, cache: StateCache(),
            liveTrackNames: { [0: "Track 1"] })
        #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "verified_op_in_progress")
    }
    #expect(await channel.calls == 1)
    await channel.unblock()
    _ = await first.value
    try #require(gate.tryAcquire())
    gate.release()
}

@Test func testPluginsDispatcherReleasesVerifiedGateAfterCompletion() async {
    let gate = VerifiedOpGate()

    let router = ChannelRouter()
    _ = await PluginsDispatcher.handle(verifiedGate: gate,

        command: "set_param_verified",
        params: [
            "track": .int(0), "insert": .int(2), "plugin": .string("Gain"),
            "param": .string("gain_db"), "value": .double(-4.0), "unit": .string("dB"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string("/tmp/x.logicx"),
        ],
        router: router,
        cache: StateCache()
    )

    #expect(gate.tryAcquire())
    gate.release()
}

@Test func testGetInventoryNotGatedByVerifiedOpLock() async {
    // Even while the verified-op gate is held, get_inventory (read-only) must
    // still run — it is not a mutating verified op.
    let gate = VerifiedOpGate()
    let acquired = gate.tryAcquire()
    #expect(acquired)

    let router = ChannelRouter()
    let result = await PluginsDispatcher.handle(verifiedGate: gate,
        command: "get_inventory",
        params: ["track": .int(0)],
        router: router,
        cache: StateCache()
    )
    gate.release()

    let text = sharedToolText(result)
    // No channels registered → channels_exhausted, NOT verified_op_in_progress.
    #expect(!text.contains("verified_op_in_progress"))
}

// Lives in this serialized suite (moved from PluginsDispatcherReachabilityTests)
// because it drives the shared VerifiedOpGate via
// callTool(set_param_verified/set_eq_band_verified/insert_verified) → runVerified.tryAcquire/release.
// Run in parallel with the gate tests above it could free a peer's claim, since
// VerifiedOpGate.release() is token-less. This is a Plane-1 reachability check.
@Test func testPluginsToolReachesRouterNotUnknownTool() async {
    let server = LogicProServer()
    let handlers = await server.makeHandlers()

    for command in ["get_inventory", "set_param_verified", "set_eq_band_verified", "insert_verified"] {
        let r = await handlers.callTool(CallTool.Parameters(
            name: "logic_plugins",
            arguments: ["command": .string(command), "params": .object(["track": .int(0)])]
        ))
        let text = sharedToolText(r)
        // Plane 1: the tool is registered — "Unknown tool" means callTool's
        // switch has no case for logic_plugins.
        #expect(!text.contains("Unknown tool"), "\(command): Plane 1 — tool not dispatched")
        // Plane 1 (dispatcher): the command is recognised inside PluginsDispatcher.
        #expect(!text.contains("Unknown plugins command"), "\(command): dispatcher command not handled")
        #expect(!text.isEmpty)
    }
}

}  // end @Suite(.serialized) struct VerifiedOpGateSharedTests

private actor HeldVerifiedChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private(set) var calls = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "held verified operation") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls += 1
        entered?.resume()
        entered = nil
        await withCheckedContinuation { release = $0 }
        return .success(HonestContract.encodeV2StateA())
    }
    func waitForEntry() async {
        if calls == 0 { await withCheckedContinuation { entered = $0 } }
    }
    func unblock() {
        release?.resume()
        release = nil
    }
}
