import Dispatch
import Foundation
import Testing
@testable import LogicProMCP

// Mock channel for router tests
actor MockChannel: Channel {
    nonisolated let id: ChannelID
    var executedOps: [(String, [String: String])] = []
    var isAvailable: Bool = true
    let healthOverride: ChannelHealth?

    init(id: ChannelID, available: Bool = true, healthOverride: ChannelHealth? = nil) {
        self.id = id
        self.isAvailable = available
        self.healthOverride = healthOverride
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        return .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        if let healthOverride {
            return healthOverride
        }
        return isAvailable
            ? ChannelHealth.healthy(detail: "Mock OK")
            : ChannelHealth.unavailable("Mock unavailable")
    }
}

enum MockStartError: Error {
    case startupFailed
}

actor FailingStartChannel: Channel {
    nonisolated let id: ChannelID

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {
        throw MockStartError.startupFailed
    }

    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        .error("should not execute")
    }

    func healthCheck() async -> ChannelHealth {
        .unavailable("startup failed")
    }
}

private final class BlockingStopProbe: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func waitUntilStopCalled(timeout: DispatchTimeInterval = .seconds(1)) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func unblock() {
        release.signal()
    }

    func blockUntilReleased() {
        entered.signal()
        release.wait()
    }
}

private actor BlockingStopChannel: Channel {
    nonisolated let id: ChannelID
    private let probe: BlockingStopProbe

    init(id: ChannelID, probe: BlockingStopProbe) {
        self.id = id
        self.probe = probe
    }

    func start() async throws {}

    func stop() async {
        probe.blockUntilReleased()
    }

    func execute(operation: String, params: [String : String]) async -> ChannelResult {
        .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "blocking stop channel")
    }
}

private actor StopAllCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 5_000_000,
    condition: @escaping @Sendable () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return await condition()
}

@Test func testRouterMixerWritePrefersAccessibilityForVerifiedReadback() async {
    let router = ChannelRouter()
    let accessibility = MockChannel(id: .accessibility)
    let mcu = MockChannel(id: .mcu)
    await router.register(accessibility)
    await router.register(mcu)

    let result = await router.route(operation: "mixer.set_volume", params: ["index": "0", "volume": "0.7"])
    #expect(result.isSuccess)

    let axOps = await accessibility.executedOps
    let mcuOps = await mcu.executedOps
    #expect(axOps.count == 1)
    #expect(axOps[0].0 == "mixer.set_volume")
    #expect(mcuOps.isEmpty)
}

@Test func testRouterEditGoesToKeyCmd() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let result = await router.route(operation: "edit.undo")
    #expect(result.isSuccess)

    let ops = await keyCmd.executedOps
    #expect(ops.count == 1)
}

@Test func testRouterEditFallbackCGEvent() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands, available: false)
    let cgEvent = MockChannel(id: .cgEvent)
    await router.register(keyCmd)
    await router.register(cgEvent)

    let result = await router.route(operation: "edit.undo")
    #expect(result.isSuccess)

    let keyCmdOps = await keyCmd.executedOps
    let cgOps = await cgEvent.executedOps
    #expect(keyCmdOps.count == 0) // skipped (unavailable)
    #expect(cgOps.count == 1)     // fallback used
}

@Test func testRouterTransportFallsBackToAppleScript() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu, available: false)
    let coreMIDI = MockChannel(id: .coreMIDI, available: false)
    let cgEvent = MockChannel(id: .cgEvent, available: false)
    let appleScript = MockChannel(id: .appleScript)
    await router.register(mcu)
    await router.register(coreMIDI)
    await router.register(cgEvent)
    await router.register(appleScript)

    let result = await router.route(operation: "transport.stop")
    #expect(result.isSuccess)

    let appleScriptOps = await appleScript.executedOps
    #expect(appleScriptOps.count == 1)
    #expect(appleScriptOps[0].0 == "transport.stop")
}

