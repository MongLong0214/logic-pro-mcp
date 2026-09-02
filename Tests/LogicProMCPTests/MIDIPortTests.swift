import CoreMIDI
import Foundation
import Testing
@testable import LogicProMCP

final class MIDIPortRuntimeHarness: @unchecked Sendable {
    enum OwnershipLockMode: Sendable {
        case acquired
        case held
        case unavailable(String)
    }

    private let lock = NSLock()
    private var nextClientRef: MIDIClientRef = 100
    private var nextEndpointRef: MIDIEndpointRef = 200

    var clientStatus: OSStatus = noErr
    var sourceStatuses: [String: OSStatus] = [:]
    var destinationStatuses: [String: OSStatus] = [:]
    var endpointDisposalStatuses: [MIDIEndpointRef: OSStatus] = [:]
    var uniqueIDStatus: OSStatus = noErr
    var foreignEndpointsByName: [String: [MIDIEndpointRef]] = [:]
    var catalogReadOverride: VirtualMIDIEndpointCatalogRead?
    var unreadableEndpointNames: Set<MIDIEndpointRef> = []
    var ownershipLockMode: OwnershipLockMode = .acquired
    private(set) var createdClients: [String] = []
    private(set) var createdSources: [String] = []
    private(set) var createdDestinations: [String] = []
    private(set) var disposedEndpoints: [MIDIEndpointRef] = []
    private(set) var disposedClients: [MIDIClientRef] = []
    private(set) var assignedUniqueIDs: [MIDIEndpointRef: Int32] = [:]
    private var endpointNames: [MIDIEndpointRef: String] = [:]
    private var claimedUniqueIDs: [Int32: MIDIEndpointRef] = [:]
    private var lifecycleEvents: [String] = []

    func runtime(
        processOwnership: VirtualMIDIEndpointProcessOwnership = .shared
    ) -> MIDIPortManager.Runtime {
        MIDIPortManager.Runtime(
            createClient: { name, client in
                self.createClient(name: name, client: &client)
            },
            createSource: { client, name, source in
                self.createSource(client: client, name: name, source: &source)
            },
            createDestination: { client, name, destination, onReceive in
                self.createDestination(client: client, name: name, destination: &destination, onReceive: onReceive)
            },
            disposeEndpoint: { endpoint in
                self.disposeEndpoint(endpoint)
            },
            disposeClient: { client in
                self.disposeClient(client)
            },
            endpointRuntime: .init(
                allEndpoints: { self.allEndpoints() },
                endpointName: { endpoint in self.endpointName(endpoint) },
                setUniqueID: { endpoint, uniqueID in self.setUniqueID(endpoint, uniqueID: uniqueID) },
                processOwnership: processOwnership
            ),
            acquireOwnershipLock: { self.acquireOwnershipLock() }
        )
    }

