struct RoutingWriteRequest: Sendable {
    let sourceTrackRef: TargetReference
    let physicalSlot: Int
    let destinationBusNumber: Int?
    let destinationRef: TargetReference?
    let replaceExisting: Bool
    let expectedProjectEpoch: UInt64

    init(
        sourceTrackRef: TargetReference,
        physicalSlot: Int,
        destinationBusNumber: Int?,
        destinationRef: TargetReference?,
        replaceExisting: Bool = false,
        expectedProjectEpoch: UInt64
    ) {
        self.sourceTrackRef = sourceTrackRef
        self.physicalSlot = physicalSlot
        self.destinationBusNumber = destinationBusNumber
        self.destinationRef = destinationRef
        self.replaceExisting = replaceExisting
        self.expectedProjectEpoch = expectedProjectEpoch
    }
}

enum RoutingWriteRejection: Equatable, Sendable {
    case staleGraph(expected: UInt64, actual: UInt64)
    case partialGraphUnsafe(reason: String)
    case slotOccupied(slot: Int)
    case slotOutOfRange(slot: Int)
    case destinationNotBusDistinguished
    case unknownDestination
    case sourceNotFound
    case sourceAmbiguous
    case cycleIntroduced
}

struct RoutingWriteDecision: Equatable, Sendable {
    let allowed: Bool
    let rejections: [RoutingWriteRejection]
    let writeAttempted: Bool
}

func evaluate(
    _ request: RoutingWriteRequest,
    against graph: RoutingGraph
) -> RoutingWriteDecision {
    var rejections: [RoutingWriteRejection] = []

    if request.expectedProjectEpoch != graph.projectEpoch {
        rejections.append(
            .staleGraph(expected: request.expectedProjectEpoch, actual: graph.projectEpoch)
        )
    }
    if !graph.complete || !graph.isConsistent {
        rejections.append(
            .partialGraphUnsafe(
                reason: graph.partialReason ?? "routing graph is incomplete or inconsistent"
            )
        )
    }
    if !routingPhysicalSendSlots.contains(request.physicalSlot) {
        rejections.append(.slotOutOfRange(slot: request.physicalSlot))
    }
    let sources = graph.nodes.filter { $0.targetRef == request.sourceTrackRef }
    if sources.count > 1 {
        rejections.append(.sourceAmbiguous)
    } else if sources.first?.kind != .track {
        rejections.append(.sourceNotFound)
    }

    let destinations = matchingDestinations(for: request, in: graph)
    if request.destinationBusNumber == nil && request.destinationRef == nil {
        rejections.append(.destinationNotBusDistinguished)
    } else if destinations.count != 1 {
        rejections.append(.unknownDestination)
    }

    let occupied = graph.edges.contains { edge in
        guard edge.kind == .send, let send = edge.send else { return false }
        return send.sourceTrackRef == request.sourceTrackRef
            && send.physicalSlot == request.physicalSlot
    }
    if occupied && !request.replaceExisting {
        rejections.append(.slotOccupied(slot: request.physicalSlot))
    }

    if rejections.isEmpty, let source = sources.first, let destination = destinations.first {
        switch routingConnectionIntroducesCycle(from: source.id, to: destination.id, in: graph) {
        case true?: rejections.append(.cycleIntroduced)
        case nil: rejections.append(.partialGraphUnsafe(reason: "routing cycle evidence unavailable"))
        case false?: break
        }
    }

    return RoutingWriteDecision(
        allowed: rejections.isEmpty,
        rejections: rejections,
        writeAttempted: false
    )
}

private func matchingDestinations(
    for request: RoutingWriteRequest,
    in graph: RoutingGraph
) -> [RoutingNode] {
    graph.nodes.filter { node in
        guard node.kind == .bus || node.kind == .aux else { return false }
        if let busNumber = request.destinationBusNumber, node.busNumber != busNumber {
            return false
        }
        if let reference = request.destinationRef, node.targetRef != reference {
            return false
        }
        return true
    }
}
