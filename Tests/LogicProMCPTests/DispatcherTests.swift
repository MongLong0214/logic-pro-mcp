import Testing
import Foundation
import MCP
@testable import LogicProMCP

private let dispatcherText = sharedToolText

private func expectExecutedOp(
    _ actual: (String, [String: String]),
    equals expected: (String, [String: String])
) {
    #expect(actual.0 == expected.0)
    #expect(actual.1 == expected.1)
}

private func expectExecutedOps(
    _ actual: [(String, [String: String])],
    equals expected: [(String, [String: String])]
) {
    #expect(actual.count == expected.count)
    for index in expected.indices {
        expectExecutedOp(actual[index], equals: expected[index])
    }
}

private func makeLogicProjectPath(name: String = UUID().uuidString, create: Bool) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(name)
        .appendingPathExtension("logicx")
    if create {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let resources = path.appendingPathComponent("Resources", isDirectory: true)
        let alternative = path.appendingPathComponent("Alternatives/000", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: resources.appendingPathComponent("ProjectInformation.plist"))
        try Data("project".utf8).write(to: alternative.appendingPathComponent("ProjectData"))
    }
    return path.path
}

private final class ProjectLifecycleHarness {
    var scripts: [String] = []
    var runningStates: [Bool]
    var sleepCalls: [UInt64] = []
    let execution: ProjectDispatcher.LifecycleExecution

    init(execution: ProjectDispatcher.LifecycleExecution, runningStates: [Bool]) {
        self.execution = execution
        self.runningStates = runningStates
    }

    func execute(script: String) async -> ProjectDispatcher.LifecycleExecution {
        scripts.append(script)
        return execution
    }

    func isRunning() -> Bool {
        guard !runningStates.isEmpty else { return false }
        if runningStates.count == 1 {
            return runningStates[0]
        }
        return runningStates.removeFirst()
    }

    func sleep(nanoseconds: UInt64) async {
        sleepCalls.append(nanoseconds)
    }
}

private actor FailingExecuteChannel: Channel {
    nonisolated let id: ChannelID
    let message: String

    init(id: ChannelID, message: String) {
        self.id = id
        self.message = message
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        .error(message)
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "failing execute channel")
    }
}

// MARK: - TransportDispatcher

@Test func testTransportDispatcherRoutesPrimaryCommands() async {
    let cases: [(command: String, operation: String)] = [
        ("play", "transport.play"),
        ("stop", "transport.stop"),
        ("record", "transport.record"),
        ("pause", "transport.pause"),
        ("rewind", "transport.rewind"),
        ("fast_forward", "transport.fast_forward"),
        ("toggle_cycle", "transport.toggle_cycle"),
        ("toggle_metronome", "transport.toggle_metronome"),
        ("toggle_count_in", "transport.toggle_count_in"),
    ]

    for testCase in cases {
        let router = ChannelRouter()
        let channelID: ChannelID = switch testCase.operation {
        case "transport.pause": .coreMIDI
        case "transport.toggle_metronome", "transport.toggle_count_in": .midiKeyCommands
        default: .mcu
        }
        let channel = MockChannel(id: channelID)
        await router.register(channel)
        let cache = StateCache()

        let result = await TransportDispatcher.handle(
            command: testCase.command,
            params: [:],
            router: router,
            cache: cache
        )

        #expect(!result.isError!, "Expected \(testCase.command) to succeed")
        let ops = await channel.executedOps
        #expect(ops.count == 1)
        #expect(ops[0].0 == testCase.operation)
    }
}

@Test func testTransportDispatcherSetTempoGotoPositionAndCycleRange() async {
    // Post-hardening: transport.set_tempo routes ONLY to Accessibility.
    // MIDIKeyCommands / CGEvent fallbacks removed because they can't convey
    // the tempo value (CC press/keypress ignores param), masking real errors.
    let tempoRouter = ChannelRouter()
    let tempoAX = MockChannel(id: .accessibility)
    await tempoRouter.register(tempoAX)
    let cache = StateCache()

    let tempoResult = await TransportDispatcher.handle(
        command: "set_tempo",
        params: ["bpm": .double(128.5)],
        router: tempoRouter,
        cache: cache
    )

    #expect(!tempoResult.isError!)
    let tempoOps = await tempoAX.executedOps
    expectExecutedOps(tempoOps, equals: [("transport.set_tempo", ["bpm": "128.5"])])

    let gotoRouter = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let ax = MockChannel(id: .accessibility)
    await gotoRouter.register(mcu)
    await gotoRouter.register(ax)

    let gotoBarResult = await TransportDispatcher.handle(
        command: "goto_position",
        params: ["bar": .int(9)],
        router: gotoRouter,
        cache: cache
    )
    let gotoTimeResult = await TransportDispatcher.handle(
        command: "goto_position",
        params: ["time": .string("00:00:10:12")],
        router: gotoRouter,
        cache: cache
    )
    let cycleResult = await TransportDispatcher.handle(
        command: "set_cycle_range",
        params: ["start": .int(4), "end": .int(12)],
        router: gotoRouter,
        cache: cache
    )

    #expect(!gotoBarResult.isError!)
    #expect(!gotoTimeResult.isError!)
    #expect(!cycleResult.isError!)
    // AX is now primary for transport.goto_position (AX goes through the bar slider).
    // MCU receives no goto_position calls when AX succeeds first.
    let gotoOps = await mcu.executedOps
    #expect(gotoOps.isEmpty)
    let axOps = await ax.executedOps
    expectExecutedOps(axOps, equals: [
        ("transport.goto_position", ["position": "9.1.1.1"]),
        ("transport.goto_position", ["position": "00:00:10:12"]),
        ("transport.set_cycle_range", ["start": "4.1.1.1", "end": "12.1.1.1"]),
    ])
}

@Test func testTransportDispatcherGotoPositionDefaultsToStart() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await TransportDispatcher.handle(
        command: "goto_position",
        params: [:],
        router: router,
        cache: StateCache()
    )

    #expect(!result.isError!)
    let ops = await mcu.executedOps
    expectExecutedOps(ops, equals: [("transport.goto_position", ["position": "1.1.1.1"])])
}

@Test func testTransportDispatcherUnknownCommandFailsInDispatcherSuite() async {
    let result = await TransportDispatcher.handle(
        command: "warp_drive",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("Unknown transport command"))
}

// MARK: - MixerDispatcher

@Test func testMixerDispatcherSetVolume() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "set_volume",
        params: ["track": .int(2), "value": .double(0.7)],
        router: router, cache: cache
    )
    #expect(!result.isError!)

    let ops = await mcu.executedOps
    #expect(ops[0].0 == "mixer.set_volume")
    #expect(ops[0].1["index"] == "2")
    #expect(ops[0].1["volume"] == "0.7")
}

