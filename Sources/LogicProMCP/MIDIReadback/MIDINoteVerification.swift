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
    case provenExternalArtifact(sourceID: String, contentBinding: String)
    #endif

    var binding: (sourceID: String, contentBinding: String)? {
        #if QUALIFICATION_FAULT_SEAM
        if case let .provenExternalArtifact(id, digest) = self { return (id, digest) }
        #endif
        return nil
    }
}

/// Deterministic binding of an external artifact's identity to the exact note
/// payload it certifies. The proof carries this value; verification recomputes it
/// from the presented notes/PPQ and rejects any mismatch, so a proof minted for
/// one artifact cannot be transferred to relabel a different (e.g. observed-
/// derived) note payload.
func expectedContentBinding(sourceID: String, notes: [MIDINoteEvent], ppq: Int) -> String {
    let notesPart = notes
        .map { "\($0.pitch),\($0.startTicks),\($0.durationTicks),\($0.velocity),\($0.channel)" }
        .joined(separator: ";")
    return "\(sourceID)|ppq=\(ppq)|\(notesPart)"
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
    guard let binding = expected.provenance.binding else {
        return .incompleteCannotVerify(
            reason: "Expected sequence must carry a proven independent provenance"
        )
    }
    guard observed.conversionPipelineID != binding.sourceID else {
        return .incompleteCannotVerify(
            reason: "Expected sequence must not share the observed conversion pipeline"
        )
    }
    // The proof must be bound to THIS payload: recompute the binding from the
    // presented notes/PPQ and reject a transferred/relabeled proof.
    guard binding.contentBinding
        == expectedContentBinding(sourceID: binding.sourceID, notes: expected.notes, ppq: expected.ppq) else {
        return .incompleteCannotVerify(
            reason: "Expected provenance proof is not bound to this payload"
        )
    }
    guard observed.ppq > 0, expected.ppq > 0 else {
        return .incompleteCannotVerify(reason: "PPQ must be positive")
    }

    let actual = canonicalize(observed.notes, ppq: observed.ppq)
    guard let normalizedExpected = normalizePPQ(expected.notes, from: expected.ppq, to: observed.ppq) else {
        return .incompleteCannotVerify(reason: "PPQ normalization overflow")
    }
    let wanted = canonicalize(normalizedExpected, ppq: observed.ppq)
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
) -> (added: [MIDINoteEvent], removed: [MIDINoteEvent])? {
    // Both sides must be complete (a decoded/incomplete payload keeps its notes
    // but must not drive added/removed claims) and must normalize without
    // overflow — else there is no trustworthy diff.
    guard before.complete, after.complete else { return nil }
    let comparisonPPQ = max(max(before.ppq, after.ppq), 1)
    guard let previousNotes = normalizePPQ(before.notes, from: before.ppq, to: comparisonPPQ),
          let currentNotes = normalizePPQ(after.notes, from: after.ppq, to: comparisonPPQ) else {
        return nil
    }
    let previous = canonicalize(previousNotes, ppq: comparisonPPQ)
    let current = canonicalize(currentNotes, ppq: comparisonPPQ)

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
