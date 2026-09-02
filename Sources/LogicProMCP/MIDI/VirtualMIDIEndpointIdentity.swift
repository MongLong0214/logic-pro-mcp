import CoreMIDI
import Darwin
import Foundation

/// The CoreMIDI endpoint kinds for which one named virtual port can create an
/// object. The direction is part of its identity because CoreMIDI unique IDs
/// are global, not scoped to a port name.
enum VirtualMIDIEndpointKind: String, Sendable {
    case source
    case destination
}

/// Whether a CoreMIDI endpoint census was actually observed.
enum VirtualMIDIEndpointCensusState: String, Sendable, Codable, Equatable {
    case observed
    case unknown
}

/// The matching CoreMIDI endpoints seen for one virtual-port name.
///
/// A zero count is meaningful only in the `.observed` state. CoreMIDI's count
/// APIs also return zero on error, so callers must take the degraded path for
/// `.unknown` rather than treating it as an empty catalog.
struct VirtualMIDIEndpointCensus: Sendable, Equatable, Codable {
    let state: VirtualMIDIEndpointCensusState
    let endpointCount: Int?
    let hasForeignEndpoint: Bool?
    let reason: String?

    init(endpointCount: Int, hasForeignEndpoint: Bool) {
        self.state = .observed
        self.endpointCount = endpointCount
        self.hasForeignEndpoint = hasForeignEndpoint
        self.reason = nil
    }

    private init(reason: String) {
        self.state = .unknown
        self.endpointCount = nil
        self.hasForeignEndpoint = nil
        self.reason = reason
    }

    static let none = Self(endpointCount: 0, hasForeignEndpoint: false)

    static func unknown(reason: String) -> Self {
        Self(reason: reason)
    }

    var isObserved: Bool {
        state == .observed
    }

    enum CodingKeys: String, CodingKey {
        case state
        case endpointCount = "endpoint_count"
        case hasForeignEndpoint = "has_foreign_endpoint"
        case reason
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCount = try values.decodeIfPresent(Int.self, forKey: .endpointCount)
        let decodedForeign = try values.decodeIfPresent(Bool.self, forKey: .hasForeignEndpoint)
        let decodedState = try values.decodeIfPresent(VirtualMIDIEndpointCensusState.self, forKey: .state)

        // Old persisted snapshots had no state. Preserve a fully represented
        // old observation, but never infer an observation from partial data.
        let resolvedState = decodedState ?? (decodedCount != nil && decodedForeign != nil ? .observed : .unknown)
        state = resolvedState
        switch resolvedState {
        case .observed:
            endpointCount = decodedCount
            hasForeignEndpoint = decodedForeign
            reason = nil
        case .unknown:
            endpointCount = nil
            hasForeignEndpoint = nil
            reason = try values.decodeIfPresent(String.self, forKey: .reason)
                ?? "CoreMIDI endpoint census was not observed"
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        switch state {
        case .observed:
            try values.encodeIfPresent(endpointCount, forKey: .endpointCount)
            try values.encodeIfPresent(hasForeignEndpoint, forKey: .hasForeignEndpoint)
        case .unknown:
            try values.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

/// The result of reading the endpoint catalog. A failed read is deliberately
/// distinct from an empty catalog.
enum VirtualMIDIEndpointCatalogRead: Sendable {
    case endpoints([MIDIEndpointRef])
    case unknown(String)
}

/// The result of reading one endpoint's name. Names participate in the
/// ownership decision, so a failed name read is not evidence that it differs.
enum VirtualMIDIEndpointNameRead: Sendable {
    case name(String)
    case unknown(String)
}

/// CoreMIDI operations shared by the virtual endpoint creators.
struct VirtualMIDIEndpointRuntime: Sendable {
    let allEndpoints: @Sendable () -> VirtualMIDIEndpointCatalogRead
    let endpointName: @Sendable (_ endpoint: MIDIEndpointRef) -> VirtualMIDIEndpointNameRead
    let setUniqueID: @Sendable (_ endpoint: MIDIEndpointRef, _ uniqueID: Int32) -> OSStatus

    static let production = Self(
        allEndpoints: { readAllEndpoints() },
        endpointName: { endpoint in readEndpointName(endpoint) },
        setUniqueID: { endpoint, uniqueID in
            MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uniqueID)
        }
    )

    func census(named name: String) -> VirtualMIDIEndpointCensus {
        switch allEndpoints() {
        case .unknown(let reason):
            return .unknown(reason: reason)
        case .endpoints(let endpoints):
            var matchingEndpoints: [MIDIEndpointRef] = []
            for endpoint in endpoints {
                switch endpointName(endpoint) {
                case .name(let observedName):
                    if observedName == name {
                        matchingEndpoints.append(endpoint)
                    }
                case .unknown(let reason):
                    return .unknown(reason: reason)
                }
            }
            return .init(
                endpointCount: matchingEndpoints.count,
                hasForeignEndpoint: matchingEndpoints.contains {
                    !VirtualMIDIEndpointProcessOwnership.shared.contains($0)
                }
            )
        }
    }

    /// `MIDIGetNumberOfSources` and `MIDIGetNumberOfDestinations` return zero
    /// both for a genuinely empty catalog and for an error. Probe the
    /// status-bearing object lookup before and after counting, so zero is used
    /// only while CoreMIDI has demonstrably answered a catalog-adjacent read.
    private static func readAllEndpoints() -> VirtualMIDIEndpointCatalogRead {
        let beforeStatus = catalogProbeStatus()
        guard isCatalogProbeResponse(beforeStatus) else {
            return .unknown("CoreMIDI endpoint catalog probe failed before enumeration (\(beforeStatus))")
        }

        let sourceCount = MIDIGetNumberOfSources()
        let destinationCount = MIDIGetNumberOfDestinations()
        var endpoints: [MIDIEndpointRef] = []
        endpoints.reserveCapacity(Int(sourceCount + destinationCount))

        for index in 0..<sourceCount {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else {
                return .unknown("CoreMIDI returned no source for catalog index \(index)")
            }
            endpoints.append(endpoint)
        }
        for index in 0..<destinationCount {
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else {
                return .unknown("CoreMIDI returned no destination for catalog index \(index)")
            }
            endpoints.append(endpoint)
        }

        let afterStatus = catalogProbeStatus()
        guard isCatalogProbeResponse(afterStatus) else {
            return .unknown("CoreMIDI endpoint catalog probe failed after enumeration (\(afterStatus))")
        }
        return .endpoints(endpoints)
    }

    private static func readEndpointName(_ endpoint: MIDIEndpointRef) -> VirtualMIDIEndpointNameRead {
        var cfName: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName)
        guard status == noErr, let name = cfName?.takeRetainedValue() as String? else {
            return .unknown("Could not read CoreMIDI endpoint name for \(endpoint) (\(status))")
        }
        return .name(name)
    }

    /// A lookup of a deliberately unassigned ID gives us a status-bearing
    /// request to MIDIServer. `kMIDIObjectNotFound` is the expected successful
    /// response; `noErr` is also a successful response if some driver uses ID 0.
    private static func catalogProbeStatus() -> OSStatus {
        var object: MIDIObjectRef = 0
        var objectType: MIDIObjectType = .device
        return MIDIObjectFindByUniqueID(0, &object, &objectType)
    }

    private static func isCatalogProbeResponse(_ status: OSStatus) -> Bool {
        status == noErr || status == kMIDIObjectNotFound
    }
}

/// Endpoint ownership is a process-wide, lock-protected set of CoreMIDI object
/// references. MIDIEngine and MIDIPortManager can both create endpoints, so no
/// actor-local set is authoritative for the other. A failed disposal leaves its
/// reference claimed for the rest of this process's lifetime: the endpoint may
/// still be live, and only process exit (or a later successful explicit release)
/// can safely end that claim.
final class VirtualMIDIEndpointProcessOwnership: @unchecked Sendable {
    static let shared = VirtualMIDIEndpointProcessOwnership()

