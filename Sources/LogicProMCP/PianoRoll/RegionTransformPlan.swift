struct RegionTransformPlan: Sendable {
    let regionRef: MIDIRegionReference
    let boundGeneration: UInt64
    let transform: MIDITransform
    let beforeSnapshot: MIDIRegionNoteSnapshot
    let predictedAfter: [MIDINoteEvent]
}

func planTransform(
    region: MIDIRegionReference,
    transform: MIDITransform,
    beforeSnapshot: MIDIRegionNoteSnapshot
) -> RegionTransformPlan? {
    guard beforeSnapshot.complete,
          beforeSnapshot.regionReference == region,
          beforeSnapshot.ppq > 0,
          beforeSnapshot.notes.allSatisfy(isValidPlanNote) else { return nil }
    let predictedAfter = applyTransform(
        transform,
        to: beforeSnapshot.notes,
        ppq: beforeSnapshot.ppq
    )
    guard predictedAfter.allSatisfy(isValidPlanNote) else { return nil }
    return RegionTransformPlan(
        regionRef: region,
        boundGeneration: beforeSnapshot.projectEpoch,
        transform: transform,
        beforeSnapshot: beforeSnapshot,
        predictedAfter: predictedAfter
    )
}

private func isValidPlanNote(_ note: MIDINoteEvent) -> Bool {
    guard note.pitch <= 127,
          (1...127).contains(note.velocity),
          (1...16).contains(note.channel),
          note.startTicks >= 0,
          note.durationTicks > 0 else { return false }
    let (_, endOverflow) = note.startTicks.addingReportingOverflow(note.durationTicks)
    return !endOverflow
}

enum PlanApplyRejection: Equatable, Sendable {
    case staleGeneration(bound: UInt64, current: UInt64)
    case snapshotIncomplete
    case regionMismatch
}

func validateApply(
    plan: RegionTransformPlan,
    currentGeneration: UInt64,
    currentRegion: MIDIRegionReference
) -> [PlanApplyRejection] {
    var rejections: [PlanApplyRejection] = []
    if currentGeneration != plan.boundGeneration {
        rejections.append(
            .staleGeneration(bound: plan.boundGeneration, current: currentGeneration)
        )
    }
    if !plan.beforeSnapshot.complete {
        rejections.append(.snapshotIncomplete)
    }
    if currentRegion != plan.regionRef
        || plan.beforeSnapshot.regionReference != plan.regionRef
    {
        rejections.append(.regionMismatch)
    }
    return rejections
}
