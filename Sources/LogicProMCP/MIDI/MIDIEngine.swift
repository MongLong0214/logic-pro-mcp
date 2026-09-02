import CoreMIDI
import Foundation

protocol CoreMIDIEngineProtocol: Actor {
    func start() throws
    func stop()
    var isActive: Bool { get }
    var unavailableReason: String? { get }
    func sendNoteOn(channel: UInt8, note: UInt8, velocity: UInt8) throws
    func sendNoteOff(channel: UInt8, note: UInt8, velocity: UInt8) throws
    func sendCC(channel: UInt8, controller: UInt8, value: UInt8) throws
    func sendProgramChange(channel: UInt8, program: UInt8) throws
    func sendPitchBend(channel: UInt8, value: UInt16) throws
    func sendAftertouch(channel: UInt8, pressure: UInt8) throws
    func sendSysEx(_ bytes: [UInt8]) throws
}

extension CoreMIDIEngineProtocol {
    /// Engines without a startup diagnostic still report their normal inactive
    /// state. MIDIEngine overrides this to preserve a refused ownership claim.
    var unavailableReason: String? { nil }
}

/// Actor wrapping CoreMIDI. Creates a virtual source (for sending MIDI to Logic Pro)
/// and a virtual destination (for receiving MIDI from Logic Pro).
actor MIDIEngine: CoreMIDIEngineProtocol {
    struct Runtime: Sendable {
        let createClient: @Sendable (_ name: String, _ onNotification: @escaping @Sendable (Int32) -> Void) -> (OSStatus, MIDIClientRef)
        let createSource: @Sendable (_ client: MIDIClientRef, _ name: String) -> (OSStatus, MIDIEndpointRef)
        let createDestination: @Sendable (
            _ client: MIDIClientRef,
            _ name: String,
            _ onBytes: @escaping @Sendable ([UInt8]) -> Void
        ) -> (OSStatus, MIDIEndpointRef)
        let disposeEndpoint: @Sendable (_ endpoint: MIDIEndpointRef) -> OSStatus
        let disposeClient: @Sendable (_ client: MIDIClientRef) -> Void
        let sendMessage: @Sendable (_ source: MIDIEndpointRef, _ bytes: [UInt8]) -> OSStatus
        let endpointRuntime: VirtualMIDIEndpointRuntime
        let acquireOwnershipLock: @Sendable () -> VirtualMIDIEndpointOwnershipLock.Acquisition

        init(
            createClient: @escaping @Sendable (_ name: String, _ onNotification: @escaping @Sendable (Int32) -> Void) -> (OSStatus, MIDIClientRef),
            createSource: @escaping @Sendable (_ client: MIDIClientRef, _ name: String) -> (OSStatus, MIDIEndpointRef),
            createDestination: @escaping @Sendable (
                _ client: MIDIClientRef,
                _ name: String,
                _ onBytes: @escaping @Sendable ([UInt8]) -> Void
            ) -> (OSStatus, MIDIEndpointRef),
            disposeEndpoint: @escaping @Sendable (_ endpoint: MIDIEndpointRef) -> OSStatus,
            disposeClient: @escaping @Sendable (_ client: MIDIClientRef) -> Void,
            sendMessage: @escaping @Sendable (_ source: MIDIEndpointRef, _ bytes: [UInt8]) -> OSStatus,
            endpointRuntime: VirtualMIDIEndpointRuntime,
            acquireOwnershipLock: @escaping @Sendable () -> VirtualMIDIEndpointOwnershipLock.Acquisition = {
                VirtualMIDIEndpointOwnershipLock.acquire()
            }
        ) {
            self.createClient = createClient
            self.createSource = createSource
            self.createDestination = createDestination
            self.disposeEndpoint = disposeEndpoint
            self.disposeClient = disposeClient
            self.sendMessage = sendMessage
            self.endpointRuntime = endpointRuntime
            self.acquireOwnershipLock = acquireOwnershipLock
        }

        static let production = Runtime(
            createClient: { name, onNotification in
                var client: MIDIClientRef = 0
                let status = MIDIClientCreateWithBlock(name as CFString, &client) { notification in
                    onNotification(notification.pointee.messageID.rawValue)
                }
                return (status, client)
            },
            createSource: { client, name in
                var source: MIDIEndpointRef = 0
                let status = MIDISourceCreate(client, name as CFString, &source)
                return (status, source)
            },
            createDestination: { client, name, onBytes in
                var destination: MIDIEndpointRef = 0
                let status = MIDIDestinationCreateWithBlock(client, name as CFString, &destination) { packetList, _ in
                    let packets = packetList.pointee
                    var list = packets
                    withUnsafePointer(to: &list.packet) { firstPacket in
                        var packet = firstPacket
                        for _ in 0..<list.numPackets {
                            let current = packet.pointee
                            let length = Int(current.length)
                            let bytes = withUnsafeBytes(of: current.data) { raw in
                                Array(raw.prefix(length).bindMemory(to: UInt8.self))
                            }
                            onBytes(bytes)
                            packet = UnsafePointer(MIDIPacketNext(packet))
                        }
                    }
                }
                return (status, destination)
            },
            disposeEndpoint: { endpoint in
                if endpoint != 0 {
                    return MIDIEndpointDispose(endpoint)
                }
                return noErr
            },
            disposeClient: { client in
                if client != 0 {
                    MIDIClientDispose(client)
                }
            },
            sendMessage: { source, bytes in
                let bufferSize = max(
                    MemoryLayout<MIDIPacketList>.size,
                    MemoryLayout<MIDIPacketList>.size + bytes.count
                )
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                return buffer.withUnsafeMutableBytes { rawBuf in
                    let packetList = rawBuf.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
                    var pkt = MIDIPacketListInit(packetList)
                    return bytes.withUnsafeBufferPointer { dataBuf in
                        guard let base = dataBuf.baseAddress else {
                            return noErr
                        }
                        pkt = MIDIPacketListAdd(packetList, bufferSize, pkt, 0, bytes.count, base)
                        return MIDIReceived(source, packetList)
                    }
                }
            },
            endpointRuntime: .production
        )
    }

    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var virtualDestination: MIDIEndpointRef = 0
    private var isRunning = false
    private var startupFailure: String?
    private let runtime: Runtime

    /// Stream of inbound MIDI packets from Logic Pro via the virtual destination.
    let inboundMessages: AsyncStream<MIDIFeedback.Event>
    private let inboundContinuation: AsyncStream<MIDIFeedback.Event>.Continuation

    init(runtime: Runtime = .production) {
        self.runtime = runtime
        let (stream, continuation) = AsyncStream<MIDIFeedback.Event>.makeStream()
        self.inboundMessages = stream
        self.inboundContinuation = continuation
    }

    deinit {
        inboundContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Create the CoreMIDI client, virtual source, and virtual destination.
    func start() throws {
        guard !isRunning else { return }
        startupFailure = nil

        do {
            try startResources()
        } catch {
            startupFailure = String(describing: error)
            throw error
        }
    }

    private func startResources() throws {
        let (clientStatus, createdClient) = runtime.createClient(
            ServerConfig.virtualMIDISourceName,
            MIDIEngine.logMIDINotification
        )
        guard clientStatus == noErr else {
            throw MIDIEngineError.clientCreationFailed(clientStatus)
        }

        let ownershipLock: VirtualMIDIEndpointOwnershipLock
        do {
            ownershipLock = try acquireOwnershipLock(named: ServerConfig.virtualMIDISourceName)
        } catch {
            runtime.disposeClient(createdClient)
            throw error
        }
        defer { ownershipLock.release() }

        do {
            try rejectForeignEndpoint(named: ServerConfig.virtualMIDISourceName)
        } catch {
            runtime.disposeClient(createdClient)
            throw error
        }

        let (sourceStatus, createdSource) = runtime.createSource(createdClient, ServerConfig.virtualMIDISourceName)
        guard sourceStatus == noErr else {
            runtime.disposeClient(createdClient)
            throw MIDIEngineError.sourceCreationFailed(sourceStatus)
        }
        VirtualMIDIEndpointProcessOwnership.shared.claim(createdSource)
        do {
            try assignStableUniqueID(
                to: createdSource,
                name: ServerConfig.virtualMIDISourceName,
                kind: .source
            )
        } catch {
            _ = disposeOwnedEndpoint(createdSource)
            runtime.disposeClient(createdClient)
            throw error
        }

        do {
            try rejectForeignEndpoint(named: ServerConfig.virtualMIDISinkName)
        } catch {
            _ = disposeOwnedEndpoint(createdSource)
            runtime.disposeClient(createdClient)
            throw error
        }

        let continuation = self.inboundContinuation
        let (destinationStatus, createdDestination) = runtime.createDestination(
            createdClient,
            ServerConfig.virtualMIDISinkName
        ) { bytes in
            for event in MIDIFeedback.parseBytes(bytes) {
                continuation.yield(event)
            }
        }
        guard destinationStatus == noErr else {
            _ = disposeOwnedEndpoint(createdSource)
            runtime.disposeClient(createdClient)
            throw MIDIEngineError.destinationCreationFailed(destinationStatus)
        }
        VirtualMIDIEndpointProcessOwnership.shared.claim(createdDestination)
        do {
            try assignStableUniqueID(
                to: createdDestination,
                name: ServerConfig.virtualMIDISinkName,
                kind: .destination
            )
        } catch {
            _ = disposeOwnedEndpoint(createdDestination)
            _ = disposeOwnedEndpoint(createdSource)
            runtime.disposeClient(createdClient)
            throw error
        }

        client = createdClient
        virtualSource = createdSource
        virtualDestination = createdDestination
        isRunning = true
        Log.info("MIDIEngine started — source: \(ServerConfig.virtualMIDISourceName), sink: \(ServerConfig.virtualMIDISinkName)", subsystem: "midi")
    }

    /// Tear down all CoreMIDI resources.
    func stop() {
        guard isRunning || virtualSource != 0 || virtualDestination != 0 || client != 0 else { return }
        if virtualSource != 0, disposeOwnedEndpoint(virtualSource) {
            virtualSource = 0
        }
        if virtualDestination != 0, disposeOwnedEndpoint(virtualDestination) {
            virtualDestination = 0
        }
        if client != 0 {
            runtime.disposeClient(client)
            client = 0
        }
        isRunning = false
        startupFailure = nil
        // v3.4.5 (H1 / P1-6): do NOT finish the inbound stream here. The
        // stream + continuation are created once in init() and cannot be
        // re-created (`inboundMessages` is a `let` the consumer holds). If
        // stop() finished the continuation, a later start() would re-capture
        // an already-finished continuation and silently drop all inbound MIDI
        // — making the engine restart-unsafe. The continuation is terminal
        // only at deinit; stop() is a restartable pause that just tears down
        // the CoreMIDI endpoints.
        Log.info("MIDIEngine stopped", subsystem: "midi")
    }

    var isActive: Bool { isRunning && client != 0 }

    var unavailableReason: String? { startupFailure }

    // MARK: - Send: Notes

    func sendNoteOn(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 100) throws {
        let status: UInt8 = 0x90 | (channel & 0x0F)
        try sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    func sendNoteOff(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 0) throws {
        let status: UInt8 = 0x80 | (channel & 0x0F)
        try sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    // MARK: - Send: Control Change

    func sendCC(channel: UInt8 = 0, controller: UInt8, value: UInt8) throws {
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        try sendShortMessage([status, controller & 0x7F, value & 0x7F])
    }

    // MARK: - Send: Program Change

    func sendProgramChange(channel: UInt8 = 0, program: UInt8) throws {
        let status: UInt8 = 0xC0 | (channel & 0x0F)
        try sendShortMessage([status, program & 0x7F])
    }

    // MARK: - Send: Pitch Bend

    /// Send pitch bend. `value` is 14-bit (0-16383), center = 8192.
    func sendPitchBend(channel: UInt8 = 0, value: UInt16 = 8192) throws {
        let clamped = min(value, 16383)
        let lsb = UInt8(clamped & 0x7F)
        let msb = UInt8((clamped >> 7) & 0x7F)
        let status: UInt8 = 0xE0 | (channel & 0x0F)
        try sendShortMessage([status, lsb, msb])
    }

    // MARK: - Send: Aftertouch

    /// Channel pressure (mono aftertouch).
    func sendAftertouch(channel: UInt8 = 0, pressure: UInt8) throws {
        let status: UInt8 = 0xD0 | (channel & 0x0F)
        try sendShortMessage([status, pressure & 0x7F])
    }

    // MARK: - Send: SysEx

    /// Send a complete SysEx message (must start with 0xF0 and end with 0xF7, middle bytes < 0x80).
    func sendSysEx(_ bytes: [UInt8]) throws {
        guard MCUProtocol.isValidSysEx(bytes) else {
            Log.error("Invalid SysEx: must start with F0, end with F7, middle bytes < 0x80", subsystem: "midi")
            throw MIDIEngineError.invalidSysEx
        }
        try sendRawBytes(bytes)
    }

    // MARK: - Send: Raw

    /// Send arbitrary MIDI bytes through the virtual source.
    /// Uses dynamic buffer for large messages (SysEx 256+ bytes).
    func sendRawBytes(_ bytes: [UInt8]) throws {
        guard isRunning else {
            Log.warn("MIDIEngine not running — dropping message", subsystem: "midi")
            throw MIDIEngineError.notRunning
        }
        let status = runtime.sendMessage(virtualSource, bytes)
        if status != noErr {
            Log.error("MIDIReceived failed with status \(status)", subsystem: "midi")
            throw MIDIEngineError.sendFailed(status)
        }
    }

    // MARK: - Private

    private func sendShortMessage(_ bytes: [UInt8]) throws {
        try sendRawBytes(bytes)
        Log.debug("MIDI out: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))", subsystem: "midi")
    }

    private func rejectForeignEndpoint(named name: String) throws {
        let census = runtime.endpointRuntime.census(named: name)
        guard census.isObserved,
              let endpointCount = census.endpointCount,
              let hasForeignEndpoint = census.hasForeignEndpoint else {
            Log.warn(
                "Virtual MIDI endpoint '\(name)' census is unknown; skipping creation (\(census.reason ?? "no reason supplied"))",
                subsystem: "midi"
            )
            throw MIDIEngineError.censusUnknown(name: name, census: census)
        }
        guard !hasForeignEndpoint else {
            Log.warn(
                "Virtual MIDI endpoint '\(name)' is owned by another instance or is stale; skipping creation "
                    + "(\(endpointCount) matching endpoint(s))",
                subsystem: "midi"
            )
            throw MIDIEngineError.foreignEndpointConflict(name: name, census: census)
        }
    }

    private func acquireOwnershipLock(named name: String) throws -> VirtualMIDIEndpointOwnershipLock {
        switch runtime.acquireOwnershipLock() {
        case .acquired(let lock):
            return lock
        case .held:
            Log.warn(
                "Virtual MIDI endpoint '\(name)' ownership lock is held by another process; skipping creation",
                subsystem: "midi"
            )
            throw MIDIEngineError.ownershipLockHeld(name: name)
        case .unavailable(let reason):
            Log.warn(
                "Virtual MIDI endpoint '\(name)' ownership lock is unavailable; skipping creation (\(reason))",
                subsystem: "midi"
            )
            throw MIDIEngineError.ownershipLockUnavailable(name: name, reason: reason)
        }
    }

    @discardableResult
    private func disposeOwnedEndpoint(_ endpoint: MIDIEndpointRef) -> Bool {
        let status = runtime.disposeEndpoint(endpoint)
        guard status == noErr else {
            Log.warn(
                "Could not dispose virtual MIDI endpoint \(endpoint) (\(status)); retaining process ownership",
                subsystem: "midi"
            )
            return false
        }
        VirtualMIDIEndpointProcessOwnership.shared.release(endpoint)
        return true
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
                throw MIDIEngineError.uniqueIDCollision(name: name, kind: kind, uniqueID: uniqueID)
            }
            Log.warn(
                "Could not assign stable unique ID \(uniqueID) to virtual MIDI \(kind.rawValue) '\(name)': \(status)",
                subsystem: "midi"
            )
            throw MIDIEngineError.uniqueIDAssignmentFailed(name: name, kind: kind, status: status)
        }
    }

    private static func logMIDINotification(_ rawValue: Int32) {
        let id = MIDINotificationMessageID(rawValue: rawValue)
        switch id {
        case .some(.msgSetupChanged):
            Log.debug("MIDI setup changed", subsystem: "midi")
        case .some(.msgObjectAdded):
            Log.debug("MIDI object added", subsystem: "midi")
        case .some(.msgObjectRemoved):
            Log.debug("MIDI object removed", subsystem: "midi")
        default:
            Log.debug("MIDI notification: \(rawValue)", subsystem: "midi")
        }
    }
}

// MARK: - Errors

enum MIDIEngineError: Error, Sendable, CustomStringConvertible {
    case clientCreationFailed(OSStatus)
    case sourceCreationFailed(OSStatus)
    case destinationCreationFailed(OSStatus)
    case notRunning
    case sendFailed(OSStatus)
    case invalidSysEx
    case foreignEndpointConflict(name: String, census: VirtualMIDIEndpointCensus)
    case censusUnknown(name: String, census: VirtualMIDIEndpointCensus)
    case ownershipLockHeld(name: String)
    case ownershipLockUnavailable(name: String, reason: String)
    case uniqueIDCollision(name: String, kind: VirtualMIDIEndpointKind, uniqueID: Int32)
    case uniqueIDAssignmentFailed(name: String, kind: VirtualMIDIEndpointKind, status: OSStatus)

    var description: String {
        switch self {
        case .clientCreationFailed(let status):
            return "MIDI client creation failed (\(status))"
        case .sourceCreationFailed(let status):
            return "MIDI source creation failed (\(status))"
        case .destinationCreationFailed(let status):
            return "MIDI destination creation failed (\(status))"
        case .notRunning:
            return "MIDI engine is not running"
        case .sendFailed(let status):
            return "MIDI send failed (\(status))"
        case .invalidSysEx:
            return "Invalid SysEx"
        case .foreignEndpointConflict(let name, let census):
            return "MIDI endpoint '\(name)' ownership conflict: \(census.endpointCount ?? 0) matching endpoint(s) are held by another process or left by a stale endpoint"
        case .censusUnknown(let name, let census):
            return "MIDI endpoint '\(name)' was not created because its CoreMIDI endpoint census is unknown: \(census.reason ?? "no reason supplied")"
        case .ownershipLockHeld(let name):
            return "MIDI endpoint '\(name)' was not created because another process is checking or creating virtual MIDI endpoints"
        case .ownershipLockUnavailable(let name, let reason):
            return "MIDI endpoint '\(name)' was not created because cross-process ownership locking is unavailable: \(reason)"
        case .uniqueIDCollision(let name, let kind, let uniqueID):
            return "MIDI \(kind.rawValue) '\(name)' cannot claim stable unique ID \(uniqueID): another endpoint already holds it"
        case .uniqueIDAssignmentFailed(let name, let kind, let status):
            return "MIDI \(kind.rawValue) '\(name)' could not claim its stable unique ID (\(status))"
        }
    }
}
