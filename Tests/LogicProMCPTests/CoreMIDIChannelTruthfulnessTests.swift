import CoreMIDI
import Testing
@testable import LogicProMCP

enum MockCoreMIDIHarnessError: Error, Sendable {
    case startFailed
    case createPortFailed
}

actor MockCoreMIDIEngine: CoreMIDIEngineProtocol {
    enum Message: Equatable, Sendable {
        case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
        case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
        case cc(channel: UInt8, controller: UInt8, value: UInt8)
        case programChange(channel: UInt8, program: UInt8)
        case pitchBend(channel: UInt8, value: UInt16)
        case aftertouch(channel: UInt8, pressure: UInt8)
    }

    var sysexMessages: [[UInt8]] = []
    var shortMessages: [Message] = []
    var active: Bool
    var startCount = 0
    var stopCount = 0
    let startFailure: MockCoreMIDIHarnessError?

    init(active: Bool = true, startFailure: MockCoreMIDIHarnessError? = nil) {
        self.active = active
        self.startFailure = startFailure
    }

    func start() throws {
        startCount += 1
        if let startFailure {
            throw startFailure
        }
        active = true
    }

    func stop() {
        stopCount += 1
        active = false
    }

    var isActive: Bool { active }
    func sendNoteOn(channel: UInt8, note: UInt8, velocity: UInt8) {
        shortMessages.append(.noteOn(channel: channel, note: note, velocity: velocity))
    }

    func sendNoteOff(channel: UInt8, note: UInt8, velocity: UInt8) {
        shortMessages.append(.noteOff(channel: channel, note: note, velocity: velocity))
    }

    func sendCC(channel: UInt8, controller: UInt8, value: UInt8) {
        shortMessages.append(.cc(channel: channel, controller: controller, value: value))
    }

    func sendProgramChange(channel: UInt8, program: UInt8) {
        shortMessages.append(.programChange(channel: channel, program: program))
    }

    func sendPitchBend(channel: UInt8, value: UInt16) {
        shortMessages.append(.pitchBend(channel: channel, value: value))
    }

    func sendAftertouch(channel: UInt8, pressure: UInt8) {
        shortMessages.append(.aftertouch(channel: channel, pressure: pressure))
    }

    func sendSysEx(_ bytes: [UInt8]) {
        sysexMessages.append(bytes)
    }
}

actor MockVirtualPortManager: VirtualPortManaging {
    var createdNames: [String] = []
    let failure: MockCoreMIDIHarnessError?

    init(failure: MockCoreMIDIHarnessError? = nil) {
        self.failure = failure
    }

    func createSendOnlyPort(name: String) throws -> MIDIPortManager.MIDIPortPair {
        if let failure {
            throw failure
        }
        createdNames.append(name)
        return .init(name: name, source: 1, destination: nil)
    }

    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortManager.MIDIPortPair {
        createdNames.append(name)
        return .init(name: name, source: 1, destination: 2)
    }
}

@Test func testCoreMIDIChannelMMCLocateSendsSysExForTimecode() async {
    let engine = MockCoreMIDIEngine()
    let channel = CoreMIDIChannel(engine: engine)

    let result = await channel.execute(
        operation: "mmc.locate",
        params: ["time": "01:02:03:04"]
    )

    #expect(result.isSuccess)
    let sent = await engine.sysexMessages
    #expect(sent.count == 1)
    #expect(sent[0] == MMCCommands.locate(hours: 1, minutes: 2, seconds: 3, frames: 4))
}

@Test func testCoreMIDIChannelGotoPositionReturnsExplicitError() async {
    let channel = CoreMIDIChannel(engine: MockCoreMIDIEngine())
    let result = await channel.execute(
        operation: "transport.goto_position",
        params: ["position": "12.1.1.1"]
    )

    #expect(!result.isSuccess)
    #expect(result.message.contains("cannot position the playhead directly"))
}

