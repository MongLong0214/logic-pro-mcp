import Foundation

struct EQBandRecommendation: Codable, Equatable, Sendable {
    let centerHz: Double
    let gainDb: Double
    let q: Double
    let reason: String
}

/// ADR-012 I2/A8 — recommendation-only, structural.
/// The type has NO representable non-advisory state: there is no `advisory` flag to set
/// false, and no `applied`/`verified`/`adjusted` case or field. A recommendation is
/// inherently advisory by construction, so a mutation/apply claim (ADR-013 #301) cannot be
/// expressed through this type at all — the honesty boundary is enforced by the compiler,
/// not by a runtime check that could be flipped.
enum EQRecommendationOutcome: Equatable, Sendable {
    case recommendation(bands: [EQBandRecommendation])
    case noSafeRecommendation(reason: String)
}

func recommendEQ(
    _ analysis: SpectralAnalysisResult,
    minimumLevel: Double = 0.6
) -> EQRecommendationOutcome {
    guard analysis.complete else {
        return .noSafeRecommendation(reason: "analysis_incomplete")
    }
    // A LOUDNESS gate, named as one. It refuses to recommend EQ for near-silence, which is
    // sensible; what it never was is a measure of how sure the classifier is.
    guard analysis.levelConfidence >= minimumLevel else {
        return .noSafeRecommendation(reason: "level_below_minimum")
    }
    guard analysis.classification != .unknown else {
        return .noSafeRecommendation(reason: "source_classification_unknown")
    }

    let bands = analysis.resonances.map {
        EQBandRecommendation(
            centerHz: $0.hz,
            gainDb: -abs($0.gainDb),
            q: $0.q,
            reason: "resonance_cut"
        )
    }
    return .recommendation(bands: bands)
}
