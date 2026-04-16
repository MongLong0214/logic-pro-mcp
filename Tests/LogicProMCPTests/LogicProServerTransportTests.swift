import CoreMIDI
import Foundation
import Testing
@testable import LogicProMCP

private enum MockPortManagerError: Error {
    case createFailed
}

private func withTestMIDIEventList(
    bytes: [UInt8],
    numPackets: UInt32 = 1,
    wordCountOverride: UInt32? = nil,
    _ body: (UnsafePointer<MIDIEventList>) -> Void
) {
    let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet) ?? 0
    let wordCount = Int(wordCountOverride ?? UInt32((bytes.count + 3) / 4))
    let paddedByteCount = max(0, wordCount * MemoryLayout<UInt32>.size)
    let bufferSize = packetOffset + MemoryLayout<MIDIEventPacket>.size + max(0, paddedByteCount - MemoryLayout<UInt32>.size)
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: max(bufferSize, MemoryLayout<MIDIEventList>.size),
        alignment: MemoryLayout<MIDIEventList>.alignment
    )
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: max(bufferSize, MemoryLayout<MIDIEventList>.size))
    defer { raw.deallocate() }

    let list = raw.assumingMemoryBound(to: MIDIEventList.self)
    list.pointee.numPackets = numPackets

    if numPackets > 0 {
        let packet = raw.advanced(by: packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        packet.pointee.wordCount = UInt32(wordCount)
        var padded = bytes
        if padded.count < paddedByteCount {
            padded.append(contentsOf: repeatElement(0, count: paddedByteCount - padded.count))
        }
        withUnsafeMutableBytes(of: &packet.pointee.words) { words in
            words.copyBytes(from: padded)
        }
    }

    body(UnsafePointer(list))
}

private actor MockServerPortManager: VirtualPortManaging {
    var sendOnlyNames: [String] = []
    var bidirectionalNames: [String] = []
    var sendOnlyError: MockPortManagerError?
    var bidirectionalError: MockPortManagerError?
    var receiveHandlerInstalled = false
    var bidirectionalHandler: (@Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void)?

    func setSendOnlyError(_ error: MockPortManagerError?) {
        sendOnlyError = error
    }

    func setBidirectionalError(_ error: MockPortManagerError?) {
        bidirectionalError = error
    }

    func createSendOnlyPort(name: String) throws -> MIDIPortManager.MIDIPortPair {
        sendOnlyNames.append(name)
        if let sendOnlyError {
            throw sendOnlyError
        }
        return .init(name: name, source: 101, destination: nil)
    }

    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortManager.MIDIPortPair {
        bidirectionalNames.append(name)
        receiveHandlerInstalled = true
        bidirectionalHandler = onReceive
        if let bidirectionalError {
            throw bidirectionalError
        }
        return .init(name: name, source: 201, destination: 202)
    }

    func emitBidirectionalBytes(
        _ bytes: [UInt8],
        numPackets: UInt32 = 1,
        wordCountOverride: UInt32? = nil
    ) {
        guard let bidirectionalHandler else { return }
        withTestMIDIEventList(bytes: bytes, numPackets: numPackets, wordCountOverride: wordCountOverride) { list in
            bidirectionalHandler(list, nil)
        }
    }
}

private actor PacketSinkRecorder {
    var packets: [(MIDIEndpointRef, [UInt8])] = []

    func record(endpoint: MIDIEndpointRef, bytes: [UInt8]) {
        packets.append((endpoint, bytes))
    }

    func snapshot() -> [(MIDIEndpointRef, [UInt8])] {
        packets
    }
}

private actor FeedbackEventRecorder {
    var events: [String] = []

    func record(_ event: MIDIFeedback.Event) {
        switch event {
        case .noteOn(let channel, let note, let velocity):
            events.append("noteOn:\(channel):\(note):\(velocity)")
        case .noteOff(let channel, let note, let velocity):
            events.append("noteOff:\(channel):\(note):\(velocity)")
        case .controlChange(let channel, let controller, let value):
            events.append("cc:\(channel):\(controller):\(value)")
        case .sysEx(let bytes):
            events.append("sysex:\(bytes.map { String(format: "%02X", $0) }.joined(separator: "-"))")
        default:
            events.append("other")
        }
    }

    func snapshot() -> [String] {
        events
    }
}

@Test func testProductionKeyCmdTransportReadinessStartsUnavailable() async {
    let transport = ProductionKeyCmdTransport(portManager: MockServerPortManager())

    let readiness = await transport.readiness()

    #expect(!readiness.available)
    #expect(readiness.detail.contains("has not been prepared"))
}

