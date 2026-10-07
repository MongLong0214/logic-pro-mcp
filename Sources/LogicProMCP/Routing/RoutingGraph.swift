import Foundation

let routingPhysicalSendSlots = 0..<12

enum RoutingNodeKind: String, Codable, Sendable {
    case track
    /// An independently observed Mixer strip; its Arrange association/type remains unknown.
    case physicalStrip = "physical_strip"
    case aux
    case bus
    case input
    case output
}

/// What a source strip's output-slot description was classified as (#291).
///
/// A classification of the SOURCE's own slot, read by the canon-derived label sets in
/// `AXLocalePolicy`. `physicalOutput` and `noOutput` publish no node and no edge; only `bus`
/// publishes a `bus_<n>` node and a `mainOutput` edge. `unclassified` is a label none of the sets
/// recognise — an I/O-label rename, or a locale the sets do not carry — and is never guessed into
/// one of the other three.
enum RoutingOutputClassification: String, Codable, Sendable {
    case physicalOutput = "physical_output"
    case bus
    case noOutput = "no_output"
    case unclassified
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
    /// How `observedOutputLabel` classified. Nil when the slot was not read, and on every node
    /// that is not a source.
    let outputClassification: RoutingOutputClassification?
    /// Captured own input-control display evidence, not a bus/port identity or an edge.
    let observedInputSlot: InputSlotObservation?

    enum CodingKeys: String, CodingKey {
        case id, kind, displayName, busNumber, targetRef
        case observedOutputLabel = "observed_output_label"
        case outputClassification = "output_classification"
        case observedInputSlot = "observed_input_slot"
    }