@Test func testRouterTransportPlayFallsBackToAppleScriptAfterAXLookupMiss() async {
    let router = ChannelRouter()
    let ax = TerminalStateCChannel(
        id: .accessibility,
        envelope: HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "transport button 'Play' not located in the visible Logic transport UI",
            extras: ["button": "Play"]
        )
    )
    let mcu = MockChannel(id: .mcu, available: false)
    let coreMIDI = MockChannel(id: .coreMIDI, available: false)
    let cgEvent = MockChannel(id: .cgEvent, available: false)
    let appleScript = MockChannel(id: .appleScript)
    await router.register(ax)
    await router.register(mcu)
    await router.register(coreMIDI)
    await router.register(cgEvent)
    await router.register(appleScript)

    let result = await router.route(operation: "transport.play")
    #expect(result.isSuccess, "transport.play should fall through after AX element_not_found")

    let appleScriptOps = await appleScript.executedOps
    #expect(appleScriptOps.count == 1)
    #expect(appleScriptOps[0].0 == "transport.play")
}

@Test func testRouterSkipsManualValidationChannelsAndFallsBackToRuntimeReadyChannel() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands, healthOverride: .healthy(
        detail: "Preset installation is not verifiable programmatically",
        verificationStatus: .manualValidationRequired
    ))
    let cgEvent = MockChannel(id: .cgEvent)
    await router.register(keyCmd)
    await router.register(cgEvent)

    let result = await router.route(operation: "edit.undo")
    #expect(result.isSuccess)

    let keyCmdOps = await keyCmd.executedOps
    let cgOps = await cgEvent.executedOps
    #expect(keyCmdOps.isEmpty)
    #expect(cgOps.count == 1)
}

@Test func testRouterSetTempoRoutesOnlyToAccessibility() async {
    // Post-hardening: transport.set_tempo now routes AX-only. MIDIKeyCommands
    // and CGEvent fallbacks were removed because they can't convey the tempo
    // value (CC fire / key press ignores the numeric param).
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    let ax = MockChannel(id: .accessibility)
    await router.register(mcu)
    await router.register(keyCmd)
    await router.register(ax)

    let result = await router.route(operation: "transport.set_tempo")
    #expect(result.isSuccess)

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    let axOps = await ax.executedOps
    #expect(mcuOps.count == 0)
    #expect(keyCmdOps.count == 0)
    #expect(axOps.count == 1)
}

@Test func testRouterMixerNoFallback() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu, available: false)
    await router.register(mcu)

    let result = await router.route(operation: "mixer.set_volume")
    #expect(!result.isSuccess) // No fallback for mixer
}

@Test func testRouterNewCommandSetPluginParam() async {
    let router = ChannelRouter()
    let scripter = MockChannel(id: .scripter)
    await router.register(scripter)

    let result = await router.route(operation: "mixer.set_plugin_param")
    #expect(result.isSuccess)
}

@Test func testRouterNewCommandStepInput() async {
    let router = ChannelRouter()
    let coreMidi = MockChannel(id: .coreMIDI)
    await router.register(coreMidi)

    let result = await router.route(operation: "midi.step_input")
    #expect(result.isSuccess)
}

@Test func testRouterNewCommandSetAutomation() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await router.route(operation: "track.set_automation")
    #expect(result.isSuccess)
}

@Test func testRouterAllOperationsHaveChannel() async {
    let table = ChannelRouter.v2RoutingTable
    let systemOps = ["system.health", "system.cache_state", "system.refresh", "system.permissions", "project.is_running"]
    for (op, channels) in table {
        if systemOps.contains(op) {
            continue // System ops intentionally have no channel
        }
        #expect(!channels.isEmpty, "Operation '\(op)' has no channels assigned")
    }
    #expect(table.count > 80, "Expected 80+ operations, got \(table.count)")
}

// v3.1.2 P1-1 — terminal State C from a primary channel must not fall
// through to the next channel. Pre-v3.1.2, an AX `element_not_found` on
// `track.select { index: 99999 }` bubbled into the MCU fallback, which then
// pressed a press-only LED button and reported State B `readback_unavailable`
// — masking the honest "this index does not exist" answer with what looked
// like a successful press.
actor TerminalStateCChannel: Channel {
    nonisolated let id: ChannelID
    let envelope: String

    init(id: ChannelID, envelope: String) {
        self.id = id
        self.envelope = envelope
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        .error(envelope)
    }

    func healthCheck() async -> ChannelHealth { .healthy(detail: "Mock OK") }
}