@Test func testProductionKeyCmdTransportPrepareAndStopUpdateReadiness() async throws {
    let manager = MockServerPortManager()
    let transport = ProductionKeyCmdTransport(portManager: manager, portName: "KeyCmd-Test")

    try await transport.prepare()
    let ready = await transport.readiness()
    await transport.stop()
    let stopped = await transport.readiness()

    #expect(ready.available)
    #expect(ready.detail.contains("KeyCmd-Test"))
    #expect(!stopped.available)
    #expect(stopped.detail.contains("has not been prepared"))
    let names = await manager.sendOnlyNames
    #expect(names == ["KeyCmd-Test"])
}

@Test func testProductionKeyCmdTransportPrepareIsIdempotent() async throws {
    let manager = MockServerPortManager()
    let transport = ProductionKeyCmdTransport(portManager: manager, portName: "Idempotent-Port")

    try await transport.prepare()
    try await transport.prepare()

    let names = await manager.sendOnlyNames
    #expect(names == ["Idempotent-Port"])
}

@Test func testProductionKeyCmdTransportSendPreparesPortAndEmitsBytes() async throws {
    let manager = MockServerPortManager()
    let recorder = PacketSinkRecorder()
    let transport = ProductionKeyCmdTransport(
        portManager: manager,
        portName: "Send-Test",
        packetSink: { endpoint, bytes in
            Task { await recorder.record(endpoint: endpoint, bytes: bytes) }
        }
    )

    try await transport.send([0x90, 0x3C, 0x64])
    await Task.yield()

    let names = await manager.sendOnlyNames
    let packets = await recorder.snapshot()
    #expect(names == ["Send-Test"])
    #expect(packets.count == 1)
    #expect(packets[0].0 == 101)
    #expect(packets[0].1 == [0x90, 0x3C, 0x64])
}

@Test func testProductionKeyCmdTransportDefaultPacketSinkSmoke() async throws {
    let manager = MIDIPortManager()
    let transport = ProductionKeyCmdTransport(
        portManager: manager,
        portName: "LogicProMCP-KeyCmd-Smoke-\(UUID().uuidString)"
    )

    try await manager.start()
    try await transport.send([0x90, 0x3C, 0x64])

    let readiness = await transport.readiness()
    #expect(readiness.available)

    await transport.stop()
    await manager.stop()
}

@Test func testProductionKeyCmdTransportReadinessReflectsStartupFailure() async {
    let manager = MockServerPortManager()
    await manager.setSendOnlyError(.createFailed)
    let transport = ProductionKeyCmdTransport(portManager: manager, portName: "Broken-Port")

    await #expect(throws: MockPortManagerError.createFailed) {
        try await transport.prepare()
    }

    let readiness = await transport.readiness()
    #expect(!readiness.available)
    #expect(readiness.detail.contains("Broken-Port"))
}

@Test func testProductionKeyCmdTransportStopClearsStartupFailureState() async {
    let manager = MockServerPortManager()
    await manager.setSendOnlyError(.createFailed)
    let transport = ProductionKeyCmdTransport(portManager: manager, portName: "Recoverable-Port")

    await #expect(throws: MockPortManagerError.createFailed) {
        try await transport.prepare()
    }
    await transport.stop()

    let readiness = await transport.readiness()
    #expect(!readiness.available)
    #expect(readiness.detail.contains("has not been prepared"))
}

@Test func testProductionMCUTransportSendBeforeStartIsNoOp() async {
    let recorder = PacketSinkRecorder()
    let transport = ProductionMCUTransport(
        portManager: MockServerPortManager(),
        packetSink: { endpoint, bytes in
            Task { await recorder.record(endpoint: endpoint, bytes: bytes) }
        }
    )

    await transport.send([0x01, 0x02, 0x03])

    let packets = await recorder.snapshot()
    #expect(packets.isEmpty)
}

@Test func testProductionMCUTransportStartCreatesBidirectionalPort() async throws {
    let manager = MockServerPortManager()
    let transport = ProductionMCUTransport(portManager: manager)

    try await transport.start { _ in }

    let names = await manager.bidirectionalNames
    let handlerInstalled = await manager.receiveHandlerInstalled
    #expect(names == ["LogicProMCP-MCU-Internal"])
    #expect(handlerInstalled)
}

@Test func testProductionMCUTransportReceiveParsesFeedbackEvents() async throws {
    let manager = MockServerPortManager()
    let recorder = FeedbackEventRecorder()
    let transport = ProductionMCUTransport(portManager: manager)

    try await transport.start { event in
        Task { await recorder.record(event) }
    }
    await manager.emitBidirectionalBytes([0x90, 0x40, 0x7F])
    await Task.yield()
    await Task.yield()

    let events = await recorder.snapshot()
    #expect(events == ["noteOn:0:64:127"])
}