    func createClient(name: String, client: inout MIDIClientRef) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        createdClients.append(name)
        guard clientStatus == noErr else {
            return clientStatus
        }
        client = nextClientRef
        nextClientRef += 1
        return noErr
    }

    func createSource(client: MIDIClientRef, name: String, source: inout MIDIEndpointRef) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        createdSources.append(name)
        lifecycleEvents.append("source creation")
        let status = sourceStatuses[name] ?? noErr
        guard status == noErr else {
            return status
        }
        source = nextEndpointRef
        nextEndpointRef += 1
        endpointNames[source] = name
        return noErr
    }

    func createDestination(
        client: MIDIClientRef,
        name: String,
        destination: inout MIDIEndpointRef,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        createdDestinations.append(name)
        lifecycleEvents.append("destination creation")
        let status = destinationStatuses[name] ?? noErr
        guard status == noErr else {
            return status
        }
        destination = nextEndpointRef
        nextEndpointRef += 1
        endpointNames[destination] = name
        return noErr
    }

    func disposeEndpoint(_ endpoint: MIDIEndpointRef) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        disposedEndpoints.append(endpoint)
        let status = endpointDisposalStatuses[endpoint] ?? noErr
        guard status == noErr else {
            return status
        }
        endpointNames.removeValue(forKey: endpoint)
        assignedUniqueIDs.removeValue(forKey: endpoint)
        claimedUniqueIDs = claimedUniqueIDs.filter { $0.value != endpoint }
        return noErr
    }

    func disposeClient(_ client: MIDIClientRef) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        disposedClients.append(client)
        return noErr
    }

    func allEndpoints() -> VirtualMIDIEndpointCatalogRead {
        lock.lock()
        defer { lock.unlock() }
        lifecycleEvents.append("census")
        if let catalogReadOverride {
            return catalogReadOverride
        }
        let foreign = foreignEndpointsByName.values.flatMap { $0 }
        return .endpoints(Array(Set(endpointNames.keys).union(foreign)))
    }

    func endpointName(_ endpoint: MIDIEndpointRef) -> VirtualMIDIEndpointNameRead {
        lock.lock()
        defer { lock.unlock() }
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

    func setUniqueID(_ endpoint: MIDIEndpointRef, uniqueID: Int32) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard uniqueIDStatus == noErr else { return uniqueIDStatus }
        if let claimant = claimedUniqueIDs[uniqueID], claimant != endpoint {
            return kMIDIIDNotUnique
        }
        assignedUniqueIDs[endpoint] = uniqueID
        claimedUniqueIDs[uniqueID] = endpoint
        return noErr
    }

    func acquireOwnershipLock() -> VirtualMIDIEndpointOwnershipLock.Acquisition {
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
        lock.lock()
        defer { lock.unlock() }
        return lifecycleEvents
    }
}

@Test func testMIDIPortManagerPortCountStartsAtZero() async {
    let manager = MIDIPortManager(runtime: MIDIPortRuntimeHarness().runtime())
    #expect(await manager.portCount == 0)
    #expect(await manager.getPort(name: "nonexistent") == nil)
}

@Test func testMIDIPortManagerRejectsPortCreationBeforeStart() async {
    let manager = MIDIPortManager(runtime: MIDIPortRuntimeHarness().runtime())

    do {
        _ = try await manager.createSendOnlyPort(name: "LogicProMCP-KeyCmd-Internal")
        Issue.record("Expected notRunning error for send-only port creation")
    } catch let error as MIDIPortError {
        guard case .notRunning = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected non-MIDIPortError: \(error)")
    }

    do {
        _ = try await manager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { _, _ in }
        Issue.record("Expected notRunning error for bidirectional port creation")
    } catch let error as MIDIPortError {
        guard case .notRunning = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected non-MIDIPortError: \(error)")
    }
}

@Test func testMIDIPortManagerStartIsIdempotentAndStopDisposesClient() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())

    try await manager.start()
    try await manager.start()
    await manager.stop()
    await manager.stop()

    #expect(harness.createdClients == ["LogicProMCP"])
    #expect(harness.disposedClients == [100])
    #expect(await manager.portCount == 0)
}

@Test func testMIDIPortManagerCreateSendOnlyPortReusesExistingPair() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    let first = try await manager.createSendOnlyPort(name: "LogicProMCP-KeyCmd-Internal")
    let second = try await manager.createSendOnlyPort(name: "LogicProMCP-KeyCmd-Internal")

    #expect(first.name == "LogicProMCP-KeyCmd-Internal")
    #expect(first.source == second.source)
    #expect(first.destination == nil)
    #expect(harness.createdSources == ["LogicProMCP-KeyCmd-Internal"])
    #expect(await manager.portCount == 1)
}

@Test func testMIDIPortManagerCreateBidirectionalPortReusesExistingPair() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    let first = try await manager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { _, _ in }
    let second = try await manager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { _, _ in }

    #expect(first.name == "LogicProMCP-MCU-Internal")
    #expect(first.source == second.source)
    #expect(first.destination == second.destination)
    #expect(first.destination != nil)
    #expect(harness.createdSources == ["LogicProMCP-MCU-Internal"])
    #expect(harness.createdDestinations == ["LogicProMCP-MCU-Internal"])
    #expect(await manager.portCount == 1)
}

