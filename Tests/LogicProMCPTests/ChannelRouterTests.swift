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

@Test func testRouterMixerGoesToMCU() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await router.route(operation: "mixer.set_volume", params: ["index": "0", "volume": "0.7"])
    #expect(result.isSuccess)

    let ops = await mcu.executedOps
    #expect(ops.count == 1)
    #expect(ops[0].0 == "mixer.set_volume")
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
    #expect(report.hasFailures == true)
}

@Test func testRouterStartAllTreatsOptionalStartupFailureAsDegraded() async {
    let router = ChannelRouter()
    await router.register(FailingStartChannel(id: .accessibility))

    let report = await router.startAll()

    #expect(report.failures.isEmpty)
    #expect(report.degraded[.accessibility] != nil)
    #expect(report.hasFailures == false)
    #expect(report.hasDegraded == true)
}