    private let lock = NSLock()
    private var endpoints: Set<MIDIEndpointRef> = []

    func claim(_ endpoint: MIDIEndpointRef) {
        lock.lock()
        endpoints.insert(endpoint)
        lock.unlock()
    }

    func release(_ endpoint: MIDIEndpointRef) {
        lock.lock()
        endpoints.remove(endpoint)
        lock.unlock()
    }

    func contains(_ endpoint: MIDIEndpointRef) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return endpoints.contains(endpoint)
    }
}

/// A process-safe token for the cross-process virtual-endpoint ownership lock.
final class VirtualMIDIEndpointOwnershipLock: @unchecked Sendable {
    enum Acquisition: Sendable {
        case acquired(VirtualMIDIEndpointOwnershipLock)
        case held
        case unavailable(String)
    }

    private let stateLock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    private init(releaseAction: @escaping @Sendable () -> Void) {
        self.releaseAction = releaseAction
    }

    deinit {
        release()
    }

    static func acquire() -> Acquisition {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-virtual-midi-ownership.lock")
            .path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            // Without a lock file there is no safe cross-process exclusion, so
            // callers degrade and refuse creation rather than risk a twin.
            return .unavailable("could not create virtual MIDI ownership lock file (errno \(errno))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = close(descriptor)
            if lockError == EWOULDBLOCK {
                return .held
            }
            return .unavailable("could not acquire virtual MIDI ownership lock (errno \(lockError))")
        }
        return .acquired(Self(releaseAction: {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }))
    }

    static func testing(onRelease: @escaping @Sendable () -> Void = {}) -> Self {
        Self(releaseAction: onRelease)
    }

    func release() {
        stateLock.lock()
        let action = releaseAction
        releaseAction = nil
        stateLock.unlock()
        action?()
    }
}

enum VirtualMIDIEndpointIdentity {
    /// CoreMIDI otherwise assigns a fresh ID each launch. This deterministic
    /// request gives an endpoint an identity that survives a restart; setting
    /// it still checks CoreMIDI's global collision rule. It makes no claim
    /// about MCU registration, whose observed failure tracks duplicate names.
    static func uniqueID(forPortNamed name: String, kind: VirtualMIDIEndpointKind) -> Int32 {
        // FNV-1a is deliberately specified here instead of Swift's Hasher,
        // whose seed changes between process launches.
        var hash: UInt32 = 2_166_136_261
        for byte in "LogicProMCP\\u{1F}\(kind.rawValue)\\u{1F}\(name)".utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        let positive = Int32(bitPattern: hash & 0x7fff_ffff)
        return positive == 0 ? 1 : positive
    }
}