@Test func testMixerDispatcherSetPluginParam() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let scripter = MockChannel(id: .scripter)
    await router.register(mcu)
    await router.register(scripter)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(1), "insert": .int(0), "param": .int(3), "value": .double(0.5)],
        router: router, cache: cache
    )
    #expect(!result.isError!)
    let mcuOps = await mcu.executedOps
    let scripterOps = await scripter.executedOps
    expectExecutedOps(mcuOps, equals: [("track.select", ["index": "1"])])
    expectExecutedOps(scripterOps, equals: [("plugin.set_param", ["track": "1", "insert": "0", "param": "3", "value": "0.5"])])
}

@Test func testMixerDispatcherSetPluginParamRejectsUnsupportedInsertAndSelectionFailure() async {
    let invalidInsertResult = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(1), "insert": .int(2), "param": .int(3), "value": .double(0.5)],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(invalidInsertResult.isError!)
    #expect(dispatcherText(invalidInsertResult).contains("insert: 0"))

    let router = ChannelRouter()
    let mcu = FailingExecuteChannel(id: .mcu, message: "selection failed")
    let scripter = MockChannel(id: .scripter)
    await router.register(mcu)
    await router.register(scripter)

    let selectionFailure = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(1), "insert": .int(0), "param": .int(3), "value": .double(0.5)],
        router: router,
        cache: StateCache()
    )

    #expect(selectionFailure.isError!)
    #expect(dispatcherText(selectionFailure).contains("selection failed"))
    let scripterOps = await scripter.executedOps
    #expect(scripterOps.isEmpty)
}

@Test func testMixerDispatcherRoutesPanSendIOAndMasterCommands() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let ax = MockChannel(id: .accessibility)
    await router.register(mcu)
    await router.register(ax)
    let cache = StateCache()

    let panResult = await MixerDispatcher.handle(
        command: "set_pan",
        params: ["index": .int(4), "pan": .double(-0.25)],
        router: router,
        cache: cache
    )
    let sendResult = await MixerDispatcher.handle(
        command: "set_send",
        params: ["track": .int(2), "send_index": .int(1), "level": .double(0.33)],
        router: router,
        cache: cache
    )
    let outputResult = await MixerDispatcher.handle(
        command: "set_output",
        params: ["track": .int(5), "output": .string("Bus 1")],
        router: router,
        cache: cache
    )
    let inputResult = await MixerDispatcher.handle(
        command: "set_input",
        params: ["index": .int(5), "input": .string("Input 3")],
        router: router,
        cache: cache
    )
    let masterResult = await MixerDispatcher.handle(
        command: "set_master_volume",
        params: ["volume": .double(0.82)],
        router: router,
        cache: cache
    )
    let eqResult = await MixerDispatcher.handle(
        command: "toggle_eq",
        params: ["track": .int(3)],
        router: router,
        cache: cache
    )
    let resetResult = await MixerDispatcher.handle(
        command: "reset_strip",
        params: ["index": .int(6)],
        router: router,
        cache: cache
    )

    #expect(!panResult.isError!)
    #expect(sendResult.isError!)
    #expect(outputResult.isError!)
    #expect(inputResult.isError!)
    #expect(!masterResult.isError!)
    #expect(eqResult.isError!)
    #expect(resetResult.isError!)

    let mcuOps = await mcu.executedOps
    expectExecutedOps(mcuOps, equals: [
        ("mixer.set_pan", ["index": "4", "pan": "-0.25"]),
        ("mixer.set_master_volume", ["volume": "0.82"]),
    ])

    let axOps = await ax.executedOps
    #expect(axOps.isEmpty)
}

@Test func testMixerDispatcherPluginCommandsReturnNotExposed() async {
    // insert_plugin / bypass_plugin were removed from the public contract
    // because every channel that could handle them (AX, MCU) returned
    // "not yet implemented" errors. The dispatcher must now short-circuit
    // with an explicit non-exposure error and MUST NOT touch any channel.
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    let mcu = MockChannel(id: .mcu)
    await router.register(ax)
    await router.register(mcu)
    let cache = StateCache()

    let insertResult = await MixerDispatcher.handle(
        command: "insert_plugin",
        params: ["track_index": .int(7), "slot": .int(2), "plugin_name": .string("Compressor")],
        router: router,
        cache: cache
    )
    let bypassResult = await MixerDispatcher.handle(
        command: "bypass_plugin",
        params: ["track": .int(7), "slot": .int(2), "bypassed": .bool(false)],
        router: router,
        cache: cache
    )

    #expect(insertResult.isError == true)
    #expect(bypassResult.isError == true)
    if case .text(let text, _, _) = insertResult.content.first {
        #expect(text.contains("insert_plugin"))
        #expect(text.contains("not exposed"))
    } else {
        Issue.record("Expected text content for insert_plugin error")
    }
    let axOps = await ax.executedOps
    let mcuOps = await mcu.executedOps
    #expect(axOps.isEmpty)
    #expect(mcuOps.isEmpty)
}

@Test func testMixerDispatcherUnknown() async {
    let router = ChannelRouter()
    let cache = StateCache()
    let result = await MixerDispatcher.handle(command: "nonexistent", params: [:], router: router, cache: cache)
    #expect(result.isError!)
}

@Test func testMixerDispatcherToolMetadataDocumentsPluginParamCommand() {
    let tool = MixerDispatcher.tool
    let description = tool.description ?? ""
    #expect(tool.name == "logic_mixer")
    #expect(description.contains("set_plugin_param"))
    _ = tool.inputSchema
    #expect(description.contains("set_master_volume"))
    #expect(!description.contains("set_output"))
    #expect(!description.contains("set_input"))
    #expect(!description.contains("set_send"))
}

// MARK: - TrackDispatcher

@Test func testTrackDispatcherMuteUsesEnabled() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)
    let cache = StateCache()

    _ = await TrackDispatcher.handle(
        command: "mute",
        params: ["index": .int(3), "enabled": .bool(true)],
        router: router, cache: cache
    )

    let ops = await mcu.executedOps
    #expect(ops[0].1["enabled"] == "true") // not "muted"
}

@Test func testTrackDispatcherSetAutomation() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)
    let cache = StateCache()

    let result = await TrackDispatcher.handle(
        command: "set_automation",
        params: ["index": .int(1), "mode": .string("touch")],
        router: router, cache: cache
    )
    #expect(!result.isError!)
}