@Test func sendOnly_then_bidirectional_same_name_throws_modeConflict() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    _ = try await manager.createSendOnlyPort(name: "LogicProMCP-Shared-Internal")

    do {
        _ = try await manager.createBidirectionalPort(name: "LogicProMCP-Shared-Internal") { _, _ in }
        Issue.record("Expected modeConflict when reusing send-only name as bidirectional")
    } catch MIDIPortError.modeConflict(name: let name, existing: let existing, requested: let requested) {
        #expect(name == "LogicProMCP-Shared-Internal")
        #expect(existing == .sendOnly)
        #expect(requested == .bidirectional)
    } catch {
        Issue.record("Unexpected non-MIDIPortError: \(error)")
    }

    #expect(harness.createdSources == ["LogicProMCP-Shared-Internal"])
    #expect(harness.createdDestinations.isEmpty)
    #expect(await manager.portCount == 1)
}

@Test func bidirectional_then_sendOnly_same_name_throws_modeConflict() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    _ = try await manager.createBidirectionalPort(name: "LogicProMCP-Shared-Internal") { _, _ in }

    do {
        _ = try await manager.createSendOnlyPort(name: "LogicProMCP-Shared-Internal")
        Issue.record("Expected modeConflict when reusing bidirectional name as send-only")
    } catch MIDIPortError.modeConflict(name: let name, existing: let existing, requested: let requested) {
        #expect(name == "LogicProMCP-Shared-Internal")
        #expect(existing == .bidirectional)
        #expect(requested == .sendOnly)
    } catch {
        Issue.record("Unexpected non-MIDIPortError: \(error)")
    }

    #expect(harness.createdSources == ["LogicProMCP-Shared-Internal"])
    #expect(harness.createdDestinations == ["LogicProMCP-Shared-Internal"])
    #expect(await manager.portCount == 1)
}

@Test func same_name_same_mode_reuse_preserved_across_restart() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    let first = try await manager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { _, _ in }
    let restarted = try await manager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { _, _ in }

    #expect(restarted.source == first.source)
    #expect(restarted.destination == first.destination)
    #expect(harness.createdSources == ["LogicProMCP-MCU-Internal"])
    #expect(harness.createdDestinations == ["LogicProMCP-MCU-Internal"])
    #expect(await manager.portCount == 1)
}

@Test func testMIDIPortManagerClientCreationFailureSurfacesError() async {
    let harness = MIDIPortRuntimeHarness()
    harness.clientStatus = -50
    let manager = MIDIPortManager(runtime: harness.runtime())

    do {
        try await manager.start()
        Issue.record("Expected clientCreationFailed error")
    } catch let error as MIDIPortError {
        guard case .clientCreationFailed(let status) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(status == -50)
    } catch {
        Issue.record("Unexpected non-MIDIPortError: \(error)")
    }
}

@Test func testMIDIPortManagerSourceCreationFailureSurfacesError() async throws {
    let harness = MIDIPortRuntimeHarness()
    harness.sourceStatuses["LogicProMCP-KeyCmd-Internal"] = -60
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    do {
        _ = try await manager.createSendOnlyPort(name: "LogicProMCP-KeyCmd-Internal")
        Issue.record("Expected sourceCreationFailed error")
    } catch let error as MIDIPortError {
        guard case .sourceCreationFailed(let name, let status) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(name == "LogicProMCP-KeyCmd-Internal")
        #expect(status == -60)
    } catch {
        Issue.record("Unexpected non-MIDIPortError: \(error)")
    }
}

@Test func testMIDIPortManagerDestinationCreationFailureDisposesSource() async throws {
    let harness = MIDIPortRuntimeHarness()
    harness.destinationStatuses["LogicProMCP-MCU-Internal"] = -70
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    do {
        _ = try await manager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { _, _ in }
        Issue.record("Expected destinationCreationFailed error")
    } catch let error as MIDIPortError {
        guard case .destinationCreationFailed(let name, let status) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(name == "LogicProMCP-MCU-Internal")
        #expect(status == -70)
    } catch {
        Issue.record("Unexpected non-MIDIPortError: \(error)")
    }

    #expect(harness.disposedEndpoints == [200])
    #expect(await manager.portCount == 0)
}

