import CoreMIDI
import Foundation
import MCP
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
    let assignedUniqueIDs: [MIDIEndpointRef: Int32]
}

private final class MIDIEngineRuntimeHarness: @unchecked Sendable {
    enum OwnershipLockMode: Sendable {
        case acquired
        case held
        case unavailable(String)
    }

    private let lock = NSLock()

    var clientStatus: OSStatus = noErr
    var sourceStatus: OSStatus = noErr
    var destinationStatus: OSStatus = noErr
    var sendStatus: OSStatus = noErr
    var uniqueIDStatus: OSStatus = noErr
    var endpointDisposalStatuses: [MIDIEndpointRef: OSStatus] = [:]
    var foreignEndpointsByName: [String: [MIDIEndpointRef]] = [:]
    var catalogReadOverride: VirtualMIDIEndpointCatalogRead?
    var unreadableEndpointNames: Set<MIDIEndpointRef> = []
    var ownershipLockMode: OwnershipLockMode = .acquired
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
    private var endpointNames: [MIDIEndpointRef: String] = [:]
    private var assignedUniqueIDs: [MIDIEndpointRef: Int32] = [:]
    private var inboundHandler: (@Sendable ([UInt8]) -> Void)?
    private var notificationHandler: (@Sendable (Int32) -> Void)?
    private var lifecycleEvents: [String] = []

    func makeRuntime(
        processOwnership: VirtualMIDIEndpointProcessOwnership = .shared
    ) -> MIDIEngine.Runtime {
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
                    lifecycleEvents.append("source creation")
                    lastSourceName = name
                    if sourceStatus == noErr {
                        endpointNames[createdSource] = name
                    }
                    return (sourceStatus, createdSource)
                }
            },
            createDestination: { [self] client, name, onBytes in
                withLock {
                    createDestinationCalls += 1
                    lifecycleEvents.append("destination creation")
                    lastDestinationName = name
                    inboundHandler = onBytes
                    if destinationStatus == noErr {
                        endpointNames[createdDestination] = name
                    }
                    return (destinationStatus, createdDestination)
                }
            },
            disposeEndpoint: { [self] endpoint in
                withLock {
                    disposedEndpoints.append(endpoint)
                    let status = endpointDisposalStatuses[endpoint] ?? noErr
                    guard status == noErr else { return status }
                    endpointNames.removeValue(forKey: endpoint)
                    return noErr
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
            },
            endpointRuntime: .init(
                allEndpoints: { [self] in self.allEndpoints() },
                endpointName: { [self] endpoint in self.endpointName(endpoint) },
                setUniqueID: { [self] endpoint, uniqueID in self.setUniqueID(endpoint, uniqueID: uniqueID) },
                processOwnership: processOwnership
            ),
            acquireOwnershipLock: { [self] in acquireOwnershipLock() }
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
                sentMessages: sentMessages,
                assignedUniqueIDs: assignedUniqueIDs
            )
        }
    }

    private func allEndpoints() -> VirtualMIDIEndpointCatalogRead {
        withLock {
            lifecycleEvents.append("census")
            if let catalogReadOverride {
                return catalogReadOverride
            }
            let foreign = foreignEndpointsByName.values.flatMap { $0 }
            return .endpoints(Array(Set(endpointNames.keys).union(foreign)))
        }
    }

    private func endpointName(_ endpoint: MIDIEndpointRef) -> VirtualMIDIEndpointNameRead {
        withLock {
            if unreadableEndpointNames.contains(endpoint) {
                return .unknown("test endpoint name read failed")
            }
            if let name = endpointNames[endpoint] {
                return .name(name)
            }
            for (name, endpoints) in foreignEndpointsByName where endpoints.contains(endpoint) {
                return .name(name)
            }
            return .unknown("test endpoint has no name")
        }
    }

    private func setUniqueID(_ endpoint: MIDIEndpointRef, uniqueID: Int32) -> OSStatus {
        withLock {
            guard uniqueIDStatus == noErr else { return uniqueIDStatus }
            assignedUniqueIDs[endpoint] = uniqueID
            return noErr
        }
    }

    private func acquireOwnershipLock() -> VirtualMIDIEndpointOwnershipLock.Acquisition {
        lock.lock()
        switch ownershipLockMode {
        case .acquired:
            lifecycleEvents.append("lock acquired")
            lock.unlock()
            return .acquired(.testing { [self] in
                lock.lock()
                lifecycleEvents.append("lock released")
                lock.unlock()
            })
        case .held:
            lock.unlock()
            return .held
        case .unavailable(let reason):
            lock.unlock()
            return .unavailable(reason)
        }
    }

    func snapshotLifecycleEvents() -> [String] {
        withLock { lifecycleEvents }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class MIDIBytesRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPackets: [[UInt8]] = []

    func append(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        storedPackets.append(bytes)
    }

    var packets: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return storedPackets
    }
}

