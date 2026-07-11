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
    beforeSnapshot: MIDIRegionNoteSnapshot,
    ppq: Int
) -> RegionTransformPlan? {
    guard beforeSnapshot.complete, beforeSnapshot.regionReference == region else { return nil }
    return RegionTransformPlan(
        regionRef: region,
        boundGeneration: beforeSnapshot.projectEpoch,
        transform: transform,
        beforeSnapshot: beforeSnapshot,
        predictedAfter: applyTransform(transform, to: beforeSnapshot.notes, ppq: ppq)
    )
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
