enum TempoMutationRejection: Equatable, Sendable {
    case snapshotIncomplete
    case invalidTempoMap
    case noCheckpoint
    case restoreNotVerified
}

func tempoMapDiff(
    before: TempoMapSnapshot,
    after: TempoMapSnapshot
) -> (addedOrChanged: [TempoMapEvent], removed: [TempoMapEvent]) {
    let addedOrChanged = after.events.filter { event in
        guard let previous = before.events.first(where: { $0.tick == event.tick }) else {
            return true
        }
        return previous != event
    }
    let removed = before.events.filter { event in
        !after.events.contains(where: { $0.tick == event.tick })
    }
    return (addedOrChanged, removed)
}

func tempoMapSagaEligibility(
    beforeCheckpoint: TempoMapSnapshot?,
    restoreVerified: Bool
) -> [TempoMutationRejection] {
    var rejections: [TempoMutationRejection] = []
    if let beforeCheckpoint {
        if !beforeCheckpoint.complete {
            rejections.append(.snapshotIncomplete)
        }
        if !isValidTempoMap(beforeCheckpoint) {
            rejections.append(.invalidTempoMap)
        }
    } else {
        rejections.append(.noCheckpoint)
    }
    if !restoreVerified {
        rejections.append(.restoreNotVerified)
    }
    return rejections
}