private func withCoreMIDIPacketList(
    _ packets: [[UInt8]],
    _ body: (UnsafeMutablePointer<MIDIPacketList>) -> Void
) {
    let payloadSize = packets.reduce(0) { partial, packet in
        partial + max(MemoryLayout<MIDIPacket>.size, packet.count)
    }
    let bufferSize = max(1024, MemoryLayout<MIDIPacketList>.size + payloadSize)
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    buffer.withUnsafeMutableBytes { rawBuffer in
        let packetList = rawBuffer.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
        var currentPacket = MIDIPacketListInit(packetList)

        for packetBytes in packets {
            packetBytes.withUnsafeBufferPointer { bytes in
                if let base = bytes.baseAddress {
                    currentPacket = MIDIPacketListAdd(
                        packetList,
                        bufferSize,
                        currentPacket,
                        0,
                        packetBytes.count,
                        base
                    )
                }
            }
        }

        body(packetList)
    }
}

private func boundaryCrossingPackets() -> [[UInt8]] {
    (0..<64).map { index in
        let value = UInt8(index)
        switch index % 4 {
        case 0:
            return [0x90, value, 0x40]
        case 1:
            return [0xF0, 0x7D, value, 0xF7]
        case 2:
            return [0xF0, 0x7D, 0x01, value, 0xF7]
        default:
            return [0xF0, 0x7D, 0x01, 0x02, value, 0xF7]
        }
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
    #expect(started.createDestinationCalls == 0)   // #755 — no destination is published
    #expect(started.lastClientName == ServerConfig.virtualMIDISourceName)
    #expect(started.lastSourceName == ServerConfig.virtualMIDISourceName)
    #expect(
        started.assignedUniqueIDs[harness.createdSource]
            == VirtualMIDIEndpointIdentity.uniqueID(
                forPortNamed: ServerConfig.virtualMIDISourceName,
                kind: .source
            )
    )

    await engine.stop()
    await engine.stop()
    #expect(!(await engine.isActive))

    let stopped = harness.snapshot()
    #expect(stopped.disposedEndpoints == [harness.createdSource])
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


@Test func issue736HeldOwnershipLockRefusesMIDIEngineBeforeEndpointCreation() async {
    let harness = MIDIEngineRuntimeHarness()
    harness.ownershipLockMode = .held
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    var refusedPortName: String?
    do {
        try await engine.start()
        Issue.record("Expected MIDIEngine ownership-lock refusal")
    } catch MIDIEngineError.ownershipLockHeld(name: let name) {
        refusedPortName = name
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(refusedPortName == ServerConfig.virtualMIDISourceName)
    let snapshot = harness.snapshot()
    #expect(snapshot.createSourceCalls == 0)
    #expect(snapshot.createDestinationCalls == 0)
    #expect(snapshot.disposedClients == [harness.createdClient])
}

// #736 — the lock must be held across the census AND the creation it decides, or two processes
// each read "nobody owns this" and both publish. One endpoint remains (#755 unpublished the
// destination), so the sequence is one census and one creation; what this pins is that neither
// falls outside the lock, which is the property, not the count.
@Test func issue736MIDIEngineOwnershipLockCoversTheCensusAndTheCreation() async throws {
    let harness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    try await engine.start()

    let observedEvents = harness.snapshotLifecycleEvents()
    #expect(observedEvents == [
        "lock acquired",
        "census",
        "source creation",
        "lock released",
    ])

    await engine.stop()
}