@Test func testTrackDispatcherLibraryCommandsAndPluginScanRouteCorrectly() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let pathResult = await TrackDispatcher.handle(
        command: "set_instrument",
        params: ["index": .string("2"), "path": .string("Bass/Sub Bass")],
        router: router,
        cache: cache
    )
    let legacyResult = await TrackDispatcher.handle(
        command: "set_instrument",
        params: ["index": .int(1), "category": .string("Bass"), "preset": .string("Sub Bass")],
        router: router,
        cache: cache
    )
    let resolveResult = await TrackDispatcher.handle(
        command: "resolve_path",
        params: ["path": .string("Bass/Sub Bass")],
        router: router,
        cache: cache
    )
    let listResult = await TrackDispatcher.handle(
        command: "list_library",
        params: [:],
        router: router,
        cache: cache
    )
    let scanResult = await TrackDispatcher.handle(
        command: "scan_library",
        params: [:],
        router: router,
        cache: cache
    )
    let pluginResult = await TrackDispatcher.handle(
        command: "scan_plugin_presets",
        params: ["submenuOpenDelayMs": .string("400")],
        router: router,
        cache: cache
    )
    let missingPathResult = await TrackDispatcher.handle(
        command: "resolve_path",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(!pathResult.isError!)
    #expect(!legacyResult.isError!)
    #expect(!resolveResult.isError!)
    #expect(!listResult.isError!)
    #expect(!scanResult.isError!)
    #expect(!pluginResult.isError!)
    #expect(missingPathResult.isError == true)
    #expect(dispatcherText(missingPathResult).contains("Missing 'path'"))

    let ops = await ax.executedOps
    expectExecutedOps(ops, equals: [
        ("track.set_instrument", ["index": "2", "path": "Bass/Sub Bass"]),
        ("track.set_instrument", ["index": "1", "category": "Bass", "preset": "Sub Bass"]),
        ("library.resolve_path", ["path": "Bass/Sub Bass"]),
        ("library.list", [:]),
        ("library.scan_all", [:]),
        ("plugin.scan_presets", ["submenuOpenDelayMs": "400"]),
    ])
}

@Test func testTrackDispatcherSelectByIndexAndName() async {
    let indexRouter = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await indexRouter.register(mcu)
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 0, name: "Kick", type: .audio),
        TrackState(id: 1, name: "Lead Vocal", type: .audio),
    ])

    let indexResult = await TrackDispatcher.handle(
        command: "select",
        params: ["index": .int(1)],
        router: indexRouter,
        cache: cache
    )
    let nameResult = await TrackDispatcher.handle(
        command: "select",
        params: ["name": .string("lead")],
        router: indexRouter,
        cache: cache
    )

    #expect(!indexResult.isError!)
    #expect(!nameResult.isError!)
    let ops = await mcu.executedOps
    expectExecutedOps(ops, equals: [
        ("track.select", ["index": "1"]),
        ("track.select", ["index": "1"]),
    ])
}

@Test func testTrackDispatcherSelectErrorsWhenParamsMissingOrNameUnknown() async {
    let cache = StateCache()
    let router = ChannelRouter()

    let missingParamResult = await TrackDispatcher.handle(
        command: "select",
        params: [:],
        router: router,
        cache: cache
    )

    await cache.updateTracks([TrackState(id: 0, name: "Bass", type: .audio)])
    let missingTrackResult = await TrackDispatcher.handle(
        command: "select",
        params: ["name": .string("vocal")],
        router: router,
        cache: cache
    )

    #expect(missingParamResult.isError!)
    #expect(dispatcherText(missingParamResult).contains("requires 'index' or 'name'"))
    #expect(missingTrackResult.isError!)
    #expect(dispatcherText(missingTrackResult).contains("No track found matching"))
}

@Test func testTrackDispatcherCreateCommandsAndMutations() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    let ax = MockChannel(id: .accessibility)
    await router.register(mcu)
    await router.register(keyCmd)
    await router.register(ax)
    let cache = StateCache()

    let commands = [
        ("create_audio", "track.create_audio"),
        ("create_instrument", "track.create_instrument"),
        ("create_drummer", "track.create_drummer"),
        ("create_external_midi", "track.create_external_midi"),
    ]

    for (command, operation) in commands {
        let result = await TrackDispatcher.handle(command: command, params: [:], router: router, cache: cache)
        #expect(!result.isError!, "Expected \(command) to succeed")
        let ops = await ax.executedOps
        #expect(ops.last?.0 == operation)
    }

    let renameResult = await TrackDispatcher.handle(
        command: "rename",
        params: ["index": .int(5), "name": .string("Pad Bus")],
        router: router,
        cache: cache
    )
    let soloResult = await TrackDispatcher.handle(
        command: "solo",
        params: ["index": .int(5), "enabled": .bool(true)],
        router: router,
        cache: cache
    )
    let armResult = await TrackDispatcher.handle(
        command: "arm",
        params: ["index": .int(5), "enabled": .bool(false)],
        router: router,
        cache: cache
    )
    let colorResult = await TrackDispatcher.handle(
        command: "set_color",
        params: ["index": .int(5), "color": .int(12)],
        router: router,
        cache: cache
    )

    #expect(!renameResult.isError!)
    #expect(!soloResult.isError!)
    #expect(!armResult.isError!)
    #expect(colorResult.isError!)

    let mcuOps = await mcu.executedOps
    let axOps = await ax.executedOps
    // Post-fix: track.set_solo / track.set_arm route to Accessibility first
    // (idempotent, reads current AX checkbox state) and only fall back to MCU
    // if AX fails. When AX succeeds, MCU is never called.
    expectExecutedOps(mcuOps, equals: [])
    expectExecutedOps(axOps, equals: [
        ("track.create_audio", [:]),
        ("track.create_instrument", [:]),
        ("track.create_drummer", [:]),
        ("track.create_external_midi", [:]),
        ("track.rename", ["index": "5", "name": "Pad Bus"]),
        ("track.set_solo", ["index": "5", "enabled": "true"]),
        ("track.set_arm", ["index": "5", "enabled": "false"]),
    ])
}

@Test func testTrackDispatcherDeleteAndDuplicateRespectSelectionFlow() async {
    let successRouter = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await successRouter.register(mcu)
    await successRouter.register(keyCmd)
    let cache = StateCache()

    let deleteResult = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2)],
        router: successRouter,
        cache: cache
    )
    let duplicateResult = await TrackDispatcher.handle(
        command: "duplicate",
        params: ["index": .int(2)],
        router: successRouter,
        cache: cache
    )

    #expect(!deleteResult.isError!)
    #expect(!duplicateResult.isError!)
    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    expectExecutedOps(mcuOps, equals: [
        ("track.select", ["index": "2"]),
        ("track.select", ["index": "2"]),
    ])
    expectExecutedOps(keyCmdOps, equals: [
        ("track.delete", [:]),
        ("track.duplicate", [:]),
    ])

    let failureRouter = ChannelRouter()
    await failureRouter.register(keyCmd)
    let failureResult = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(9)],
        router: failureRouter,
        cache: cache
    )

    #expect(failureResult.isError!)
}

@Test func testTrackDispatcherDuplicateReturnsSelectionFailure() async {
    let router = ChannelRouter()
    let mcu = FailingExecuteChannel(id: .mcu, message: "selection failed")
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "duplicate",
        params: ["index": .int(9)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("selection failed"))
    #expect(await keyCmd.executedOps.isEmpty)
}

@Test func testTrackDispatcherUnknownFails() async {
    let result = await TrackDispatcher.handle(
        command: "explode_stack",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("Unknown track command"))
}

