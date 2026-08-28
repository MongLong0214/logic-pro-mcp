import Foundation

struct EQBandRecommendation: Codable, Equatable, Sendable {
    let centerHz: Double
    let gainDb: Double
    let q: Double
    let reason: String

    /// How far the peak stood above the level that made it a peak at all.
    ///
    /// The detector accepts a band as a resonance when its prominence over the local baseline
    /// reaches `prominenceMinDb` (6 dB). This is that prominence, published rather than discarded,
    /// so a consumer can see how close the call was instead of taking the recommendation on trust.
    let prominenceDb: Double

    /// 0 where the peak only just qualified, 1 where it cleared the bar by as much again.
    ///
    /// `(prominenceDb - P_min) / P_min`, clamped — so 6 dB scores 0 and 12 dB or more scores 1 —
    /// and capped at 0.5 when Q is resolution-limited, because a Q the analysis can only bound from
    /// below leaves the band's shape under-determined however tall the peak is.
    ///
    /// Derived from the two values that already DECIDED this recommendation, not invented beside
    /// them. `prominenceDb` and `resolutionLimited` are published too, so the compression above can
    /// be checked rather than believed.
    let confidence: Double

    /// True when Q is a lower bound rather than a measurement, mirroring `SpectralResonance`.
    let resolutionLimited: Bool
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

/// The prominence a band must clear to be a resonance at all.
///
/// READ from the analysis config rather than restated. A literal `6` here would be a second copy of
/// the threshold, and the confidence below is measured against it — so the two drifting apart would
/// silently rescale every published figure while both files still looked right. The first draft of
/// this file did exactly that, in a comment warning against it.
private var prominenceMinDb: Double {
    AudioFeatureExtractionEngine.Config.default.prominenceMinDb
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

    let bands = analysis.resonances.map { resonance -> EQBandRecommendation in
        let prominence = abs(resonance.gainDb)
        let margin = (prominence - prominenceMinDb) / prominenceMinDb
        let clamped = min(max(margin, 0), 1)
        return EQBandRecommendation(
            centerHz: resonance.hz,
            gainDb: -prominence,
            q: resonance.q,
            reason: "resonance_cut",
            prominenceDb: prominence,
            confidence: resonance.resolutionLimited ? min(clamped, 0.5) : clamped,
            resolutionLimited: resonance.resolutionLimited
        )
    }
    return .recommendation(bands: bands)
}