@Test func issue736MIDIEngineUnknownCensusRefusesEndpointCreation() async throws {
    let harness = MIDIEngineRuntimeHarness()
    harness.catalogReadOverride = .unknown("test catalog read failed")
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    var unknownCensus: VirtualMIDIEndpointCensus?
    do {
        try await engine.start()
        Issue.record("Expected MIDIEngine unknown-census refusal")
    } catch MIDIEngineError.censusUnknown(_, census: let census) {
        unknownCensus = census
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let observedCensus = try #require(unknownCensus)
    #expect(observedCensus.state == .unknown)
    #expect(observedCensus.endpointCount == nil)
    let snapshot = harness.snapshot()
    #expect(snapshot.createSourceCalls == 0)
    #expect(snapshot.createDestinationCalls == 0)
}

@Test func issue736ObservedEmptyCensusCannotReportAnOwnershipConflict() {
    let emptyCensus = VirtualMIDIEndpointCensus(endpointCount: 0, hasForeignEndpoint: true)

    let reportsConflict = emptyCensus.hasForeignConflict
    let doesNotReportConflict = !reportsConflict

    #expect(doesNotReportConflict)
}

@Test func issue736MIDIEngineOwnershipIsSharedWithPortManager() async throws {
    let processOwnership = VirtualMIDIEndpointProcessOwnership()
    let engineHarness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: engineHarness.makeRuntime(processOwnership: processOwnership))
    try await engine.start()

    let managerHarness = MIDIPortRuntimeHarness()
    managerHarness.foreignEndpointsByName[ServerConfig.virtualMIDISourceName] = [engineHarness.createdSource]
    let manager = MIDIPortManager(runtime: managerHarness.runtime(processOwnership: processOwnership))
    try await manager.start()

    let census = await manager.endpointCensus(name: ServerConfig.virtualMIDISourceName)
    let hasForeignEndpoint = try #require(census.hasForeignEndpoint as Bool?)
    let treatsEngineEndpointAsLocal = !hasForeignEndpoint
    #expect(treatsEngineEndpointAsLocal)

    await manager.stop()
    await engine.stop()
}

@Test func issue736EndpointClaimedByAnotherProcessStillConflicts() async throws {
    let otherProcessOwnership = VirtualMIDIEndpointProcessOwnership()
    let thisProcessOwnership = VirtualMIDIEndpointProcessOwnership()
    let portName = ServerConfig.virtualMIDISourceName
    let otherProcessHarness = MIDIEngineRuntimeHarness()
    let otherProcessEngine = MIDIEngine(
        runtime: otherProcessHarness.makeRuntime(processOwnership: otherProcessOwnership)
    )
    try await otherProcessEngine.start()
    // This testing process also has a claim for the same integer reference.
    // A census must use *its configured process registry*, not whichever
    // process-wide singleton happens to contain the reference.
    VirtualMIDIEndpointProcessOwnership.shared.claim(otherProcessHarness.createdSource)

    let harness = MIDIPortRuntimeHarness()
    harness.foreignEndpointsByName[portName] = [otherProcessHarness.createdSource]
    let manager = MIDIPortManager(runtime: harness.runtime(processOwnership: thisProcessOwnership))
    try await manager.start()

    var conflict: MIDIPortError?
    do {
        _ = try await manager.createSendOnlyPort(name: portName)
        Issue.record("Expected the other process endpoint to be refused")
    } catch let error as MIDIPortError {
        conflict = error
    }

    guard case .foreignEndpointConflict(name: let rejectedName, census: let census)? = conflict else {
        Issue.record("Expected foreign endpoint conflict, got: \(String(describing: conflict))")
        await manager.stop()
        VirtualMIDIEndpointProcessOwnership.shared.release(otherProcessHarness.createdSource)
        await otherProcessEngine.stop()
        return
    }
    let isOtherProcessEndpoint = rejectedName == portName && census.hasForeignConflict
    #expect(isOtherProcessEndpoint)

    await manager.stop()
    VirtualMIDIEndpointProcessOwnership.shared.release(otherProcessHarness.createdSource)
    await otherProcessEngine.stop()
}

