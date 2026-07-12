import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-017 Flex Pitch")
struct FlexPitchTests {
    @Test func editRequiresQualifiedProvenanceAndDualEvidence() {
        let unqualified = makeFlexSnapshot(provenance: .none)
        let qualified = makeFlexSnapshot(provenance: .midiTrackFromFlexPlusReadback)
        let reference = unqualified.notes[0].reference

        #expect(
            editEligibility(
                snapshot: unqualified,
                ref: reference,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2
            ) == .experimental(reasons: ["dual evidence required"])
        )
        #expect(
            editEligibility(
                snapshot: qualified,
                ref: qualified.notes[0].reference,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 1
            ) == .experimental(reasons: ["dual evidence required"])
        )
        #expect(
            publicEditableReferences(
                snapshot: unqualified,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 0
            ).isEmpty
        )
    }

    @Test func polyphonicConfidenceIsExperimental() {
        let snapshot = makeFlexSnapshot(confidence: 0.89)

        #expect(
            editEligibility(
                snapshot: snapshot,
                ref: snapshot.notes[0].reference,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2
            ) == .experimental(reasons: ["monophonic confidence below threshold"])
        )
    }

    @Test func incompleteSnapshotIsExperimental() {
        let snapshot = makeFlexSnapshot(complete: false)

        #expect(
            editEligibility(
                snapshot: snapshot,
                ref: snapshot.notes[0].reference,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2
            ) == .experimental(reasons: ["snapshot incomplete"])
        )
    }

    @Test func staleReferencesAreExperimentalAndDetected() {
        let stale = makeFlexReference(generation: 6, ordinal: 0)
        let fresh = makeFlexReference(generation: 7, ordinal: 1)
        let snapshot = makeFlexSnapshot(generation: 6, references: [stale])

        #expect(
            editEligibility(
                snapshot: snapshot,
                ref: stale,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2
            ) == .experimental(reasons: ["stale snapshot", "stale note reference"])
        )
        #expect(staleReferences([fresh, stale], currentAnalysisGeneration: 7) == [stale])
    }

    @Test func referenceMustBelongToCurrentSnapshot() {
        let snapshot = makeFlexSnapshot()
        let otherRegion = FlexPitchNoteReference(
            regionRef: TargetReference(rawValue: "trk_other"),
            analysisGeneration: 7,
            noteOrdinal: 0,
            startTick: 0,
            durationTicks: 120,
            coarsePitch: 60,
            pitchCurveFingerprint: "curve_0"
        )

        #expect(
            editEligibility(
                snapshot: snapshot,
                ref: otherRegion,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2
            ) == .experimental(reasons: ["note reference does not belong to snapshot"])
        )
    }

    @Test func invalidConfidenceAndThresholdFailClosed() {
        for confidence in [Double.nan, -.infinity, .infinity, -0.01, 1.01] {
            let snapshot = makeFlexSnapshot(confidence: confidence)
            #expect(
                editEligibility(
                    snapshot: snapshot,
                    ref: snapshot.notes[0].reference,
                    currentAnalysisGeneration: 7,
                    dualEvidenceCount: 2
                ) == .experimental(reasons: ["monophonic confidence outside 0...1"])
            )
        }

        let snapshot = makeFlexSnapshot()
        #expect(
            editEligibility(
                snapshot: snapshot,
                ref: snapshot.notes[0].reference,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2,
                monophonicThreshold: .nan
            ) == .experimental(reasons: ["monophonic threshold outside 0...1"])
        )
    }

    @Test func fullyQualifiedSyntheticReferenceIsPublicEligible() {
        let snapshot = makeFlexSnapshot()

        #expect(
            editEligibility(
                snapshot: snapshot,
                ref: snapshot.notes[0].reference,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2
            ) == .publicEligible
        )
        #expect(
            publicEditableReferences(
                snapshot: snapshot,
                currentAnalysisGeneration: 7,
                dualEvidenceCount: 2
            ) == snapshot.notes.map(\.reference)
        )
    }

    @Test func referenceValidityUsesOnlyAnalysisGeneration() {
        let reference = makeFlexReference(generation: 7)

        #expect(isReferenceCurrent(reference, currentAnalysisGeneration: 7))
        #expect(!isReferenceCurrent(reference, currentAnalysisGeneration: 8))
    }

    @Test func completeSnapshotAlwaysClearsPartialReason() throws {
        let initialized = makeFlexSnapshot(complete: true, partialReason: "stale reason")
        let encoded = Data(
            #"{"regionRef":{"rawValue":"trk_test"},"analysisGeneration":7,"monophonicConfidence":0.95,"notes":[],"provenance":"none","complete":true,"partialReason":"stale reason"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(FlexPitchSnapshot.self, from: encoded)

        #expect(initialized.partialReason == nil)
        #expect(decoded.partialReason == nil)
    }

    @Test func snapshotCodableRoundTrips() throws {
        let snapshot = makeFlexSnapshot(complete: false, partialReason: "synthetic partial")
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FlexPitchSnapshot.self, from: encoded)

        #expect(decoded == snapshot)
    }

    @Test func adr017FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR017_FLEX_PITCH"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr017FlexPitch)
    }
}

private func makeFlexReference(
    generation: UInt64 = 7,
    ordinal: Int = 0
) -> FlexPitchNoteReference {
    FlexPitchNoteReference(
        regionRef: TargetReference(rawValue: "trk_test"),
        analysisGeneration: generation,
        noteOrdinal: ordinal,
        startTick: Int64(ordinal * 120),
        durationTicks: 120,
        coarsePitch: 60 + ordinal,
        pitchCurveFingerprint: "curve_\(ordinal)"
    )
}

private func makeFlexSnapshot(
    confidence: Double = 0.95,
    complete: Bool = true,
    partialReason: String? = nil,
    provenance: FlexProvenance = .midiTrackFromFlexPlusReadback,
    generation: UInt64 = 7,
    references: [FlexPitchNoteReference]? = nil
) -> FlexPitchSnapshot {
    let noteReferences = references ?? [makeFlexReference(generation: generation)]
    return FlexPitchSnapshot(
        regionRef: TargetReference(rawValue: "trk_test"),
        analysisGeneration: generation,
        monophonicConfidence: confidence,
        notes: noteReferences.map { FlexPitchNote(reference: $0, cents: 12.5, gainDb: -1) },
        provenance: provenance,
        complete: complete,
        partialReason: partialReason ?? (complete ? nil : "synthetic incomplete snapshot")
    )
}