    init(
        id: String,
        kind: RoutingNodeKind,
        displayName: String,
        busNumber: Int?,
        targetRef: TargetReference?,
        observedOutputLabel: String? = nil,
        outputClassification: RoutingOutputClassification? = nil,
        observedInputSlot: InputSlotObservation? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.busNumber = busNumber
        self.targetRef = targetRef
        self.observedOutputLabel = observedOutputLabel
        self.outputClassification = outputClassification
        self.observedInputSlot = observedInputSlot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(RoutingNodeKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        busNumber = try container.decodeIfPresent(Int.self, forKey: .busNumber)
        targetRef = try container.decodeIfPresent(TargetReference.self, forKey: .targetRef)
        observedOutputLabel = try container.decodeIfPresent(String.self, forKey: .observedOutputLabel)
        outputClassification = try container.decodeIfPresent(
            RoutingOutputClassification.self,
            forKey: .outputClassification
        )
        observedInputSlot = try container.decodeIfPresent(InputSlotObservation.self, forKey: .observedInputSlot)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(busNumber, forKey: .busNumber)
        try container.encodeIfPresent(targetRef, forKey: .targetRef)
        try container.encodeIfPresent(observedOutputLabel, forKey: .observedOutputLabel)
        try container.encodeIfPresent(outputClassification, forKey: .outputClassification)
        try container.encodeIfPresent(observedInputSlot, forKey: .observedInputSlot)
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

enum RoutingCoverageState: String, Codable, Sendable {
    case complete
    case partial
    case unavailable
    case unstable
    case notObserved = "not_observed"
}

/// One routing domain's coverage and the reasons it is not `complete`.
struct RoutingDomainCoverage: Codable, Equatable, Sendable {
    let state: RoutingCoverageState
    let reasons: [String]
}

/// Per-domain coverage of a routing graph (#291).
///
/// The graph is `complete` only when every domain is; `isConsistent` enforces that, so a graph
/// that claims completeness while any domain is partial, unread, moved or not observed is refused
/// by `RoutingWriteGate` without that gate knowing the domains exist.
struct RoutingCoverage: Codable, Equatable, Sendable {
    let population: RoutingDomainCoverage
    let stripTrackAssociation: RoutingDomainCoverage
    let mainOutput: RoutingDomainCoverage
    let physicalOutput: RoutingDomainCoverage
    let busToAuxInput: RoutingDomainCoverage
    let sends: RoutingDomainCoverage

    enum CodingKeys: String, CodingKey {
        case population
        case stripTrackAssociation = "strip_track_association"
        case mainOutput = "main_output"
        case physicalOutput = "physical_output"
        case busToAuxInput = "bus_to_aux_input"
        case sends
    }

    /// Every domain the same, for a capture that answers nothing domain by domain.
    static func uniform(_ domain: RoutingDomainCoverage) -> RoutingCoverage {
        RoutingCoverage(
            population: domain,
            stripTrackAssociation: domain,
            mainOutput: domain,
            physicalOutput: domain,
            busToAuxInput: domain,
            sends: domain
        )
    }

    /// In wire order.
    var domains: [RoutingDomainCoverage] {
        [population, stripTrackAssociation, mainOutput, physicalOutput, busToAuxInput, sends]
    }

    var isComplete: Bool {
        domains.allSatisfy { $0.state == .complete }
    }

    /// The domain whose evidence an edge of `kind` rests on. An input assignment is the receiving
    /// side of a bus-to-aux edge, the one input edge this model publishes.
    func domain(for kind: RoutingEdgeKind) -> RoutingDomainCoverage {
        switch kind {
        case .mainOutput: return mainOutput
        case .send: return sends
        case .inputAssignment: return busToAuxInput
        }
    }
}

struct RoutingGraph: Codable, Equatable, Sendable {
    /// Issued through `ProjectReferenceIssuance`, the same observed project
    /// identity `logic://project/info` uses, from the cached name and bundle
    /// path only. Nil, with the reason in `partialReason`, when the cache does
    /// not yet carry both.
    let projectReference: TargetReference?
    let projectEpoch: UInt64
    let complete: Bool
    let partialReason: String?
    let nodes: [RoutingNode]
    let edges: [RoutingEdge]
    let provenance: [RoutingProvenance]
    /// The opaque identity of the capture, `SessionPopulationObservation.snapshotID(for:)`
    /// of the same capture, so it equals `inspect_session`'s `snapshot_id` for that capture.
    let snapshotId: String
    let coverage: RoutingCoverage

    enum CodingKeys: String, CodingKey {
        case projectReference, projectEpoch, complete, partialReason, nodes, edges, provenance
        case snapshotId = "snapshot_id"
        case coverage
    }

    var isConsistent: Bool {
        // Completeness is the coverage's to claim, and an edge is published only from a domain
        // that was read.
        guard complete == coverage.isComplete,
              edges.allSatisfy({ [.complete, .partial].contains(coverage.domain(for: $0.kind).state) })
        else {
            return false
        }
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

enum RoutingPathState: String, Sendable {
    case connected
    case disconnected
    case unverified
}

/// A structural path through the recorded directed edges, not audible signal, channel-format
/// compatibility or sidechain/monitor safety. Complete endpoint/edge evidence is mandatory;
/// bypass and level never delete an observed send connection. Callers bind the graph to their
/// capture before using this shared #291 predicate. No scanner or planner policy lives here.
func routingPath(from sourceRef: TargetReference, to sinkNodeID: String, in graph: RoutingGraph) -> RoutingPathState {
    guard graph.complete, graph.isConsistent else { return .unverified }
    let sources = graph.nodes.filter { $0.targetRef == sourceRef }
    let sinks = graph.nodes.filter { $0.id == sinkNodeID }
    guard sources.count == 1, let source = sources.first,
          sinks.count == 1, let sink = sinks.first, [.bus, .aux, .output].contains(sink.kind),
          source.id != sinkNodeID else { return .unverified }
    let outputs = graph.edges.filter { $0.kind == .mainOutput }
    guard Dictionary(grouping: outputs, by: \.source).values.allSatisfy({ $0.count == 1 }) else {
        return .unverified
    }
    let adjacency = Dictionary(grouping: graph.edges, by: \.source)
    var pending = [source.id]
    var visited = Set<String>()
    while let node = pending.popLast() {
        guard visited.insert(node).inserted else { continue }
        if node == sinkNodeID { return .connected }
        pending.append(contentsOf: (adjacency[node] ?? []).map(\.destination))
    }
    return .disconnected
}