@Test func testMIDIPortManagerStopDisposesAllPortsAndClearsCache() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    let sendOnly = try await manager.createSendOnlyPort(name: "LogicProMCP-KeyCmd-Internal")
    let bidirectional = try await manager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { _, _ in }

    await manager.stop()

    #expect(await manager.portCount == 0)
    #expect(await manager.getPort(name: sendOnly.name) == nil)
    #expect(await manager.getPort(name: bidirectional.name) == nil)
    #expect(
        harness.disposedEndpoints.sorted() == [sendOnly.source, bidirectional.source, bidirectional.destination!].sorted()
    )
    #expect(harness.disposedClients == [100])
}

@Test func issue736OwnershipLockCoversCensusAndBothEndpointCreations() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    _ = try await manager.createBidirectionalPort(name: "LogicProMCP-Lock-Sequence") { _, _ in }

    let observedEvents = harness.snapshotLifecycleEvents()
    #expect(observedEvents == [
        "lock acquired",
        "census",
        "source creation",
        "destination creation",
        "lock released",
    ])

    await manager.stop()
}

@Test func issue736HeldOwnershipLockRefusesPortCreationWithoutPublishingEndpoint() async throws {
    let harness = MIDIPortRuntimeHarness()
    harness.ownershipLockMode = .held
    let manager = MIDIPortManager(runtime: harness.runtime())
    let name = "LogicProMCP-Locked-Port"
    try await manager.start()

    var refusedPortName: String?
    do {
        _ = try await manager.createSendOnlyPort(name: name)
        Issue.record("Expected ownership-lock refusal")
    } catch MIDIPortError.ownershipLockHeld(name: let rejectedName) {
        refusedPortName = rejectedName
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(refusedPortName == name)
    let createdSources = harness.createdSources
    #expect(createdSources.isEmpty)

    await manager.stop()
}

@Test func issue736UnknownCatalogAndUnreadableEndpointNameRefuseCreation() async throws {
    let catalogFailureHarness = MIDIPortRuntimeHarness()
    catalogFailureHarness.catalogReadOverride = .unknown("test catalog read failed")
    let catalogFailureManager = MIDIPortManager(runtime: catalogFailureHarness.runtime())
    try await catalogFailureManager.start()

    var catalogFailureCensus: VirtualMIDIEndpointCensus?
    do {
        _ = try await catalogFailureManager.createSendOnlyPort(name: "LogicProMCP-Unknown-Catalog")
        Issue.record("Expected unknown-census refusal")
    } catch MIDIPortError.censusUnknown(_, census: let census) {
        catalogFailureCensus = census
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let observedCatalogFailure = try #require(catalogFailureCensus)
    #expect(observedCatalogFailure.state == .unknown)
    #expect(observedCatalogFailure.endpointCount == nil)
    let catalogFailureCreates = catalogFailureHarness.createdSources
    #expect(catalogFailureCreates.isEmpty)

    let unreadableNameHarness = MIDIPortRuntimeHarness()
    let unreadableName = "LogicProMCP-Unreadable-Name"
    unreadableNameHarness.foreignEndpointsByName[unreadableName] = [999]
    unreadableNameHarness.unreadableEndpointNames.insert(999)
    let unreadableNameManager = MIDIPortManager(runtime: unreadableNameHarness.runtime())
    try await unreadableNameManager.start()

    var unreadableNameCensus: VirtualMIDIEndpointCensus?
    do {
        _ = try await unreadableNameManager.createSendOnlyPort(name: unreadableName)
        Issue.record("Expected unreadable-name census refusal")
    } catch MIDIPortError.censusUnknown(_, census: let census) {
        unreadableNameCensus = census
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let observedUnreadableName = try #require(unreadableNameCensus)
    #expect(observedUnreadableName.state == .unknown)
    let unreadableReason = try #require(observedUnreadableName.reason)
    let reasonNamesReadFailure = unreadableReason.contains("name read failed")
    #expect(reasonNamesReadFailure)
    let unreadableNameCreates = unreadableNameHarness.createdSources
    #expect(unreadableNameCreates.isEmpty)

    await catalogFailureManager.stop()
    await unreadableNameManager.stop()
}

@Test func issue736HealthPublishesUnknownCensusWithoutInventingZero() async throws {
    let harness = MIDIPortRuntimeHarness()
    harness.catalogReadOverride = .unknown("test catalog read failed")
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()
    let cache = StateCache()
    let channel = MCUChannel(
        transport: ProductionMCUTransport(portManager: manager),
        cache: cache
    )
    do {
        try await channel.start()
        Issue.record("Expected unknown-census startup refusal")
    } catch MIDIPortError.censusUnknown {
        // The health read below must preserve unknown rather than publish zero.
    }

    let router = ChannelRouter()
    await router.register(channel)
    let result = await SystemDispatcher.handle(
        command: "health",
        params: [:],
        router: router,
        cache: cache
    )
    let json = try #require(sharedParseJSON(sharedToolText(result)) as? [String: Any])
    let mcu = try #require(json["mcu"] as? [String: Any])
    let census = try #require(mcu["port_census"] as? [String: Any])
    let state = try #require(census["state"] as? String)
    let reason = try #require(census["reason"] as? String)
    #expect(state == "unknown")
    let reasonNamesCatalogFailure = reason.contains("catalog read failed")
    #expect(reasonNamesCatalogFailure)
    #expect(census["endpoint_count"] == nil)
    #expect(census["has_foreign_endpoint"] == nil)

    await channel.stop()
    await manager.stop()
}

@Test func issue736FailedEndpointDisposalKeepsProcessOwnership() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    let name = "LogicProMCP-Disposal-Failure"
    try await manager.start()
    let port = try await manager.createSendOnlyPort(name: name)
    harness.endpointDisposalStatuses[port.source] = -99

    await manager.stop()

    // A new manager models the next start in the same server process. The
    // leaked endpoint must remain ours rather than becoming a false foreign
    // conflict simply because the actor that created it has stopped.
    let restartedManager = MIDIPortManager(runtime: harness.runtime())
    try await restartedManager.start()
    let postFailureCensus = await restartedManager.endpointCensus(name: name)
    #expect(postFailureCensus.state == .observed)
    #expect(postFailureCensus.endpointCount == 1)
    let endpointRemainsOwned = try #require(postFailureCensus.hasForeignEndpoint)
    #expect(!endpointRemainsOwned)

    await restartedManager.stop()

    // The harness deliberately models a leaked endpoint. Its process-wide
    // ownership entry must be cleaned up here so it cannot alias a later fake
    // CoreMIDI reference in this test process.
    harness.endpointDisposalStatuses[port.source] = noErr
    _ = harness.disposeEndpoint(port.source)
    VirtualMIDIEndpointProcessOwnership.shared.release(port.source)
}

@Test func issue736RealHashCollisionIsRefusedAndLeavesManagerUsable() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    let firstName = "kRPI1eQeasjZ"
    let collidingName = "Y65lWHfsr5sr"
    let recoveryName = "LogicProMCP-Collision-Recovery"
    let firstID = VirtualMIDIEndpointIdentity.uniqueID(forPortNamed: firstName, kind: .source)
    let collidingID = VirtualMIDIEndpointIdentity.uniqueID(forPortNamed: collidingName, kind: .source)
    try await manager.start()

    #expect(firstID == collidingID)
    let firstPort = try await manager.createSendOnlyPort(name: firstName)

    var collisionName: String?
    var collisionID: Int32?
    do {
        _ = try await manager.createSendOnlyPort(name: collidingName)
        Issue.record("Expected the pinned FNV collision to be refused")
    } catch MIDIPortError.uniqueIDCollision(name: let rejectedName, kind: let kind, uniqueID: let rejectedID) {
        guard kind == .source else {
            Issue.record("Expected source collision, got \(kind)")
            await manager.stop()
            return
        }
        collisionName = rejectedName
        collisionID = rejectedID
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(collisionName == collidingName)
    #expect(collisionID == firstID)
    let survivingFirstPort = try #require(await manager.getPort(name: firstName))
    #expect(survivingFirstPort.source == firstPort.source)
    #expect(await manager.getPort(name: collidingName) == nil)

    let recoveryPort = try await manager.createSendOnlyPort(name: recoveryName)
    #expect(recoveryPort.name == recoveryName)
    #expect(await manager.portCount == 2)

    await manager.stop()
}

@Test func issue736ForeignEndpointSkipsCreationAndHealthReportsOwnershipConflict() async throws {
    let harness = MIDIPortRuntimeHarness()
    let name = "LogicProMCP-MCU-Internal"
    harness.foreignEndpointsByName[name] = [999]
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    let cache = StateCache()
    let channel = MCUChannel(
        transport: ProductionMCUTransport(portManager: manager),
        cache: cache
    )

    do {
        try await channel.start()
        Issue.record("Expected foreign endpoint conflict")
    } catch MIDIPortError.foreignEndpointConflict(let conflictingName, let census) {
        #expect(conflictingName == name)
        #expect(census.state == .observed)
        #expect(census.endpointCount == 1)
        let hasForeignEndpoint = try #require(census.hasForeignEndpoint)
        #expect(hasForeignEndpoint)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let createdSources = harness.createdSources
    #expect(createdSources.isEmpty)
    let channelHealth = await channel.healthCheck()
    let conflictDiagnostic = channelHealth.detail.contains("did not create")
    #expect(conflictDiagnostic)

    let router = ChannelRouter()
    await router.register(channel)
    let result = await SystemDispatcher.handle(
        command: "health",
        params: [:],
        router: router,
        cache: cache
    )
    let json = try #require(sharedParseJSON(sharedToolText(result)) as? [String: Any])
    let mcu = try #require(json["mcu"] as? [String: Any])
    let census = try #require(mcu["port_census"] as? [String: Any])
    let endpointCount = try #require(census["endpoint_count"] as? Int)
    let hasForeignEndpoint = try #require(census["has_foreign_endpoint"] as? Bool)
    #expect(endpointCount == 1)
    #expect(hasForeignEndpoint)

    await channel.stop()
    await manager.stop()
}

@Test func issue736CleanMCUPortHealthReportsNoForeignEndpoint() async throws {
    let harness = MIDIPortRuntimeHarness()
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    let cache = StateCache()
    let channel = MCUChannel(
        transport: ProductionMCUTransport(portManager: manager),
        cache: cache
    )
    try await channel.start()

    let result = await SystemDispatcher.handle(
        command: "health",
        params: [:],
        router: ChannelRouter(),
        cache: cache
    )
    let json = try #require(sharedParseJSON(sharedToolText(result)) as? [String: Any])
    let mcu = try #require(json["mcu"] as? [String: Any])
    let census = try #require(mcu["port_census"] as? [String: Any])
    let endpointCount = try #require(census["endpoint_count"] as? Int)
    let hasForeignEndpoint = try #require(census["has_foreign_endpoint"] as? Bool)
    #expect(endpointCount == 2)
    #expect(!hasForeignEndpoint)

    await channel.stop()
    await manager.stop()
}

@Test func issue736HealthRefreshesMCUPortCensusInsteadOfPublishingStartupSnapshot() async throws {
    let harness = MIDIPortRuntimeHarness()
    let name = "LogicProMCP-MCU-Internal"
    harness.foreignEndpointsByName[name] = [999]
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    let cache = StateCache()
    let channel = MCUChannel(
        transport: ProductionMCUTransport(portManager: manager),
        cache: cache
    )
    do {
        try await channel.start()
        Issue.record("Expected initial foreign-endpoint refusal")
    } catch MIDIPortError.foreignEndpointConflict {
        // The startup cache now contains the observed conflict.
    }

    harness.foreignEndpointsByName[name] = []
    let router = ChannelRouter()
    await router.register(channel)
    let result = await SystemDispatcher.handle(
        command: "health",
        params: [:],
        router: router,
        cache: cache
    )
    let json = try #require(sharedParseJSON(sharedToolText(result)) as? [String: Any])
    let mcu = try #require(json["mcu"] as? [String: Any])
    let census = try #require(mcu["port_census"] as? [String: Any])
    let state = try #require(census["state"] as? String)
    let endpointCount = try #require(census["endpoint_count"] as? Int)
    let hasForeignEndpoint = try #require(census["has_foreign_endpoint"] as? Bool)
    #expect(state == "observed")
    #expect(endpointCount == 0)
    #expect(!hasForeignEndpoint)

    await channel.stop()
    await manager.stop()
}

@Test func issue736UniqueIDCollisionIsReportedInsteadOfUsingRandomIdentity() async throws {
    let harness = MIDIPortRuntimeHarness()
    harness.uniqueIDStatus = kMIDIIDNotUnique
    let manager = MIDIPortManager(runtime: harness.runtime())
    try await manager.start()

    var collisionWasReported = false
    do {
        _ = try await manager.createSendOnlyPort(name: "LogicProMCP-KeyCmd-Internal")
        Issue.record("Expected stable unique ID collision")
    } catch MIDIPortError.uniqueIDCollision(let name, let kind, let uniqueID) {
        collisionWasReported = name == "LogicProMCP-KeyCmd-Internal"
            && kind == .source
            && uniqueID == VirtualMIDIEndpointIdentity.uniqueID(
                forPortNamed: "LogicProMCP-KeyCmd-Internal",
                kind: .source
            )
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(collisionWasReported)
    #expect(harness.disposedEndpoints == [200])
    #expect(await manager.portCount == 0)
}

@Test func issue736StableUniqueIDsAreRepeatableAndPortSpecific() {
    let first = VirtualMIDIEndpointIdentity.uniqueID(
        forPortNamed: "LogicProMCP-MCU-Internal",
        kind: .source
    )
    let again = VirtualMIDIEndpointIdentity.uniqueID(
        forPortNamed: "LogicProMCP-MCU-Internal",
        kind: .source
    )
    let anotherPort = VirtualMIDIEndpointIdentity.uniqueID(
        forPortNamed: "LogicProMCP-KeyCmd-Internal",
        kind: .source
    )
    let destination = VirtualMIDIEndpointIdentity.uniqueID(
        forPortNamed: "LogicProMCP-MCU-Internal",
        kind: .destination
    )

    let isStable = first == again
    let isPortSpecific = first != anotherPort
    let isDirectionSpecific = first != destination
    #expect(isStable)
    #expect(isPortSpecific)
    #expect(isDirectionSpecific)
}

@Test(coreMIDIUnavailableInSandbox)
func testMIDIPortManagerProductionRuntimeSmokeCreatesAndStopsPorts() async throws {
    let manager = MIDIPortManager()
    let sendOnlyName = "LogicProMCP-Smoke-\(UUID().uuidString)"
    let bidirectionalName = "LogicProMCP-Smoke-Bidi-\(UUID().uuidString)"

    // See the MIDIEngine smoke test: only a refusal seen before AND after this
    // product path is environmental. A post-start probe alone could describe a
    // service this very start() call broke.
    let preflightProbeStatus = coreMIDIRefusesAClientRightNow()
    do {
        try await manager.start()
    } catch let error as MIDIPortError {
        let postFailureProbeStatus = coreMIDIRefusesAClientRightNow()
        guard case .clientCreationFailed(let startStatus) = error,
              let preflightProbeStatus,
              let postFailureProbeStatus,
              coreMIDIRefusalPredatedProductStart(
                  before: preflightProbeStatus,
                  after: postFailureProbeStatus
              ) else {
            throw error
        }
        reportCoreMIDIUnavailable(
            "testMIDIPortManagerProductionRuntimeSmokeCreatesAndStopsPorts",
            startStatus: startStatus,
            preflightProbeStatus: preflightProbeStatus,
            postFailureProbeStatus: postFailureProbeStatus
        )
        return
    }

    let sendOnly = try await manager.createSendOnlyPort(name: sendOnlyName)
    let bidirectional = try await manager.createBidirectionalPort(name: bidirectionalName) { _, _ in }

    #expect(sendOnly.name == sendOnlyName)
    #expect(sendOnly.source != 0)
    #expect(sendOnly.destination == nil)
    #expect(bidirectional.name == bidirectionalName)
    #expect(bidirectional.source != 0)
    #expect(bidirectional.destination != nil)
    #expect(await manager.portCount == 2)

    await manager.stop()

    #expect(await manager.portCount == 0)
}
