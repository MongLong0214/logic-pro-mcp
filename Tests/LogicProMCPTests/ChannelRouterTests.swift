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

@Test func testRouterSetTempoGoesToKeyCmd() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await router.route(operation: "transport.set_tempo")
    #expect(result.isSuccess)

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.count == 0)    // MCU has no native tempo set
    #expect(keyCmdOps.count == 1) // KeyCmd primary for set_tempo
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
