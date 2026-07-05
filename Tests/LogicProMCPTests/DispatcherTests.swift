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

private func encodeDispatcherJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try! encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}

private func parseDispatcherObject(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

@Test func testDispatcherHumanControlErrorsUseHonestContractStateC() async {
    func expectStateC(
        _ result: CallTool.Result,
        error expectedError: String,
        operation expectedOperation: String
    ) {
        #expect(result.isError!)
        let object = parseDispatcherObject(dispatcherText(result))
        #expect(!((object?["success"] as? Bool)!))
        #expect(object?["error"] as? String == expectedError)
        #expect(object?["operation"] as? String == expectedOperation)
    }

    let router = ChannelRouter()
    let cache = StateCache()

    let missingProjectPath = await ProjectDispatcher.handle(
        command: "open",
        params: [:],
        router: router,
        cache: cache
    )
    expectStateC(missingProjectPath, error: "invalid_params", operation: "project.open")

    let unknownView = await NavigateDispatcher.handle(
        command: "toggle_view",
        params: ["view": .string("notation")],
        router: router,
        cache: cache
    )
    expectStateC(unknownView, error: "invalid_params", operation: "nav.toggle_view")

    await cache.updateTracks([TrackState(id: 0, name: "Bass", type: .audio)])
    let missingTrack = await TrackDispatcher.handle(
        command: "select",
        params: ["name": .string("vocal")],
        router: router,
        cache: cache
    )
    expectStateC(missingTrack, error: "element_not_found", operation: "track.select")

    let unsupportedMixerCommand = await MixerDispatcher.handle(
        command: "set_output",
        params: [:],
        router: router,
        cache: cache
    )
    // #202: deliberately not-exposed commands now report the distinct,
    // machine-classifiable `command_not_exposed` code (not the generic
    // `not_implemented`), so a complete-surface harness can mark them expected.
    expectStateC(unsupportedMixerCommand, error: "command_not_exposed", operation: "mixer.set_output")
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

private actor TrackArmEnvelopeChannel: Channel {
    nonisolated let id: ChannelID
    let unverifiedIndices: Set<Int>
    let failedIndices: Set<Int>

    init(
        id: ChannelID = .accessibility,
        unverifiedIndices: Set<Int> = [],
        failedIndices: Set<Int> = []
    ) {
        self.id = id
        self.unverifiedIndices = unverifiedIndices
        self.failedIndices = failedIndices
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "track.set_arm" else {
            return .success("Mock: \(operation)")
        }
        let index = Int(params["index"] ?? "") ?? -1
        let enabled = (params["enabled"] ?? "true") == "true"
        let extras: [String: Any] = [
            "track": index,
            "enabled": enabled,
            "function": "recArm",
            "verification_source": "mock_ax_readback",
        ]
        if failedIndices.contains(index) {
            return .error("Mock failure: track.set_arm \(index)")
        }
        if unverifiedIndices.contains(index) {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        return .success(HonestContract.encodeStateA(
            extras: extras.merging([
                "observed": enabled,
                "verification_source": "mock_ax_readback",
            ]) { _, new in new }
        ))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "track arm envelope channel")
    }
}

private actor UnverifiedCreateChannel: Channel {
    nonisolated let id: ChannelID

    init(id: ChannelID = .accessibility) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        if operation.hasPrefix("track.create_") {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["operation": operation, "method": "mock_keycmd"]
            ))
        }
        return .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "unverified create channel")
    }
}

private actor StaticResultChannel: Channel {
    nonisolated let id: ChannelID
    let results: [String: ChannelResult]
    let defaultResult: ChannelResult
    var executedOps: [(String, [String: String])] = []

    init(
        id: ChannelID,
        results: [String: ChannelResult],
        defaultResult: ChannelResult = .error("unexpected operation")
    ) {
        self.id = id
        self.results = results
        self.defaultResult = defaultResult
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        return results[operation] ?? defaultResult
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "static result channel")
    }
}

private actor SequencedTransportReadbackChannel: Channel {
    nonisolated let id: ChannelID
    let toggleResult: ChannelResult
    let gotoPositionResult: ChannelResult
    var transportStates: [TransportState]
    var executedOps: [(String, [String: String])] = []

    init(
        id: ChannelID = .accessibility,
        toggleResult: ChannelResult = .error("unexpected toggle"),
        gotoPositionResult: ChannelResult = .error("unexpected goto"),
        transportStates: [TransportState]
    ) {
        self.id = id
        self.toggleResult = toggleResult
        self.gotoPositionResult = gotoPositionResult
        self.transportStates = transportStates
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        switch operation {
        case "transport.toggle_metronome":
            return toggleResult
        case "transport.goto_position":
            return gotoPositionResult
        case "transport.get_state":
            guard !transportStates.isEmpty else {
                return .error("missing transport state")
            }
            let next = transportStates.removeFirst()
            return .success(encodeDispatcherJSON(next))
        default:
            return .error("unexpected operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "sequenced transport readback")
    }
}

private actor SequencedMarkersChannel: Channel {
    nonisolated let id: ChannelID
    var markerSnapshots: [[MarkerState]]
    var executedOps: [(String, [String: String])] = []

    init(id: ChannelID = .accessibility, markerSnapshots: [[MarkerState]]) {
        self.id = id
        self.markerSnapshots = markerSnapshots
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        guard operation == "nav.get_markers" else {
            return .error("unexpected operation: \(operation)")
        }
        guard !markerSnapshots.isEmpty else {
            return .error("missing marker snapshot")
        }
        let next = markerSnapshots.removeFirst()
        return .success(encodeDispatcherJSON(next))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "sequenced marker readback")
    }
}

private actor FixedResultChannel: Channel {
    nonisolated let id: ChannelID
    let result: ChannelResult
    var executedOps: [(String, [String: String])] = []

    init(id: ChannelID, result: ChannelResult) {
        self.id = id
        self.result = result
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        return result
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "fixed result")
    }
}