@Test func testTerminalStateCDoesNotFallThrough() async {
    // Primary channel returns terminal State C `element_not_found`. Router
    // must surface that envelope verbatim instead of advancing to the MCU
    // fallback (which would press a button on the wrong strip and lie about it).
    let router = ChannelRouter()
    let terminalEnvelope = HonestContract.encodeStateC(
        error: .elementNotFound,
        hint: "no track at index 99999"
    )
    let ax = TerminalStateCChannel(id: .accessibility, envelope: terminalEnvelope)
    let mcu = MockChannel(id: .mcu)
    await router.register(ax)
    await router.register(mcu)

    let result = await router.route(
        operation: "track.select",
        params: ["index": "99999"]
    )
    #expect(!result.isSuccess, "terminal State C must surface as router error")
    #expect(
        result.message == terminalEnvelope,
        "router must preserve the original State C envelope, got: \(result.message)"
    )
    let mcuOps = await mcu.executedOps
    #expect(
        mcuOps.isEmpty,
        "MCU fallback must NOT execute when AX returned terminal State C"
    )
}

@Test func testNonTerminalStateCStillFallsThrough() async {
    // `ax_write_failed` is non-terminal: the AX write may have failed for
    // reasons (focus stolen, plugin window grabbing input) that the next
    // channel down can route around. Router must keep the existing fallback
    // behavior in that case so we don't over-correct the P1-1 fix.
    let router = ChannelRouter()
    let nonTerminalEnvelope = HonestContract.encodeStateC(
        error: .axWriteFailed,
        hint: "AX write returned -25212"
    )
    let ax = TerminalStateCChannel(id: .accessibility, envelope: nonTerminalEnvelope)
    let mcu = MockChannel(id: .mcu)
    await router.register(ax)
    await router.register(mcu)

    let result = await router.route(
        operation: "track.set_mute",
        params: ["index": "0", "enabled": "true"]
    )
    #expect(result.isSuccess, "non-terminal State C should advance to MCU fallback")
    let mcuOps = await mcu.executedOps
    #expect(mcuOps.count == 1, "MCU fallback should fire on ax_write_failed")
}

// MARK: - P2 (verified-plugin envelope fidelity): single-channel non-terminal
// State C must surface VERBATIM (not wrapped in channels_exhausted).
//
// `ax_write_failed` / `readback_mismatch` are deliberately non-terminal (so a
// MULTI-channel chain can still fall back — guarded by
// testNonTerminalStateCStillFallsThrough above). But the verified-plugin ops
// (`plugin.set_param_verified` / `insert_verified`) route through a SINGLE
// `[.accessibility]` chain. Before the fix, those non-terminal envelopes fell
// through the loop and got wrapped in `channels_exhausted`, stripping AC8's
// post-write fidelity (write_attempted, rollback_*, target_identity, hc_schema,
// state). The router must instead return the channel's State C verbatim because
// a single-channel chain has no fallback target to mask it.

/// Build the exact `readback_mismatch` envelope `performVerifiedParamWrite`
/// emits on a tolerance miss (AccessibilityChannel+VerifiedPlugins.swift
/// step 13 rollback path), so this test pins the real wire shape rather than a
/// stand-in.
private func verifiedReadbackMismatchEnvelope() -> String {
    HonestContract.encodeV2StateC(
        error: .readbackMismatch,
        extras: [
            "operation": "logic_plugins.set_param_verified",
            "target_identity": [
                "plugin_id": "logic.stock.effect.compressor",
                "track_index": 0,
                "insert": 6,
            ],
            "param": "threshold",
            "requested_normalized": 60,
            "observed_normalized": 40,
            "observed_display": "40 %",
            "display_unit": "%",
            "tolerance": 1.0,
            "rollback_attempted": true,
            "rollback_succeeded": false,
            "rollback_to": 51,
            "what_was_attempted": "verify the 'Threshold' write within tolerance 1.0",
            "what_was_observed": "observed 40.0 differs from requested 60.0 beyond tolerance",
            "safe_to_retry": false,
            "write_attempted": true,
        ]
    )
}

