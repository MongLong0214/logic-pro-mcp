import Foundation
import Testing
@testable import LogicProMCP

// E0 — independence-guard suite for ADR-014/#302 R1 (CI, no Logic).
// The whole suite is `#if QUALIFICATION_FAULT_SEAM`: a release build has no
// testFixture `IndependentExpectedProof` at all. R1 grants NO positive match in ANY
// configuration (including this debug seam); the seam exercises only the rejection
// guards (Decision-B). Under the seam we make a seam-only test fixture to drive them.
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

/// A seam-only independent test fixture (stands in for R2's live ingestion).
private func e0TestFixture(
    root: IndependentExpectedRoot = .authoredIntent,
    rootID: String = "authored.intent.v1",
    region: MIDIRegionReference = e0RegionA,
    ppq: Int = 480,
    notes: [MIDINoteEvent]
) -> IndependentExpectedProof {
    IndependentExpectedSeam.makeTestFixture(root: root, rootID: rootID, region: region, notes: notes, ppq: ppq)
}

@Suite struct MIDIIndependentVerificationTests {
    // AC-4 (S1): an expected that is a note-identical COPY of the observed must NOT be
    // granted a positive match — R1 grants no positive verification.
    @Test func oToECopyDoesNotMatch() {
        let notes = [e0Note(60), e0Note(64, start: 120)]
        guard case .incompleteCannotVerify = verifyRegion(
            observed: e0Observed(notes: notes), expected: e0TestFixture(notes: notes)
        ) else { Issue.record("O→E copy must not be granted a positive match"); return }
    }

    // AC-2 (S2): RegionMatchVerdict has NO positive-match case. An exhaustive switch
    // over exactly {.mismatch, .incompleteCannotVerify} with no default proves no third
    // (positive) case exists.
    @Test func noExactMatchCaseExists() {
        let result = verifyRegion(observed: e0Observed(notes: [e0Note(60)]), expected: .unproven)
        switch result {
        case .mismatch: break
        case .incompleteCannotVerify: break
        }
    }