private actor ScriptedTransportChannel: Channel {
    nonisolated let id: ChannelID
    let results: [String: ChannelResult]
    var executedOps: [String] = []

    init(id: ChannelID, results: [String: ChannelResult]) {
        self.id = id
        self.results = results
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params _: [String: String]) async -> ChannelResult {
        executedOps.append(operation)
        return results[operation] ?? .error("unexpected operation: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "scripted transport channel")
    }
}

private func liveTransportJSON(
    isPlaying: Bool,
    isRecording: Bool,
    position: String = "1.1.1.1"
) -> String {
    """
    {"isPlaying":\(isPlaying),"isRecording":\(isRecording),"isPaused":false,"tempo":120.0,"position":"\(position)","timePosition":"00:00:00.000","sampleRate":44100,"isCycleEnabled":false,"isMetronomeEnabled":false,"lastUpdated":"2026-06-19T02:17:42.000Z"}
    """
}

// MARK: - TransportDispatcher

@Test func testTransportDispatcherRoutesPrimaryCommands() async {
    // NOTE: `pause` is intentionally absent here — it is now a verified
    // Honest-Contract command (see verifiedPauseResult / the dedicated
    // pause tests below) and can no longer succeed against a plain
    // MockChannel that does not answer transport.get_state.
    let cases: [(command: String, operation: String)] = [
        ("play", "transport.play"),
        ("record", "transport.record"),
        ("rewind", "transport.rewind"),
        ("fast_forward", "transport.fast_forward"),
        ("toggle_cycle", "transport.toggle_cycle"),
        ("toggle_metronome", "transport.toggle_metronome"),
        ("toggle_count_in", "transport.toggle_count_in"),
    ]

    for testCase in cases {
        let router = ChannelRouter()
        let channelID: ChannelID = switch testCase.operation {
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
            cache: cache,
            sleep: { _ in }
        )

        if testCase.command == "play" || testCase.command == "record" {
            #expect(result.isError!, "Expected \(testCase.command) State B to be surfaced as an error")
            #expect(dispatcherText(result).contains(#""verified":false"#))
        } else {
            #expect(!result.isError!, "Expected \(testCase.command) to succeed")
        }
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
        // v3.0.0 removed the `time` alias — callers now use the canonical `position` key
        // for both B.B.S.S and SMPTE HH:MM:SS:FF formats.
        params: ["position": .string("00:00:10:12")],
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

@Test func testTransportDispatcherRefusesWritesWhenBlockingDialogPresent() async throws {
    let router = ChannelRouter()
    let ax = FixedResultChannel(id: .accessibility, result: .success("should not execute"))
    await router.register(ax)

    let result = await TransportDispatcher.handle(
        command: "set_tempo",
        params: ["tempo": .double(78)],
        router: router,
        cache: StateCache(),
        dialogPresent: { true }
    )

    #expect(result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect(object["error"] as? String == "unsupported_state")
    #expect(object["operation"] as? String == "transport.set_tempo")
    #expect(object["failure_stage"] as? String == "preflight_blocking_dialog")
    #expect((object["blocking_dialog_present"] as? Bool)!)
    #expect(!((object["write_attempted"] as? Bool)!))

    let executed = await ax.executedOps
    #expect(executed.isEmpty)
}

@Test func testBlockingLogicDialogResultEnrichesDiagnosticWithDialogIdentity() throws {
    // #190: when a blocking dialog is identified, the refusal envelope must carry
    // its title, role, owning window, buttons, and a safe recovery action — not
    // just a generic blocking_dialog_present.
    let info = AXLogicProElements.BlockingDialogInfo(
        title: "Save",
        role: "AXDialog",
        owningWindow: "Demo - Tracks",
        buttonTitles: ["Cancel", "Save"],
        recoveryAction: "Press \"Cancel\" to dismiss this dialog, then retry."
    )

    let result = blockingLogicDialogResult(operation: "transport.play", info: info)

    #expect(result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect(object["error"] as? String == "unsupported_state")
    #expect(object["operation"] as? String == "transport.play")
    #expect(object["failure_stage"] as? String == "preflight_blocking_dialog")
    #expect((object["blocking_dialog_present"] as? Bool)!)
    #expect(object["dialog_title"] as? String == "Save")
    #expect(object["dialog_role"] as? String == "AXDialog")
    #expect(object["owning_window"] as? String == "Demo - Tracks")
    #expect((object["dialog_buttons"] as? [String])!.contains("Cancel"))
    #expect(object["recovery_action"] as? String == info.recoveryAction)
    #expect((object["hint"] as? String)!.contains("Cancel"))
}

@Test func testBlockingLogicDialogResultWithoutInfoStaysGenericButHonest() throws {
    // No identifiable dialog (probe returned nil): keep the base fail-closed
    // envelope without fabricating identity fields.
    let result = blockingLogicDialogResult(operation: "transport.play", info: nil)

    #expect(result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect(object["error"] as? String == "unsupported_state")
    #expect((object["blocking_dialog_present"] as? Bool)!)
    #expect(object["dialog_title"] == nil)
    #expect(object["dialog_role"] == nil)
    #expect(object["recovery_action"] == nil)
}

@Test func testTransportDispatcherToggleMetronomeVerifiesViaTransportStateReadback() async throws {
    let router = ChannelRouter()
    let ax = SequencedTransportReadbackChannel(
        toggleResult: .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "transport button not visible"
        )),
        transportStates: [
            TransportState(
                isMetronomeEnabled: false,
                position: "1.1.1.1",
                timePosition: "00:00:00.000",
                lastUpdated: Date()
            ),
            TransportState(
                isMetronomeEnabled: true,
                position: "1.1.1.1",
                timePosition: "00:00:00.000",
                lastUpdated: Date()
            ),
        ]
    )
    let keyCmd = StaticResultChannel(
        id: .midiKeyCommands,
        results: [
            "transport.toggle_metronome": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["method": "midi_key_command"]
            ))
        ]
    )
    await router.register(ax)
    await router.register(keyCmd)

    let result = await TransportDispatcher.handle(
        command: "toggle_metronome",
        params: [:],
        router: router,
        cache: StateCache()
    )

    #expect(!result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect((object["verified"] as? Bool)!)
    #expect(object["verification_source"] as? String == "transport_state")
    #expect(!((object["previous_enabled"] as? Bool)!))
    #expect((object["requested_enabled"] as? Bool)!)
    #expect((object["observed_enabled"] as? Bool)!)
}

@Test func testTransportDispatcherGotoPositionReturnsErrorWhenTransportReadbackDoesNotMatch() async throws {
    let router = ChannelRouter()
    let ax = SequencedTransportReadbackChannel(
        gotoPositionResult: .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["via": "dialog"]
        )),
        transportStates: [
            TransportState(
                position: "8.1.1.1",
                timePosition: "00:00:08.000",
                lastUpdated: Date()
            )
        ]
    )
    await router.register(ax)

    let result = await TransportDispatcher.handle(
        command: "goto_position",
        params: ["bar": .int(9)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect(!((object["verified"] as? Bool)!))
    #expect(object["reason"] as? String == "readback_mismatch")
    #expect(object["verification_source"] as? String == "transport_state")
    #expect(object["requested"] as? String == "9.1.1.1")
    #expect(object["observed"] as? String == "8.1.1.1")
}

@Test func testTransportDispatcherPauseReturnsStateAWhenPlaybackStops() async throws {
    // #138: pause must verify via transport readback like stop, not report
    // bare success. Routing: transport.pause -> .coreMIDI; transport.get_state
    // -> .accessibility, so the write and the readback live on separate fakes.
    let router = ChannelRouter()
    let pauseWrite = FixedResultChannel(id: .coreMIDI, result: .success("MMC pause sent"))
    let readback = SequencedTransportReadbackChannel(
        id: .accessibility,
        transportStates: [
            // before: playing -> first poll: stopped
            TransportState(isPlaying: true, position: "1.2.1.1", timePosition: "00:00:02.000", lastUpdated: Date()),
            TransportState(isPlaying: false, position: "1.2.1.1", timePosition: "00:00:02.000", lastUpdated: Date()),
        ]
    )
    await router.register(pauseWrite)
    await router.register(readback)

    let result = await TransportDispatcher.handle(
        command: "pause",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    #expect(!result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect((object["verified"] as? Bool)!)
    #expect(object["operation"] as? String == "transport.pause")
    let observedPlaying = try #require(object["observed_isPlaying"] as? Bool)
    #expect(!observedPlaying)
}

@Test func testTransportDispatcherPauseReturnsStateCWhenPlaybackContinues() async throws {
    // #138: if the playhead keeps running after the pause send, pause must
    // fail closed with State C readback_mismatch — never bare success.
    let router = ChannelRouter()
    let pauseWrite = FixedResultChannel(id: .coreMIDI, result: .success("MMC pause sent"))
    // 13 states: 1 "before" read + 12 polls, all still playing.
    let stillPlaying = Array(
        repeating: TransportState(
            isPlaying: true,
            position: "1.3.1.1",
            timePosition: "00:00:03.000",
            lastUpdated: Date()
        ),
        count: 13
    )
    let readback = SequencedTransportReadbackChannel(
        id: .accessibility,
        transportStates: stillPlaying
    )
    await router.register(pauseWrite)
    await router.register(readback)

    let result = await TransportDispatcher.handle(
        command: "pause",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    #expect(result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    // State C carries success:false + error (no `verified`/`reason` keys).
    let success = try #require(object["success"] as? Bool)
    #expect(!success)
    #expect(object["error"] as? String == "readback_mismatch")
    #expect(object["operation"] as? String == "transport.pause")
    let observedPlaying = try #require(object["observed_isPlaying"] as? Bool)
    #expect(observedPlaying)
    let safeToRetry = try #require(object["safe_to_retry"] as? Bool)
    #expect(safeToRetry)
}

@Test func testTransportDispatcherPauseReturnsStateAUnchangedWhenAlreadyStopped() async throws {
    // Idempotent early-return: already stopped means no write is attempted.
    let router = ChannelRouter()
    let pauseWrite = FixedResultChannel(id: .coreMIDI, result: .success("MMC pause sent"))
    let readback = SequencedTransportReadbackChannel(
        id: .accessibility,
        transportStates: [
            TransportState(isPlaying: false, position: "1.1.1.1", timePosition: "00:00:00.000", lastUpdated: Date())
        ]
    )
    await router.register(pauseWrite)
    await router.register(readback)

    let result = await TransportDispatcher.handle(
        command: "pause",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    #expect(!result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect((object["verified"] as? Bool)!)
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    let unchanged = try #require(object["unchanged"] as? Bool)
    #expect(unchanged)
    // No write should have been routed to the coreMIDI pause channel.
    let writeOps = await pauseWrite.executedOps
    #expect(writeOps.isEmpty)
}

@Test func testTransportDispatcherPauseReturnsStateCWhenReadbackUnavailable() async throws {
    // If no transport readback is ever available, pause must fail closed with
    // State C readback_unavailable, never bare success.
    let router = ChannelRouter()
    let pauseWrite = FixedResultChannel(id: .coreMIDI, result: .success("MMC pause sent"))
    // SequencedTransportReadbackChannel returns .error when its queue is empty,
    // so an empty queue models a transport whose state can never be read.
    let readback = SequencedTransportReadbackChannel(
        id: .accessibility,
        transportStates: []
    )
    await router.register(pauseWrite)
    await router.register(readback)

    let result = await TransportDispatcher.handle(
        command: "pause",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    #expect(result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    // State C carries success:false + error (no `verified`/`reason` keys).
    let success = try #require(object["success"] as? Bool)
    #expect(!success)
    #expect(object["error"] as? String == "readback_unavailable")
    #expect(object["operation"] as? String == "transport.pause")
}

@Test func testTransportDispatcherSetCycleRangeDocumentedUnsupported() async {
    // #138 (2): set_cycle_range stays honest fail-closed but is demoted to a
    // documented unsupported/best-effort surface in the tool description and
    // the SystemDispatcher transport help.
    let toolDescription = TransportDispatcher.tool.description ?? ""
    #expect(toolDescription.contains("set_cycle_range"))
    #expect(toolDescription.lowercased().contains("unsupported"))

    let helpResult = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("transport")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    let help = dispatcherText(helpResult)
    #expect(help.contains("set_cycle_range"))
    #expect(help.lowercased().contains("unsupported"))
}

@Test func testTransportDispatcherRejectsMissingSemanticPayloads() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let gotoResult = await TransportDispatcher.handle(
        command: "goto_position",
        params: [:],
        router: router,
        cache: StateCache()
    )
    let tempoResult = await TransportDispatcher.handle(
        command: "set_tempo",
        params: [:],
        router: router,
        cache: StateCache()
    )
    let cycleResult = await TransportDispatcher.handle(
        command: "set_cycle_range",
        params: ["start": .int(1)],
        router: router,
        cache: StateCache()
    )

    #expect(gotoResult.isError!)
    #expect(tempoResult.isError!)
    #expect(cycleResult.isError!)
    #expect(dispatcherText(gotoResult).contains("invalid_params"))
    #expect(dispatcherText(tempoResult).contains("invalid_params"))
    #expect(dispatcherText(cycleResult).contains("invalid_params"))
    let ops = await mcu.executedOps
    #expect(ops.isEmpty)
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
    let accessibility = MockChannel(id: .accessibility)
    await router.register(accessibility)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "set_volume",
        params: ["track": .int(2), "value": .double(0.7)],
        router: router, cache: cache
    )
    #expect(!result.isError!)

    let ops = await accessibility.executedOps
    #expect(ops[0].0 == "mixer.set_volume")
    #expect(ops[0].1["index"] == "2")
    #expect(ops[0].1["volume"] == "0.7")
}

// RB-1.a (2026-05-08 enterprise review): mutating mixer commands must
// reject missing/negative track index instead of falling through to track 0.
// Pre-fix the dispatchers used `intParam(default 0)` which silently routed
// `set_volume {value: 0.5}` (no track) to `index: "0"` — wrong-track mutation.
// These tests prove the new fail-closed gates and assert that the router was
// never reached on rejection.
@Test func testMixerDispatcherSetVolumeRejectsMissingTrack() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await MixerDispatcher.handle(
        command: "set_volume",
        params: ["value": .double(0.5)],
        router: router, cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("requires explicit 'track'"))
    let ops = await mcu.executedOps
    #expect(ops.isEmpty, "Router must not be invoked when target is missing")
}

@Test func testMixerDispatcherSetVolumeRejectsNegativeTrack() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await MixerDispatcher.handle(
        command: "set_volume",
        params: ["track": .int(-1), "value": .double(0.5)],
        router: router, cache: StateCache()
    )

    #expect(result.isError!)
    let ops = await mcu.executedOps
    #expect(ops.isEmpty)
}

@Test func testMixerDispatcherSetPanRejectsMissingTrack() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await MixerDispatcher.handle(
        command: "set_pan",
        params: ["value": .double(0.0)],
        router: router, cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("requires explicit 'track'"))
    let ops = await mcu.executedOps
    #expect(ops.isEmpty)
}

