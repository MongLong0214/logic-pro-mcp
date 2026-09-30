func compareSpectra(
    _ a: SpectralAnalysisResult,
    _ b: SpectralAnalysisResult
) -> [(centerHz: Double, deltaDb: Double)] {
    let bEnergy = Dictionary(
        b.bands.filter(\.measured).map { ($0.centerHz, $0.energyDb) },
        uniquingKeysWith: { first, _ in first }
    )
    return a.bands.compactMap { band in
        guard band.measured, let energyDb = bEnergy[band.centerHz] else { return nil }
        return (centerHz: band.centerHz, deltaDb: energyDb - band.energyDb)
    }
}

struct SpectralAnalysisPolicy: Codable, Equatable, Sendable {
    let algorithm: String
    let config: AudioFeatureExtractionEngine.Config
    let removesDC: Bool

    init(config: AudioFeatureExtractionEngine.Config, removesDC: Bool) {
        algorithm = "welch_energy_average.v1"
        self.config = config
        self.removesDC = removesDC
    }
}

struct SpectralComparisonResult: Codable, Equatable, Sendable {
    struct Band: Codable, Equatable, Sendable {
        let centerHz: Double
        let deltaDb: Double?
        let unavailableReason: String?
    }

    let before: SpectralAnalysisResult
    let after: SpectralAnalysisResult
    let bands: [Band]
    /// True only when every band has a measured, uncensored difference.
    let complete: Bool
    let limitations: [String]

    enum Failure: String, Error {
        case incompleteInput = "incomplete_input"
        case incompatibleAnalysis = "incompatible_analysis"
        case invalidBands = "invalid_bands"
        case unboundArtifact = "unbound_artifact"
    }

    init(before: SpectralAnalysisResult, after: SpectralAnalysisResult) throws {
        guard before.complete, after.complete else { throw Failure.incompleteInput }
        guard let policy = before.analysisPolicy, policy == after.analysisPolicy,
              before.sampleRate > 0, before.sampleRate == after.sampleRate,
              before.channelCount > 0, before.channelCount == after.channelCount,
              before.channelMode == after.channelMode,
              before.channelMode == ChannelMode(channelCount: before.channelCount),
              before.durationSeconds.isFinite, before.durationSeconds > 0,
              after.durationSeconds.isFinite, after.durationSeconds > 0,
              before.windowsAnalyzed > 0, after.windowsAnalyzed > 0 else {
            throw Failure.incompatibleAnalysis
        }
        for fingerprint in [before.artifactFingerprint, after.artifactFingerprint] {
            guard fingerprint.hasPrefix("sha256:"), fingerprint.count == 71,
                  fingerprint.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw Failure.unboundArtifact
            }
        }
        let centers = before.bands.map(\.centerHz)
        guard !centers.isEmpty, centers == after.bands.map(\.centerHz),
              Set(centers).count == centers.count,
              zip(centers, centers.dropFirst()).allSatisfy({ $0 < $1 }),
              (before.bands + after.bands).allSatisfy({
                  $0.centerHz.isFinite && $0.centerHz > 0 && $0.energyDb.isFinite
              }) else { throw Failure.invalidBands }

        let differences = Dictionary(uniqueKeysWithValues: compareSpectra(before, after))
        guard differences.values.allSatisfy(\.isFinite) else { throw Failure.invalidBands }
        bands = zip(before.bands, after.bands).map { a, b in
            let reason: String?
            if !a.measured || !b.measured {
                reason = "unmeasured_band"
            } else if a.energyDb <= policy.config.floorDbfs || b.energyDb <= policy.config.floorDbfs {
                reason = "at_analysis_floor"
            } else {
                reason = nil
            }
            return Band(centerHz: a.centerHz, deltaDb: reason == nil ? differences[a.centerHz] : nil,
                        unavailableReason: reason)
        }
        self.before = before
        self.after = after
        complete = bands.allSatisfy { $0.deltaDb != nil }
        var limits = ["whole_artifact_not_time_aligned", "raw_energy_not_level_normalized",
                      "no_musical_quality_or_applied_eq_claim"]
        if before.durationSeconds != after.durationSeconds || before.windowsAnalyzed != after.windowsAnalyzed {
            limits.append("unequal_temporal_coverage")
        }
        if !complete { limits.append("some_bands_unavailable") }
        limitations = limits
    }
}
