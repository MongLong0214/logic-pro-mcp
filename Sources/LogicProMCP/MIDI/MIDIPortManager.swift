import CoreMIDI
import Foundation

protocol VirtualPortManaging: Actor {
    func createSendOnlyPort(name: String) throws -> MIDIPortManager.MIDIPortPair
    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortManager.MIDIPortPair
    func endpointCensus(name: String) -> VirtualMIDIEndpointCensus
}

extension VirtualPortManaging {
    /// Test-only and non-CoreMIDI implementations have no endpoint catalog.
    func endpointCensus(name: String) -> VirtualMIDIEndpointCensus {
        _ = name
        return .none
    }
}

enum MIDIPortMode: String, Sendable {
    case sendOnly = "send_only"
    case bidirectional
}

/// Manages multiple virtual MIDI port pairs for the MCP server.
/// Each channel (MCU, CoreMIDI, KeyCommands, Scripter) gets its own named port.
actor MIDIPortManager: VirtualPortManaging {
    struct Runtime: Sendable {
        let createClient: @Sendable (_ name: String, _ client: inout MIDIClientRef) -> OSStatus
        let createSource: @Sendable (_ client: MIDIClientRef, _ name: String, _ source: inout MIDIEndpointRef) -> OSStatus
        let createDestination: @Sendable (
            _ client: MIDIClientRef,
            _ name: String,
            _ destination: inout MIDIEndpointRef,
            _ onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
        ) -> OSStatus
        let disposeEndpoint: @Sendable (_ endpoint: MIDIEndpointRef) -> OSStatus
        let disposeClient: @Sendable (_ client: MIDIClientRef) -> OSStatus
        let endpointRuntime: VirtualMIDIEndpointRuntime

        static let production = Runtime(
            createClient: { name, client in
                MIDIClientCreateWithBlock(name as CFString, &client) { notification in
                    Log.debug(
                        "MIDIPortManager notification: \(notification.pointee.messageID.rawValue)",
                        subsystem: "midi"
                    )
                }
            },
            createSource: { client, name, source in
                MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
            },
            createDestination: { client, name, destination, onReceive in
                MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination, onReceive)
            },
            disposeEndpoint: { endpoint in
                MIDIEndpointDispose(endpoint)
            },
            disposeClient: { client in
                MIDIClientDispose(client)
            },
            endpointRuntime: .production
        )
    }

    private var client: MIDIClientRef = 0
    private var ports: [String: MIDIPortPair] = [:]
    private var ownedEndpoints: Set<MIDIEndpointRef> = []
    private var latestCensus: [String: VirtualMIDIEndpointCensus] = [:]
    private var isRunning = false
    private let runtime: Runtime

    init(runtime: Runtime = .production) {
        self.runtime = runtime
    }

    struct MIDIPortPair: Sendable {
        let name: String
        let source: MIDIEndpointRef       // MCP → Logic Pro
        let destination: MIDIEndpointRef?  // Logic Pro → MCP (nil for send-only)
        let mode: MIDIPortMode

        init(
            name: String,
            source: MIDIEndpointRef,
            destination: MIDIEndpointRef?,
            mode: MIDIPortMode? = nil
        ) {
            self.name = name
            self.source = source
            self.destination = destination
            self.mode = mode ?? (destination == nil ? .sendOnly : .bidirectional)
        }
    }

    /// Start the MIDI client.
    func start() throws {
        guard !isRunning else { return }
        let status = runtime.createClient("LogicProMCP", &client)
        guard status == noErr else {
            throw MIDIPortError.clientCreationFailed(status)
        }
        isRunning = true
        Log.info("MIDIPortManager started (client: \(client))", subsystem: "midi")
    }

    /// Create a bidirectional port pair (source + destination).
    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortPair {
        guard isRunning else { throw MIDIPortError.notRunning }

        if let existing = try cachedPort(named: name, requestedMode: .bidirectional) {
            return existing
        }

        try rejectForeignEndpoint(named: name)

        var source: MIDIEndpointRef = 0
        var status = runtime.createSource(client, name, &source)
        guard status == noErr else {
            throw MIDIPortError.sourceCreationFailed(name, status)
        }
        do {
            try assignStableUniqueID(to: source, name: name, kind: .source)
        } catch {
            _ = runtime.disposeEndpoint(source)
            throw error
        }
        ownedEndpoints.insert(source)

        var dest: MIDIEndpointRef = 0
        status = runtime.createDestination(client, name, &dest, onReceive)
        guard status == noErr else {
            ownedEndpoints.remove(source)
            _ = runtime.disposeEndpoint(source)
            throw MIDIPortError.destinationCreationFailed(name, status)
        }
        do {
            try assignStableUniqueID(to: dest, name: name, kind: .destination)
        } catch {
            ownedEndpoints.remove(source)
            _ = runtime.disposeEndpoint(dest)
            _ = runtime.disposeEndpoint(source)
            throw error
        }
        ownedEndpoints.insert(dest)

        let pair = MIDIPortPair(name: name, source: source, destination: dest, mode: .bidirectional)
        ports[name] = pair
        latestCensus[name] = currentCensus(named: name)
        Log.info("Created bidirectional port: \(name) (src: \(source), dst: \(dest))", subsystem: "midi")
        return pair
    }

    /// Create a send-only port (source only, no destination).
    func createSendOnlyPort(name: String) throws -> MIDIPortPair {
        guard isRunning else { throw MIDIPortError.notRunning }

        if let existing = try cachedPort(named: name, requestedMode: .sendOnly) {
            return existing
        }

        try rejectForeignEndpoint(named: name)

        var source: MIDIEndpointRef = 0
        let status = runtime.createSource(client, name, &source)
        guard status == noErr else {
            throw MIDIPortError.sourceCreationFailed(name, status)
        }
        do {
            try assignStableUniqueID(to: source, name: name, kind: .source)
        } catch {
            _ = runtime.disposeEndpoint(source)
            throw error
        }
        ownedEndpoints.insert(source)

        let pair = MIDIPortPair(name: name, source: source, destination: nil, mode: .sendOnly)
        ports[name] = pair
        latestCensus[name] = currentCensus(named: name)
        Log.info("Created send-only port: \(name) (src: \(source))", subsystem: "midi")
        return pair
    }

    private func cachedPort(named name: String, requestedMode: MIDIPortMode) throws -> MIDIPortPair? {
        guard let existing = ports[name] else { return nil }
        guard existing.mode == requestedMode else {
            throw MIDIPortError.modeConflict(name: name, existing: existing.mode, requested: requestedMode)
        }
        Log.info("Reusing existing port: \(name)", subsystem: "midi")
        return existing
    }

    /// Get an existing port by name.
    func getPort(name: String) -> MIDIPortPair? {
        ports[name]
    }

    /// Report the live CoreMIDI census, retaining a conflict observed during a
    /// failed creation attempt even though this process owns no endpoint.
    func endpointCensus(name: String) -> VirtualMIDIEndpointCensus {
        let census = currentCensus(named: name)
        if census.endpointCount > 0 || census.hasForeignEndpoint {
            latestCensus[name] = census
            return census
        }
        return latestCensus[name] ?? census
    }

    /// Number of active ports.
    var portCount: Int { ports.count }

    /// Stop and dispose all ports.
    func stop() {
        for (name, pair) in ports {
            _ = runtime.disposeEndpoint(pair.source)
            if let dest = pair.destination {
                _ = runtime.disposeEndpoint(dest)
            }
            Log.info("Disposed port: \(name)", subsystem: "midi")
        }
        ports.removeAll()
        ownedEndpoints.removeAll()
        latestCensus.removeAll()
        if client != 0 {
            _ = runtime.disposeClient(client)
            client = 0
        }
        isRunning = false
        Log.info("MIDIPortManager stopped", subsystem: "midi")
    }

    private func currentCensus(named name: String) -> VirtualMIDIEndpointCensus {
        runtime.endpointRuntime.census(named: name, ownedEndpoints: ownedEndpoints)
    }

    private func rejectForeignEndpoint(named name: String) throws {
        let census = currentCensus(named: name)
        latestCensus[name] = census
        guard !census.hasForeignEndpoint else {
            // The first instance to start owns the ports. A later instance runs
            // degraded and cannot use this MIDI port; if the owner exits, this
            // process does not take over because it created nothing. Restart it.
            Log.warn(
                "Virtual MIDI port '\(name)' is owned by another instance or is stale; skipping creation "
                    + "(\(census.endpointCount) matching endpoint(s))",
                subsystem: "midi"
            )
            throw MIDIPortError.foreignEndpointConflict(name: name, census: census)
        }
    }

    private func assignStableUniqueID(
        to endpoint: MIDIEndpointRef,
        name: String,
        kind: VirtualMIDIEndpointKind
    ) throws {
        let uniqueID = VirtualMIDIEndpointIdentity.uniqueID(forPortNamed: name, kind: kind)
        let status = runtime.endpointRuntime.setUniqueID(endpoint, uniqueID)
        guard status == noErr else {
            if status == kMIDIIDNotUnique {
                Log.warn(
                    "Stable unique ID \(uniqueID) for virtual MIDI \(kind.rawValue) '\(name)' is already held by another endpoint",
                    subsystem: "midi"
                )
                throw MIDIPortError.uniqueIDCollision(name: name, kind: kind, uniqueID: uniqueID)
            }
            Log.warn(
                "Could not assign stable unique ID \(uniqueID) to virtual MIDI \(kind.rawValue) '\(name)': \(status)",
                subsystem: "midi"
            )
            throw MIDIPortError.uniqueIDAssignmentFailed(name: name, kind: kind, status: status)
        }
    }
}