    // --- REJECTIONS (Decision-B independence guard) ---
    @Test func unprovenExpectedRejected() {
        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: e0Observed(notes: [e0Note(60)]), expected: .unproven
        ) else { Issue.record("unproven expected must not verify"); return }
        #expect(reason.contains("expected must carry a sealed independent provenance proof"))
    }

    @Test func samePipelineRootRejected() {
        // An "independent" expected whose root id equals the OBSERVED conversion
        // pipeline is not independent → rejected (provenance spoof).
        let notes = [e0Note(60)]
        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: e0Observed(notes: notes),
            expected: e0TestFixture(rootID: MIDIRegionNoteSnapshot.eventListConversionID, notes: notes)
        ) else { Issue.record("expected sharing the observed pipeline must be rejected"); return }
        #expect(reason.contains("expected root shares the observed conversion pipeline"))
    }

    @Test func wrongRegionBindingRejected() {
        // A fixture bound to region A cannot certify an observation of region B.
        let notes = [e0Note(60)]
        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: e0Observed(region: e0RegionB, notes: notes),
            expected: e0TestFixture(region: e0RegionA, notes: notes)
        ) else { Issue.record("region-identity mismatch must be rejected"); return }
        #expect(reason.contains("expected proof is not bound to the observed region"))
    }

    @Test func foreignNotesYieldMismatch() {
        // AC-5: a fixture carries its OWN independent notes; against different observed
        // notes the result is a structured mismatch (added = observed-only, removed =
        // expected-only), never a false positive match.
        let observedOnly = e0Note(60)
        let expectedOnly = e0Note(99)
        guard case .mismatch(let added, let removed) = verifyRegion(
            observed: e0Observed(notes: [observedOnly]),
            expected: e0TestFixture(notes: [expectedOnly])
        ) else { Issue.record("foreign notes must yield mismatch"); return }
        #expect(added == [observedOnly])
        #expect(removed == [expectedOnly])
    }

    @Test func incompleteObservedRejected() {
        let notes = [e0Note(60)]
        let incomplete = MIDIRegionNoteSnapshot.makeIncompleteForTesting(
            regionReference: e0RegionA, projectEpoch: 1, ppq: 480
        )
        guard case .incompleteCannotVerify(let reason) = verifyRegion(observed: incomplete, expected: e0TestFixture(notes: notes)) else {
            Issue.record("incomplete observed must not verify"); return
        }
        #expect(reason.contains("observed readback is not complete"))
    }

    // --- CONTENT-BINDING INTEGRITY (AC-3e) ---
    @Test func contentBindingTamperRejected() {
        // A corrupted fixture whose content binding does not match its own notes/PPQ is
        // rejected — a fixture cannot be relabeled onto foreign notes.
        let notes = [e0Note(60)]
        let corrupt = IndependentExpectedSeam.makeCorruptedTestFixture(
            root: .authoredIntent, rootID: "authored.intent.v1",
            region: e0RegionA, notes: notes, ppq: 480, digest: "forged-binding"
        )
        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: e0Observed(notes: notes), expected: corrupt
        ) else { Issue.record("content-binding tamper must be rejected"); return }
        #expect(reason.contains("content binding"))
    }

    @Test func normalMakerCannotMismatch() {
        // The normal maker co-computes the content binding from the fixture's own
        // notes/PPQ, so a normal fixture always carries a valid binding.
        let notes = [e0Note(60), e0Note(64, start: 120)]
        guard let payload = e0TestFixture(notes: notes).independentPayload else {
            Issue.record("normal maker must yield a payload"); return
        }
        #expect(payload.contentBinding == midiRegionNoteDigest(payload.notes, ppq: payload.ppq))
    }

    // --- PPQ VALIDITY (AC-3f.1/.2/.3) ---
    @Test func observedPPQNonPositiveRejected() {
        let notes = [e0Note(60)]
        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: e0Observed(ppq: 0, notes: notes), expected: e0TestFixture(notes: notes)
        ) else { Issue.record("non-positive observed PPQ must be rejected"); return }
        #expect(reason.contains("PPQ must be positive"))
    }

    @Test func fixturePPQNonPositiveRejected() {
        let notes = [e0Note(60)]
        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: e0Observed(notes: notes), expected: e0TestFixture(ppq: 0, notes: notes)
        ) else { Issue.record("non-positive fixture PPQ must be rejected"); return }
        #expect(reason.contains("PPQ must be positive"))
    }

    @Test func ppqNormalizationOverflowRejected() {
        let overflowNote = e0Note(60, start: Int64.max / 240)
        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: e0Observed(ppq: 480, notes: [e0Note(60)]),
            expected: e0TestFixture(ppq: 1, notes: [overflowNote])
        ) else { Issue.record("PPQ normalization overflow must be rejected"); return }
        #expect(reason.contains("PPQ normalization overflow"))
    }

    // --- PROVENANCE TAXONOMY (AC-6) ---
    @Test func provenanceRootsDistinctAndNonObserved() {
        // Exhaustive (no default): the taxonomy is exactly these two independent roots.
        for root in [IndependentExpectedRoot.authoredIntent, .controlledExport] {
            switch root {
            case .authoredIntent: break
            case .controlledExport: break
            }
        }
        // The two roots are distinct from each other AND neither is the OBSERVED
        // conversion pipeline id — an expected is never the observed.
        #expect(IndependentExpectedRoot.authoredIntent.rawValue != IndependentExpectedRoot.controlledExport.rawValue)
        #expect(IndependentExpectedRoot.authoredIntent.rawValue != MIDIRegionNoteSnapshot.eventListConversionID)
        #expect(IndependentExpectedRoot.controlledExport.rawValue != MIDIRegionNoteSnapshot.eventListConversionID)
    }
}
#endif
