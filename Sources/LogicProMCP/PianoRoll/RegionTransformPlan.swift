enum MIDINoteSelection: Equatable, Sendable {
    case all
    case occurrences([Int])
}

struct RegionTransformPlan: Sendable {
    let regionRef: MIDIRegionReference
    let boundGeneration: UInt64
    // These indices are local to beforeSnapshot and are not persistent Event List row identity.
    let selectedOccurrenceIndices: [Int]
    let transform: MIDITransform
    let beforeSnapshot: MIDIRegionNoteSnapshot
    let predictedAfter: [MIDINoteEvent]
}

func planTransform(
    region: MIDIRegionReference,
    selection: MIDINoteSelection = .all,
    transform: MIDITransform,
    beforeSnapshot: MIDIRegionNoteSnapshot
) -> RegionTransformPlan? {
    guard beforeSnapshot.complete,
          beforeSnapshot.regionReference == region,
          beforeSnapshot.ppq > 0,
          beforeSnapshot.notes.allSatisfy(isValidPlanNote) else { return nil }
    guard let selectedOccurrenceIndices = resolveSelection(
        selection,
        noteCount: beforeSnapshot.notes.count
    ) else { return nil }
    let selectedNotes = selectedOccurrenceIndices.map { beforeSnapshot.notes[$0] }
    let transformedNotes = applyTransform(
        transform,
        to: selectedNotes,
        ppq: beforeSnapshot.ppq
    )
    var predictedAfter = beforeSnapshot.notes
    for (index, note) in zip(selectedOccurrenceIndices, transformedNotes) {
        predictedAfter[index] = note
    }
    guard predictedAfter.allSatisfy(isValidPlanNote) else { return nil }
    return RegionTransformPlan(
        regionRef: region,
        boundGeneration: beforeSnapshot.projectEpoch,
        selectedOccurrenceIndices: selectedOccurrenceIndices,
        transform: transform,
        beforeSnapshot: beforeSnapshot,
        predictedAfter: predictedAfter
    )
}

private func resolveSelection(
    _ selection: MIDINoteSelection,
    noteCount: Int
) -> [Int]? {
    switch selection {
    case .all:
        return Array(0..<noteCount)
    case .occurrences(let indices):
        guard Set(indices).count == indices.count,
              indices.allSatisfy({ (0..<noteCount).contains($0) }) else { return nil }
        return indices.sorted()
    }
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