enum MIDIPortError: Error, CustomStringConvertible {
    case clientCreationFailed(OSStatus)
    case notRunning
    case sourceCreationFailed(String, OSStatus)
    case destinationCreationFailed(String, OSStatus)
    case modeConflict(name: String, existing: MIDIPortMode, requested: MIDIPortMode)
    case foreignEndpointConflict(name: String, census: VirtualMIDIEndpointCensus)
    case uniqueIDCollision(name: String, kind: VirtualMIDIEndpointKind, uniqueID: Int32)
    case uniqueIDAssignmentFailed(name: String, kind: VirtualMIDIEndpointKind, status: OSStatus)

    var description: String {
        switch self {
        case .clientCreationFailed(let status):
            return "MIDI client creation failed (\(status))"
        case .notRunning:
            return "MIDI port manager is not running"
        case .sourceCreationFailed(let name, let status):
            return "MIDI source '\(name)' creation failed (\(status))"
        case .destinationCreationFailed(let name, let status):
            return "MIDI destination '\(name)' creation failed (\(status))"
        case .modeConflict(let name, let existing, let requested):
            return "MIDI port '\(name)' already exists as \(existing.rawValue), not \(requested.rawValue)"
        case .foreignEndpointConflict(let name, let census):
            return "MIDI port '\(name)' has \(census.endpointCount) foreign matching endpoint(s)"
        case .uniqueIDCollision(let name, let kind, let uniqueID):
            return "MIDI \(kind.rawValue) '\(name)' cannot claim stable unique ID \(uniqueID): another endpoint already holds it"
        case .uniqueIDAssignmentFailed(let name, let kind, let status):
            return "MIDI \(kind.rawValue) '\(name)' could not claim its stable unique ID (\(status))"
        }
    }
}
