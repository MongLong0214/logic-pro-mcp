import CoreMIDI
import Foundation

/// The CoreMIDI endpoint kinds for which one named virtual port can create an
/// object. The direction is part of its identity because CoreMIDI unique IDs
/// are global, not scoped to a port name.
enum VirtualMIDIEndpointKind: String, Sendable {
    case source
    case destination
}

/// The matching CoreMIDI endpoints seen for one virtual-port name.
struct VirtualMIDIEndpointCensus: Sendable, Equatable, Codable {
    let endpointCount: Int
    let hasForeignEndpoint: Bool

    static let none = Self(endpointCount: 0, hasForeignEndpoint: false)

    enum CodingKeys: String, CodingKey {
        case endpointCount = "endpoint_count"
        case hasForeignEndpoint = "has_foreign_endpoint"
    }
}

/// CoreMIDI operations shared by the virtual endpoint creators.
struct VirtualMIDIEndpointRuntime: Sendable {
    let endpointsNamed: @Sendable (_ name: String) -> [MIDIEndpointRef]
    let setUniqueID: @Sendable (_ endpoint: MIDIEndpointRef, _ uniqueID: Int32) -> OSStatus

    static let production = Self(
        endpointsNamed: { requestedName in
            let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
            let destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
            return (sources + destinations).filter { endpoint in
                endpointName(endpoint) == requestedName
            }
        },
        setUniqueID: { endpoint, uniqueID in
            MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uniqueID)
        }
    )

    func census(named name: String, ownedEndpoints: Set<MIDIEndpointRef>) -> VirtualMIDIEndpointCensus {
        let endpoints = endpointsNamed(name)
        return .init(
            endpointCount: endpoints.count,
            hasForeignEndpoint: endpoints.contains { !ownedEndpoints.contains($0) }
        )
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String? {
        var cfName: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName) == noErr else {
            return nil
        }
        return cfName?.takeRetainedValue() as String?
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
