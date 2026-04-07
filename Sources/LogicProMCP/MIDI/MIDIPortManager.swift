import CoreMIDI
import Foundation

protocol VirtualPortManaging: Actor {
    func createSendOnlyPort(name: String) throws -> MIDIPortManager.MIDIPortPair
    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortManager.MIDIPortPair
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
            }
        )
    }

    private var client: MIDIClientRef = 0
    private var ports: [String: MIDIPortPair] = [:]
    private var isRunning = false
    private let runtime: Runtime

    init(runtime: Runtime = .production) {
        self.runtime = runtime
    }

    struct MIDIPortPair: Sendable {
        let name: String
        let source: MIDIEndpointRef       // MCP → Logic Pro
        let destination: MIDIEndpointRef?  // Logic Pro → MCP (nil for send-only)
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

        // Check for existing port with same name
        if let existing = ports[name] {
            Log.info("Reusing existing port: \(name)", subsystem: "midi")
            return existing
        }

        var source: MIDIEndpointRef = 0
        var status = runtime.createSource(client, name, &source)
        guard status == noErr else {
            throw MIDIPortError.sourceCreationFailed(name, status)
        }

        var dest: MIDIEndpointRef = 0
        status = runtime.createDestination(client, name, &dest, onReceive)
        guard status == noErr else {
            _ = runtime.disposeEndpoint(source)
            throw MIDIPortError.destinationCreationFailed(name, status)
        }

        let pair = MIDIPortPair(name: name, source: source, destination: dest)
        ports[name] = pair
        Log.info("Created bidirectional port: \(name) (src: \(source), dst: \(dest))", subsystem: "midi")
        return pair
    }

    /// Create a send-only port (source only, no destination).
    func createSendOnlyPort(name: String) throws -> MIDIPortPair {
        guard isRunning else { throw MIDIPortError.notRunning }

        if let existing = ports[name] {
            Log.info("Reusing existing port: \(name)", subsystem: "midi")
            return existing
        }

        var source: MIDIEndpointRef = 0
        let status = runtime.createSource(client, name, &source)
        guard status == noErr else {
            throw MIDIPortError.sourceCreationFailed(name, status)
        }

        let pair = MIDIPortPair(name: name, source: source, destination: nil)
        ports[name] = pair
        Log.info("Created send-only port: \(name) (src: \(source))", subsystem: "midi")
        return pair
    }

    /// Get an existing port by name.
    func getPort(name: String) -> MIDIPortPair? {
        ports[name]
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
        if client != 0 {
            _ = runtime.disposeClient(client)
            client = 0
        }
        isRunning = false
        Log.info("MIDIPortManager stopped", subsystem: "midi")
    }
}

enum MIDIPortError: Error {
    case clientCreationFailed(OSStatus)
    case notRunning
    case sourceCreationFailed(String, OSStatus)
    case destinationCreationFailed(String, OSStatus)
}