@Test func issue736OwnershipConflictSurvivesToCoreMIDIOperationResponse() async throws {
    let harness = MIDIEngineRuntimeHarness()
    harness.foreignEndpointsByName[ServerConfig.virtualMIDISourceName] = [999]
    let engine = MIDIEngine(runtime: harness.makeRuntime())
    let channel = CoreMIDIChannel(engine: engine)

    do {
        try await channel.start()
        Issue.record("Expected CoreMIDI startup ownership conflict")
    } catch MIDIEngineError.foreignEndpointConflict {
        // The engine records this cause for subsequent health and routing reads.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let router = ChannelRouter()
    await router.register(channel)
    let response = await MIDIDispatcher.handle(
        command: "send_cc",
        params: ["controller": .int(74), "value": .int(80), "channel": .int(3)],
        router: router,
        cache: StateCache()
    )
    #expect(response.isError!)
    let envelope = try #require(sharedJSONObject(sharedToolText(response)))
    #expect(envelope["error"] as? String == "channels_exhausted")
    let hint = try #require(envelope["hint"] as? String)
    let namesOwnershipConflict = hint.contains("held by another process")
    let namesConflictingPort = hint.contains(ServerConfig.virtualMIDISourceName)
    #expect(namesOwnershipConflict)
    #expect(namesConflictingPort)
}

@Test func testMIDIEngineSendMethodsEncodeExpectedBytes() async throws {
    let harness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: harness.makeRuntime())
    try await engine.start()

    try await engine.sendNoteOn(channel: 0x11, note: 0xFF, velocity: 0xFE)
    try await engine.sendNoteOff(channel: 0x12, note: 61, velocity: 0)
    try await engine.sendCC(channel: 0x13, controller: 0x87, value: 0xC0)
    try await engine.sendProgramChange(channel: 0x14, program: 10)
    try await engine.sendPitchBend(channel: 0x15, value: 20_000)
    try await engine.sendAftertouch(channel: 0x16, pressure: 0xFF)
    try await engine.sendSysEx([0xF0, 0x7D, 0x01, 0xF7])
    do {
        try await engine.sendSysEx([0xF0, 0x7D, 0x80, 0xF7])
        Issue.record("Expected invalid SysEx to throw")
    } catch MIDIEngineError.invalidSysEx {
        // Expected.
    } catch {
        Issue.record("Unexpected invalid SysEx error: \(error)")
    }
    try await engine.sendRawBytes([0xF6])

    let snapshot = harness.snapshot()
    #expect(snapshot.sentSources == Array(repeating: harness.createdSource, count: 8))
    #expect(snapshot.sentMessages == [
        [0x91, 0x7F, 0x7E],
        [0x82, 61, 0],
        [0xB3, 0x07, 0x40],
        [0xC4, 10],
        [0xE5, 0x7F, 0x7F],
        [0xD6, 0x7F],
        [0xF0, 0x7D, 0x01, 0xF7],
        [0xF6],
    ])
}

@Test func testMIDIEngineSendRawBytesThrowsWhenInactive() async {
    let harness = MIDIEngineRuntimeHarness()
    let engine = MIDIEngine(runtime: harness.makeRuntime())

    await #expect(throws: MIDIEngineError.self) {
        try await engine.sendNoteOn(channel: 0, note: 60, velocity: 100)
    }
    await #expect(throws: MIDIEngineError.self) {
        try await engine.sendSysEx([0xF0, 0x7D, 0x01, 0xF7])
    }
    await #expect(throws: MIDIEngineError.self) {
        try await engine.sendRawBytes([0xF6])
    }

    let snapshot = harness.snapshot()
    #expect(snapshot.sentMessages.isEmpty)
}

@Test func testMIDIEngineSendFailureThrowsAfterAttemptingDelivery() async throws {
    let harness = MIDIEngineRuntimeHarness()
    harness.sendStatus = -40
    let engine = MIDIEngine(runtime: harness.makeRuntime())
    try await engine.start()

    do {
        try await engine.sendCC(channel: 9, controller: 10, value: 11)
        Issue.record("Expected send failure to throw")
    } catch MIDIEngineError.sendFailed(let status) {
        #expect(status == -40)
    } catch {
        Issue.record("Unexpected send failure error: \(error)")
    }

    let snapshot = harness.snapshot()
    #expect(snapshot.sentMessages == [[0xB9, 10, 11]])
    #expect(await engine.isActive)
}


// 64 deliberately varied packets exceed the one-packet window a Swift value copy
// of MIDIPacketList retains. Comparing the complete array also pins packet order.

// Three tests were removed with the inbound destination (#755): the one asserting that a
// destination-creation failure propagates and disposes intermediates, the one driving
// `inboundMessages` from runtime bytes, and T-H1's restart proof that a second start() restored
// the inbound path. None of the three has a subject any more — nothing is created, nothing
// yields, and there is no inbound path to restore.
//
// What did NOT go with them is the traversal #735 fixed:
// `testMIDIEngineReceivesEveryPacketAcrossMIDIPacketListCopyBoundary` drives 64 packets across
// the value-copy boundary that crashed, against a real CoreMIDI packet list, and
// `testMIDIEngineRejectsOversizedMIDIPacketDataTuple` covers the 257-byte reject. Those are the
// crash conditions; the live harness that sent to the endpoint proved the PLUMBING, and the
// plumbing is what this change removes.

@Test func testMIDIEngineReceivesEveryPacketAcrossMIDIPacketListCopyBoundary() {
    let expectedPackets = boundaryCrossingPackets()
    let recorder = MIDIBytesRecorder()

    withCoreMIDIPacketList(expectedPackets) { packetList in
        MIDIEngine.receivePackets(from: packetList) { bytes in
            recorder.append(bytes)
        }
    }

    let receivedPackets = recorder.packets
    #expect(receivedPackets == expectedPackets)
}

