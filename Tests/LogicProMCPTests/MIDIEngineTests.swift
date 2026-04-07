import CoreMIDI
import Foundation
import Testing
@testable import LogicProMCP

private struct MIDIEngineRuntimeSnapshot: Sendable {
    let createClientCalls: Int
    let createSourceCalls: Int
    let createDestinationCalls: Int
    let lastClientName: String?
    let lastSourceName: String?
    let lastDestinationName: String?
    let disposedEndpoints: [MIDIEndpointRef]
    let disposedClients: [MIDIClientRef]
    let sentSources: [MIDIEndpointRef]
    let sentMessages: [[UInt8]]
}

private final class MIDIEngineRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()

    var clientStatus: OSStatus = noErr
    var sourceStatus: OSStatus = noErr
    var destinationStatus: OSStatus = noErr
    var sendStatus: OSStatus = noErr
    var createdClient: MIDIClientRef = 101
    var createdSource: MIDIEndpointRef = 202
    var createdDestination: MIDIEndpointRef = 303

    private var createClientCalls = 0
    private var createSourceCalls = 0
    private var createDestinationCalls = 0
    private var lastClientName: String?
    private var lastSourceName: String?
    private var lastDestinationName: String?
    private var disposedEndpoints: [MIDIEndpointRef] = []
    private var disposedClients: [MIDIClientRef] = []
    private var sentSources: [MIDIEndpointRef] = []
    private var sentMessages: [[UInt8]] = []
    private var inboundHandler: (@Sendable ([UInt8]) -> Void)?
    private var notificationHandler: (@Sendable (Int32) -> Void)?

    func makeRuntime() -> MIDIEngine.Runtime {
        MIDIEngine.Runtime(
            createClient: { [self] name, onNotification in
                withLock {
                    createClientCalls += 1
                    lastClientName = name
                    notificationHandler = onNotification
                    return (clientStatus, createdClient)
                }
            },
            createSource: { [self] client, name in
                withLock {
                    createSourceCalls += 1
                    lastSourceName = name
                    return (sourceStatus, createdSource)
                }
            },
            createDestination: { [self] client, name, onBytes in
                withLock {
                    createDestinationCalls += 1
                    lastDestinationName = name
                    inboundHandler = onBytes
                    return (destinationStatus, createdDestination)
                }
            },
            disposeEndpoint: { [self] endpoint in
                withLock {
                    disposedEndpoints.append(endpoint)
                }
            },
            disposeClient: { [self] client in
                withLock {
                    disposedClients.append(client)
                }
            },
            sendMessage: { [self] source, bytes in
                withLock {
                    sentSources.append(source)
                    sentMessages.append(bytes)
                    return sendStatus
                }
            }
        )
    }

    func deliverInbound(_ bytes: [UInt8]) {
        let handler = withLock { inboundHandler }
        handler?(bytes)
    }

    func emitNotification(_ rawValue: Int32) {
        let handler = withLock { notificationHandler }
        handler?(rawValue)
    }

    func snapshot() -> MIDIEngineRuntimeSnapshot {
        withLock {
            MIDIEngineRuntimeSnapshot(
                createClientCalls: createClientCalls,
                createSourceCalls: createSourceCalls,
                createDestinationCalls: createDestinationCalls,
                lastClientName: lastClientName,
                lastSourceName: lastSourceName,
                lastDestinationName: lastDestinationName,
                disposedEndpoints: disposedEndpoints,
                disposedClients: disposedClients,
                sentSources: sentSources,
                sentMessages: sentMessages
            )
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@Test func testMIDIEngineStartAndStopLifecycleUsesRuntimeResources() async throws {
    let harness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    try await engine.start()
    try await engine.start()
    #expect(await engine.isActive)

    harness.emitNotification(MIDINotificationMessageID.msgSetupChanged.rawValue)
    harness.emitNotification(MIDINotificationMessageID.msgObjectAdded.rawValue)
    harness.emitNotification(MIDINotificationMessageID.msgObjectRemoved.rawValue)
    harness.emitNotification(Int32.max)

    let started = harness.snapshot()
    #expect(started.createClientCalls == 1)
    #expect(started.createSourceCalls == 1)
    #expect(started.createDestinationCalls == 1)
    #expect(started.lastClientName == ServerConfig.virtualMIDISourceName)
    #expect(started.lastSourceName == ServerConfig.virtualMIDISourceName)
    #expect(started.lastDestinationName == ServerConfig.virtualMIDISinkName)

    await engine.stop()
    await engine.stop()
    #expect(!(await engine.isActive))

    let stopped = harness.snapshot()
    #expect(stopped.disposedEndpoints == [harness.createdSource, harness.createdDestination])
    #expect(stopped.disposedClients == [harness.createdClient])
}

@Test func testMIDIEngineStartPropagatesClientCreationFailure() async {
    let harness = MIDIEngineRuntimeHarness()
    harness.clientStatus = -10
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    do {
        try await engine.start()
        Issue.record("Expected client creation failure")
    } catch let error as MIDIEngineError {
        if case .clientCreationFailed(let status) = error {
            #expect(status == -10)
        } else {
            Issue.record("Expected clientCreationFailed, got \(error)")
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let snapshot = harness.snapshot()
    #expect(snapshot.createClientCalls == 1)
    #expect(snapshot.createSourceCalls == 0)
    #expect(snapshot.createDestinationCalls == 0)
    #expect(snapshot.disposedEndpoints.isEmpty)
    #expect(snapshot.disposedClients.isEmpty)
    #expect(!(await engine.isActive))
}

@Test func testMIDIEngineStartPropagatesSourceCreationFailureAndDisposesClient() async {
    let harness = MIDIEngineRuntimeHarness()
    harness.sourceStatus = -20
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    do {
        try await engine.start()
        Issue.record("Expected source creation failure")
    } catch let error as MIDIEngineError {
        if case .sourceCreationFailed(let status) = error {
            #expect(status == -20)
        } else {
            Issue.record("Expected sourceCreationFailed, got \(error)")
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let snapshot = harness.snapshot()
    #expect(snapshot.createClientCalls == 1)
    #expect(snapshot.createSourceCalls == 1)
    #expect(snapshot.createDestinationCalls == 0)
    #expect(snapshot.disposedEndpoints.isEmpty)
    #expect(snapshot.disposedClients == [harness.createdClient])
    #expect(!(await engine.isActive))
}

@Test func testMIDIEngineStartPropagatesDestinationCreationFailureAndDisposesIntermediates() async {
    let harness = MIDIEngineRuntimeHarness()
    harness.destinationStatus = -30
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    do {
        try await engine.start()
        Issue.record("Expected destination creation failure")
    } catch let error as MIDIEngineError {
        if case .destinationCreationFailed(let status) = error {
            #expect(status == -30)
        } else {
            Issue.record("Expected destinationCreationFailed, got \(error)")
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let snapshot = harness.snapshot()
    #expect(snapshot.createClientCalls == 1)
    #expect(snapshot.createSourceCalls == 1)
    #expect(snapshot.createDestinationCalls == 1)
    #expect(snapshot.disposedEndpoints == [harness.createdSource])
    #expect(snapshot.disposedClients == [harness.createdClient])
    #expect(!(await engine.isActive))
}

@Test func testMIDIEngineSendMethodsEncodeExpectedBytes() async throws {
    let harness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: harness.makeRuntime())
    try await engine.start()

    await engine.sendNoteOn(channel: 0x11, note: 0xFF, velocity: 0xFE)
    await engine.sendNoteOff(channel: 0x12, note: 61, velocity: 0)
    await engine.sendCC(channel: 0x13, controller: 0x87, value: 0xC0)
    await engine.sendProgramChange(channel: 0x14, program: 10)
    await engine.sendPitchBend(channel: 0x15, value: 20_000)
    await engine.sendAftertouch(channel: 0x16, pressure: 0xFF)
    await engine.sendPolyAftertouch(channel: 0x17, note: 65, pressure: 66)
    await engine.sendSysEx([0xF0, 0x7D, 0x01, 0xF7])
    await engine.sendSysEx([0xF0, 0x7D, 0x80, 0xF7])
    await engine.sendRawBytes([0xF6])

    let snapshot = harness.snapshot()
    #expect(snapshot.sentSources == Array(repeating: harness.createdSource, count: 9))
    #expect(snapshot.sentMessages == [
        [0x91, 0x7F, 0x7E],
        [0x82, 61, 0],
        [0xB3, 0x07, 0x40],
        [0xC4, 10],
        [0xE5, 0x7F, 0x7F],
        [0xD6, 0x7F],
        [0xA7, 65, 66],
        [0xF0, 0x7D, 0x01, 0xF7],
        [0xF6],
    ])
}

@Test func testMIDIEngineSendRawBytesDropsWhenInactive() async {
    let harness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    await engine.sendNoteOn(channel: 0, note: 60, velocity: 100)
    await engine.sendSysEx([0xF0, 0x7D, 0x01, 0xF7])
    await engine.sendRawBytes([0xF6])

    let snapshot = harness.snapshot()
    #expect(snapshot.sentMessages.isEmpty)
}

@Test func testMIDIEngineSendFailureStillAttemptsDelivery() async throws {
    let harness = MIDIEngineRuntimeHarness()
    harness.sendStatus = -40
    let engine = MIDIEngine(runtime: harness.makeRuntime())
    try await engine.start()

    await engine.sendCC(channel: 9, controller: 10, value: 11)

    let snapshot = harness.snapshot()
    #expect(snapshot.sentMessages == [[0xB9, 10, 11]])
    #expect(await engine.isActive)
}

@Test func testMIDIEngineInboundMessagesYieldParsedEventsFromRuntimeBytes() async throws {
    let harness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: harness.makeRuntime())
    let stream = await engine.inboundMessages
    var iterator = stream.makeAsyncIterator()

    try await engine.start()
    harness.deliverInbound([0x90, 0x3C, 0x64, 0x3E, 0x60])

    let first = await iterator.next()
    let second = await iterator.next()

    if case .noteOn(let channel, let note, let velocity)? = first {
        #expect(channel == 0)
        #expect(note == 0x3C)
        #expect(velocity == 0x64)
    } else {
        Issue.record("Expected first inbound noteOn event")
    }

    if case .noteOn(let channel, let note, let velocity)? = second {
        #expect(channel == 0)
        #expect(note == 0x3E)
        #expect(velocity == 0x60)
    } else {
        Issue.record("Expected second inbound noteOn event from running status")
    }

    await engine.stop()
    let finished = await iterator.next()
    #expect(finished == nil)
}

@Test func testMIDIEngineProductionRuntimeStartStopSmoke() async throws {
    let engine = MIDIEngine()

    try await engine.start()
    #expect(await engine.isActive)

    await engine.sendRawBytes([])
    await engine.sendCC(channel: 0, controller: 1, value: 64)

    await engine.stop()
    #expect(!(await engine.isActive))
}