@Test func testVerifiedSetParamReadbackMismatchSurfacesVerbatimNotChannelsExhausted() async {
    let router = ChannelRouter()
    let envelope = verifiedReadbackMismatchEnvelope()
    let ax = TerminalStateCChannel(id: .accessibility, envelope: envelope)
    await router.register(ax)

    let result = await router.route(
        operation: "plugin.set_param_verified",
        params: ["track": "0", "insert": "6"]
    )

    #expect(!result.isSuccess, "a verified readback_mismatch must remain a failure")
    #expect(
        result.message == envelope,
        "single-channel verified State C must be returned byte-for-byte, got: \(result.message)"
    )

    // Field-level fidelity: prove the AC8 / §4 payload survived the router
    // instead of being buried inside a channels_exhausted `hint` string.
    guard let obj = try? JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any] else {
        Issue.record("router output must be a structured HC envelope, got: \(result.message)")
        return
    }
    #expect(obj["error"] as? String == "readback_mismatch", "must NOT be rewritten to channels_exhausted")
    #expect(obj["state"] as? String == "C")
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(!((obj["verified"] as? Bool)!))
    #expect((obj["write_attempted"] as? Bool)!)
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect(!((obj["rollback_succeeded"] as? Bool)!))
    #expect(obj["rollback_to"] as? Double == 51)
    #expect(obj["requested_normalized"] as? Double == 60)
    #expect(obj["observed_normalized"] as? Double == 40)
    #expect(!((obj["safe_to_retry"] as? Bool)!))
    #expect(obj["target_identity"] is [String: Any], "target_identity must be preserved")
    // The exhaustion-only fields must be absent — confirms no wrapping occurred.
    #expect(obj["last_error"] == nil, "channels_exhausted wrapper must not be applied")
}

@Test func testVerifiedSetParamAxWriteFailedSurfacesVerbatimNotChannelsExhausted() async {
    // The other non-terminal verified post-write failure: the AXValue write was
    // rejected (step 11). Same single-channel verbatim contract.
    let router = ChannelRouter()
    let envelope = HonestContract.encodeV2StateC(
        error: .axWriteFailed,
        extras: [
            "operation": "logic_plugins.set_param_verified",
            "target_identity": ["plugin_id": "logic.stock.effect.compressor", "track_index": 0, "insert": 6],
            "param": "threshold",
            "requested_normalized": 60,
            "what_was_attempted": "set AXValue 60.0 on the 'Threshold' slider",
            "what_was_observed": "the AX value write was rejected",
            "safe_to_retry": true,
            "write_attempted": true,
        ]
    )
    let ax = TerminalStateCChannel(id: .accessibility, envelope: envelope)
    await router.register(ax)

    let result = await router.route(operation: "plugin.set_param_verified", params: ["track": "0"])

    #expect(!result.isSuccess)
    #expect(result.message == envelope, "ax_write_failed on a single-channel verified op must surface verbatim")
    guard let obj = try? JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any] else {
        Issue.record("expected structured envelope, got: \(result.message)")
        return
    }
    #expect(obj["error"] as? String == "ax_write_failed")
    #expect((obj["write_attempted"] as? Bool)!)
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(obj["last_error"] == nil)
}

@Test func testVerifiedInsertReadbackMismatchSurfacesVerbatim() async {
    // insert_verified shares the same single-channel `[.accessibility]` chain
    // and the same non-terminal post-write codes, so it gets the same fix.
    let router = ChannelRouter()
    let envelope = HonestContract.encodeV2StateC(
        error: .readbackMismatch,
        extras: [
            "operation": "logic_plugins.insert_verified",
            "target_identity": ["plugin_id": "logic.stock.effect.compressor", "track_index": 0, "insert": 6],
            "write_attempted": true,
            "safe_to_retry": false,
        ]
    )
    let ax = TerminalStateCChannel(id: .accessibility, envelope: envelope)
    await router.register(ax)

    let result = await router.route(operation: "plugin.insert_verified", params: ["track": "0"])
    #expect(result.message == envelope, "insert_verified single-channel State C must surface verbatim")
    let obj = try? JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
    #expect(obj?["error"] as? String == "readback_mismatch")
    #expect(obj?["last_error"] == nil)
}

@Test func testSingleChannelFreeFormErrorStillWrapsAsChannelsExhausted() async {
    // Companion guard for the fix's `stateCErrorCode != nil` scope clause: a
    // single-channel op whose only channel produces a FREE-FORM (non-State-C)
    // error — or never executes — must still fall through to the structured
    // channels_exhausted envelope. This is the MCU/no-channel exhaustion
    // contract (EndToEndTests / IntegrationTests) and must not regress.
    let router = ChannelRouter()
    let ax = TerminalStateCChannel(id: .accessibility, envelope: "free-form: AX subsystem hiccup")
    await router.register(ax)

    // transport.set_tempo is single-channel [.accessibility].
    let result = await router.route(operation: "transport.set_tempo", params: ["bpm": "120"])
    #expect(!result.isSuccess)
    guard let obj = try? JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any] else {
        Issue.record("expected structured channels_exhausted envelope, got: \(result.message)")
        return
    }
    #expect(
        obj["error"] as? String == "channels_exhausted",
        "free-form single-channel error must still be wrapped (no valid State C to surface)"
    )
    #expect(obj["operation"] as? String == "transport.set_tempo")
    #expect(obj["last_error"] as? String == "free-form: AX subsystem hiccup")
}

