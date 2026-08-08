import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-015 Piano Roll Transform")
struct PianoRollTransformTests {
    @Test func transposeClampsPitch() {
        let notes = [note(pitch: 1), note(pitch: 120)]

        #expect(applyTransform(.transpose(semitones: -12), to: notes, ppq: 480) == [
            note(pitch: 0),
            note(pitch: 108),
        ])
        #expect(applyTransform(.transpose(semitones: 12), to: notes, ppq: 480) == [
            note(pitch: 13),
            note(pitch: 127),
        ])
    }

    @Test func setVelocityClampsToMidiRange() {
        let notes = [note(pitch: 60, velocity: 40), note(pitch: 64, velocity: 100)]

        #expect(applyTransform(.setVelocity(0), to: notes, ppq: 480).map(\.velocity) == [1, 1])
        #expect(applyTransform(.setVelocity(200), to: notes, ppq: 480).map(\.velocity) == [127, 127])
    }

    @Test func scaleVelocityUsesPivotAndClamps() {
        let notes = [
            note(pitch: 60, velocity: 1),
            note(pitch: 62, velocity: 80),
            note(pitch: 64, velocity: 127),
        ]

        #expect(
            applyTransform(
                .scaleVelocity(factor: 2, pivot: 64),
                to: notes,
                ppq: 480
            ).map(\.velocity) == [1, 96, 127]
        )
    }

    @Test func quantizeAppliesGridStrengthAndSwing() {
        let notes = [note(pitch: 60, start: 350)]

        #expect(QuantizeGrid.sixteenth.ticks(ppq: 480) == 120)
        #expect(
            applyTransform(
                .quantize(grid: .eighth, strength: 0.5, swing: 0.5),
                to: notes,
                ppq: 480
            ) == [note(pitch: 60, start: 325)]
        )
    }

    @Test func humanizeIsSeedDeterministic() {
        let notes = [
            note(pitch: 60, start: 100, velocity: 30),
            note(pitch: 62, start: 200, velocity: 70),
            note(pitch: 64, start: 300, velocity: 120),
        ]
        let transform = MIDITransform.humanize(timingTicks: 40, velocity: 20, seed: 42)

        let first = applyTransform(transform, to: notes, ppq: 480)
        let second = applyTransform(transform, to: notes, ppq: 480)
        let differentSeed = applyTransform(
            .humanize(timingTicks: 40, velocity: 20, seed: 43),
            to: notes,
            ppq: 480
        )

        #expect(first == second)
        #expect(first != differentSeed)
    }

    @Test func incompleteBeforeSnapshotCannotProducePlan() {
        #expect(
            planTransform(
                region: region(),
                transform: .transpose(semitones: 2),
                beforeSnapshot: snapshot(complete: false),
                ppq: 480
            ) == nil
        )
    }

    @Test func planBindsGenerationAndRejectsStaleApply() throws {
        let target = region()
        let plan = try #require(
            planTransform(
                region: target,
                transform: .transpose(semitones: 2),
                beforeSnapshot: snapshot(region: target, generation: 7, notes: [note(pitch: 60)]),
                ppq: 480
            )
        )

        #expect(plan.boundGeneration == 7)
        #expect(plan.predictedAfter == [note(pitch: 62)])
        #expect(
            validateApply(plan: plan, currentGeneration: 8, currentRegion: target) == [
                .staleGeneration(bound: 7, current: 8),
            ]
        )
        #expect(validateApply(plan: plan, currentGeneration: 7, currentRegion: target).isEmpty)
    }

    @Test func applyValidationRejectsRegionMismatch() throws {
        let target = region(index: 0)
        let plan = try #require(
            planTransform(
                region: target,
                transform: .setVelocity(90),
                beforeSnapshot: snapshot(region: target),
                ppq: 480
            )
        )

        #expect(
            validateApply(
                plan: plan,
                currentGeneration: plan.boundGeneration,
                currentRegion: region(index: 1)
            ) == [.regionMismatch]
        )
    }

    @Test func exactCompleteNextGenerationMultisetIsR1Unverified() throws {
        let target = region()
        let duplicate = note(pitch: 60, start: 120)
        let other = note(pitch: 64, start: 0)
        let plan = try #require(
            planTransform(
                region: target,
                transform: .transpose(semitones: 0),
                beforeSnapshot: snapshot(
                    region: target,
                    generation: 10,
                    notes: [duplicate, duplicate, other]
                ),
                ppq: 480
            )
        )
        let observed = snapshot(
            region: target,
            generation: 11,
            notes: [other, duplicate, duplicate]
        )

        guard case .stateBUnverified(let reason) = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: independentExpected(region: target, notes: [other, duplicate, duplicate])
        ) else {
            Issue.record("An R1 exact match must not be granted State A")
            return
        }
        #expect(reason == "R1 grants no positive match; independent positive verification is R2 live-ingestion")
    }

    @Test func incompleteObservedSnapshotIsNeverStateA() throws {
        let plan = try #require(makePlan())
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration + 1,
            complete: false,
            notes: plan.predictedAfter
        )

        guard case .stateBUnverified = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: .unproven
        ) else {
            Issue.record("An incomplete post-write snapshot must never be State A")
            return
        }
    }

    @Test func unexpectedGenerationIsNeverStateA() throws {
        let plan = try #require(makePlan())
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration,
            notes: plan.predictedAfter
        )

        guard case .stateBUnverified = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: .unproven
        ) else {
            Issue.record("State A requires the expected generation transition")
            return
        }
    }

    @Test func observedRegionMismatchIsNeverStateA() throws {
        let plan = try #require(makePlan())
        let observed = snapshot(
            region: region(index: 1),
            generation: plan.boundGeneration + 1,
            notes: plan.predictedAfter
        )

        guard case .stateBUnverified = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: .unproven
        ) else {
            Issue.record("State A requires the same region reference")
            return
        }
    }

    @Test func multisetMismatchReportsUnexpectedEvents() throws {
        let expected = note(pitch: 60)
        let unexpected = note(pitch: 67)
        let plan = try #require(
            planTransform(
                region: region(),
                transform: .transpose(semitones: 0),
                beforeSnapshot: snapshot(notes: [expected, expected]),
                ppq: 480
            )
        )
        let observed = snapshot(
            generation: plan.boundGeneration + 1,
            notes: [expected, unexpected]
        )

        #expect(
            verifyTransform(
                plan: plan,
                observedAfter: observed,
                expected: independentExpected(region: plan.regionRef, notes: [expected, expected])
            ) == .mismatch(
                unexpected: [unexpected]
            )
        )
    }

    @Test func samePathRederivationIsRejected() throws {
        let plan = try #require(makePlan())
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration + 1,
            notes: plan.predictedAfter
        )

        guard case .stateBUnverified(let reason) = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: independentExpected(
                rootID: observed.conversionPipelineID,
                region: plan.regionRef,
                notes: plan.predictedAfter
            )
        ) else {
            Issue.record("An expected derived from the observed conversion pipeline must be rejected")
            return
        }
        #expect(reason.contains("expected root shares the observed conversion pipeline"))
    }

    @Test func ppqSkewedBareSortedMatchIsRejected() throws {
        let plan = try #require(makePlan())
        let unscaled = note(pitch: 60, start: 120, duration: 120)
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration + 1,
            notes: [unscaled]
        )

        // The two raw events are equal, so the former bare sorted comparison would
        // match. Their tick values differ after a 960→480 PPQ normalization.
        guard case .mismatch(let unexpected) = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: independentExpected(region: plan.regionRef, notes: [unscaled], ppq: 960)
        ) else {
            Issue.record("A PPQ-skewed raw match must be a mismatch, never State A or the R1 refusal")
            return
        }
        #expect(unexpected == [unscaled])
    }

    @Test func unprovenExpectedIsRejected() throws {
        let plan = try #require(makePlan())
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration + 1,
            notes: plan.predictedAfter
        )

        guard case .stateBUnverified(let reason) = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: .unproven
        ) else {
            Issue.record("An unproven expected sequence must be rejected")
            return
        }
        #expect(reason.contains("expected must carry a sealed independent provenance proof"))
    }

    @Test func corruptedExpectedContentBindingIsRejected() throws {
        let plan = try #require(makePlan())
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration + 1,
            notes: plan.predictedAfter
        )
        let corrupted = IndependentExpectedSeam.makeCorruptedTestFixture(
            root: .authoredIntent,
            rootID: "authored.intent.v1",
            region: plan.regionRef,
            notes: plan.predictedAfter,
            ppq: 480,
            digest: "forged-binding"
        )

        guard case .stateBUnverified(let reason) = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: corrupted
        ) else {
            Issue.record("A corrupted expected content binding must be rejected")
            return
        }
        #expect(reason.contains("expected proof content binding is invalid"))
    }

    @Test func independentlySourcedCanonicalizedMatchReachesR1Refusal() throws {
        let plan = try #require(makePlan())
        let observedNotes = [
            note(pitch: 60, start: 0, duration: 240),
            note(pitch: 60, start: 120, duration: 120),
        ]
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration + 1,
            notes: observedNotes
        )

        guard case .stateBUnverified(let reason) = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: independentExpected(region: plan.regionRef, notes: observedNotes.reversed())
        ) else {
            Issue.record("A valid independent canonicalized match must reach the R1 refusal")
            return
        }
        #expect(reason == "R1 grants no positive match; independent positive verification is R2 live-ingestion")
    }

    @Test func stateAIsUnreachableForFullyValidIndependentExpected() throws {
        let plan = try #require(makePlan())
        let notes = [note(pitch: 60), note(pitch: 64, start: 120)]
        let observed = snapshot(
            region: plan.regionRef,
            generation: plan.boundGeneration + 1,
            notes: notes
        )
        let verdict = verifyTransform(
            plan: plan,
            observedAfter: observed,
            expected: independentExpected(region: plan.regionRef, notes: notes.reversed())
        )

        #expect(verdict != .stateA)
    }

    @Test func compensationRestoresExactBeforeSnapshot() throws {
        let before = [note(pitch: 60, start: 20), note(pitch: 60, start: 20)]
        let plan = try #require(
            planTransform(
                region: region(),
                transform: .humanize(timingTicks: 10, velocity: 4, seed: 9),
                beforeSnapshot: snapshot(notes: before),
                ppq: 480
            )
        )

        #expect(compensationNotes(plan: plan) == before)
    }

    @Test func adr015FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR015_PIANO_ROLL"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr015PianoRoll)
    }

    private func makePlan() -> RegionTransformPlan? {
        planTransform(
            region: region(),
            transform: .transpose(semitones: 2),
            beforeSnapshot: snapshot(notes: [note(pitch: 60)]),
            ppq: 480
        )
    }

    private func region(index: Int = 0) -> MIDIRegionReference {
        MIDIRegionReference(
            targetRef: TargetReference(rawValue: "trk_test"),
            regionIndex: index
        )
    }

    private func snapshot(
        region: MIDIRegionReference? = nil,
        generation: UInt64 = 1,
        complete: Bool = true,
        notes: [MIDINoteEvent] = []
    ) -> MIDIRegionNoteSnapshot {
        let ref = region ?? self.region()
        return complete
            ? .makeCompleteForTesting(regionReference: ref, projectEpoch: generation, ppq: 480, notes: notes)
            : .makeIncompleteForTesting(regionReference: ref, projectEpoch: generation, ppq: 480)
    }

    private func independentExpected(
        root: IndependentExpectedRoot = .authoredIntent,
        rootID: String = "authored.intent.v1",
        region: MIDIRegionReference,
        notes: [MIDINoteEvent],
        ppq: Int = 480
    ) -> IndependentExpectedProof {
        IndependentExpectedSeam.makeTestFixture(
            root: root,
            rootID: rootID,
            region: region,
            notes: notes,
            ppq: ppq
        )
    }

    private func note(
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