@Test func testMixerDispatcherSetPluginParamRejectsMissingTargets() async {
    let router = ChannelRouter()
    let scripter = MockChannel(id: .scripter)
    await router.register(scripter)

    // Missing track
    let noTrack = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["insert": .int(0), "param": .int(0), "value": .double(0.5)],
        router: router, cache: StateCache()
    )
    #expect(noTrack.isError!)
    #expect(dispatcherText(noTrack).contains("requires explicit 'track'"))

    // Missing insert
    let noInsert = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(0), "param": .int(0), "value": .double(0.5)],
        router: router, cache: StateCache()
    )
    #expect(noInsert.isError!)
    #expect(dispatcherText(noInsert).contains("requires explicit 'insert'"))

    // Missing param
    let noParam = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(0), "insert": .int(0), "value": .double(0.5)],
        router: router, cache: StateCache()
    )
    #expect(noParam.isError!)
    #expect(dispatcherText(noParam).contains("requires explicit 'param'"))

    // Missing value
    let noValue = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(0), "insert": .int(0), "param": .int(0)],
        router: router, cache: StateCache()
    )
    #expect(noValue.isError!)
    // Phase 6 P1: message tightened to require a *numeric* value (strict parse
    // before the track.select side effect).
    #expect(dispatcherText(noValue).contains("requires explicit numeric 'value'"))

    let ops = await scripter.executedOps
    #expect(ops.isEmpty, "Router must not be invoked for any missing-target case")
}

@Test func testMixerDispatcherSetPluginParam() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
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

    let axOps = await ax.executedOps
    expectExecutedOps(axOps, equals: [
        ("mixer.set_pan", ["index": "4", "pan": "-0.25"]),
    ])

    let mcuOps = await mcu.executedOps
    expectExecutedOps(mcuOps, equals: [
        ("mixer.set_master_volume", ["volume": "0.82"]),
    ])
}

@Test func testMixerDispatcherInsertPluginRequiresConfirmation() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "insert_plugin",
        params: ["track": .int(7), "slot": .int(2), "plugin_name": .string("Gain")],
        router: router,
        cache: cache
    )

    let resultIsError = result.isError ?? false
    #expect(!resultIsError)
    if case .text(let text, _, _) = result.content.first {
        #expect(text.contains("\"confirmation_required\""))
        #expect(text.contains("\"command\":\"insert_plugin\""))
        #expect(text.contains("\"level\":\"L2\""))
    } else {
        Issue.record("Expected confirmation_required text for insert_plugin")
    }
    let axOps = await ax.executedOps
    #expect(axOps.isEmpty)
}

@Test func testMixerDispatcherInsertPluginRejectsUnsupportedPluginBeforeRoute() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "insert_plugin",
        params: [
            "track": .int(7),
            "slot": .int(2),
            "plugin_name": .string("Some Third Party Plugin"),
            "confirmed": .bool(true),
        ],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
    if case .text(let text, _, _) = result.content.first {
        #expect(text.contains("unsupported plugin"))
        #expect(text.contains("Gain"))
    } else {
        Issue.record("Expected unsupported plugin error text")
    }
    let axOps = await ax.executedOps
    #expect(axOps.isEmpty)
}

@Test func testMixerDispatcherInsertPluginRoutesConfirmedAllowlistedPluginToAX() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    let mcu = MockChannel(id: .mcu)
    await router.register(ax)
    await router.register(mcu)
    let cache = StateCache()

    let insertResult = await MixerDispatcher.handle(
        command: "insert_plugin",
        params: [
            "track_index": .int(7),
            "slot": .int(2),
            "plugin_name": .string("Gain"),
            "confirmed": .bool(true),
        ],
        router: router,
        cache: cache
    )

    let insertResultIsError = insertResult.isError ?? false
    #expect(!insertResultIsError)
    let axOps = await ax.executedOps
    let mcuOps = await mcu.executedOps
    expectExecutedOps(axOps, equals: [
        ("plugin.insert", ["plugin_name": "Gain", "slot": "2", "track": "7"]),
    ])
    #expect(mcuOps.isEmpty)
}

@Test func testMixerDispatcherBypassPluginRemainsNotExposed() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "bypass_plugin",
        params: ["track": .int(7), "slot": .int(2), "bypassed": .bool(false)],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
    let axOps = await ax.executedOps
    #expect(axOps.isEmpty)
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
    #expect(missingPathResult.isError!)
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

