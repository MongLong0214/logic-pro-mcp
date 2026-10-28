/// Pure B1 evidence contract for an explicitly requested receiving Aux bus (#967).
///
/// This type does not read Logic, reserve a Bus, create an Aux, or grant write authority.
/// A future native provider must supply the complete namespace and consumer snapshot. Callers
/// must revalidate that exact evidence immediately before any separately qualified creation.
enum AuxNamespaceEvidence {
    struct Binding: Equatable, Sendable {
        let projectReference: TargetReference
        let projectEpoch: UInt64
        let snapshotID: String
        let namespaceGeneration: UInt64
    }

    struct Consumer: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case auxReceiver = "aux_receiver"
            case instrumentMultiOutput = "instrument_multi_output"
            case other
        }

        let id: String
        let targetReference: TargetReference
        let busNumber: Int
        let kind: Kind
        let displayName: String
        let hidden: Bool
        let mixerOnly: Bool
        let sharedStrip: Bool
    }

    struct Snapshot: Equatable, Sendable {
        let binding: Binding
        let namespaceAvailabilityComplete: Bool
        let consumerCoverageComplete: Bool
        /// Bus numbers the provider positively observed as allocatable now. This is not a menu
        /// offering or a range inferred from labels.
        let availableBusNumbers: [Int]
        /// Every consumer is retained even when it is not an Aux candidate.
        let consumers: [Consumer]
    }

    enum UnavailableReason: String, Equatable, Sendable, Comparable {
        case invalidRequestedBus = "invalid_requested_bus"
        case projectMismatch = "project_mismatch"
        case epochMismatch = "epoch_mismatch"
        case snapshotMismatch = "snapshot_mismatch"
        case namespaceGenerationMismatch = "namespace_generation_mismatch"
        case namespaceAvailabilityIncomplete = "namespace_availability_incomplete"
        case consumerCoverageIncomplete = "consumer_coverage_incomplete"
        case invalidAvailableBus = "invalid_available_bus"
        case duplicateAvailableBus = "duplicate_available_bus"
        case invalidConsumer = "invalid_consumer"
        case duplicateConsumerIdentity = "duplicate_consumer_identity"
        case duplicateConsumerReference = "duplicate_consumer_reference"
        case availableBusHasConsumer = "available_bus_has_consumer"
        case requestedBusUnavailable = "requested_bus_unavailable"
        case occupiedWithoutAuxReceiver = "occupied_without_aux_receiver"

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Reuse: Equatable, Sendable {
        let busNumber: Int
        let binding: Binding
        let auxCandidates: [Consumer]
        let consumers: [Consumer]
    }

    struct Allocation: Equatable, Sendable {
        let busNumber: Int
        let binding: Binding
    }

    enum Decision: Equatable, Sendable {
        case reuse(Reuse)
        case allocate(Allocation)
        case unavailable([UnavailableReason])
    }

    struct Conflict: Equatable, Sendable {
        let requestedBus: Int
        let previewDecision: Decision
        let currentDecision: Decision
    }

    enum Revalidation: Equatable, Sendable {
        case retained(Decision)
        case conflict(Conflict)
    }

    static func decision(for requestedBus: Int, expected: Binding, snapshot: Snapshot) -> Decision {
        var reasons = validationReasons(requestedBus: requestedBus, expected: expected, snapshot: snapshot)
        if !reasons.isEmpty { return .unavailable(reasons.sorted()) }

        let consumers = snapshot.consumers
            .filter { $0.busNumber == requestedBus }
            .sorted(by: consumerOrder)
        let auxCandidates = consumers.filter { $0.kind == .auxReceiver }
        if !auxCandidates.isEmpty {
            return .reuse(.init(busNumber: requestedBus, binding: snapshot.binding,
                                auxCandidates: auxCandidates, consumers: consumers))
        }
        if !consumers.isEmpty {
            return .unavailable([.occupiedWithoutAuxReceiver])
        }
        if snapshot.availableBusNumbers.contains(requestedBus) {
            return .allocate(.init(busNumber: requestedBus, binding: snapshot.binding))
        }
        reasons.append(.requestedBusUnavailable)
        return .unavailable(reasons.sorted())
    }

    /// Revalidation compares the whole decision, including the exact evidence binding. A changed
    /// generation never causes a silent fallback to a different Bus; it requires a new preview.
    static func revalidate(_ previewDecision: Decision, requestedBus: Int,
                           expected: Binding, snapshot: Snapshot) -> Revalidation {
        let current = decision(for: requestedBus, expected: expected, snapshot: snapshot)
        guard current == previewDecision else {
            return .conflict(.init(requestedBus: requestedBus,
                                   previewDecision: previewDecision, currentDecision: current))
        }
        return .retained(current)
    }

    private static func validationReasons(requestedBus: Int, expected: Binding,
                                          snapshot: Snapshot) -> [UnavailableReason] {
        var reasons = Set<UnavailableReason>()
        if !OutputAssignment.busNumbers.contains(requestedBus) { reasons.insert(.invalidRequestedBus) }
        if snapshot.binding.projectReference != expected.projectReference { reasons.insert(.projectMismatch) }
        if snapshot.binding.projectEpoch != expected.projectEpoch { reasons.insert(.epochMismatch) }
        if snapshot.binding.snapshotID != expected.snapshotID { reasons.insert(.snapshotMismatch) }
        if snapshot.binding.namespaceGeneration != expected.namespaceGeneration {
            reasons.insert(.namespaceGenerationMismatch)
        }
        if !snapshot.namespaceAvailabilityComplete { reasons.insert(.namespaceAvailabilityIncomplete) }
        if !snapshot.consumerCoverageComplete { reasons.insert(.consumerCoverageIncomplete) }

        if snapshot.availableBusNumbers.contains(where: { !OutputAssignment.busNumbers.contains($0) }) {
            reasons.insert(.invalidAvailableBus)
        }
        if Set(snapshot.availableBusNumbers).count != snapshot.availableBusNumbers.count {
            reasons.insert(.duplicateAvailableBus)
        }

        let invalidConsumer = snapshot.consumers.contains {
            $0.id.isEmpty || $0.targetReference.rawValue.isEmpty
                || !OutputAssignment.busNumbers.contains($0.busNumber)
        }
        if invalidConsumer { reasons.insert(.invalidConsumer) }
        if Set(snapshot.consumers.map(\.id)).count != snapshot.consumers.count {
            reasons.insert(.duplicateConsumerIdentity)
        }
        if Set(snapshot.consumers.map { $0.targetReference.rawValue }).count != snapshot.consumers.count {
            reasons.insert(.duplicateConsumerReference)
        }
        let consumed = Set(snapshot.consumers.map(\.busNumber))
        if !consumed.isDisjoint(with: Set(snapshot.availableBusNumbers)) {
            reasons.insert(.availableBusHasConsumer)
        }
        return reasons.sorted()
    }

    private static func consumerOrder(_ lhs: Consumer, _ rhs: Consumer) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.targetReference.rawValue < rhs.targetReference.rawValue
    }
}