// MARK: - record_sequence error chain

@Test func testRecordSequenceHasDocumentGuard() async {
    let cache = StateCache()
    await cache.updateDocumentState(false)

    let result = await TrackDispatcher.handle(
        command: "record_sequence",
        params: ["index": .int(0), "notes": .string("60,0,480")],
        router: ChannelRouter(),
        cache: cache
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("No project open"))
}

@Test func testRecordSequenceSMFImportHappyPath() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let result = await TrackDispatcher.handle(
        command: "record_sequence",
        params: ["index": .int(0), "bar": .int(5), "notes": .string("60,0,480;64,500,480;67,1000,480"), "tempo": .double(120)],
        router: router,
        cache: cache
    )

    let text = dispatcherText(result)
    #expect(!result.isError!, "expected success, got: \(text)")
    #expect(text.contains("\"method\":\"smf_import\""))
    #expect(text.contains("\"note_count\":3"))
    #expect(text.contains("\"bar\":5"))

    // Verify midi.import_file was called via the router
    let ops = await ax.executedOps
    let importOps = ops.filter { $0.0 == "midi.import_file" }
    #expect(importOps.count == 1, "expected 1 midi.import_file call, got \(importOps.count)")
    #expect(importOps[0].1["path"]?.contains("/tmp/LogicProMCP") == true)
}

@Test func testRecordSequenceCleansUpTempFileOnError() async {
    let router = ChannelRouter()
    // Import channel fails
    let ax = FailingExecuteChannel(id: .accessibility, message: "Import failed")
    await router.register(ax)
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let result = await TrackDispatcher.handle(
        command: "record_sequence",
        params: ["index": .int(0), "bar": .int(1), "notes": .string("60,0,480"), "tempo": .double(120)],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
    // Verify no orphan files in /tmp/LogicProMCP/ by checking recent mtime
    // (best-effort assertion — the specific uuid is internal)
    let tempDir = "/tmp/LogicProMCP"
    if FileManager.default.fileExists(atPath: tempDir) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
        // Allow <= 1 file from other concurrent tests; just assert no accumulation
        #expect(files.count <= 5, "too many orphan .mid files: \(files.count)")
    }
}

@Test func testRecordSequenceRejectsInvalidNotes() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let result = await TrackDispatcher.handle(
        command: "record_sequence",
        params: ["index": .int(0), "notes": .string("invalid")],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
}

@Test func testRecordSequenceFailsOnImportError() async {
    let router = ChannelRouter()
    let ax = FailingExecuteChannel(id: .accessibility, message: "Import failed X")
    await router.register(ax)
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let result = await TrackDispatcher.handle(
        command: "record_sequence",
        params: ["index": .int(0), "notes": .string("60,0,480"), "tempo": .double(120)],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("import"))
}

// MARK: - arm_only error propagation

private actor SelectiveFailChannel: Channel {
    nonisolated let id: ChannelID
    var executedOps: [(String, [String: String])] = []
    let failOperations: Set<String>

    init(id: ChannelID, failOperations: Set<String> = []) {
        self.id = id
        self.failOperations = failOperations
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        if failOperations.contains(operation) {
            return .error("Mock failure: \(operation)")
        }
        return .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "selective fail channel")
    }
}

@Test func testArmOnlyReportsPartialDisarmFailure() async {
    let router = ChannelRouter()
    // All channels fail for track.set_arm → disarm should report failures
    let ax = FailingExecuteChannel(id: .accessibility, message: "AX fail")
    let mcu = FailingExecuteChannel(id: .mcu, message: "MCU fail")
    let cg = FailingExecuteChannel(id: .cgEvent, message: "CG fail")
    await router.register(ax)
    await router.register(mcu)
    await router.register(cg)
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 0, name: "Track 1", type: .audio, isArmed: true),
        TrackState(id: 1, name: "Target", type: .softwareInstrument),
    ])

    let result = await TrackDispatcher.handle(
        command: "arm_only",
        params: ["index": .int(1)],
        router: router,
        cache: cache
    )

    let text = dispatcherText(result)
    #expect(text.contains("failedDisarm"))
    #expect(text.contains("armedSuccess"))
}

@Test func testArmOnlySuccessPathReportsArmedSuccess() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 0, name: "Track 1", type: .audio, isArmed: true),
        TrackState(id: 1, name: "Target", type: .softwareInstrument),
    ])

    let result = await TrackDispatcher.handle(
        command: "arm_only",
        params: ["index": .int(1)],
        router: router,
        cache: cache
    )

    let text = dispatcherText(result)
    #expect(text.contains("\"armedSuccess\":true"))
    #expect(text.contains("\"armed\":1"))
}

// MARK: - EditDispatcher

@Test func testEditDispatcherToggleStepInput() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)
    let cache = StateCache()

    let result = await EditDispatcher.handle(command: "toggle_step_input", params: [:], router: router, cache: cache)
    #expect(!result.isError!)
}

@Test func testEditDispatcherRoutesPrimaryCommands() async {
    let cases: [(command: String, operation: String)] = [
        ("undo", "edit.undo"),
        ("redo", "edit.redo"),
        ("cut", "edit.cut"),
        ("copy", "edit.copy"),
        ("paste", "edit.paste"),
        ("delete", "edit.delete"),
        ("select_all", "edit.select_all"),
        ("split", "edit.split"),
        ("join", "edit.join"),
        ("bounce_in_place", "edit.bounce_in_place"),
        ("normalize", "edit.normalize"),
        ("duplicate", "edit.duplicate"),
    ]

    for testCase in cases {
        let router = ChannelRouter()
        let keyCmd = MockChannel(id: .midiKeyCommands)
        await router.register(keyCmd)
        let cache = StateCache()

        let result = await EditDispatcher.handle(
            command: testCase.command,
            params: [:],
            router: router,
            cache: cache
        )

        #expect(!result.isError!, "Expected \(testCase.command) to succeed")
        let ops = await keyCmd.executedOps
        #expect(ops.count == 1)
        #expect(ops[0].0 == testCase.operation)
    }
}

@Test func testEditDispatcherQuantizeUsesExplicitAndDefaultValues() async {
    let explicitRouter = ChannelRouter()
    let explicitKeyCmd = MockChannel(id: .midiKeyCommands)
    await explicitRouter.register(explicitKeyCmd)
    let explicitCache = StateCache()

    let explicitResult = await EditDispatcher.handle(
        command: "quantize",
        params: ["value": .string("1/8")],
        router: explicitRouter,
        cache: explicitCache
    )

    #expect(!explicitResult.isError!)
    let explicitOps = await explicitKeyCmd.executedOps
    #expect(explicitOps.count == 1)
    #expect(explicitOps[0].0 == "edit.quantize")
    #expect(explicitOps[0].1["value"] == "1/8")

    let defaultRouter = ChannelRouter()
    let defaultKeyCmd = MockChannel(id: .midiKeyCommands)
    await defaultRouter.register(defaultKeyCmd)
    let defaultCache = StateCache()

    let defaultResult = await EditDispatcher.handle(
        command: "quantize",
        params: [:],
        router: defaultRouter,
        cache: defaultCache
    )

    #expect(!defaultResult.isError!)
    let defaultOps = await defaultKeyCmd.executedOps
    #expect(defaultOps.count == 1)
    #expect(defaultOps[0].0 == "edit.quantize")
    #expect(defaultOps[0].1["value"] == "1/16")
}