@Test func testCoreMIDIChannelCreateVirtualPortUsesPortManager() async {
    let manager = MockVirtualPortManager()
    let channel = CoreMIDIChannel(engine: MockCoreMIDIEngine(), portManager: manager)

    let result = await channel.execute(
        operation: "midi.create_virtual_port",
        params: ["name": "Session-Port"]
    )

    #expect(result.isSuccess)
    let names = await manager.createdNames
    #expect(names == ["Session-Port"])
}

@Test func testCoreMIDIChannelCreateVirtualPortErrorsWithoutManager() async {
    let channel = CoreMIDIChannel(engine: MockCoreMIDIEngine())
    let result = await channel.execute(
        operation: "midi.create_virtual_port",
        params: ["name": "Session-Port"]
    )

    #expect(!result.isSuccess)
    #expect(result.message.contains("unavailable"))
}

@Test func testCoreMIDIChannelTransportAndMMCAliasesSendExpectedSysEx() async {
    let engine = MockCoreMIDIEngine()
    let channel = CoreMIDIChannel(engine: engine)

    let operations: [(String, [String: String], [UInt8])] = [
        ("transport.play", [:], MMCCommands.play()),
        ("transport.stop", [:], MMCCommands.stop()),
        ("transport.pause", [:], MMCCommands.pause()),
        ("transport.record_strobe", [:], MMCCommands.recordStrobe()),
        ("transport.record_exit", [:], MMCCommands.recordExit()),
        ("transport.fast_forward", [:], MMCCommands.fastForward()),
        ("transport.rewind", [:], MMCCommands.rewind()),
        ("transport.record", [:], MMCCommands.recordStrobe()),
        ("mmc.play", [:], MMCCommands.play()),
        ("mmc.stop", [:], MMCCommands.stop()),
        ("mmc.record_strobe", [:], MMCCommands.recordStrobe()),
        ("mmc.record_exit", [:], MMCCommands.recordExit()),
        ("mmc.pause", [:], MMCCommands.pause()),
    ]

    for (operation, params, expectedBytes) in operations {
        let result = await channel.execute(operation: operation, params: params)
        #expect(result.isSuccess)
        let sentMessages = await engine.sysexMessages
        #expect(sentMessages.last == expectedBytes)
    }

    let sentMessages = await engine.sysexMessages
    #expect(sentMessages == operations.map(\.2))
}

@Test func testCoreMIDIChannelLocateVariantsValidateAndEncode() async {
    let engine = MockCoreMIDIEngine()
    let channel = CoreMIDIChannel(engine: engine)

    let transportLocate = await channel.execute(
        operation: "transport.locate",
        params: [
            "hours": "1",
            "minutes": "2",
            "seconds": "3",
            "frames": "4",
            "subframes": "5",
        ]
    )
    #expect(transportLocate.isSuccess)

    let mmcLocate = await channel.execute(
        operation: "mmc.locate",
        params: ["time": "06:07:08:09"]
    )
    #expect(mmcLocate.isSuccess)

    let missingTransportParts = await channel.execute(
        operation: "transport.locate",
        params: ["hours": "1"]
    )
    #expect(!missingTransportParts.isSuccess)
    #expect(missingTransportParts.message.contains("requires hours"))

    let invalidMMCTime = await channel.execute(
        operation: "mmc.locate",
        params: ["time": "06:07:08"]
    )
    #expect(!invalidMMCTime.isSuccess)
    #expect(invalidMMCTime.message.contains("HH:MM:SS:FF"))

    let sentMessages = await engine.sysexMessages
    #expect(sentMessages == [
        MMCCommands.locate(hours: 1, minutes: 2, seconds: 3, frames: 4, subframes: 5),
        MMCCommands.locate(hours: 6, minutes: 7, seconds: 8, frames: 9),
    ])
}

