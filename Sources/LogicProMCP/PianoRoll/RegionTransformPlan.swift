enum MIDINoteSelection: Equatable, Sendable {
    case all
    case occurrences([Int])
}

enum MIDIOverlapPolicy: Equatable, Sendable {
    case allow
    case rejectNewSamePitchAndChannel
}

struct MIDINoteTransformChange: Equatable, Sendable {
    let occurrenceIndex: Int
    let before: MIDINoteEvent
    let after: MIDINoteEvent
}

enum RegionTransformPlanWarning: Equatable, Sendable {
    case emptySelection
    case noChangesPredicted
    case samePitchAndChannelOverlaps(count: Int)
}

struct RegionTransformPlan: Sendable {
    let regionRef: MIDIRegionReference
    let boundGeneration: UInt64
    // These indices are local to beforeSnapshot and are not persistent Event List row identity.
    let selectedOccurrenceIndices: [Int]
    var selectedCount: Int { selectedOccurrenceIndices.count }
    let overlapPolicy: MIDIOverlapPolicy
    let transform: MIDITransform
    let beforeSnapshot: MIDIRegionNoteSnapshot
    var beforeFingerprint: String {
        midiSnapshotCompletenessBinding(
            regionReference: beforeSnapshot.regionReference,
            projectEpoch: beforeSnapshot.projectEpoch,
            provenance: beforeSnapshot.provenance,
            conversionPipelineID: beforeSnapshot.conversionPipelineID,
            notes: beforeSnapshot.notes,
            ppq: beforeSnapshot.ppq
        )
    }
    let predictedAfter: [MIDINoteEvent]
    let predictedChanges: [MIDINoteTransformChange]
    let warnings: [RegionTransformPlanWarning]
}

func planTransform(
    region: MIDIRegionReference,
    selection: MIDINoteSelection = .all,
    overlapPolicy: MIDIOverlapPolicy = .rejectNewSamePitchAndChannel,
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
    guard predictedAfter.allSatisfy(isValidPlanNote),
          overlapPolicy.permits(before: beforeSnapshot.notes, after: predictedAfter) else { return nil }
    let predictedChanges = selectedOccurrenceIndices.compactMap { index in
        let before = beforeSnapshot.notes[index]
        let after = predictedAfter[index]
        return before == after ? nil : MIDINoteTransformChange(
            occurrenceIndex: index,
            before: before,
            after: after
        )
    }
    guard let predictedOverlapPairs = samePitchAndChannelOverlapPairs(
        in: predictedAfter
    ) else { return nil }
    var warnings: [RegionTransformPlanWarning] = []
    if selectedOccurrenceIndices.isEmpty {
        warnings.append(.emptySelection)
    } else if predictedChanges.isEmpty {
        warnings.append(.noChangesPredicted)
    }
    if !predictedOverlapPairs.isEmpty {
        warnings.append(
            .samePitchAndChannelOverlaps(count: predictedOverlapPairs.count)
        )
    }
    return RegionTransformPlan(
        regionRef: region,
        boundGeneration: beforeSnapshot.projectEpoch,
        selectedOccurrenceIndices: selectedOccurrenceIndices,
        overlapPolicy: overlapPolicy,
        transform: transform,
        beforeSnapshot: beforeSnapshot,
        predictedAfter: predictedAfter,
        predictedChanges: predictedChanges,
        warnings: warnings
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

private extension MIDIOverlapPolicy {
    func permits(before: [MIDINoteEvent], after: [MIDINoteEvent]) -> Bool {
        switch self {
        case .allow:
            return true
        case .rejectNewSamePitchAndChannel:
            guard let beforePairs = samePitchAndChannelOverlapPairs(in: before),
                  let afterPairs = samePitchAndChannelOverlapPairs(in: after) else { return false }
            return afterPairs.isSubset(of: beforePairs)
        }
    }
}

private struct MIDINoteOverlapPair: Hashable {
    let lowerIndex: Int
    let upperIndex: Int
}

private func samePitchAndChannelOverlapPairs(
    in notes: [MIDINoteEvent]
) -> Set<MIDINoteOverlapPair>? {
    var pairs: Set<MIDINoteOverlapPair> = []
    for lowerIndex in notes.indices {
        let lower = notes[lowerIndex]
        let (lowerEnd, lowerOverflow) = lower.startTicks.addingReportingOverflow(
            lower.durationTicks
        )
        guard !lowerOverflow else { return nil }

        for upperIndex in notes.indices where upperIndex > lowerIndex {
            let upper = notes[upperIndex]
            guard lower.pitch == upper.pitch,
                  lower.channel == upper.channel else { continue }
            let (upperEnd, upperOverflow) = upper.startTicks.addingReportingOverflow(
                upper.durationTicks
            )
            guard !upperOverflow else { return nil }
            if lower.startTicks < upperEnd, upper.startTicks < lowerEnd {
                pairs.insert(MIDINoteOverlapPair(
                    lowerIndex: lowerIndex,
                    upperIndex: upperIndex
                ))
            }
        }
    }
    return pairs
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