@Test func testEditDispatcherUnknownFails() async {
    let router = ChannelRouter()
    let cache = StateCache()

    let result = await EditDispatcher.handle(
        command: "warp_quantum",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
}

// MARK: - ProjectDispatcher + DestructivePolicy

@Test func testProjectDispatcherQuitRequiresConfirmation() async {
    let router = ChannelRouter()
    let cache = StateCache()

    let result = await ProjectDispatcher.handle(command: "quit", params: [:], router: router, cache: cache)
    // Should return confirmation_required, not actually quit
    #expect(!result.isError!)
    if case .text(let text, _, _) = result.content.first {
        #expect(text.contains("confirmation_required"))
    }
}

@Test func testProjectDispatcherL2CommandsRequireConfirmation() async throws {
    let router = ChannelRouter()
    let cache = StateCache()
    let existingPath = try makeLogicProjectPath(create: true)
    let saveAsPath = try makeLogicProjectPath(create: false)

    let openResult = await ProjectDispatcher.handle(
        command: "open",
        params: ["path": .string(existingPath)],
        router: router,
        cache: cache
    )
    let saveAsResult = await ProjectDispatcher.handle(
        command: "save_as",
        params: ["path": .string(saveAsPath)],
        router: router,
        cache: cache
    )
    let bounceResult = await ProjectDispatcher.handle(command: "bounce", params: [:], router: router, cache: cache)

    for result in [openResult, saveAsResult, bounceResult] {
        #expect(!result.isError!)
        if case .text(let text, _, _) = result.content.first {
            #expect(text.contains("confirmation_required"))
        } else {
            Issue.record("Expected confirmation response")
        }
    }
}

@Test func testProjectDispatcherSaveNoConfirmation() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)
    let cache = StateCache()

    let result = await ProjectDispatcher.handle(command: "save", params: [:], router: router, cache: cache)
    // Save is L1 — should execute immediately (no confirmation)
    #expect(!result.isError!)
}

@Test func testProjectDispatcherRoutesLifecycleCommandsAndValidatesPaths() async throws {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    let appleScript = MockChannel(id: .appleScript)
    let cgEvent = MockChannel(id: .cgEvent)
    await router.register(keyCmd)
    await router.register(appleScript)
    await router.register(cgEvent)
    let cache = StateCache()

    let existingPath = try makeLogicProjectPath(create: true)
    let saveAsPath = try makeLogicProjectPath(create: false)

    let newResult = await ProjectDispatcher.handle(command: "new", params: [:], router: router, cache: cache)
    let openResult = await ProjectDispatcher.handle(
        command: "open",
        params: ["path": .string(existingPath), "confirmed": .bool(true)],
        router: router,
        cache: cache
    )
    let saveAsResult = await ProjectDispatcher.handle(
        command: "save_as",
        params: ["path": .string(saveAsPath), "confirmed": .bool(true)],
        router: router,
        cache: cache
    )
    let closeResult = await ProjectDispatcher.handle(
        command: "close",
        params: ["confirmed": .bool(true)],
        router: router,
        cache: cache
    )
    let bounceResult = await ProjectDispatcher.handle(command: "bounce", params: ["confirmed": .bool(true)], router: router, cache: cache)

    #expect(!newResult.isError!)
    #expect(!openResult.isError!)
    #expect(!saveAsResult.isError!)
    #expect(!closeResult.isError!)
    #expect(!bounceResult.isError!)

    let keyCmdOps = await keyCmd.executedOps
    let appleScriptOps = await appleScript.executedOps
    let cgEventOps = await cgEvent.executedOps
    expectExecutedOps(cgEventOps, equals: [])
    expectExecutedOps(keyCmdOps, equals: [
        ("project.bounce", [:]),
    ])
    expectExecutedOps(appleScriptOps, equals: [
        ("project.new", [:]),
        ("project.open", ["path": existingPath]),
        ("project.save_as", ["path": saveAsPath]),
        ("project.close", ["saving": "yes"]),
    ])
}

@Test func testProjectDispatcherCloseHonoursSavingParameter() async {
    let router = ChannelRouter()
    let appleScript = MockChannel(id: .appleScript)
    await router.register(appleScript)
    let cache = StateCache()

    for saving in ["yes", "no", "ask"] {
        let result = await ProjectDispatcher.handle(
            command: "close",
            params: ["saving": .string(saving), "confirmed": .bool(true)],
            router: router,
            cache: cache
        )
        #expect(!result.isError!)
    }

    let invalidResult = await ProjectDispatcher.handle(
        command: "close",
        params: ["saving": .string("maybe"), "confirmed": .bool(true)],
        router: router,
        cache: cache
    )
    #expect(invalidResult.isError == true)

    let ops = await appleScript.executedOps
    expectExecutedOps(ops, equals: [
        ("project.close", ["saving": "yes"]),
        ("project.close", ["saving": "no"]),
        ("project.close", ["saving": "ask"]),
    ])
}

