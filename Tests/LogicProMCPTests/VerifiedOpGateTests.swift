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

// These three tests mutate the process-global VerifiedOpGate.shared singleton.
// They must run serially so a peer test's unconditional release() cannot free
// another's in-flight claim — the default-parallel race the repo's --no-parallel
// CI used to mask (same class of flake fixed in ProjectAuditPhaseTests).
@Suite(.serialized)
struct VerifiedOpGateSharedTests {

@Test func testPluginsDispatcherRefusesConcurrentVerifiedOp() async {
    // Hold the shared gate, then issue a verified op through the dispatcher and
    // confirm it is refused with verified_op_in_progress before touching AX.
    // Release is synchronous so the shared singleton is clean before this test
    // returns.
    let acquired = VerifiedOpGate.shared.tryAcquire()
    #expect(acquired)

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
    VerifiedOpGate.shared.release()

    let text = sharedToolText(result)
    let obj = try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! [String: Any]
    #expect(obj["error"] as? String == "verified_op_in_progress")
    #expect(obj["state"] as? String == "C")
    #expect((obj["safe_to_retry"] as? Bool)!)
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testPluginsDispatcherReleasesVerifiedGateAfterCompletion() async {
    VerifiedOpGate.shared.release()

    let router = ChannelRouter()
    _ = await PluginsDispatcher.handle(
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

    #expect(VerifiedOpGate.shared.tryAcquire())
    VerifiedOpGate.shared.release()
}

@Test func testGetInventoryNotGatedByVerifiedOpLock() async {
    // Even while the verified-op gate is held, get_inventory (read-only) must
    // still run — it is not a mutating verified op.
    let acquired = VerifiedOpGate.shared.tryAcquire()
    #expect(acquired)

    let router = ChannelRouter()
    let result = await PluginsDispatcher.handle(
        command: "get_inventory",
        params: ["track": .int(0)],
        router: router,
        cache: StateCache()
    )
    VerifiedOpGate.shared.release()

    let text = sharedToolText(result)
    // No channels registered → channels_exhausted, NOT verified_op_in_progress.
    #expect(!text.contains("verified_op_in_progress"))
}

// Lives in this serialized suite (moved from PluginsDispatcherReachabilityTests)
// because it drives the shared VerifiedOpGate via
// callTool(set_param_verified/insert_verified) → runVerified.tryAcquire/release.
// Run in parallel with the gate tests above it could free a peer's claim, since
// VerifiedOpGate.release() is token-less. This is a Plane-1 reachability check.
@Test func testPluginsToolReachesRouterNotUnknownTool() async {
    let server = LogicProServer()
    let handlers = await server.makeHandlers()

    for command in ["get_inventory", "set_param_verified", "insert_verified"] {
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