@Test func testCoreMIDIChannelRoutesNoteControllerAndPressureOperations() async {
    let engine = MockCoreMIDIEngine()
    let channel = CoreMIDIChannel(engine: engine)

    let operations: [(String, [String: String])] = [
        ("midi.send_note", ["note": "60", "channel": "2", "velocity": "90", "duration_ms": "0"]),
        ("midi.note_on", ["note": "61", "channel": "1", "velocity": "91"]),
        ("midi.note_off", ["note": "61", "channel": "1"]),
        ("midi.send_cc", ["controller": "74", "value": "80", "channel": "3"]),
        ("midi.program_change", ["program": "10", "channel": "4"]),
        ("midi.send_program_change", ["program": "11", "channel": "5"]),
        ("midi.send_pitch_bend", ["value": "-8192", "channel": "6"]),
        ("midi.pitch_bend", ["value": "20000", "channel": "7"]),
        ("midi.aftertouch", ["pressure": "70", "channel": "8"]),
        ("midi.send_aftertouch", ["value": "71", "channel": "9"]),
    ]

    for (operation, params) in operations {
        let result = await channel.execute(operation: operation, params: params)
        #expect(result.isSuccess)
    }

    let messages = await engine.shortMessages
    #expect(messages == [
        .noteOn(channel: 2, note: 60, velocity: 90),
        .noteOff(channel: 2, note: 60, velocity: 0),
        .noteOn(channel: 1, note: 61, velocity: 91),
        .noteOff(channel: 1, note: 61, velocity: 0),
        .cc(channel: 3, controller: 74, value: 80),
        .programChange(channel: 4, program: 10),
        .programChange(channel: 5, program: 11),
        .pitchBend(channel: 6, value: 0),
        .pitchBend(channel: 7, value: 16_383),
        .aftertouch(channel: 8, pressure: 70),
        .aftertouch(channel: 9, pressure: 71),
    ])
}

@Test func testCoreMIDIChannelRoutesChordStepInputSysExAndStateQueries() async {
    let engine = MockCoreMIDIEngine()
    let channel = CoreMIDIChannel(engine: engine)

    let chord = await channel.execute(
        operation: "midi.send_chord",
        params: ["notes": "60, 64,67", "velocity": "88", "channel": "3", "duration_ms": "0"]
    )
    #expect(chord.isSuccess)

    let stepInput = await channel.execute(
        operation: "midi.step_input",
        params: ["note": "62", "duration": "1/8"]
    )
    #expect(stepInput.isSuccess)
    #expect(stepInput.message.contains("125ms"))

    let sysex = await channel.execute(
        operation: "midi.send_sysex",
        params: ["bytes": "F0 7F 7F 06 02 F7"]
    )
    #expect(sysex.isSuccess)

    let listPorts = await channel.execute(operation: "midi.list_ports", params: [:])
    #expect(listPorts.isSuccess)
    #expect(listPorts.message.contains("\"sources\""))
    #expect(listPorts.message.contains("\"destinations\""))

    let inputState = await channel.execute(operation: "midi.get_input_state", params: [:])
    #expect(inputState.isSuccess)
    #expect(inputState.message.contains("\"active\":true"))

    let messages = await engine.shortMessages
    #expect(messages == [
        .noteOn(channel: 3, note: 60, velocity: 88),
        .noteOn(channel: 3, note: 64, velocity: 88),
        .noteOn(channel: 3, note: 67, velocity: 88),
        .noteOff(channel: 3, note: 60, velocity: 0),
        .noteOff(channel: 3, note: 64, velocity: 0),
        .noteOff(channel: 3, note: 67, velocity: 0),
        .noteOn(channel: 0, note: 62, velocity: 80),
        .noteOff(channel: 0, note: 62, velocity: 0),
    ])

    let sentMessages = await engine.sysexMessages
    #expect(sentMessages == [[0xF0, 0x7F, 0x7F, 0x06, 0x02, 0xF7]])
}

