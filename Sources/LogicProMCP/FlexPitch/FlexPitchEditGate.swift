enum FlexEditEligibility: Equatable, Sendable {
    case publicEligible
    case experimental(reasons: [String])
}

func editEligibility(
    snapshot: FlexPitchSnapshot,
    ref: FlexPitchNoteReference,
    currentAnalysisGeneration: UInt64,
    dualEvidenceCount: Int,
    monophonicThreshold: Double = 0.9
) -> FlexEditEligibility {
    var reasons: [String] = []
    if !snapshot.complete {
        reasons.append("snapshot incomplete")
    }
    if snapshot.analysisGeneration != currentAnalysisGeneration {
        reasons.append("stale snapshot")
    }
    if !isReferenceCurrent(ref, currentAnalysisGeneration: currentAnalysisGeneration) {
        reasons.append("stale note reference")
    }
    if !snapshot.notes.contains(where: { $0.reference == ref }) {
        reasons.append("note reference does not belong to snapshot")
    }

    // Fail closed on non-finite / out-of-range confidence or threshold, and only
    // compare the two when both are in range (an out-of-range value is its own,
    // distinct rejection rather than a silent threshold comparison).
    let confidenceInRange = snapshot.monophonicConfidence.isFinite
        && (0 ... 1).contains(snapshot.monophonicConfidence)
    let thresholdInRange = monophonicThreshold.isFinite
        && (0 ... 1).contains(monophonicThreshold)
    if !confidenceInRange {
        reasons.append("monophonic confidence outside 0...1")
    }
    if !thresholdInRange {
        reasons.append("monophonic threshold outside 0...1")
    }
    if confidenceInRange, thresholdInRange, snapshot.monophonicConfidence < monophonicThreshold {
        reasons.append("monophonic confidence below threshold")
    }

    if snapshot.provenance == .none || dualEvidenceCount < 2 {
        reasons.append("dual evidence required")
    }
    return reasons.isEmpty ? .publicEligible : .experimental(reasons: reasons)
}

func publicEditableReferences(
    snapshot: FlexPitchSnapshot,
    currentAnalysisGeneration: UInt64,
    dualEvidenceCount: Int
) -> [FlexPitchNoteReference] {
    snapshot.notes.compactMap { note in
        guard editEligibility(
            snapshot: snapshot,
            ref: note.reference,
            currentAnalysisGeneration: currentAnalysisGeneration,
            dualEvidenceCount: dualEvidenceCount
        ) == .publicEligible else {
            return nil
        }
        return note.reference
    }
}
