enum TransformVerdict: Equatable, Sendable {
    case stateA
    case stateBUnverified(reason: String)
    case mismatch(unexpected: [MIDINoteEvent])
}

func verifyTransform(
    plan: RegionTransformPlan,
    observedAfter: MIDIRegionNoteSnapshot
) -> TransformVerdict {
    guard observedAfter.complete else {
        return .stateBUnverified(
            reason: observedAfter.partialReason ?? "Post-write MIDI snapshot is incomplete"
        )
    }
    guard observedAfter.regionReference == plan.regionRef else {
        return .stateBUnverified(reason: "Post-write region does not match the transform plan")
    }
    let (expectedGeneration, overflow) = plan.boundGeneration.addingReportingOverflow(1)
    guard !overflow, observedAfter.projectEpoch == expectedGeneration else {
        return .stateBUnverified(reason: "Post-write generation transition is not verified")
    }

    let expected = sortedNotes(plan.predictedAfter)
    let observed = sortedNotes(observedAfter.notes)
    guard observed != expected else { return .stateA }

    var unmatchedExpected = expected
    let unexpected = observed.filter { note in
        guard let index = unmatchedExpected.firstIndex(of: note) else { return true }
        unmatchedExpected.remove(at: index)
        return false
    }
    return .mismatch(unexpected: unexpected)
}

func compensationNotes(plan: RegionTransformPlan) -> [MIDINoteEvent] {
    plan.beforeSnapshot.notes
}

private func sortedNotes(_ notes: [MIDINoteEvent]) -> [MIDINoteEvent] {
    notes.sorted { lhs, rhs in
        if lhs.pitch != rhs.pitch { return lhs.pitch < rhs.pitch }
        if lhs.startTicks != rhs.startTicks { return lhs.startTicks < rhs.startTicks }
        if lhs.durationTicks != rhs.durationTicks { return lhs.durationTicks < rhs.durationTicks }
        if lhs.velocity != rhs.velocity { return lhs.velocity < rhs.velocity }
        return lhs.channel < rhs.channel
    }
}
