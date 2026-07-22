enum RegionMatchVerdict: Sendable {
    case exactMatch
    case mismatch(
        added: [MIDINoteEvent],
        removed: [MIDINoteEvent],
        changed: [(MIDINoteEvent, MIDINoteEvent)]
    )
    case incompleteCannotVerify(reason: String)
}

extension RegionMatchVerdict: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.exactMatch, .exactMatch):
            true
        case let (.incompleteCannotVerify(left), .incompleteCannotVerify(right)):
            left == right
        case let (
            .mismatch(leftAdded, leftRemoved, leftChanged),
            .mismatch(rightAdded, rightRemoved, rightChanged)
        ):
            leftAdded == rightAdded
                && leftRemoved == rightRemoved
                && leftChanged.count == rightChanged.count
                && zip(leftChanged, rightChanged).allSatisfy { left, right in
                    left.0 == right.0 && left.1 == right.1
                }
        default:
            false
        }
    }
}

/// A caller's expected note sequence, bundled with the provenance that produced
/// it. There is NO default provenance: the caller must state where the expected
/// notes came from, and verification requires that provenance to differ from the
/// observed snapshot's conversion — so a sequence re-derived by the SAME
/// conversion (which would share its bugs) can never be accepted as an
/// independent match. An empty provenance id is rejected (unstated == unusable).
struct ExpectedSequence {
    let notes: [MIDINoteEvent]
    let ppq: Int
    let provenanceID: String

    init(notes: [MIDINoteEvent], ppq: Int, provenanceID: String) {
        self.notes = notes
        self.ppq = ppq
        self.provenanceID = provenanceID
    }
}

func verifyRegion(
    observed: MIDIRegionNoteSnapshot,
    expected: ExpectedSequence
) -> RegionMatchVerdict {
    guard observed.complete else {
        return .incompleteCannotVerify(
            reason: observed.partialReason ?? "MIDI note scan is incomplete"
        )
    }
    guard observed.provenance != .none else {
        return .incompleteCannotVerify(reason: "Independent readback provenance is required")
    }
    // Correlated-conversion guard: the expected sequence must state a provenance,
    // and it must DIFFER from the observed snapshot's conversion, so a
    // re-derivation sharing the observed conversion's bugs cannot produce a false
    // match. An unstated (empty) provenance is unusable, not a pass.
    guard !expected.provenanceID.isEmpty else {
        return .incompleteCannotVerify(reason: "Expected sequence must state its provenance")
    }
    guard observed.conversionPipelineID != expected.provenanceID else {
        return .incompleteCannotVerify(
            reason: "Expected sequence must not share the observed conversion pipeline"
        )
    }
    guard observed.ppq > 0, expected.ppq > 0 else {
        return .incompleteCannotVerify(reason: "PPQ must be positive")
    }

    let actual = canonicalize(observed.notes, ppq: observed.ppq)
    let wanted = canonicalize(
        normalizePPQ(expected.notes, from: expected.ppq, to: observed.ppq),
        ppq: observed.ppq
    )
    guard actual != wanted else { return .exactMatch }

    let differences = noteDifferences(expected: wanted, observed: actual)
    return .mismatch(
        added: differences.added,
        removed: differences.removed,
        changed: differences.changed
    )
}

func diffRegions(
    before: MIDIRegionNoteSnapshot,
    after: MIDIRegionNoteSnapshot
) -> (added: [MIDINoteEvent], removed: [MIDINoteEvent]) {
    let comparisonPPQ = max(max(before.ppq, after.ppq), 1)
    let previous = canonicalize(
        normalizePPQ(before.notes, from: before.ppq, to: comparisonPPQ),
        ppq: comparisonPPQ
    )
    let current = canonicalize(
        normalizePPQ(after.notes, from: after.ppq, to: comparisonPPQ),
        ppq: comparisonPPQ
    )

    // ponytail: O(n²) preserves duplicate-note multiset semantics; index if qualified
    // providers make very large region diffs a measured hot path.
    var unmatchedPrevious = previous
    var added: [MIDINoteEvent] = []
    for note in current {
        if let index = unmatchedPrevious.firstIndex(of: note) {
            unmatchedPrevious.remove(at: index)
        } else {
            added.append(note)
        }
    }
    return (added: added, removed: unmatchedPrevious)
}

private func noteDifferences(
    expected: [MIDINoteEvent],
    observed: [MIDINoteEvent]
) -> (
    added: [MIDINoteEvent],
    removed: [MIDINoteEvent],
    changed: [(MIDINoteEvent, MIDINoteEvent)]
) {
    var remainingObserved = observed
    var remainingExpected: [MIDINoteEvent] = []
    for note in expected {
        if let index = remainingObserved.firstIndex(of: note) {
            remainingObserved.remove(at: index)
        } else {
            remainingExpected.append(note)
        }
    }

    var removed: [MIDINoteEvent] = []
    var changed: [(MIDINoteEvent, MIDINoteEvent)] = []
    for note in remainingExpected {
        if let index = remainingObserved.firstIndex(where: { sameIdentity($0, note) }) {
            changed.append((note, remainingObserved.remove(at: index)))
        } else {
            removed.append(note)
        }
    }
    return (added: remainingObserved, removed: removed, changed: changed)
}

private func sameIdentity(_ lhs: MIDINoteEvent, _ rhs: MIDINoteEvent) -> Bool {
    lhs.pitch == rhs.pitch
        && lhs.channel == rhs.channel
        && lhs.startTicks == rhs.startTicks
}