@Test func testTrackDispatcherScanLibraryForwardsModeParam() async {
    // v3.0.7 regression: dispatcher dropped `mode` on the floor, making
    // {mode:"disk"} fell back to the default scanner. Lock the forward path.
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let diskResult = await TrackDispatcher.handle(
        command: "scan_library",
        params: ["mode": .string("disk")],
        router: router,
        cache: cache
    )
    let bothResult = await TrackDispatcher.handle(
        command: "scan_library",
        params: ["mode": .string("both")],
        router: router,
        cache: cache
    )
    let mixedCaseResult = await TrackDispatcher.handle(
        command: "scan_library",
        params: ["mode": .string("AX")],
        router: router,
        cache: cache
    )
    let defaultResult = await TrackDispatcher.handle(
        command: "scan_library",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(!diskResult.isError!)
    #expect(!bothResult.isError!)
    #expect(!mixedCaseResult.isError!)
    #expect(!defaultResult.isError!)

    let ops = await ax.executedOps
    expectExecutedOps(ops, equals: [
        ("library.scan_all", ["mode": "disk"]),
        ("library.scan_all", ["mode": "both"]),
        ("library.scan_all", ["mode": "ax"]),
        ("library.scan_all", [:]),
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

@Test func testTrackDispatcherCreateCommandsReturnErrorForUnverifiedEnvelope() async {
    let router = ChannelRouter()
    let ax = UnverifiedCreateChannel()
    await router.register(ax)
    let cache = StateCache()

    for command in ["create_audio", "create_instrument", "create_drummer", "create_external_midi"] {
        let result = await TrackDispatcher.handle(command: command, params: [:], router: router, cache: cache)
        let text = dispatcherText(result)
        #expect(result.isError!, "Expected \(command) to surface outer error for State B")
        #expect(text.contains("\"verified\":false"))
        #expect(text.contains("\"reason\":\"readback_unavailable\""))
    }
}

@Test func testTrackDispatcherRenameTreatsStateBAsError() async {
    let router = ChannelRouter()
    let ax = FixedResultChannel(
        id: .accessibility,
        result: .success("""
        {"success":true,"verified":false,"reason":"readback_mismatch","track":0,"requested":"Bass","observed":"Deluxe Classic"}
        """)
    )
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "rename",
        params: ["index": .int(0), "name": .string("Bass")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("\"verified\":false"))
    let ops = await ax.executedOps
    expectExecutedOps(ops, equals: [("track.rename", ["index": "0", "name": "Bass"])])
}

@Test func testTrackDispatcherDeleteAndDuplicateRespectSelectionFlow() async {
    // v3.1.2 P1-5 — `track.delete` requires that the preceding
    // `track.select` returns a State A envelope (`verified:true`).
    // RB-1.c (2026-05-08 enterprise review) — `track.duplicate` now
    // enforces the same State-A gate so duplicating an unverified target
    // can't silently duplicate a different track. Both ops therefore need
    // the envelope-returning `VerifiedSelectMockChannel` for the MCU
    // (track.select routes to MCU per the routing table); the generic
    // `MockChannel` returns plain `"Mock: track.select"` which is now
    // intentionally rejected by both gates.
    let successRouter = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
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

/// Mock channel that returns a State A envelope (`success:true`,
/// `verified:true`) for `track.select` so the v3.1.2 P1-5 gate in
/// `TrackDispatcher.delete` accepts the selection. All other operations
/// fall through to the generic `"Mock: <op>"` reply, matching `MockChannel`.
actor VerifiedSelectMockChannel: Channel {
    nonisolated let id: ChannelID
    var executedOps: [(String, [String: String])] = []

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        if operation == "track.select" {
            let extras: [String: Any] = [
                "requested": Int(params["index"] ?? "0") ?? 0,
                "observed": Int(params["index"] ?? "0") ?? 0,
            ]
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        return .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "verified select mock")
    }
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

// MARK: - Explicit-index hardening (v2.4.0+)
// Every mutating track command must reject requests missing `index` — the
// old behavior silently defaulted to track 0, corrupting the wrong track on
// malformed calls.

@Test func testTrackDispatcherDeleteRequiresExplicitIndex() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: [:],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("explicit 'index'"))
    #expect(await keyCmd.executedOps.isEmpty)
}

@Test func testTrackDispatcherDuplicateRequiresExplicitIndex() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "duplicate",
        params: [:],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("explicit 'index'"))
    #expect(await keyCmd.executedOps.isEmpty)
}

@Test func testTrackDispatcherMuteRequiresExplicitIndex() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await TrackDispatcher.handle(
        command: "mute",
        params: ["enabled": .bool(true)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("explicit 'index'"))
    #expect(await mcu.executedOps.isEmpty)
}

@Test func testTrackDispatcherRenameRequiresExplicitIndex() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "rename",
        params: ["name": .string("New Name")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("explicit 'index'"))
    #expect(await ax.executedOps.isEmpty)
}

@Test func testTrackDispatcherRenameRejectsExcessiveNameBeforeRouting() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "rename",
        params: ["index": .int(0), "name": .string(String(repeating: "A", count: 129))],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("128 characters or fewer"))
    #expect(await ax.executedOps.isEmpty)
}

@Test func testTrackDispatcherSetAutomationRequiresExplicitIndex() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await TrackDispatcher.handle(
        command: "set_automation",
        params: ["mode": .string("touch")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("explicit 'index'"))
    #expect(await mcu.executedOps.isEmpty)
}

@Test func testTrackDispatcherSetInstrumentRequiresExplicitIndex() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "set_instrument",
        params: ["path": .string("Bass/Retro Crunch")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("explicit 'index'"))
    #expect(await ax.executedOps.isEmpty)
}

@Test func testTrackDispatcherSetInstrumentRequiresPathOrCategoryAndPreset() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "set_instrument",
        params: ["index": .int(0)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("path") || dispatcherText(result).contains("preset"))
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

/// Mock channel that records the operations it sees. v3.1.2 P0-2 moved
/// record_sequence's verification from `cache.getTracks().count` (3-second
/// poll lag) to `AXLogicProElements.allTrackHeaders().count` (live read), so
/// inserting tracks into the cache no longer satisfies verification — the
/// previous `TrackInsertingMockChannel` was renamed and gutted accordingly.
private actor TrackInsertingMockChannel: Channel {
    nonisolated let id: ChannelID
    let cache: StateCache
    var executedOps: [(String, [String: String])] = []

    init(id: ChannelID, cache: StateCache) {
        self.id = id
        self.cache = cache
    }

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "insert mock") }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        return .success("Mock: \(operation)")
    }
}

@Test func testRecordSequenceSMFImportRoutingSequence() async {
    let router = ChannelRouter()
    let cache = StateCache()
    await cache.updateDocumentState(true)
    let ax = TrackInsertingMockChannel(id: .accessibility, cache: cache)
    await router.register(ax)
    final class HeaderCountSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [1, 2]

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            if values.count <= 1 { return values.first ?? 2 }
            return values.removeFirst()
        }
    }
    final class RegionSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func next() -> TrackDispatcher.RecordSequenceRegionReadback {
            lock.lock()
            defer {
                calls += 1
                lock.unlock()
            }
            if calls == 0 {
                return .success([])
            }
            return .success([
                RegionInfo(
                    name: "Imported MIDI",
                    trackIndex: 1,
                    startBar: 1,
                    endBar: 6,
                    kind: "midi",
                    rawHelp: nil
                )
            ])
        }
    }
    let headerCounts = HeaderCountSequence()
    let regions = RegionSequence()

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["bar": .int(5), "notes": .string("60,0,480;64,500,480;67,1000,480"), "tempo": .double(120)],
        router: router,
        cache: cache,
        trackHeaderCount: { headerCounts.next() },
        trackNameAt: { $0 == 1 ? "Imported MIDI Track" : nil },
        readRegions: { regions.next() },
        settleReadback: {}
    )

    let text = dispatcherText(result)
    #expect(!result.isError!, "expected deterministic verified import, got: \(text)")
    #expect(text.contains("\"success\":true"), "expected State A success, got: \(text)")

    // Verify routing sequence regardless of verification outcome.
    let ops = await ax.executedOps
    let importOps = ops.filter { $0.0 == "midi.import_file" }
    #expect(importOps.count == 1, "expected 1 midi.import_file call, got \(importOps.count)")
    #expect((importOps[0].1["path"]?.hasPrefix(SMFWriter.temporaryDirectoryPrefix()))!)

    // Playhead must be reset to bar 1 BEFORE import (otherwise Logic anchors
    // the region at the current playhead, defeating bar positioning).
    let gotoOps = ops.filter { $0.0 == "transport.goto_position" && $0.1["bar"] == "1" }
    #expect(gotoOps.count == 1, "expected transport.goto_position with bar=1 before import")
    let gotoIndex = ops.firstIndex { $0.0 == "transport.goto_position" } ?? -1
    let importIndex = ops.firstIndex { $0.0 == "midi.import_file" } ?? -1
    #expect(gotoIndex >= 0 && importIndex >= 0 && gotoIndex < importIndex,
            "goto_position must be routed BEFORE midi.import_file")
}

