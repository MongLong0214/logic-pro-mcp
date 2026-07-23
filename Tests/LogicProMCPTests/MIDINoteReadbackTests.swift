import Foundation
import Testing
@testable import LogicProMCP

@Suite struct MIDINoteReadbackTests {
    // Fail-closed expected sequence (no independence proof) — usable in any
    // configuration; verifyRegion returns incompleteCannotVerify for it.
    private func expectSeq(_ notes: [MIDINoteEvent], ppq: Int = 480) -> ExpectedSequence {
        ExpectedSequence(notes: notes, ppq: ppq, provenance: .unproven)
    }

    #if QUALIFICATION_FAULT_SEAM
    // A proven independently-sourced expected sequence (debug seam only): a
    // release build cannot present one, so match paths are exercised only here.
    private func provenExpectSeq(_ notes: [MIDINoteEvent], ppq: Int = 480) -> ExpectedSequence {
        let sourceID = "external.user-provided"
        return ExpectedSequence(
            notes: notes, ppq: ppq,
            provenance: .provenExternalArtifact(
                sourceID: sourceID,
                contentBinding: expectedContentBinding(sourceID: sourceID, notes: notes, ppq: ppq)
            )
        )
    }
    #endif

    @Test func incompleteSnapshotCannotReportExactMatch() {
        let note = makeNote(pitch: 60)
        let observed = makeSnapshot(complete: false, notes: [note])

        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: observed,
            expected: expectSeq([note])
        ) else {
            Issue.record("An incomplete scan must never report a full match")
            return
        }
        #expect(reason == String(describing: PartialReason.timingUnproven))
    }

    @Test func missingIndependentProvenanceCannotReportExactMatch() {
        let note = makeNote(pitch: 60)
        let observed = makeSnapshot(provenance: .none, notes: [note])

        guard case .incompleteCannotVerify = verifyRegion(
            observed: observed,
            expected: expectSeq([note])
        ) else {
            Issue.record("Server-owned input without independent provenance is not readback")
            return
        }
    }

    @Test func canonicalizationRemovesVelocityZeroTrimsOverlapAndSorts() {
        let canonical = canonicalize([
            makeNote(pitch: 67, start: 20, duration: 10, velocity: 70, channel: 1),
            makeNote(pitch: 64, start: 0, duration: 100, velocity: 90),
            makeNote(pitch: 60, start: 0, duration: 20, velocity: 110, channel: 1),
            makeNote(pitch: 60, start: 0, duration: 20, velocity: 90),
            makeNote(pitch: 64, start: 60, duration: 30, velocity: 80),
            makeNote(pitch: 70, start: 5, duration: 10, velocity: 0),
        ], ppq: 480)

        #expect(canonical == [
            makeNote(pitch: 60, start: 0, duration: 20, velocity: 90),
            makeNote(pitch: 60, start: 0, duration: 20, velocity: 110, channel: 1),
            makeNote(pitch: 64, start: 0, duration: 60, velocity: 90),
            makeNote(pitch: 67, start: 20, duration: 10, velocity: 70, channel: 1),
            makeNote(pitch: 64, start: 60, duration: 30, velocity: 80),
        ])
    }

    #if QUALIFICATION_FAULT_SEAM
    @Test func ppqNormalizationAllowsExactMatch() {
        let expected = [makeNote(pitch: 60, start: 480, duration: 240)]
        let observed = makeSnapshot(
            ppq: 960,
            notes: [makeNote(pitch: 60, start: 960, duration: 480)]
        )

        #expect(verifyRegion(observed: observed, expected: provenExpectSeq(expected)) == .exactMatch)
    }

    @Test func verificationMatchesCanonicalNotes() {
        let expected = [
            makeNote(pitch: 64, start: 60, duration: 30, velocity: 80),
            makeNote(pitch: 64, start: 0, duration: 100, velocity: 90),
            makeNote(pitch: 70, start: 5, duration: 10, velocity: 0),
        ]
        let observed = makeSnapshot(notes: [
            makeNote(pitch: 64, start: 0, duration: 60, velocity: 90),
            makeNote(pitch: 64, start: 60, duration: 30, velocity: 80),
        ])

        #expect(verifyRegion(observed: observed, expected: provenExpectSeq(expected)) == .exactMatch)
    }

    @Test func verificationReportsAddedRemovedAndChangedNotes() {
        let changedBefore = makeNote(pitch: 60, start: 0, duration: 100)
        let changedAfter = makeNote(pitch: 60, start: 0, duration: 80)
        let unchanged = makeNote(pitch: 62, start: 120, duration: 50)
        let removedNote = makeNote(pitch: 64, start: 240, duration: 60)
        let addedNote = makeNote(pitch: 65, start: 300, duration: 40)
        let observed = makeSnapshot(notes: [changedAfter, unchanged, addedNote])

        guard case .mismatch(let added, let removed, let changed) = verifyRegion(
            observed: observed,
            expected: provenExpectSeq([changedBefore, unchanged, removedNote])
        ) else {
            Issue.record("Expected a structured mismatch")
            return
        }
        #expect(added == [addedNote])
        #expect(removed == [removedNote])
        #expect(changed.count == 1)
        #expect(changed.first?.0 == changedBefore)
        #expect(changed.first?.1 == changedAfter)
    }
    #endif

    #if QUALIFICATION_FAULT_SEAM
    @Test func regionDiffReportsAddedAndRemovedNotes() {
        let removedNote = makeNote(pitch: 60)
        let unchanged = makeNote(pitch: 62, start: 120)
        let addedNote = makeNote(pitch: 64, start: 240)

        let result = diffRegions(
            before: makeSnapshot(notes: [removedNote, unchanged]),
            after: makeSnapshot(notes: [unchanged, addedNote])
        )

        #expect(result?.added == [addedNote])
        #expect(result?.removed == [removedNote])
    }

    @Test func regionDiffRejectsIncompleteSnapshot() {
        // An incomplete side must not drive a diff (decoded/incomplete payloads
        // keep their notes but are not trustworthy).
        let note = makeNote(pitch: 60)
        #expect(diffRegions(
            before: makeSnapshot(complete: false, notes: [note]),
            after: makeSnapshot(notes: [note])
        ) == nil)
    }

    @Test func rePairedCompleteProofIsNotComplete() {
        // A completeness proof minted for one payload cannot certify a different
        // note set: `complete` recomputes the binding from the snapshot's notes.
        let region = MIDIRegionReference(targetRef: TargetReference(rawValue: "trk_test"), regionIndex: 0)
        let genuine = MIDIRegionNoteSnapshot.makeCompleteForTesting(
            regionReference: region, projectEpoch: 1, ppq: 480, notes: [makeNote(pitch: 61)]
        )
        #expect(genuine.complete)
        let reNoted = MIDIRegionNoteSnapshot(
            regionReference: region,
            projectEpoch: 1,
            noteCompleteness: genuine.noteCompleteness,  // proof bound to pitch 61
            provenance: .eventListAX,
            ppq: 480,
            notes: [makeNote(pitch: 60)],  // NOT what the proof was bound to
            tempoMap: [],
            timeSignatures: []
        )
        #expect(!reNoted.complete)
    }

    @Test func envelopeTransplantIsNotComplete() {
        // A completeness proof also seals the snapshot IDENTITY it certifies, so a
        // genuine proof transplanted onto a foreign envelope (different region,
        // epoch, provenance, or conversion pipeline) — even with identical
        // notes+PPQ — cannot read complete. Each field is flipped alone, so
        // dropping any one field from the binding turns that assertion red.
        let notes = [makeNote(pitch: 60)]
        let regionA = MIDIRegionReference(targetRef: TargetReference(rawValue: "trk_A"), regionIndex: 0)
        let genuine = MIDIRegionNoteSnapshot.makeCompleteForTesting(
            regionReference: regionA, projectEpoch: 1, ppq: 480, notes: notes
        )
        #expect(genuine.complete)

        func transplant(
            region: MIDIRegionReference = regionA,
            epoch: UInt64 = 1,
            provenance: MIDIReadbackProvenance = .eventListAX,
            pipeline: String = MIDIRegionNoteSnapshot.eventListConversionID
        ) -> MIDIRegionNoteSnapshot {
            MIDIRegionNoteSnapshot(
                regionReference: region,
                projectEpoch: epoch,
                noteCompleteness: genuine.noteCompleteness,
                provenance: provenance,
                ppq: 480,
                notes: notes,
                tempoMap: [],
                timeSignatures: [],
                conversionPipelineID: pipeline
            )
        }

        // Faithful transplant onto the SAME envelope stays complete (guards that
        // the helper itself is honest — otherwise the checks below pass vacuously).
        #expect(transplant().complete)
        // Each identity field, changed alone, breaks completeness.
        #expect(!transplant(region: MIDIRegionReference(
            targetRef: TargetReference(rawValue: "trk_B"), regionIndex: 0)).complete)
        #expect(!transplant(region: MIDIRegionReference(
            targetRef: TargetReference(rawValue: "trk_A"), regionIndex: 7)).complete)
        #expect(!transplant(epoch: 999).complete)
        #expect(!transplant(provenance: .controlledSMFExport).complete)
        #expect(!transplant(pipeline: "not-the-real-pipeline").complete)
    }
    #endif

    @Test func nonPositivePPQNormalizationFailsClosed() {
        // normalizePPQ must return nil (unverifiable) for a non-positive PPQ, never
        // fall back to unscaled notes — a caller comparing unscaled ticks would
        // accept a false match.
        let note = makeNote(pitch: 60)
        for pair in [(0, 480), (-1, 480), (480, 0), (480, -5)] {
            if normalizePPQ([note], from: pair.0, to: pair.1) != nil {
                Issue.record("normalizePPQ must fail closed on non-positive PPQ (from=\(pair.0), to=\(pair.1))")
            }
        }
    }

    @Test func providerGateHasNoPublicProviderBeforeQualification() {
        let registry = QualifiedProviderRegistry()

        #expect(registry.publicProvider() == nil)
        #expect(registry.candidateProvenances() == [
            .eventListAX,
            .controlledSMFExport,
            .projectPackageParser,
            .playbackCapture,
        ])
        #expect(registry.qualificationStatuses().allSatisfy {
            !$0.qualified && !$0.requiredProofs.isEmpty
        })
    }

    @Test func completeSnapshotHasNoReasonIncompleteCarriesEnumReason() {
        let complete = makeSnapshot(complete: true)
        let incomplete = makeSnapshot(complete: false)

        #expect(complete.partialReason == nil)
        #expect(complete.noteCompleteness.partialReason == nil)
        #expect(incomplete.noteCompleteness.partialReason == .timingUnproven)
    }

    @Test func featureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR010_MIDI_READBACK"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr010MidiReadback)
    }

    private func makeSnapshot(
        complete: Bool = true,
        provenance: MIDIReadbackProvenance = .eventListAX,
        ppq: Int = 480,
        notes: [MIDINoteEvent] = []
    ) -> MIDIRegionNoteSnapshot {
        let region = MIDIRegionReference(
            targetRef: TargetReference(rawValue: "trk_test"),
            regionIndex: 0
        )
        return complete
            ? .makeCompleteForTesting(
                regionReference: region, projectEpoch: 1, ppq: ppq, notes: notes, provenance: provenance
            )
            : .makeIncompleteForTesting(
                regionReference: region, projectEpoch: 1, ppq: ppq, provenance: provenance
            )
    }

    private func makeNote(
        pitch: UInt8,
        start: Int64 = 0,
        duration: Int64 = 120,
        velocity: UInt8 = 100,
        channel: UInt8 = 0
    ) -> MIDINoteEvent {
        MIDINoteEvent(
            pitch: pitch,
            startTicks: start,
            durationTicks: duration,
            velocity: velocity,
            channel: channel
        )
    }
}
