import Foundation
import Testing
@testable import LogicProMCP

// E0 — independence-guard suite for ADR-014/#302 R1 (CI, no Logic).
// The whole suite is `#if QUALIFICATION_FAULT_SEAM`: a release build has no proven
// `IndependentExpectedProof` at all, so `verifyRegion` can never grant a positive
// match in release. Under the seam we mint a genuine proof to exercise BOTH the
// rejections (Decision-B guard) and one positive grant control (so independence is
// not "proven" by permanent darkness).
#if QUALIFICATION_FAULT_SEAM

private let e0RegionA = MIDIRegionReference(targetRef: TargetReference(rawValue: "trk_A"), regionIndex: 0)
private let e0RegionB = MIDIRegionReference(targetRef: TargetReference(rawValue: "trk_B"), regionIndex: 1)

private func e0Note(_ pitch: UInt8, start: Int64 = 0, dur: Int64 = 120, vel: UInt8 = 100, ch: UInt8 = 1) -> MIDINoteEvent {
    MIDINoteEvent(pitch: pitch, startTicks: start, durationTicks: dur, velocity: vel, channel: ch)
}

/// Observed snapshot (Event List AX = the observed conversion, pipeline id
/// `MIDIRegionNoteSnapshot.eventListConversionID`).
private func e0Observed(region: MIDIRegionReference = e0RegionA, ppq: Int = 480, notes: [MIDINoteEvent]) -> MIDIRegionNoteSnapshot {
    .makeCompleteForTesting(regionReference: region, projectEpoch: 1, ppq: ppq, notes: notes)
}

/// A genuine seam-minted independent proof (stands in for R2's live ingestion).
private func e0Proven(
    root: IndependentExpectedRoot = .authoredIntent,
    rootID: String = "authored.intent.v1",
    region: MIDIRegionReference = e0RegionA,
    ppq: Int = 480,
    notes: [MIDINoteEvent]
) -> IndependentExpectedProof {
    IndependentExpectedSeam.mint(root: root, rootID: rootID, region: region, notes: notes, ppq: ppq)
}

@Suite struct MIDIIndependentVerificationTests {
    // --- POSITIVE CONTROL (proves the grant path is real, not vacuous darkness) ---
    @Test func sealedIndependentProofGrantsExactMatch() {
        let notes = [e0Note(60), e0Note(64, start: 120)]
        #expect(verifyRegion(observed: e0Observed(notes: notes), expected: e0Proven(notes: notes)) == .exactMatch)
    }

    // --- REJECTIONS (Decision-B independence guard) ---
    @Test func unprovenExpectedNeverMatches() {
        guard case .incompleteCannotVerify = verifyRegion(
            observed: e0Observed(notes: [e0Note(60)]), expected: .unproven
        ) else { Issue.record("unproven expected must not verify"); return }
    }

    @Test func samePipelineRootRejected() {
        // An "independent" expected whose root id equals the OBSERVED conversion
        // pipeline is not independent → rejected (provenance spoof).
        let notes = [e0Note(60)]
        guard case .incompleteCannotVerify = verifyRegion(
            observed: e0Observed(notes: notes),
            expected: e0Proven(rootID: MIDIRegionNoteSnapshot.eventListConversionID, notes: notes)
        ) else { Issue.record("expected sharing the observed pipeline must be rejected"); return }
    }

    @Test func wrongRegionBindingRejected() {
        // Proof bound to region A cannot certify an observation of region B.
        let notes = [e0Note(60)]
        guard case .incompleteCannotVerify = verifyRegion(
            observed: e0Observed(region: e0RegionB, notes: notes),
            expected: e0Proven(region: e0RegionA, notes: notes)
        ) else { Issue.record("region-identity mismatch must be rejected"); return }
    }

    @Test func foreignNotesYieldMismatchNotMatch() {
        // A proof carries its OWN independent notes; against different observed notes
        // the result is a structured mismatch, never a false exactMatch.
        guard case .mismatch = verifyRegion(
            observed: e0Observed(notes: [e0Note(60)]),
            expected: e0Proven(notes: [e0Note(99)])
        ) else { Issue.record("foreign notes must yield mismatch, not exactMatch"); return }
    }

    @Test func incompleteObservedNeverMatches() {
        let notes = [e0Note(60)]
        let incomplete = MIDIRegionNoteSnapshot.makeIncompleteForTesting(
            regionReference: e0RegionA, projectEpoch: 1, ppq: 480
        )
        guard case .incompleteCannotVerify = verifyRegion(observed: incomplete, expected: e0Proven(notes: notes)) else {
            Issue.record("incomplete observed must not verify"); return
        }
    }
}
#endif