@Test func testRecordSequenceFailsOnGotoPositionError() async {
    // If pre-import playhead reset fails, the import would land at the wrong
    // bar. Treat goto failure as a hard stop.
    let router = ChannelRouter()
    let ax = FailingExecuteChannel(id: .accessibility, message: "goto clamped")
    await router.register(ax)
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let result = await TrackDispatcher.handle(
        command: "record_sequence",
        params: ["bar": .int(5), "notes": .string("60,0,480"), "tempo": .double(120)],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("playhead"))
}

@Test func testRecordSequenceFailsWhenTrackDoesNotAppear() async {
    // v3.1.2 P0-2 — if live AX shows no new track header after import claims
    // success, we must surface that as a verification failure rather than
    // fabricate a `created_track` index. (Pre-v3.1.2 this used the cache
    // poll loop with the misleading "never appeared" wording — see CHANGELOG
    // for why that path was wrong.)
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)  // returns success without touching AX
    await router.register(ax)
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["bar": .int(1), "notes": .string("60,0,480"), "tempo": .double(120)],
        router: router,
        cache: cache,
        trackHeaderCount: { 1 },
        trackNameAt: { _ in nil },
        readRegions: { .success([]) },
        settleReadback: {}
    )

    #expect(result.isError!)
    let text = dispatcherText(result)
    #expect(
        text.contains("live AX still shows"),
        "expected new live-AX failure wording, got: \(text)"
    )
}

@Test func testRecordSequenceCleansUpTempFileOnError() async {
    let router = ChannelRouter()
    // Let the required playhead reset succeed, then fail the import path so
    // this test verifies cleanup for the exact SMF file handed to import.
    let ax = SelectiveFailChannel(id: .accessibility, failOperations: ["midi.import_file"])
    await router.register(ax)
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["index": .int(0), "bar": .int(1), "notes": .string("60,0,480"), "tempo": .double(120)],
        router: router,
        cache: cache,
        trackHeaderCount: { 1 },
        trackNameAt: { _ in nil },
        readRegions: { .success([]) },
        settleReadback: {}
    )

    #expect(result.isError!)
    let ops = await ax.executedOps
    let importOps = ops.filter { $0.0 == "midi.import_file" }
    #expect(importOps.count == 1, "expected one midi.import_file call, got \(importOps.count)")
    let importedPath = importOps.first?.1["path"] ?? ""
    #expect(importedPath.hasPrefix(SMFWriter.temporaryDirectoryPrefix()))
    #expect(importedPath.hasSuffix(".mid"))
    #expect(
        !FileManager.default.fileExists(atPath: importedPath),
        "record_sequence must remove its own SMF temp file after import failure: \(importedPath)"
    )
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

@Test func testArmOnlyReportsPartialDisarmFailureAsError() async {
    // All channels fail for track.set_arm → both disarm of track 0 AND arm of
    // track 1 fail. The dispatcher must surface this as an error, not a
    // structured success payload that buries the failure in `failedDisarm`.
    let router = ChannelRouter()
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

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("arm_only failed"))
}

@Test func testArmOnlyRequiresExplicitIndex() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()

    let result = await TrackDispatcher.handle(
        command: "arm_only",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("explicit 'index'"))
}

@Test func testArmOnlySuccessPathReportsArmedSuccess() async {
    let router = ChannelRouter()
    let ax = TrackArmEnvelopeChannel()
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
    #expect(text.contains("\"verified\":true"))
    #expect(text.contains("\"requested_enabled\":true"))
    #expect(text.contains("\"observed_enabled\":true"))
    #expect(text.contains("\"verification_source\":\"mock_ax_readback\""))
}

@Test func testArmReturnsErrorForUnverifiedEnvelope() async {
    let router = ChannelRouter()
    let ax = TrackArmEnvelopeChannel(unverifiedIndices: [5])
    await router.register(ax)
    let cache = StateCache()

    let result = await TrackDispatcher.handle(
        command: "arm",
        params: ["index": .int(5), "enabled": .bool(true)],
        router: router,
        cache: cache
    )

    let text = dispatcherText(result)
    #expect(result.isError!)
    #expect(text.contains("\"verified\":false"))
    #expect(text.contains("\"reason\":\"readback_unavailable\""))
    #expect(text.contains("\"verification_source\":\"mock_ax_readback\""))
}

@Test func testArmOnlyTreatsUnverifiedTargetArmAsError() async {
    let router = ChannelRouter()
    let ax = TrackArmEnvelopeChannel(unverifiedIndices: [1])
    await router.register(ax)
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 1, name: "Target", type: .softwareInstrument),
    ])

    let result = await TrackDispatcher.handle(
        command: "arm_only",
        params: ["index": .int(1)],
        router: router,
        cache: cache
    )

    let text = dispatcherText(result)
    #expect(result.isError!)
    #expect(text.contains("\"armedSuccess\":false"))
    #expect(text.contains("\"verified\":false"))
    #expect(text.contains("\"unverifiedDisarm\":[]"))
    #expect(text.contains("\"requested_enabled\":true"))
    #expect(text.contains("\"observed_enabled\":null"))
    #expect(text.contains("\"verification_source\":\"mock_ax_readback\""))
}

@Test func testArmOnlyTreatsUnverifiedDisarmAsError() async {
    let router = ChannelRouter()
    let ax = TrackArmEnvelopeChannel(unverifiedIndices: [0])
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
    #expect(result.isError!)
    #expect(text.contains("\"armed\":1"))
    #expect(text.contains("\"unverifiedDisarm\":[0]"))
    #expect(text.contains("\"verified\":false"))
    #expect(text.contains("\"requested_enabled\":true"))
    #expect(text.contains("\"observed_enabled\":true"))
    #expect(text.contains("\"verification_source\":\"mock_ax_readback\""))
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

@Test func testEditDispatcherQuantizeRequiresExplicitGrid() async {
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

    let missingRouter = ChannelRouter()
    let missingKeyCmd = MockChannel(id: .midiKeyCommands)
    await missingRouter.register(missingKeyCmd)
    let missingCache = StateCache()

    let missingResult = await EditDispatcher.handle(
        command: "quantize",
        params: [:],
        router: missingRouter,
        cache: missingCache
    )

    #expect(missingResult.isError!)
    #expect(dispatcherText(missingResult).contains("invalid_params"))
    #expect(await missingKeyCmd.executedOps.isEmpty)
}

@Test func testEditDispatcherTreatsUnverifiedStateBAsError() async {
    let router = ChannelRouter()
    let keyCmd = StaticResultChannel(
        id: .midiKeyCommands,
        results: [
            "edit.select_all": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["method": "midi_key_command"]
            )),
            "edit.quantize": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["method": "midi_key_command"]
            )),
        ]
    )
    await router.register(keyCmd)
    let cache = StateCache()

    let selectAllResult = await EditDispatcher.handle(
        command: "select_all",
        params: [:],
        router: router,
        cache: cache
    )
    let quantizeResult = await EditDispatcher.handle(
        command: "quantize",
        params: ["value": .string("1/16")],
        router: router,
        cache: cache
    )

    #expect(selectAllResult.isError!)
    #expect(quantizeResult.isError!)
    #expect(dispatcherText(selectAllResult).contains("\"verified\":false"))
    #expect(dispatcherText(quantizeResult).contains("\"verified\":false"))
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