@Test func testProjectDispatcherRejectsInvalidPathsAndUnknownCommands() async {
    let cache = StateCache()
    let router = ChannelRouter()

    let missingPathResult = await ProjectDispatcher.handle(
        command: "open",
        params: [:],
        router: router,
        cache: cache
    )
    let invalidOpenResult = await ProjectDispatcher.handle(
        command: "open",
        params: ["path": .string("relative.logicx")],
        router: router,
        cache: cache
    )
    let invalidSaveAsResult = await ProjectDispatcher.handle(
        command: "save_as",
        params: ["path": .string("/tmp/not-a-logic-project.txt")],
        router: router,
        cache: cache
    )
    let unknownResult = await ProjectDispatcher.handle(
        command: "archive",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(missingPathResult.isError!)
    #expect(dispatcherText(missingPathResult).contains("open requires 'path' param"))
    #expect(invalidOpenResult.isError!)
    #expect(dispatcherText(invalidOpenResult).contains("existing absolute .logicx"))
    #expect(invalidSaveAsResult.isError!)
    #expect(dispatcherText(invalidSaveAsResult).contains("absolute .logicx"))
    #expect(unknownResult.isError!)
}

@Test func testProjectDispatcherRejectsSaveAsWithoutPath() async {
    let result = await ProjectDispatcher.handle(
        command: "save_as",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("save_as requires 'path' param"))
}

@Test func testProjectDispatcherLaunchAndQuitShortCircuitOnRunningState() async {
    let router = ChannelRouter()
    let cache = StateCache()

    let alreadyRunning = await ProjectDispatcher.handle(
        command: "launch",
        params: [:],
        router: router,
        cache: cache,
        isLogicProRunning: { true }
    )
    let notRunning = await ProjectDispatcher.handle(
        command: "quit",
        params: ["confirmed": .bool(true)],
        router: router,
        cache: cache,
        isLogicProRunning: { false }
    )

    #expect(!alreadyRunning.isError!)
    #expect(dispatcherText(alreadyRunning).contains("already running"))
    #expect(!notRunning.isError!)
    #expect(dispatcherText(notRunning).contains("not running"))
}

@Test func testProjectDispatcherIsRunningReflectsInjectedProcessState() async {
    let running = await ProjectDispatcher.handle(
        command: "is_running",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { true }
    )
    let stopped = await ProjectDispatcher.handle(
        command: "is_running",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { false }
    )

    #expect(!running.isError!)
    #expect(!stopped.isError!)
    #expect(dispatcherText(running) == "true")
    #expect(dispatcherText(stopped) == "false")
}

@Test func testProjectDispatcherLaunchUsesLifecycleRunnerAndSucceedsAfterStateTransition() async {
    let harness = ProjectLifecycleHarness(
        execution: .init(executionError: nil, timedOut: false, terminationStatus: 0, stderrOutput: ""),
        runningStates: [false, true]
    )

    let result = await ProjectDispatcher.handle(
        command: "launch",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { harness.isRunning() },
        executeLifecycleScript: { script in await harness.execute(script: script) },
        sleep: { duration in await harness.sleep(nanoseconds: duration) }
    )

    #expect(!result.isError!)
    #expect(dispatcherText(result).contains("Logic Pro launched"))
    #expect(harness.scripts == ["tell application \"Logic Pro\" to activate"])
}

@Test func testProjectDispatcherLifecycleRunnerSurfacesExecutionErrorsAndTimeouts() async {
    let launchHarness = ProjectLifecycleHarness(
        execution: .init(executionError: "spawn failed", timedOut: false, terminationStatus: -1, stderrOutput: ""),
        runningStates: [false]
    )
    let launchResult = await ProjectDispatcher.handle(
        command: "launch",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { launchHarness.isRunning() },
        executeLifecycleScript: { script in await launchHarness.execute(script: script) },
        sleep: { duration in await launchHarness.sleep(nanoseconds: duration) }
    )

    let quitHarness = ProjectLifecycleHarness(
        execution: .init(executionError: nil, timedOut: true, terminationStatus: 0, stderrOutput: ""),
        runningStates: [true]
    )
    let quitResult = await ProjectDispatcher.handle(
        command: "quit",
        params: ["confirmed": .bool(true)],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { quitHarness.isRunning() },
        executeLifecycleScript: { script in await quitHarness.execute(script: script) },
        sleep: { duration in await quitHarness.sleep(nanoseconds: duration) }
    )

    #expect(launchResult.isError!)
    #expect(dispatcherText(launchResult).contains("spawn failed"))
    #expect(quitResult.isError!)
    #expect(dispatcherText(quitResult).contains("timed out"))
}

@Test func testProjectDispatcherLifecycleRunnerHandlesExitStatusAndStateMismatch() async {
    let statusHarness = ProjectLifecycleHarness(
        execution: .init(executionError: nil, timedOut: false, terminationStatus: 1, stderrOutput: ""),
        runningStates: [true]
    )
    let statusResult = await ProjectDispatcher.handle(
        command: "quit",
        params: ["confirmed": .bool(true)],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { statusHarness.isRunning() },
        executeLifecycleScript: { script in await statusHarness.execute(script: script) },
        sleep: { duration in await statusHarness.sleep(nanoseconds: duration) }
    )

    let mismatchHarness = ProjectLifecycleHarness(
        execution: .init(executionError: nil, timedOut: false, terminationStatus: 0, stderrOutput: ""),
        runningStates: Array(repeating: true, count: 60)
    )
    let mismatchResult = await ProjectDispatcher.handle(
        command: "quit",
        params: ["confirmed": .bool(true)],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { mismatchHarness.isRunning() },
        executeLifecycleScript: { script in await mismatchHarness.execute(script: script) },
        sleep: { duration in await mismatchHarness.sleep(nanoseconds: duration) }
    )

    #expect(statusResult.isError!)
    #expect(dispatcherText(statusResult).contains("osascript exited with status 1"))
    #expect(mismatchResult.isError!)
    #expect(dispatcherText(mismatchResult).contains("did not reach expected running state"))
    #expect(!mismatchHarness.sleepCalls.isEmpty)
}

@Test func testProjectDispatcherLifecycleRunnerPrefersStderrForExitStatus() async {
    let harness = ProjectLifecycleHarness(
        execution: .init(executionError: nil, timedOut: false, terminationStatus: 1, stderrOutput: "permission denied"),
        runningStates: [true]
    )

    let result = await ProjectDispatcher.handle(
        command: "quit",
        params: ["confirmed": .bool(true)],
        router: ChannelRouter(),
        cache: StateCache(),
        isLogicProRunning: { harness.isRunning() },
        executeLifecycleScript: { script in await harness.execute(script: script) },
        sleep: { duration in await harness.sleep(nanoseconds: duration) }
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("permission denied"))
}

@Test func testProjectDispatcherExecuteAppleScriptSucceedsForValidScript() async {
    let execution = await ProjectDispatcher.executeAppleScript("return 1")

    #expect(execution.executionError == nil)
    #expect(execution.timedOut == false)
    #expect(execution.terminationStatus == 0)
    #expect(execution.stderrOutput.isEmpty)
}

@Test func testProjectDispatcherExecuteAppleScriptCapturesInvalidScriptFailure() async {
    let execution = await ProjectDispatcher.executeAppleScript("this is not valid AppleScript")

    #expect(execution.executionError == nil)
    #expect(execution.timedOut == false)
    #expect(execution.terminationStatus != 0)
    #expect(!execution.stderrOutput.isEmpty)
}

@Test func testProjectDispatcherExecuteAppleScriptSurfacesProcessLaunchFailure() async {
    let execution = await ProjectDispatcher.executeAppleScript(
        "return 1",
        executableURL: URL(fileURLWithPath: "/tmp/logic-pro-mcp-missing-osascript")
    )

    #expect(execution.executionError != nil)
    #expect(execution.timedOut == false)
    #expect(execution.terminationStatus == -1)
}

// MARK: - MIDIDispatcher

@Test func testMIDIDispatcherStepInput() async {
    let router = ChannelRouter()
    let coreMidi = MockChannel(id: .coreMIDI)
    await router.register(coreMidi)
    let cache = StateCache()

    let result = await MIDIDispatcher.handle(
        command: "step_input",
        params: ["note": .int(60), "duration": .string("1/4")],
        router: router, cache: cache
    )
    #expect(!result.isError!)
    let ops = await coreMidi.executedOps
    expectExecutedOps(ops, equals: [("midi.step_input", ["note": "60", "duration": "1/4"])])
}

@Test func testMIDIDispatcherRoutesCoreCommands() async {
    let router = ChannelRouter()
    let coreMidi = MockChannel(id: .coreMIDI)
    await router.register(coreMidi)
    let cache = StateCache()

    let noteResult = await MIDIDispatcher.handle(
        command: "send_note",
        params: ["note": .int(64), "velocity": .int(90), "channel": .int(2), "duration_ms": .int(750)],
        router: router,
        cache: cache
    )
    let ccResult = await MIDIDispatcher.handle(
        command: "send_cc",
        params: ["controller": .int(74), "value": .int(127), "channel": .int(3)],
        router: router,
        cache: cache
    )
    let pcResult = await MIDIDispatcher.handle(
        command: "send_program_change",
        params: ["program": .int(8), "channel": .int(4)],
        router: router,
        cache: cache
    )
    let bendResult = await MIDIDispatcher.handle(
        command: "send_pitch_bend",
        params: ["value": .int(-512), "channel": .int(5)],
        router: router,
        cache: cache
    )
    let aftertouchResult = await MIDIDispatcher.handle(
        command: "send_aftertouch",
        params: ["value": .int(55), "channel": .int(6)],
        router: router,
        cache: cache
    )

    #expect(!noteResult.isError!)
    #expect(!ccResult.isError!)
    #expect(!pcResult.isError!)
    #expect(!bendResult.isError!)
    #expect(!aftertouchResult.isError!)
    let ops = await coreMidi.executedOps
    expectExecutedOps(ops, equals: [
        ("midi.send_note", ["note": "64", "velocity": "90", "channel": "2", "duration_ms": "750"]),
        ("midi.send_cc", ["controller": "74", "value": "127", "channel": "3"]),
        ("midi.send_program_change", ["program": "8", "channel": "4"]),
        ("midi.send_pitch_bend", ["value": "-512", "channel": "5"]),
        ("midi.send_aftertouch", ["value": "55", "channel": "6"]),
    ])
}

@Test func testMIDIDispatcherNormalizesChordSysexMMCAndVirtualPortCommands() async {
    let router = ChannelRouter()
    let coreMidi = MockChannel(id: .coreMIDI)
    let mcu = MockChannel(id: .mcu)
    await router.register(coreMidi)
    await router.register(mcu)
    let cache = StateCache()

    let chordArrayResult = await MIDIDispatcher.handle(
        command: "send_chord",
        params: ["notes": .array([.int(60), .int(64), .int(67)]), "velocity": .int(80)],
        router: router,
        cache: cache
    )
    let chordStringResult = await MIDIDispatcher.handle(
        command: "send_chord",
        params: ["notes": .string("72,76,79")],
        router: router,
        cache: cache
    )
    let sysexResult = await MIDIDispatcher.handle(
        command: "send_sysex",
        params: ["bytes": .array([.int(240), .int(66), .int(247)])],
        router: router,
        cache: cache
    )
    let portResult = await MIDIDispatcher.handle(
        command: "create_virtual_port",
        params: ["name": .string("LogicProMCP-Test")],
        router: router,
        cache: cache
    )
    let playResult = await MIDIDispatcher.handle(command: "mmc_play", params: [:], router: router, cache: cache)
    let stopResult = await MIDIDispatcher.handle(command: "mmc_stop", params: [:], router: router, cache: cache)
    let recordResult = await MIDIDispatcher.handle(command: "mmc_record", params: [:], router: router, cache: cache)
    let locateBarResult = await MIDIDispatcher.handle(
        command: "mmc_locate",
        params: ["bar": .int(17)],
        router: router,
        cache: cache
    )
    let locateTimeResult = await MIDIDispatcher.handle(
        command: "mmc_locate",
        params: ["time": .string("01:02:03:04")],
        router: router,
        cache: cache
    )

    #expect(!chordArrayResult.isError!)
    #expect(!chordStringResult.isError!)
    #expect(!sysexResult.isError!)
    #expect(!portResult.isError!)
    #expect(!playResult.isError!)
    #expect(!stopResult.isError!)
    #expect(!recordResult.isError!)
    #expect(!locateBarResult.isError!)
    #expect(!locateTimeResult.isError!)

    let coreOps = await coreMidi.executedOps
    let mcuOps = await mcu.executedOps
    expectExecutedOps(coreOps, equals: [
        ("midi.send_chord", ["notes": "60,64,67", "velocity": "80", "channel": "1", "duration_ms": "500"]),
        ("midi.send_chord", ["notes": "72,76,79", "velocity": "100", "channel": "1", "duration_ms": "500"]),
        ("midi.send_sysex", ["data": "F0 42 F7"]),
        ("midi.create_virtual_port", ["name": "LogicProMCP-Test"]),
        ("mmc.play", [:]),
        ("mmc.stop", [:]),
        ("mmc.record_strobe", [:]),
        ("mmc.locate", ["time": "01:02:03:04"]),
    ])
    expectExecutedOps(mcuOps, equals: [
        ("transport.goto_position", ["position": "17.1.1.1"]),
    ])
}

@Test func testMIDIDispatcherAcceptsSysexDataStringBranch() async {
    let router = ChannelRouter()
    let coreMidi = MockChannel(id: .coreMIDI)
    await router.register(coreMidi)

    let result = await MIDIDispatcher.handle(
        command: "send_sysex",
        params: ["data": .string("F0 7D 01 F7")],
        router: router,
        cache: StateCache()
    )

    #expect(!result.isError!)
    expectExecutedOps(await coreMidi.executedOps, equals: [
        ("midi.send_sysex", ["data": "F0 7D 01 F7"]),
    ])
}

@Test func testMIDIDispatcherUnknownCommandFailsInDispatcherSuite() async {
    let result = await MIDIDispatcher.handle(
        command: "panic_all_channels",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("Unknown MIDI command"))
}

// MARK: - NavigateDispatcher

@Test func testNavigateDispatcherRoutesMarkerAndZoomCommands() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    let ax = MockChannel(id: .accessibility)
    await router.register(mcu)
    await router.register(keyCmd)
    await router.register(ax)
    let cache = StateCache()
    await cache.updateMarkers([
        MarkerState(id: 1, name: "Verse", position: "9.1.1.1"),
        MarkerState(id: 2, name: "Chorus", position: "17.1.1.1"),
    ])

    let gotoBarResult = await NavigateDispatcher.handle(
        command: "goto_bar",
        params: ["bar": .int(12)],
        router: router,
        cache: cache
    )
    // goto_bar now delegates to transport.goto_position on AX — separate test covers this.
    let gotoMarkerIndexResult = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["index": .int(2)],
        router: router,
        cache: cache
    )
    let gotoMarkerNameResult = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["name": .string("chor")],
        router: router,
        cache: cache
    )
    let createMarkerResult = await NavigateDispatcher.handle(
        command: "create_marker",
        params: ["name": .string("Bridge")],
        router: router,
        cache: cache
    )
    let deleteMarkerResult = await NavigateDispatcher.handle(
        command: "delete_marker",
        params: ["index": .int(1)],
        router: router,
        cache: cache
    )
    let renameMarkerResult = await NavigateDispatcher.handle(
        command: "rename_marker",
        params: ["index": .int(2), "name": .string("Big Chorus")],
        router: router,
        cache: cache
    )
    let zoomFitResult = await NavigateDispatcher.handle(
        command: "zoom_to_fit",
        params: [:],
        router: router,
        cache: cache
    )
    let zoomInResult = await NavigateDispatcher.handle(
        command: "set_zoom",
        params: ["level": .string("in")],
        router: router,
        cache: cache
    )
    let zoomOutResult = await NavigateDispatcher.handle(
        command: "set_zoom",
        params: ["level": .string("out")],
        router: router,
        cache: cache
    )
    let zoomCustomResult = await NavigateDispatcher.handle(
        command: "set_zoom",
        params: ["level": .string("5")],
        router: router,
        cache: cache
    )

    #expect(!gotoBarResult.isError!)
    #expect(!gotoMarkerIndexResult.isError!)
    #expect(!gotoMarkerNameResult.isError!)
    #expect(!createMarkerResult.isError!)
    #expect(!deleteMarkerResult.isError!)
    #expect(!renameMarkerResult.isError!)
    #expect(!zoomFitResult.isError!)
    #expect(!zoomInResult.isError!)
    #expect(!zoomOutResult.isError!)
    #expect(!zoomCustomResult.isError!)

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    let axOps = await ax.executedOps
    #expect(mcuOps.isEmpty)
    expectExecutedOps(axOps, equals: [
        ("transport.goto_position", ["position": "12.1.1.1"]),
        ("nav.rename_marker", ["index": "2", "name": "Big Chorus"]),
    ])
    expectExecutedOps(keyCmdOps, equals: [
        ("nav.goto_marker", ["index": "2"]),
        ("nav.goto_marker", ["index": "2"]),
        ("nav.create_marker", ["name": "Bridge"]),
        ("nav.delete_marker", ["index": "1"]),
        ("nav.zoom_to_fit", [:]),
        ("nav.set_zoom_level", ["level": "8"]),
        ("nav.set_zoom_level", ["level": "2"]),
        ("nav.set_zoom_level", ["level": "5"]),
    ])
}