@Test func testProductionMCUTransportReceiveIgnoresEmptyPacketLists() async throws {
    let manager = MockServerPortManager()
    let recorder = FeedbackEventRecorder()
    let transport = ProductionMCUTransport(portManager: manager)

    try await transport.start { event in
        Task { await recorder.record(event) }
    }
    await manager.emitBidirectionalBytes([], numPackets: 0)
    await Task.yield()

    let events = await recorder.snapshot()
    #expect(events.isEmpty)
}

@Test func testProductionMCUTransportSendUsesPacketSinkAfterStart() async throws {
    let manager = MockServerPortManager()
    let recorder = PacketSinkRecorder()
    let transport = ProductionMCUTransport(
        portManager: manager,
        packetSink: { endpoint, bytes in
            Task { await recorder.record(endpoint: endpoint, bytes: bytes) }
        }
    )

    try await transport.start { _ in }
    await transport.send([0x7F, 0x01])
    await Task.yield()

    let packets = await recorder.snapshot()
    #expect(packets.count == 1)
    #expect(packets[0].0 == 201)
    #expect(packets[0].1 == [0x7F, 0x01])
}

@Test func testProductionMCUTransportStopClearsPortAndDropsSubsequentSends() async throws {
    let manager = MockServerPortManager()
    let recorder = PacketSinkRecorder()
    let transport = ProductionMCUTransport(
        portManager: manager,
        packetSink: { endpoint, bytes in
            Task { await recorder.record(endpoint: endpoint, bytes: bytes) }
        }
    )

    try await transport.start { _ in }
    await transport.stop()
    await transport.send([0x11, 0x22, 0x33])
    await Task.yield()

    let packets = await recorder.snapshot()
    #expect(packets.isEmpty)
}

@Test func testProductionMCUTransportStartSurfacesPortCreationFailure() async {
    let manager = MockServerPortManager()
    await manager.setBidirectionalError(.createFailed)
    let transport = ProductionMCUTransport(portManager: manager)

    await #expect(throws: MockPortManagerError.createFailed) {
        try await transport.start { _ in }
    }
}

@Test func testLogicProServerStartupErrorDescriptionSortsFailures() {
    let error = LogicProServer.StartupError.channelStartupFailed([
        .midiKeyCommands: "preset missing",
        .appleScript: "permission denied",
        .mcu: "handshake failed",
    ])

    let description = String(describing: error)

    #expect(description == "Channel startup failed — AppleScript: permission denied; MCU: handshake failed; MIDIKeyCommands: preset missing")
}

@Test func testServerCatalogSnapshotIncludesCommercialSurface() {
    let snapshot = ServerCatalog.snapshot(channelIDs: [.mcu, .midiKeyCommands, .scripter, .coreMIDI])

    #expect(snapshot.channelIDs == [.mcu, .midiKeyCommands, .scripter, .coreMIDI])
    #expect(snapshot.toolNames == [
        "logic_transport",
        "logic_tracks",
        "logic_mixer",
        "logic_midi",
        "logic_edit",
        "logic_navigate",
        "logic_project",
        "logic_system",
    ])
    #expect(snapshot.resourceURIs == [
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://project/info",
        "logic://midi/ports",
        "logic://system/health",
    ])
    #expect(snapshot.templateURIs == ["logic://tracks/{index}"])
    #expect(snapshot.startupBanner == "Starting logic-pro-mcp v2.2.0 — 8 tools, 6 resources, 4 channels")
}

@Test func testServerCatalogStartupBannerUsesProvidedChannelCount() {
    let banner = ServerCatalog.startupBanner(channelCount: 7)
    #expect(banner == "Starting logic-pro-mcp v2.2.0 — 8 tools, 6 resources, 7 channels")
}

@Test func testLogicProServerCompositionSnapshotMatchesExpectedOrder() async {
    let server = LogicProServer()

    let snapshot = await server.compositionSnapshot()

    #expect(snapshot.channelIDs == [
        .mcu,
        .midiKeyCommands,
        .scripter,
        .coreMIDI,
        .accessibility,
        .cgEvent,
        .appleScript,
    ])
    #expect(snapshot.toolNames.count == 8)
    #expect(snapshot.resourceURIs.contains("logic://system/health"))
    #expect(snapshot.startupBanner == "Starting logic-pro-mcp v2.2.0 — 8 tools, 6 resources, 7 channels")
}