@Test func testFreeFormErrorStillFallsThrough() async {
    // Plain non-JSON error strings (legacy channels that haven't been
    // promoted to the contract yet) must keep the existing fallback
    // behavior — `isTerminalStateC` only short-circuits on real State C
    // envelopes with a known terminal error code.
    let router = ChannelRouter()
    let ax = TerminalStateCChannel(id: .accessibility, envelope: "free-form: something went wrong")
    let mcu = MockChannel(id: .mcu)
    await router.register(ax)
    await router.register(mcu)

    let result = await router.route(
        operation: "track.set_arm",
        params: ["index": "1", "enabled": "true"]
    )
    #expect(result.isSuccess, "free-form error should not be treated as terminal")
    let mcuOps = await mcu.executedOps
    #expect(mcuOps.count == 1)
}

@Test func testTransportToggleAXButtonMissFallsThroughToKeyCmd() async {
    let router = ChannelRouter()
    let ax = TerminalStateCChannel(
        id: .accessibility,
        envelope: HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "transport button 'Metronome' not located in control bar",
            extras: ["button": "Metronome"]
        )
    )
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(ax)
    await router.register(keyCmd)

    let result = await router.route(operation: "transport.toggle_metronome")

    #expect(result.isSuccess, "transport toggle should fall through when AX control-bar lookup misses")
    let keyCmdOps = await keyCmd.executedOps
    #expect(keyCmdOps.count == 1)
    #expect(keyCmdOps[0].0 == "transport.toggle_metronome")
}

@Test func testTransportToggleCyclePrefersKeyCmdBeforeMCUAfterAXButtonMiss() async {
    let router = ChannelRouter()
    let ax = TerminalStateCChannel(
        id: .accessibility,
        envelope: HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "transport button 'Cycle' not located in control bar",
            extras: ["button": "Cycle"]
        )
    )
    let keyCmd = MockChannel(id: .midiKeyCommands)
    let mcu = MockChannel(id: .mcu)
    await router.register(ax)
    await router.register(keyCmd)
    await router.register(mcu)

    let result = await router.route(operation: "transport.toggle_cycle")

    #expect(result.isSuccess, "cycle toggle should use learned key command before MCU readback-unavailable success")
    let keyCmdOps = await keyCmd.executedOps
    let mcuOps = await mcu.executedOps
    #expect(keyCmdOps.count == 1)
    #expect(keyCmdOps[0].0 == "transport.toggle_cycle")
    #expect(mcuOps.isEmpty)
}

@Test func testRouterStartAllReportsChannelFailures() async {
    let router = ChannelRouter()
    await router.register(MockChannel(id: .coreMIDI))
    await router.register(FailingStartChannel(id: .appleScript))

    let report = await router.startAll()

    #expect(report.started.contains(.coreMIDI))
    #expect(report.failures[.appleScript] != nil)
    #expect(report.hasFailures)
}

@Test func testRouterStartAllTreatsOptionalStartupFailureAsDegraded() async {
    let router = ChannelRouter()
    await router.register(FailingStartChannel(id: .accessibility))

    let report = await router.startAll()

    #expect(report.failures.isEmpty)
    #expect(report.degraded[.accessibility] != nil)
    #expect(!(report.hasFailures))
    #expect(report.hasDegraded)
}

@Test func testRouterStopAllCanSkipAccessibilityDuringForcedShutdown() async throws {
    let probe = BlockingStopProbe()
    let completion = StopAllCompletionProbe()
    let router = ChannelRouter()
    await router.register(BlockingStopChannel(id: .accessibility, probe: probe))
    await router.register(MockChannel(id: .coreMIDI))

    let stopTask = Task {
        await router.stopAll(excluding: [.accessibility])
        await completion.markCompleted()
    }

    #expect(try await waitUntil { await completion.isCompleted() })
    #expect(!(probe.waitUntilStopCalled(timeout: .milliseconds(10))))

    probe.unblock()
    await stopTask.value
}