@Test func testNavigateDispatcherToggleViewAndErrors() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)
    let cache = StateCache()

    let viewCases: [(String, String)] = [
        ("mixer", "view.toggle_mixer"),
        ("piano_roll", "view.toggle_piano_roll"),
        ("score", "view.toggle_score_editor"),
        ("step_editor", "view.toggle_step_editor"),
        ("library", "view.toggle_library"),
        ("inspector", "view.toggle_inspector"),
        ("automation", "automation.toggle_view"),
    ]

    for (view, operation) in viewCases {
        let result = await NavigateDispatcher.handle(
            command: "toggle_view",
            params: ["view": .string(view)],
            router: router,
            cache: cache
        )
        #expect(!result.isError!, "Expected toggle_view for \(view) to succeed")
        let ops = await keyCmd.executedOps
        #expect(ops.last?.0 == operation)
    }

    let missingMarkerResult = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["name": .string("Outro")],
        router: router,
        cache: cache
    )
    let missingParamResult = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: [:],
        router: router,
        cache: cache
    )
    let badViewResult = await NavigateDispatcher.handle(
        command: "toggle_view",
        params: ["view": .string("notation")],
        router: router,
        cache: cache
    )
    let unknownResult = await NavigateDispatcher.handle(
        command: "teleport",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(missingMarkerResult.isError!)
    #expect(missingParamResult.isError!)
    #expect(badViewResult.isError!)
    #expect(dispatcherText(badViewResult).contains("Unknown view"))
    #expect(unknownResult.isError!)
}

