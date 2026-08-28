import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-012 spectral EQ recommendations")
struct EQRecommendationTests {
    @Test func lowConfidenceReturnsNoSafeRecommendation() {
        expectNoSafeRecommendation(recommendEQ(analysis(levelConfidence: 0.59)))
    }

    @Test func unknownSourceReturnsNoSafeRecommendation() {
        expectNoSafeRecommendation(recommendEQ(analysis(classification: .unknown)))
    }

    @Test func incompleteAnalysisReturnsNoSafeRecommendation() {
        expectNoSafeRecommendation(
            recommendEQ(analysis(complete: false, partialReason: "analysis interrupted"))
        )
    }

    @Test func knownHighConfidenceResonanceProducesAdvisoryCuts() throws {
        let outcome = recommendEQ(
            analysis(resonances: [SpectralResonance(hz: 3_200, gainDb: 5, q: 2)])
        )
        // I2/A8: the recommendation type is inherently advisory — there is no `advisory`
        // flag (nor any apply/verified field) to inspect; the honesty boundary is structural.
        guard case .recommendation(let bands) = outcome else {
            Issue.record("Expected an advisory recommendation")
            return
        }

        let band = try #require(bands.first)
        #expect(!bands.isEmpty)
        #expect(band.centerHz == 3_200)
        #expect(band.gainDb == -5)
        #expect(band.q == 2)
        #expect(!band.reason.isEmpty)
    }

    @Test func recommendationsAreAlwaysAdvisoryAndNeverApplied() {
        let classifications: [SourceClassification] = [.vocal, .drums, .bass, .fullMix]

        for classification in classifications {
            let outcome = recommendEQ(
                analysis(
                    resonances: [SpectralResonance(hz: 800, gainDb: 3, q: 1.5)],
                    classification: classification
                )
            )
            // Every valid classification yields a `.recommendation`; the case carries only
            // advisory cut bands and cannot represent an applied/verified state.
            guard case .recommendation(let bands) = outcome else {
                Issue.record("Expected a recommendation for \(classification.rawValue)")
                continue
            }
            #expect(!bands.isEmpty)
        }
    }

    @Test func jobStateMachineAcceptsOnlyForwardTransitions() throws {
        let queued = AnalysisJob(ref: "analysis-1", state: .queued, progress: 0.25)
        let decoding = try #require(advance(queued, to: .decoding))
        let analyzing = try #require(advance(decoding, to: .analyzing))

        #expect(decoding.ref == queued.ref)
        #expect(decoding.progress == queued.progress)
        #expect(analyzing.state == .analyzing)
        #expect(advance(analyzing, to: .completed)?.state == .completed)
        #expect(advance(analyzing, to: .failed)?.state == .failed)
        #expect(advance(analyzing, to: .cancelled)?.state == .cancelled)
    }

    @Test func jobStateMachineRejectsBacktrackingAndSkippedStates() {
        let queued = AnalysisJob(ref: "analysis-1", state: .queued, progress: 0)
        let completed = AnalysisJob(ref: "analysis-1", state: .completed, progress: 1)

        #expect(advance(queued, to: .completed) == nil)
        #expect(advance(completed, to: .analyzing) == nil)
    }

    @Test func comparisonReturnsExactDeltasForCommonBands() {
        let before = analysis(
            bands: [
                SpectralBand(centerHz: 100, energyDb: -20),
                SpectralBand(centerHz: 1_000, energyDb: -10),
                SpectralBand(centerHz: 5_000, energyDb: -5),
            ]
        )
        let after = analysis(
            bands: [
                SpectralBand(centerHz: 100, energyDb: -17),
                SpectralBand(centerHz: 1_000, energyDb: -12),
                SpectralBand(centerHz: 9_000, energyDb: -4),
            ]
        )

        let comparison = compareSpectra(before, after)

        #expect(comparison.count == 2)
        #expect(comparison[0].centerHz == 100)
        #expect(comparison[0].deltaDb == 3)
        #expect(comparison[1].centerHz == 1_000)
        #expect(comparison[1].deltaDb == -2)
    }

    @Test func completeAnalysisAlwaysDropsPartialReason() throws {
        let complete = analysis(complete: true, partialReason: "stale")
        let incomplete = analysis(complete: false, partialReason: "analysis interrupted")

        #expect(complete.partialReason == nil)
        #expect(incomplete.partialReason == "analysis interrupted")

        let decoded = try JSONDecoder().decode(
            SpectralAnalysisResult.self,
            from: Data(
                #"{"analysisRef":"analysis-1","bands":[],"resonances":[],"classification":"vocal","confidence":0.9,"complete":true,"partialReason":"stale"}"#.utf8
            )
        )
        #expect(decoded.partialReason == nil)
    }

    @Test func confidenceStaysWithinUnitInterval() {
        #expect(analysis(levelConfidence: -0.1).levelConfidence == 0)
        #expect(analysis(levelConfidence: 1.1).levelConfidence == 1)
    }

    @Test func adr012FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR012_SPECTRAL_EQ"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr012SpectralEQ)
    }

    private func analysis(
        bands: [SpectralBand] = [],
        resonances: [SpectralResonance] = [],
        classification: SourceClassification = .vocal,
        levelConfidence: Double = 0.9,
        complete: Bool = true,
        partialReason: String? = nil
    ) -> SpectralAnalysisResult {
        SpectralAnalysisResult(
            analysisRef: "analysis-1",
            bands: bands,
            resonances: resonances,
            classification: classification,
            levelConfidence: levelConfidence,
            complete: complete,
            partialReason: partialReason
        )
    }

    private func expectNoSafeRecommendation(_ outcome: EQRecommendationOutcome) {
        guard case .noSafeRecommendation(let reason) = outcome else {
            Issue.record("Expected no_safe_recommendation")
            return
        }
        #expect(!reason.isEmpty)
    }
}
