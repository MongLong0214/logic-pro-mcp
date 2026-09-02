import Foundation

let routingPhysicalSendSlots = 0..<12

enum RoutingNodeKind: String, Codable, Sendable {
    case track
    case aux
    case bus
    case input
    case output
}

struct RoutingNode: Codable, Equatable, Sendable {
    let id: String
    let kind: RoutingNodeKind
    let displayName: String
    let busNumber: Int?
    let targetRef: TargetReference?
    /// What the source strip displays in its output slot. This is a label, not
    /// an identity: it is locale- and user-rename-dependent, and may repeat.
    let observedOutputLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, displayName, busNumber, targetRef
        case observedOutputLabel = "observed_output_label"
    }

    init(
        id: String,
        kind: RoutingNodeKind,
        displayName: String,
        busNumber: Int?,
        targetRef: TargetReference?,
        observedOutputLabel: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.busNumber = busNumber
        self.targetRef = targetRef
        self.observedOutputLabel = observedOutputLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(RoutingNodeKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        busNumber = try container.decodeIfPresent(Int.self, forKey: .busNumber)
        targetRef = try container.decodeIfPresent(TargetReference.self, forKey: .targetRef)
        observedOutputLabel = try container.decodeIfPresent(String.self, forKey: .observedOutputLabel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(busNumber, forKey: .busNumber)
        try container.encodeIfPresent(targetRef, forKey: .targetRef)
        try container.encodeIfPresent(observedOutputLabel, forKey: .observedOutputLabel)
    }
}

enum RoutingEdgeKind: String, Codable, Sendable {
    case inputAssignment
    case mainOutput
    case send
}

struct SendEdge: Codable, Equatable, Sendable {
    let sourceTrackRef: TargetReference
    let physicalSlot: Int
    let destinationBusNumber: Int?
    let destinationRef: TargetReference?
    let displayedName: String
    let level: Double?
    let mode: String?
    let enabled: Bool
}

enum RoutingProvenance: String, Codable, Sendable {
    case axMixerStrip
    case mcuEcho
    case other
}

struct RoutingEdge: Codable, Equatable, Sendable {
    let kind: RoutingEdgeKind
    let source: String
    let destination: String
    let send: SendEdge?
    let provenance: RoutingProvenance
}

struct RoutingGraph: Codable, Equatable, Sendable {
    /// The project reference when one has already been issued. A mixer read
    /// must not mint a project identity merely to fill this field.
    let projectReference: TargetReference?
    let projectEpoch: UInt64
    let complete: Bool
    let partialReason: String?
    let nodes: [RoutingNode]
    let edges: [RoutingEdge]
    let provenance: [RoutingProvenance]

    var isConsistent: Bool {
        if !complete {
            return partialReason?.isEmpty == false
        }
        guard partialReason == nil else { return false }

        let nodeIDs = Set(nodes.map(\.id))
        guard nodeIDs.count == nodes.count,
              edges.allSatisfy({ nodeIDs.contains($0.source) && nodeIDs.contains($0.destination) }),
              edges.allSatisfy({ provenance.contains($0.provenance) })
        else {
            return false
        }

        var occupiedSlots = Set<SendSlot>()
        for edge in edges {
            if edge.kind != .send {
                guard edge.send == nil else { return false }
                continue
            }
            guard let send = edge.send,
                  routingPhysicalSendSlots.contains(send.physicalSlot),
                  nodes.first(where: { $0.id == edge.source })?.targetRef == send.sourceTrackRef,
                  let destination = nodes.first(where: { $0.id == edge.destination }),
                  destinationMatches(send, node: destination),
                  occupiedSlots.insert(
                    SendSlot(source: send.sourceTrackRef, physicalSlot: send.physicalSlot)
                  ).inserted
            else {
                return false
            }
        }
        return true
    }
}

private struct SendSlot: Hashable {
    let source: TargetReference
    let physicalSlot: Int
}

private func destinationMatches(_ send: SendEdge, node: RoutingNode) -> Bool {
    guard send.destinationBusNumber != nil || send.destinationRef != nil else { return false }
    if let busNumber = send.destinationBusNumber, node.busNumber != busNumber { return false }
    if let reference = send.destinationRef, node.targetRef != reference { return false }
    return true
}
