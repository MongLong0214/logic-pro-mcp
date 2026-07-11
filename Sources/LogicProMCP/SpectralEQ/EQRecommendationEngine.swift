import Foundation

struct EQBandRecommendation: Codable, Equatable, Sendable {
    let centerHz: Double
    let gainDb: Double
    let q: Double
    let reason: String
}

enum EQRecommendationOutcome: Equatable, Sendable {
    case recommendation(bands: [EQBandRecommendation], advisory: Bool)
    case noSafeRecommendation(reason: String)
}

func recommendEQ(
    _ analysis: SpectralAnalysisResult,
    minimumConfidence: Double = 0.6
) -> EQRecommendationOutcome {
    guard analysis.complete else {
        return .noSafeRecommendation(reason: "analysis_incomplete")
    }
    guard analysis.confidence >= minimumConfidence else {
        return .noSafeRecommendation(reason: "confidence_below_minimum")
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
    return .recommendation(bands: bands, advisory: true)
}