@Test func testProjectDispatcherBounceBlocksExternalMIDIBeforeRouting() async throws {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 0, name: "GM Device 1", type: .externalMIDI),
    ])
    await cache.updateRegions([
        RegionState(
            id: "0:1:5:Lead",
            name: "Lead",
            trackIndex: 0,
            startPosition: "1 1 1 1",
            endPosition: "5 1 1 1",
            length: "4 0 0 0"
        ),
    ])

    let result = await ProjectDispatcher.handle(
        command: "bounce",
        params: ["confirmed": .bool(true)],
        router: router,
        cache: cache
    )

    let isError = try #require(result.isError)
    #expect(isError)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect(!((object["success"] as? Bool)!))
    #expect(object["error"] as? String == "export_readiness_blocked")
    #expect(object["failure_stage"] as? String == "pre_bounce_audit")
    #expect(((object["blockers"] as? [String])?.contains("external_midi_regions_bounce_risk"))!)

    let routedOps = await keyCmd.executedOps
    #expect(routedOps.isEmpty)
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
    #expect(invalidResult.isError!)

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
    let traversalSaveAsResult = await ProjectDispatcher.handle(
        command: "save_as",
        params: ["path": .string("/tmp/project/../escape.logicx")],
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
    #expect(traversalSaveAsResult.isError!)
    #expect(dispatcherText(traversalSaveAsResult).contains("absolute .logicx"))
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
    #expect(!(execution.timedOut))
    #expect(execution.terminationStatus == 0)
    #expect(execution.stderrOutput.isEmpty)
}

@Test func testProjectDispatcherExecuteAppleScriptCapturesInvalidScriptFailure() async {
    let execution = await ProjectDispatcher.executeAppleScript("this is not valid AppleScript")

    #expect(execution.executionError == nil)
    #expect(!(execution.timedOut))
    #expect(execution.terminationStatus != 0)
    #expect(!execution.stderrOutput.isEmpty)
}

@Test func testProjectDispatcherExecuteAppleScriptSurfacesProcessLaunchFailure() async {
    let execution = await ProjectDispatcher.executeAppleScript(
        "return 1",
        executableURL: URL(fileURLWithPath: "/tmp/logic-pro-mcp-missing-osascript")
    )

    #expect(execution.executionError != nil)
    #expect(!(execution.timedOut))
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
        params: ["value": .int(7_680), "channel": .int(5)],
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
    // T5 (PRD Issue#1): channel inputs are 1-based; the dispatcher now
    // encodes them to wire byte (ch-1) before forwarding to the channel,
    // unifying the previously-divergent send_cc / send_program_change /
    // send_pitch_bend / send_aftertouch paths that used to hand the raw
    // 1-based int through (silent UInt8 corruption on out-of-range input).
    expectExecutedOps(ops, equals: [
        ("midi.send_note", ["note": "64", "velocity": "90", "channel": "1", "duration_ms": "750"]),
        ("midi.send_cc", ["controller": "74", "value": "127", "channel": "2"]),
        ("midi.send_program_change", ["program": "8", "channel": "3"]),
        ("midi.send_pitch_bend", ["value": "7680", "channel": "4"]),
        ("midi.send_aftertouch", ["value": "55", "channel": "5"]),
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
    // T5: send_chord channel is 1-based on input; wire byte = ch-1.
    // Both calls omit `channel` so they default to ch 1 → wire 0.
    expectExecutedOps(coreOps, equals: [
        ("midi.send_chord", ["notes": "60,64,67", "velocity": "80", "channel": "0", "duration_ms": "500"]),
        ("midi.send_chord", ["notes": "72,76,79", "velocity": "100", "channel": "0", "duration_ms": "500"]),
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

@Test func testMIDIDispatcherRejectsOversizedSysexBeforeRouting() async {
    let router = ChannelRouter()
    let coreMidi = MockChannel(id: .coreMIDI)
    await router.register(coreMidi)

    let oversizedArray = [Value.int(0xF0)] + Array(repeating: Value.int(0x7D), count: 1023) + [.int(0xF7)]
    let arrayResult = await MIDIDispatcher.handle(
        command: "send_sysex",
        params: ["bytes": .array(oversizedArray)],
        router: router,
        cache: StateCache()
    )

    let oversizedText = "F0 " + Array(repeating: "7D", count: 1023).joined(separator: " ") + " F7"
    let textResult = await MIDIDispatcher.handle(
        command: "send_sysex",
        params: ["data": .string(oversizedText)],
        router: router,
        cache: StateCache()
    )

    #expect(arrayResult.isError!)
    #expect(textResult.isError!)
    #expect(dispatcherText(arrayResult).contains("1024-byte limit"))
    #expect(dispatcherText(textResult).contains("1024-byte limit"))
    #expect(await coreMidi.executedOps.isEmpty)
}

@Test func testMIDIDispatcherRoutesImportFileCommand() async throws {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let tempFile = try SMFWriter.temporaryMIDIFile()
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile.fileURL)
    defer { SMFWriter.cleanupTemporaryMIDIFile(tempFile) }
    let expectedPath = tempFile.fileURL.resolvingSymlinksInPath().standardizedFileURL.path

    let result = await MIDIDispatcher.handle(
        command: "import_file",
        params: ["path": .string(tempFile.fileURL.path)],
        router: router,
        cache: StateCache()
    )

    let resultIsError = result.isError ?? false
    #expect(!resultIsError)
    expectExecutedOps(await ax.executedOps, equals: [
        ("midi.import_file", ["path": expectedPath]),
    ])
}

@Test func testMIDIDispatcherRejectsLegacyFixedTmpImportFileCommand() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await MIDIDispatcher.handle(
        command: "import_file",
        params: ["path": .string("/private/tmp/LogicProMCP/acid.mid")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("server-managed LogicProMCP temp .mid"))
    #expect(await ax.executedOps.isEmpty)
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
        // v3.1.10 (boomer P1-1) — both index- and name-based goto_marker
        // now resolve from cache and route via transport.goto_position
        // using the marker's `position` string (chorus at 17.1.1.1).
        ("transport.goto_position", ["position": "17.1.1.1"]),
        ("transport.goto_position", ["position": "17.1.1.1"]),
        // AC5 — create_marker now pre-polls the marker list (nav.get_markers)
        // BEFORE the mutating route so its count-delta verify has a true
        // pre-mutation baseline. Test scenario unchanged; only this expected
        // op-list entry was stale.
        ("nav.get_markers", [:]),
        ("nav.rename_marker", ["index": "2", "name": "Big Chorus"]),
        // #109 — set_zoom is now AX-first (writable Horizontal-Zoom slider);
        // zoom_to_fit stays on the key-command path (no slider equivalent).
        ("nav.set_zoom_level", ["level": "8"]),
        ("nav.set_zoom_level", ["level": "2"]),
        ("nav.set_zoom_level", ["level": "5"]),
    ])
    expectExecutedOps(keyCmdOps, equals: [
        // v3.1.10 — `nav.goto_marker` keycmd path is reserved for the
        // cold-cache fallback (cache empty, index supplied). Cached path
        // routes to AX `transport.goto_position` (see axOps above).
        ("nav.create_marker", ["name": "Bridge"]),
        ("nav.delete_marker", ["index": "1"]),
        ("nav.zoom_to_fit", [:]),
    ])
}

@Test func testNavigateDispatcherGotoBarUsesTransportStateReadbackVerification() async throws {
    let router = ChannelRouter()
    let ax = SequencedTransportReadbackChannel(
        gotoPositionResult: .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["via": "dialog"]
        )),
        transportStates: [
            TransportState(
                position: "17.1.1.1",
                timePosition: "00:00:17.000",
                lastUpdated: Date()
            )
        ]
    )
    await router.register(ax)

    let result = await NavigateDispatcher.handle(
        command: "goto_bar",
        params: ["bar": .int(17)],
        router: router,
        cache: StateCache()
    )

    #expect(!result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect((object["verified"] as? Bool)!)
    #expect(object["verification_source"] as? String == "transport_state")
    #expect(object["observed"] as? String == "17.1.1.1")
}

