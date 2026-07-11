import Foundation
import Testing
@testable import LogicProMCP

@Suite struct MIDINoteReadbackTests {
    @Test func incompleteSnapshotCannotReportExactMatch() {
        let note = makeNote(pitch: 60)
        let observed = makeSnapshot(complete: false, partialReason: "virtualized rows", notes: [note])

        guard case .incompleteCannotVerify(let reason) = verifyRegion(
            observed: observed,
            expected: [note],
            expectedPPQ: 480
        ) else {
            Issue.record("An incomplete scan must never report a full match")
            return
        }
        #expect(reason == "virtualized rows")
    }

    @Test func missingIndependentProvenanceCannotReportExactMatch() {
        let note = makeNote(pitch: 60)
        let observed = makeSnapshot(provenance: .none, notes: [note])

        guard case .incompleteCannotVerify = verifyRegion(
            observed: observed,
            expected: [note],
            expectedPPQ: 480
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

    @Test func ppqNormalizationAllowsExactMatch() {
        let expected = [makeNote(pitch: 60, start: 480, duration: 240)]
        let observed = makeSnapshot(
            ppq: 960,
            notes: [makeNote(pitch: 60, start: 960, duration: 480)]
        )

        #expect(verifyRegion(observed: observed, expected: expected, expectedPPQ: 480) == .exactMatch)
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

        #expect(verifyRegion(observed: observed, expected: expected, expectedPPQ: 480) == .exactMatch)
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
            expected: [changedBefore, unchanged, removedNote],
            expectedPPQ: 480
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

    @Test func regionDiffReportsAddedAndRemovedNotes() {
        let removedNote = makeNote(pitch: 60)
        let unchanged = makeNote(pitch: 62, start: 120)
        let addedNote = makeNote(pitch: 64, start: 240)

        let result = diffRegions(
            before: makeSnapshot(notes: [removedNote, unchanged]),
            after: makeSnapshot(notes: [unchanged, addedNote])
        )

        #expect(result.added == [addedNote])
        #expect(result.removed == [removedNote])
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

    @Test func completeSnapshotDropsPartialReason() {
        let complete = makeSnapshot(complete: true, partialReason: "must be discarded")
        let incomplete = makeSnapshot(complete: false, partialReason: "last row unavailable")

        #expect(complete.partialReason == nil)
        #expect(incomplete.partialReason == "last row unavailable")
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
        partialReason: String? = nil,
        provenance: MIDIReadbackProvenance = .eventListAX,
        ppq: Int = 480,
        notes: [MIDINoteEvent] = []
    ) -> MIDIRegionNoteSnapshot {
        MIDIRegionNoteSnapshot(
            regionReference: MIDIRegionReference(
                targetRef: TargetReference(rawValue: "trk_test"),
                regionIndex: 0
            ),
            projectEpoch: 1,
            complete: complete,
            partialReason: partialReason,
            provenance: provenance,
            ppq: ppq,
            notes: notes,
            tempoMap: [],
            timeSignatures: []
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
