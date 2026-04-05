import Testing
@testable import LogicProMCP

// Mock channel for router tests
actor MockChannel: Channel {
    nonisolated let id: ChannelID
    var executedOps: [(String, [String: String])] = []
    var isAvailable: Bool = true

    init(id: ChannelID, available: Bool = true) {
        self.id = id
        self.isAvailable = available
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        return .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        isAvailable ? .healthy(detail: "Mock OK") : .unavailable("Mock unavailable")
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
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

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
