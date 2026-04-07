import CoreMIDI
import Foundation
import Testing
@testable import LogicProMCP

final class MIDIPortRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var nextClientRef: MIDIClientRef = 100
    private var nextEndpointRef: MIDIEndpointRef = 200

    var clientStatus: OSStatus = noErr
    var sourceStatuses: [String: OSStatus] = [:]
    var destinationStatuses: [String: OSStatus] = [:]
    private(set) var createdClients: [String] = []
    private(set) var createdSources: [String] = []
    private(set) var createdDestinations: [String] = []
    private(set) var disposedEndpoints: [MIDIEndpointRef] = []
    private(set) var disposedClients: [MIDIClientRef] = []

    func runtime() -> MIDIPortManager.Runtime {
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
            }
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
        let status = sourceStatuses[name] ?? noErr
        guard status == noErr else {
            return status
        }
        source = nextEndpointRef
        nextEndpointRef += 1
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
        let status = destinationStatuses[name] ?? noErr
        guard status == noErr else {
            return status
        }
        destination = nextEndpointRef
        nextEndpointRef += 1
        return noErr
    }

    func disposeEndpoint(_ endpoint: MIDIEndpointRef) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        disposedEndpoints.append(endpoint)
        return noErr
    }

    func disposeClient(_ client: MIDIClientRef) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        disposedClients.append(client)
        return noErr
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

@Test func testMIDIPortManagerProductionRuntimeSmokeCreatesAndStopsPorts() async throws {
    let manager = MIDIPortManager()
    let sendOnlyName = "LogicProMCP-Smoke-\(UUID().uuidString)"
    let bidirectionalName = "LogicProMCP-Smoke-Bidi-\(UUID().uuidString)"

    try await manager.start()

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
