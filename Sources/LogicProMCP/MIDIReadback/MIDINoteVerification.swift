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

/// Proof that an expected sequence came from a source INDEPENDENT of the
/// observed readback conversion (a user-authored artifact, an imported file,
/// etc.), carrying that source's identifier. There is no production-constructible
/// proven case: the proven variant compiles only under the debug seam, so a
/// release build cannot present an independently-sourced expected sequence at
/// all — verification therefore cannot report a match in a release build (a free
/// label can never stand in for genuine independence).
enum IndependentExpectedProof: Sendable {
    case unproven
    #if QUALIFICATION_FAULT_SEAM
    case provenExternalArtifact(sourceID: String)
    #endif

    var externalSourceID: String? {
        #if QUALIFICATION_FAULT_SEAM
        if case let .provenExternalArtifact(id) = self { return id }
        #endif
        return nil
    }
}

/// A caller's expected note sequence bundled with a proof of its independent
/// provenance. The provenance is a sealed proof, not a free label, so a sequence
/// re-derived by the observed conversion cannot be relabeled as independent.
struct ExpectedSequence {
    let notes: [MIDINoteEvent]
    let ppq: Int
    let provenance: IndependentExpectedProof

    init(notes: [MIDINoteEvent], ppq: Int, provenance: IndependentExpectedProof) {
        self.notes = notes
        self.ppq = ppq
        self.provenance = provenance
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
    // Independence guard: the expected sequence must carry a PROVEN independent
    // provenance (not a free label), and that source must differ from the
    // observed snapshot's conversion — so a re-derivation sharing the observed
    // conversion's bugs cannot be relabeled and accepted as a match.
    guard let expectedSourceID = expected.provenance.externalSourceID else {
        return .incompleteCannotVerify(
            reason: "Expected sequence must carry a proven independent provenance"
        )
    }
    guard observed.conversionPipelineID != expectedSourceID else {
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