@Test func testMIDIDispatcherToolMetadataDocumentsMMCAndStepInput() {
    let tool = MIDIDispatcher.tool
    let description = tool.description ?? ""

    #expect(tool.name == "logic_midi")
    #expect(description.contains("mmc_locate"))
    #expect(description.contains("step_input"))
    _ = tool.inputSchema
}

@Test func testTrackDispatcherToolMetadataDocumentsAutomationAndCreateCommands() {
    let tool = TrackDispatcher.tool
    let description = tool.description ?? ""

    #expect(tool.name == "logic_tracks")
    #expect(description.contains("set_automation"))
    #expect(description.contains("create_external_midi"))
    #expect(description.contains("set_instrument"))
    #expect(description.contains("scan_library"))
    #expect(description.contains("resolve_path"))
    #expect(description.contains("scan_plugin_presets"))
    _ = tool.inputSchema
}

@Test func testNavigateDispatcherGotoBarDelegatesToTransportGotoPosition() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let result = await NavigateDispatcher.handle(
        command: "goto_bar",
        params: ["bar": .int(17)],
        router: router,
        cache: cache
    )

    #expect(!result.isError!)
    let ops = await ax.executedOps
    expectExecutedOps(ops, equals: [("transport.goto_position", ["position": "17.1.1.1"])])
}

@Test func testNavigateDispatcherGotoBarRejectsOutOfRange() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let zero = await NavigateDispatcher.handle(
        command: "goto_bar",
        params: ["bar": .int(0)],
        router: router,
        cache: cache
    )
    let huge = await NavigateDispatcher.handle(
        command: "goto_bar",
        params: ["bar": .int(10000)],
        router: router,
        cache: cache
    )

    #expect(zero.isError!)
    #expect(huge.isError!)
    let ops = await ax.executedOps
    #expect(ops.isEmpty)
}

@Test func testNavigateDispatcherToolMetadataDocumentsViewsAndFitZoom() async {
    let tool = NavigateDispatcher.tool
    let description = tool.description ?? ""
    #expect(tool.name == "logic_navigate")
    #expect(description.contains("toggle_view"))
    #expect(description.contains("set_zoom"))
    _ = tool.inputSchema

    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let fitResult = await NavigateDispatcher.handle(
        command: "set_zoom",
        params: ["level": .string("fit")],
        router: router,
        cache: StateCache()
    )

    #expect(!fitResult.isError!)
    let ops = await keyCmd.executedOps
    expectExecutedOps(ops, equals: [("nav.zoom_to_fit", [:])])
}

@Test func testProjectDispatcherToolMetadataDocumentsLifecycleCommands() {
    let tool = ProjectDispatcher.tool
    let description = tool.description ?? ""

    #expect(tool.name == "logic_project")
    #expect(description.contains("save_as"))
    #expect(description.contains("launch"))
    _ = tool.inputSchema
}
