enum TransformVerdict: Equatable, Sendable {
    case stateA
    case stateBUnverified(reason: String)
    case mismatch(unexpected: [MIDINoteEvent])
}

func verifyTransform(
    plan: RegionTransformPlan,
    observedAfter: MIDIRegionNoteSnapshot,
    expected: IndependentExpectedProof
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
    guard let independent = expected.independentPayload else {
        return .stateBUnverified(reason: "expected must carry a sealed independent provenance proof")
    }
    guard independent.rootID != observedAfter.conversionPipelineID else {
        return .stateBUnverified(reason: "expected root shares the observed conversion pipeline")
    }
    guard independent.region == observedAfter.regionReference else {
        return .stateBUnverified(reason: "expected proof is not bound to the observed region")
    }
    guard independent.contentBinding == midiRegionNoteDigest(independent.notes, ppq: independent.ppq) else {
        return .stateBUnverified(reason: "expected proof content binding is invalid")
    }
    guard observedAfter.ppq > 0, independent.ppq > 0 else {
        return .stateBUnverified(reason: "PPQ must be positive")
    }

    let actual = canonicalize(observedAfter.notes, ppq: observedAfter.ppq)
    guard let normalized = normalizePPQ(
        independent.notes,
        from: independent.ppq,
        to: observedAfter.ppq
    ) else {
        return .stateBUnverified(reason: "PPQ normalization overflow")
    }
    let wanted = canonicalize(normalized, ppq: observedAfter.ppq)
    guard actual != wanted else {
        return .stateBUnverified(
            reason: "R1 grants no positive match; independent positive verification is R2 live-ingestion"
        )
    }

    var unmatched = wanted
    var unexpected: [MIDINoteEvent] = []
    for note in actual {
        if let index = unmatched.firstIndex(of: note) {
            unmatched.remove(at: index)
        } else {
            unexpected.append(note)
        }
    }
    return .mismatch(unexpected: unexpected)
}

func compensationNotes(plan: RegionTransformPlan) -> [MIDINoteEvent] {
    plan.beforeSnapshot.notes
}
