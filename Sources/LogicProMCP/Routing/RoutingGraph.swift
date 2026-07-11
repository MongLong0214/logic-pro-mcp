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
    let projectReference: TargetReference
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