@Test func testCoreMIDIChannelRejectsInvalidParametersAndUnknownOperations() async {
    let channel = CoreMIDIChannel(engine: MockCoreMIDIEngine())

    let failingCases: [(String, [String: String], String)] = [
        ("midi.send_note", [:], "requires 'note'"),
        ("midi.note_on", [:], "requires 'note'"),
        ("midi.note_off", [:], "requires 'note'"),
        ("midi.send_cc", ["controller": "74"], "requires 'controller' and 'value'"),
        ("midi.program_change", [:], "requires 'program'"),
        ("midi.aftertouch", [:], "requires 'pressure'"),
        ("midi.send_sysex", ["bytes": "7F 7F"], "must start with F0 and end with F7"),
        ("unknown.operation", [:], "Unknown CoreMIDI operation"),
    ]

    for (operation, params, expectedFragment) in failingCases {
        let result = await channel.execute(operation: operation, params: params)
        #expect(!result.isSuccess)
        #expect(result.message.contains(expectedFragment))
    }
}

@Test func testCoreMIDIChannelCoversRawPitchBendAndAdditionalErrorBranches() async {
    let engine = MockCoreMIDIEngine()
    let channel = CoreMIDIChannel(engine: engine)

    let rawPitchBend = await channel.execute(
        operation: "midi.pitch_bend",
        params: ["value": "12345", "channel": "2"]
    )
    #expect(rawPitchBend.isSuccess)

    let invalidPitchBend = await channel.execute(
        operation: "midi.pitch_bend",
        params: ["value": "not-a-number"]
    )
    #expect(!invalidPitchBend.isSuccess)
    #expect(invalidPitchBend.message.contains("pitch_bend requires 'value'"))

    let missingSysex = await channel.execute(
        operation: "midi.send_sysex",
        params: [:]
    )
    #expect(!missingSysex.isSuccess)
    #expect(missingSysex.message.contains("send_sysex requires 'bytes'"))

    let invalidMMCTime = await channel.execute(
        operation: "mmc.locate",
        params: ["time": "AA:BB:CC:DD"]
    )
    #expect(!invalidMMCTime.isSuccess)
    #expect(invalidMMCTime.message.contains("HH:MM:SS:FF"))

    #expect(await engine.shortMessages == [
        .pitchBend(channel: 2, value: 16_383),
    ])
}

@Test func testCoreMIDIChannelVirtualPortDefaultNameAndFailurePaths() async {
    let defaultManager = MockVirtualPortManager()
    let defaultChannel = CoreMIDIChannel(engine: MockCoreMIDIEngine(), portManager: defaultManager)
    let defaultResult = await defaultChannel.execute(operation: "midi.create_virtual_port", params: [:])
    #expect(defaultResult.isSuccess)
    #expect(await defaultManager.createdNames == ["LogicProMCP-Virtual"])

    let failingManager = MockVirtualPortManager(failure: .createPortFailed)
    let failingChannel = CoreMIDIChannel(engine: MockCoreMIDIEngine(), portManager: failingManager)
    let failingResult = await failingChannel.execute(
        operation: "midi.create_virtual_port",
        params: ["name": "Broken-Port"]
    )
    #expect(!failingResult.isSuccess)
    #expect(failingResult.message.contains("Failed to create virtual port"))
}

@Test func testCoreMIDIChannelStartStopAndHealthLifecycle() async {
    let engine = MockCoreMIDIEngine(active: false)
    let channel = CoreMIDIChannel(engine: engine)

    let unavailable = await channel.healthCheck()
    #expect(!unavailable.available)

    try? await channel.start()
    #expect(await engine.startCount == 1)

    let healthy = await channel.healthCheck()
    #expect(healthy.available)
    #expect(healthy.detail.contains("virtual ports created"))

    await channel.stop()
    #expect(await engine.stopCount == 1)
    let afterStop = await channel.healthCheck()
    #expect(!afterStop.available)
}

@Test func testCoreMIDIChannelStartPropagatesEngineFailure() async {
    let channel = CoreMIDIChannel(
        engine: MockCoreMIDIEngine(active: false, startFailure: .startFailed)
    )

    do {
        try await channel.start()
        Issue.record("Expected CoreMIDIChannel.start() to propagate engine failure")
    } catch MockCoreMIDIHarnessError.startFailed {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