@Test func testMIDIEngineRejectsOversizedMIDIPacketDataTuple() {
    let recorder = MIDIBytesRecorder()

    withCoreMIDIPacketList([[0x90, 0x3C, 0x64]]) { packetList in
        packetList.pointee.packet.length = 257
        MIDIEngine.receivePackets(from: packetList) { bytes in
            recorder.append(bytes)
        }
    }

    let receivedPackets = recorder.packets
    #expect(receivedPackets.isEmpty)
}


@Test(coreMIDIUnavailableInSandbox)
func testMIDIEngineProductionRuntimeStartStopSmoke() async throws {
    let endpointRuntime = VirtualMIDIEndpointRuntime.production
    // Only the source is censused: #755 unpublished the destination, so there is no second
    // production name for a prior process to own.
    let sourceCensus = endpointRuntime.census(named: ServerConfig.virtualMIDISourceName)
    guard sourceCensus.isObserved,
          let sourceCount = sourceCensus.endpointCount else {
        print("SKIPPED testMIDIEngineProductionRuntimeStartStopSmoke: CoreMIDI endpoint census is unknown.")
        return
    }
    guard sourceCount == 0 else {
        // This smoke test cannot safely exercise fixed production names when a
        // prior process owns them: creation must now refuse that conflict rather
        // than publishing a second endpoint. A clean preflight still requires a
        // successful product start below.
        print(
            "SKIPPED testMIDIEngineProductionRuntimeStartStopSmoke: pre-existing virtual endpoint(s) "
                + "(sources \(sourceCount))."
        )
        return
    }

    let engine = MIDIEngine()

    // A client-creation failure has two causes and only one is a defect: the
    // environment already refusing CoreMIDI, or start() being broken. Keep a
    // direct preflight probe, then compare it with a post-failure probe; asking
    // only after start() could excuse a product path that poisoned MIDIServer.
    // This replaced a check for one hardcoded status (-50, what a CI runner
    // returns), which read every OTHER environmental refusal as a product
    // failure.
    let preflightProbeStatus = coreMIDIRefusesAClientRightNow()
    do {
        try await engine.start()
    } catch let error as MIDIEngineError {
        let postFailureProbeStatus = coreMIDIRefusesAClientRightNow()
        guard case .clientCreationFailed(let startStatus) = error,
              let preflightProbeStatus,
              let postFailureProbeStatus,
              coreMIDIRefusalPredatedProductStart(
                  before: preflightProbeStatus,
                  after: postFailureProbeStatus
              ) else {
            // A different failure, healthy preflight, or recovered post-failure
            // probe leaves the product start as the failing path.
            throw error
        }
        reportCoreMIDIUnavailable(
            "testMIDIEngineProductionRuntimeStartStopSmoke",
            startStatus: startStatus,
            preflightProbeStatus: preflightProbeStatus,
            postFailureProbeStatus: postFailureProbeStatus
        )
        return
    }
    #expect(await engine.isActive)

    try await engine.sendRawBytes([])
    try await engine.sendCC(channel: 0, controller: 1, value: 64)

    await engine.stop()
    #expect(!(await engine.isActive))
}

@Test func testCoreMIDIRefusalMustPredateProductStartToExcuseSmokeFailure() {
    let unavailableBeforeAndAfter = coreMIDIRefusalPredatedProductStart(before: -2, after: -2)
    let healthyBeforeThenUnavailable = coreMIDIRefusalPredatedProductStart(before: nil, after: -2)

    #expect(unavailableBeforeAndAfter)
    // This is the mutation guard: accepting a post-failure probe by itself
    // makes a broken product start on a healthy host silently pass.
    #expect(!healthyBeforeThenUnavailable)
}

@Test(coreMIDIUnavailableInSandbox)
func testCoreMIDIAvailabilityProbeAnswersForItselfRatherThanExcusingAnything() {
    // The probe is what keeps the production smoke tests from excusing a real
    // defect. If it ever reported a refusal on a host where CoreMIDI is fine,
    // those tests would pass no matter how broken start() became.
    //
    // On a host that CAN create a client this must be nil. On a host that
    // cannot, the smoke tests are skipped and so is this — the trait and the
    // probe agree about what "unavailable" means.
    let refusal = coreMIDIRefusesAClientRightNow()
    if let refusal {
        // Not a failure: the environment genuinely refuses. Say so loudly so a
        // green run is never mistaken for one that exercised CoreMIDI.
        print("SKIPPED probe self-check: CoreMIDI refused a client (status \(refusal)).")
        return
    }
    // The probe must also leave nothing behind: a leaked client would change
    // MIDIServer's lifecycle for every later test in this process.
    #expect(coreMIDIRefusesAClientRightNow() == nil)
}
