import CoreMIDI
import Foundation

/// Manages multiple virtual MIDI port pairs for the MCP server.
/// Each channel (MCU, CoreMIDI, KeyCommands, Scripter) gets its own named port.
actor MIDIPortManager {
    private var client: MIDIClientRef = 0
    private var ports: [String: MIDIPortPair] = [:]
    private var isRunning = false

    struct MIDIPortPair: Sendable {
        let name: String
        let source: MIDIEndpointRef       // MCP → Logic Pro
        let destination: MIDIEndpointRef?  // Logic Pro → MCP (nil for send-only)
    }

    /// Start the MIDI client.
    func start() throws {
        guard !isRunning else { return }
        let status = MIDIClientCreate("LogicProMCP" as CFString, nil, nil, &client)
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
        var status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else {
            throw MIDIPortError.sourceCreationFailed(name, status)
        }

        var dest: MIDIEndpointRef = 0
        status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &dest, onReceive)
        guard status == noErr else {
            MIDIEndpointDispose(source)
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
        let status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
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
            MIDIEndpointDispose(pair.source)
            if let dest = pair.destination {
                MIDIEndpointDispose(dest)
            }
            Log.info("Disposed port: \(name)", subsystem: "midi")
        }
        ports.removeAll()
        if client != 0 {
            MIDIClientDispose(client)
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