@Test func testNavigateDispatcherCreateMarkerVerifiesViaMarkerReadback() async throws {
    let router = ChannelRouter()
    let markersAX = SequencedMarkersChannel(markerSnapshots: [
        [MarkerState(id: 0, name: "Intro", position: "1.1.1.1", positionSource: .parser)],
        [
            MarkerState(id: 0, name: "Intro", position: "1.1.1.1", positionSource: .parser),
            MarkerState(id: 1, name: "Marker 1", position: "9.1.1.1", positionSource: .parser),
        ],
    ])
    let keyCmd = StaticResultChannel(
        id: .midiKeyCommands,
        results: [
            "nav.create_marker": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["method": "midi_key_command"]
            ))
        ]
    )
    await router.register(markersAX)
    await router.register(keyCmd)
    let cache = StateCache()

    let result = await NavigateDispatcher.handle(
        command: "create_marker",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(!result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect((object["verified"] as? Bool)!)
    #expect(object["verification_source"] as? String == "logic://markers")
    #expect(object["marker_count_before"] as? Int == 1)
    #expect(object["marker_count_after"] as? Int == 2)
    #expect(object["observed_marker_name"] as? String == "Marker 1")
    #expect(await cache.getMarkers().count == 2)
}

@Test func testNavigateDispatcherCreateMarkerReturnsErrorWhenObservedNameDoesNotMatch() async throws {
    let router = ChannelRouter()
    let markersAX = SequencedMarkersChannel(markerSnapshots: [
        [MarkerState(id: 0, name: "Intro", position: "1.1.1.1", positionSource: .parser)],
        [
            MarkerState(id: 0, name: "Intro", position: "1.1.1.1", positionSource: .parser),
            MarkerState(id: 1, name: "Marker 2", position: "9.1.1.1", positionSource: .parser),
        ],
    ])
    let keyCmd = StaticResultChannel(
        id: .midiKeyCommands,
        results: [
            "nav.create_marker": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["method": "midi_key_command"]
            ))
        ]
    )
    await router.register(markersAX)
    await router.register(keyCmd)

    let result = await NavigateDispatcher.handle(
        command: "create_marker",
        params: ["name": .string("Bridge")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    let object = try #require(parseDispatcherObject(dispatcherText(result)))
    #expect(!((object["verified"] as? Bool)!))
    #expect(object["reason"] as? String == "readback_mismatch")
    #expect(object["requested_name"] as? String == "Bridge")
    #expect(object["observed_marker_name"] as? String == "Marker 2")
}

@Test func testNavigateDispatcherZoomCommandsTreatUnverifiedStateBAsError() async {
    let router = ChannelRouter()
    let keyCmd = StaticResultChannel(
        id: .midiKeyCommands,
        results: [
            "nav.zoom_to_fit": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["method": "midi_key_command"]
            )),
            "nav.set_zoom_level": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["method": "midi_key_command"]
            )),
        ]
    )
    await router.register(keyCmd)
    let cache = StateCache()

    let fitResult = await NavigateDispatcher.handle(
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

    #expect(fitResult.isError!)
    #expect(zoomInResult.isError!)
    #expect(dispatcherText(fitResult).contains("\"verified\":false"))
    #expect(dispatcherText(zoomInResult).contains("\"verified\":false"))
}

// RB-1.b (2026-05-08 enterprise review): pre-fix `delete_marker` and
// `rename_marker` defaulted the missing `index` to 0, so `delete_marker {}`
// silently deleted the first marker. Marker writes are not undoable in the
// same project session, so missing target now fails closed. `rename_marker`
// also rejects empty `name` to avoid blank-label overwrites.
@Test func testNavigateDispatcherDeleteMarkerRejectsMissingIndex() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    let cgEvent = MockChannel(id: .cgEvent)
    await router.register(keyCmd)
    await router.register(cgEvent)

    let result = await NavigateDispatcher.handle(
        command: "delete_marker",
        params: [:],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("requires explicit 'index'"))
    let keyCmdOps = await keyCmd.executedOps
    let cgEventOps = await cgEvent.executedOps
    #expect(keyCmdOps.isEmpty, "Router must not be invoked when target is missing")
    #expect(cgEventOps.isEmpty)
}

@Test func testNavigateDispatcherZoomAndViewRejectMissingSemanticPayloads() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)
    let cache = StateCache()

    let zoomResult = await NavigateDispatcher.handle(
        command: "set_zoom",
        params: [:],
        router: router,
        cache: cache
    )
    let viewResult = await NavigateDispatcher.handle(
        command: "toggle_view",
        params: [:],
        router: router,
        cache: cache
    )

    #expect(zoomResult.isError!)
    #expect(viewResult.isError!)
    #expect(dispatcherText(zoomResult).contains("invalid_params"))
    #expect(dispatcherText(viewResult).contains("invalid_params"))
    #expect(await keyCmd.executedOps.isEmpty)
}

@Test func testNavigateDispatcherDeleteMarkerRejectsNegativeIndex() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let result = await NavigateDispatcher.handle(
        command: "delete_marker",
        params: ["index": .int(-1)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    let ops = await keyCmd.executedOps
    #expect(ops.isEmpty)
}

@Test func testNavigateDispatcherRenameMarkerRejectsMissingIndex() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await NavigateDispatcher.handle(
        command: "rename_marker",
        params: ["name": .string("New name")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("requires explicit 'index'"))
    let ops = await ax.executedOps
    #expect(ops.isEmpty)
}

@Test func testNavigateDispatcherRenameMarkerRejectsEmptyName() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await NavigateDispatcher.handle(
        command: "rename_marker",
        params: ["index": .int(2)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(dispatcherText(result).contains("non-empty 'name'"))
    let ops = await ax.executedOps
    #expect(ops.isEmpty, "Empty rename must not reach the router")
}

// Issue #143 — end-to-end through the REAL AccessibilityChannel: a valid
// rename_marker request (index + non-empty name) must fail closed with a
// typed State C `not_implemented` envelope and a create+delete workaround
// hint, NOT the previous `channels_exhausted` aggregate. `nav.rename_marker`
// short-circuits inside the channel switch (never touches the AX tree), so a
// minimal trusted/Logic-running runtime reaches the not-implemented branch.
@Test func testNavigateDispatcherRenameMarkerReturnsNotImplementedEndToEnd() async {
    let router = ChannelRouter()
    // CI runs with no Logic Pro process, so the real appRoot resolver returns
    // nil and `healthCheck` reports the channel unavailable → the router skips
    // it and the end-to-end result is `channels_exhausted`, not the typed
    // `not_implemented` this test asserts. Inject a fake PID so healthCheck's
    // appRoot smoke test passes deterministically; `nav.rename_marker`
    // short-circuits to State C before any live AX call, so no real Logic is
    // needed for the routing assertion.
    await router.register(AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: AXLogicProElements.Runtime(logicProPID: { 4242 }, ax: .production)
    )))

    let result = await NavigateDispatcher.handle(
        command: "rename_marker",
        params: ["index": .int(2), "name": .string("Big Chorus")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    let text = dispatcherText(result)
    let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "not_implemented")
    #expect((obj["error"] as? String) != "channels_exhausted")
    let hint = obj["hint"] as? String ?? ""
    #expect(hint.contains("delete_marker") && hint.contains("create_marker"),
            "expected create+delete workaround hint, got: \(hint)")
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
    #expect(description.contains("export_plan"))
    _ = tool.inputSchema
}


// MARK: - #48 transport play/record/stop verified action tests (PR #85)

private actor TransportStateSequenceChannel: Channel {
    nonisolated let id: ChannelID
    private var states: [String]
    private let mutationResults: [String: ChannelResult]
    private(set) var executedOps: [(String, [String: String])] = []

    init(id: ChannelID, states: [String], mutationResults: [String: ChannelResult]) {
        self.id = id
        self.states = states
        self.mutationResults = mutationResults
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        if operation == "transport.get_state" {
            guard !states.isEmpty else { return .error("transport state unavailable") }
            let next = states.count > 1 ? states.removeFirst() : states[0]
            return .success(next)
        }
        return mutationResults[operation] ?? .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "transport sequence")
    }
}

@Test func testTransportDispatcherPlayFallsBackAndReturnsVerifiedStateA() async {
    let router = ChannelRouter()
    let ax = TransportStateSequenceChannel(
        id: .accessibility,
        states: [
            #"{"isPlaying":false,"isRecording":false,"position":"1.1.1.1","tempo":120}"#,
            #"{"isPlaying":true,"isRecording":false,"position":"1.1.1.1","tempo":120}"#
        ],
        mutationResults: [
            "transport.play": .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "transport button 'Play' not located"
            ))
        ]
    )
    let coreMIDI = MockChannel(id: .coreMIDI)
    await router.register(ax)
    await router.register(coreMIDI)

    let result = await TransportDispatcher.handle(
        command: "play",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    let text = dispatcherText(result)
    #expect(!(result.isError!))
    #expect(text.contains(#""verified":true"#))
    #expect(text.contains(#""operation":"transport.play""#))
    #expect(text.contains(#""write_attempted":true"#))
    let coreOps = await coreMIDI.executedOps
    #expect(coreOps.count == 1)
    #expect(coreOps[0].0 == "transport.play")
}

