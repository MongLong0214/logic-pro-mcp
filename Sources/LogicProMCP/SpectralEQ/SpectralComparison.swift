func compareSpectra(
    _ a: SpectralAnalysisResult,
    _ b: SpectralAnalysisResult
) -> [(centerHz: Double, deltaDb: Double)] {
    let bEnergy = Dictionary(
        b.bands.map { ($0.centerHz, $0.energyDb) },
        uniquingKeysWith: { first, _ in first }
    )
    return a.bands.compactMap { band in
        guard let energyDb = bEnergy[band.centerHz] else { return nil }
        return (centerHz: band.centerHz, deltaDb: energyDb - band.energyDb)
    }
}
