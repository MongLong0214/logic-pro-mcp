// Region note diff over TWO completeness-gated snapshots. This is NOT verification:
// it does not claim the readback is independent of any external source and it does
// not report a match. It computes an added/removed delta between two snapshots that
// have each been independently proven complete by `assessReadback`, and fails closed
// otherwise. A zero delta means "the two complete snapshots are equal", never
// "verified against Logic" or a State-A proof. There is no production caller and no
// public API in this rollout; independent verification is the owned remainder of a
// later rollout (see #293 / #446).

/// Added/removed note delta between two snapshots, or nil when it cannot be trusted.
func diffRegions(
    before: MIDIRegionNoteSnapshot,
    after: MIDIRegionNoteSnapshot
) -> (added: [MIDINoteEvent], removed: [MIDINoteEvent])? {
    // Both sides must be complete (a decoded/incomplete payload keeps its notes but
    // must not drive added/removed claims) and must normalize without overflow —
    // else there is no trustworthy diff.
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