@Test func testTransportDispatcherStopReturnsVerifiedUnchangedWhenAlreadyStopped() async {
    let router = ChannelRouter()
    let ax = TransportStateSequenceChannel(
        id: .accessibility,
        states: [#"{"isPlaying":false,"isRecording":false,"position":"1.1.1.1","tempo":120}"#],
        mutationResults: [:]
    )
    let coreMIDI = MockChannel(id: .coreMIDI)
    await router.register(ax)
    await router.register(coreMIDI)

    let result = await TransportDispatcher.handle(
        command: "stop",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    let text = dispatcherText(result)
    #expect(!(result.isError!))
    #expect(text.contains(#""verified":true"#))
    #expect(text.contains(#""write_attempted":false"#))
    #expect(text.contains(#""unchanged":true"#))
    let coreOps = await coreMIDI.executedOps
    #expect(coreOps.isEmpty)
}

@Test func testTransportDispatcherRecordReturnsReadbackMismatchWhenFallbackDoesNotRecord() async {
    let router = ChannelRouter()
    let ax = TransportStateSequenceChannel(
        id: .accessibility,
        states: [
            #"{"isPlaying":false,"isRecording":false,"position":"1.1.1.1","tempo":120}"#,
            #"{"isPlaying":true,"isRecording":false,"position":"1.1.1.1","tempo":120}"#
        ],
        mutationResults: [
            "transport.record": .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "transport button 'Record' not located"
            ))
        ]
    )
    let coreMIDI = MockChannel(id: .coreMIDI)
    await router.register(ax)
    await router.register(coreMIDI)

    let result = await TransportDispatcher.handle(
        command: "record",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    let text = dispatcherText(result)
    #expect(result.isError!)
    #expect(text.contains(#""verified":false"#))
    #expect(text.contains(#""reason":"readback_mismatch""#))
    #expect(text.contains(#""operation":"transport.record""#))
    let coreOps = await coreMIDI.executedOps
    #expect(coreOps.count == 1)
    #expect(coreOps[0].0 == "transport.record")
}

@Test func testTransportDispatcherPlayStateBReadbackUnavailableIsError() async {
    let router = ChannelRouter()
    let ax = TransportStateSequenceChannel(
        id: .accessibility,
        states: [],
        mutationResults: [
            "transport.play": .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: ["via": "ax_mock"]
            ))
        ]
    )
    await router.register(ax)

    let result = await TransportDispatcher.handle(
        command: "play",
        params: [:],
        router: router,
        cache: StateCache(),
        sleep: { _ in }
    )

    let text = dispatcherText(result)
    #expect(result.isError!)
    #expect(text.contains(#""verified":false"#))
    #expect(text.contains(#""reason":"readback_unavailable""#))
    #expect(text.contains(#""operation":"transport.play""#))
}

@Test func testTransportDispatcherStopPromotesFallbackWriteToVerifiedReadback() async {
    let router = ChannelRouter()
    let ax = TransportStateSequenceChannel(
        id: .accessibility,
        states: [
            liveTransportJSON(
                isPlaying: true,
                isRecording: false,
                position: "8.4.1.1"
            ),
            liveTransportJSON(
                isPlaying: false,
                isRecording: false,
                position: "9.1.1.1"
            )
        ],
        mutationResults: [
            "transport.stop": .error(HonestContract.encodeStateC(
                error: .readbackMismatch,
                hint: "play checkbox did not clear on first AX attempt"
            ))
        ]
    )
    let mcu = MockChannel(id: .mcu)
    await router.register(ax)
    await router.register(mcu)
    let cache = StateCache()

    let result = await TransportDispatcher.handle(
        command: "stop",
        params: [:],
        router: router,
        cache: cache,
        sleep: { _ in }
    )

    let json = try! sharedParseJSON(dispatcherText(result)) as! [String: Any]
    #expect(!(result.isError!))
    #expect((json["verified"] as? Bool)!)
    #expect(json["verify_source"] as? String == "ax_transport_state")
    #expect(!((json["observed_isPlaying"] as? Bool)!))
    #expect(!((json["observed_isRecording"] as? Bool)!))
    #expect(json["observed_position"] as? String == "9.1.1.1")
    #expect(await ax.executedOps.map(\.0) == ["transport.get_state", "transport.stop", "transport.get_state"])
    #expect(await mcu.executedOps.map(\.0) == ["transport.stop"])

    let cached = await cache.getTransport()
    #expect(!(cached.isPlaying))
    #expect(!(cached.isRecording))
    #expect(cached.position == "9.1.1.1")
}

@Test func testTransportDispatcherStopPollsUntilLiveReadbackSettles() async {
    let router = ChannelRouter()
    let ax = TransportStateSequenceChannel(
        id: .accessibility,
        states: [
            liveTransportJSON(
                isPlaying: true,
                isRecording: false,
                position: "12.1.1.1"
            ),
            liveTransportJSON(
                isPlaying: true,
                isRecording: false,
                position: "12.1.1.1"
            ),
            liveTransportJSON(
                isPlaying: false,
                isRecording: false,
                position: "12.1.1.1"
            )
        ],
        mutationResults: [:]
    )
    let cgEvent = MockChannel(id: .cgEvent)
    await router.register(ax)
    await router.register(cgEvent)
    let cache = StateCache()

    let result = await TransportDispatcher.handle(
        command: "stop",
        params: [:],
        router: router,
        cache: cache,
        sleep: { _ in }
    )

    let json = try! sharedParseJSON(dispatcherText(result)) as! [String: Any]
    #expect(!(result.isError!))
    #expect((json["verified"] as? Bool)!)
    #expect(json["operation"] as? String == "transport.stop")
    #expect(json["poll_attempts"] as? Int == 2)
    #expect(!((json["observed_isPlaying"] as? Bool)!))
    #expect(await ax.executedOps.map(\.0) == [
        "transport.get_state",
        "transport.get_state",
        "transport.get_state"
    ])
    #expect(await cgEvent.executedOps.map(\.0) == ["transport.stop"])
}

@Test func testTransportDispatcherStopFailsClosedWhenLiveReadbackUnavailable() async {
    let router = ChannelRouter()
    let ax = ScriptedTransportChannel(id: .accessibility, results: [
        "transport.stop": .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["button": "Stop"]
        )),
        "transport.get_state": .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: "Cannot locate transport bar"
        )),
    ])
    await router.register(ax)
    let cache = StateCache()
    await cache.updateTransport(TransportState(
        isPlaying: true,
        isRecording: true,
        position: "96.1.1.1",
        lastUpdated: Date(timeIntervalSinceNow: -18)
    ))

    let result = await TransportDispatcher.handle(
        command: "stop",
        params: [:],
        router: router,
        cache: cache,
        sleep: { _ in }
    )

    let json = try! sharedParseJSON(dispatcherText(result)) as! [String: Any]
    #expect(result.isError!)
    #expect(json["error"] as? String == "readback_unavailable")
    #expect(json["refresh_error"] as? String == "element_not_found")
    #expect(json["cached_source"] as? String == "cache")
    #expect((json["cache_age_sec"] as? Double ?? 0) > 0)
    #expect(((json["hint"] as? String)?.contains("refresh_cache"))!)
}

@Test func testTransportDispatcherStopFailsClosedWhenLiveStateStillReportsPlayback() async {
    let router = ChannelRouter()
    let ax = ScriptedTransportChannel(id: .accessibility, results: [
        "transport.stop": .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["button": "Stop"]
        )),
        "transport.get_state": .success(liveTransportJSON(
            isPlaying: true,
            isRecording: true,
            position: "96.1.1.1"
        )),
    ])
    await router.register(ax)
    let cache = StateCache()

    let result = await TransportDispatcher.handle(
        command: "stop",
        params: [:],
        router: router,
        cache: cache,
        sleep: { _ in }
    )

    let json = try! sharedParseJSON(dispatcherText(result)) as! [String: Any]
    #expect(result.isError!)
    #expect(json["error"] as? String == "readback_mismatch")
    #expect((json["observed_isPlaying"] as? Bool)!)
    #expect((json["observed_isRecording"] as? Bool)!)
    #expect(json["observed_position"] as? String == "96.1.1.1")
    #expect((json["safe_to_retry"] as? Bool)!)

    let cached = await cache.getTransport()
    #expect(cached.isPlaying)
    #expect(cached.isRecording)
    #expect(cached.position == "96.1.1.1")
}
