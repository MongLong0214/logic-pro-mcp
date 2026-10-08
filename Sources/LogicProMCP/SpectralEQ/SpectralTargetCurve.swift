import Foundation
import MCP

/// An explicitly supplied absolute band-energy target, not an EQ transfer function.
struct SpectralTargetCurve: Codable, Equatable, Sendable {
    static var maximumPoints: Int { AudioFeatureExtractionEngine.makeGrid().centers.count }
    struct Point: Codable, Equatable, Sendable {
        let centerHz: Double
        let energyDbfs: Double

        enum CodingKeys: String, CodingKey {
            case centerHz = "center_hz"
            case energyDbfs = "energy_dbfs"
        }
    }

    let points: [Point]

    init?(value: Value) {
        guard let array = value.arrayValue, (2...Self.maximumPoints).contains(array.count) else { return nil }
        let config = AudioFeatureExtractionEngine.Config.default
        var parsed = [Point]()
        for value in array {
            guard let object = value.objectValue,
                  Set(object.keys) == ["center_hz", "energy_dbfs"],
                  let hz = Self.number(object["center_hz"]),
                  let energy = Self.number(object["energy_dbfs"]),
                  (config.fMinHz...config.fMaxHz).contains(hz),
                  (config.floorDbfs...0).contains(energy),
                  parsed.last.map({ $0.centerHz < hz }) ?? true else { return nil }
            parsed.append(Point(centerHz: hz, energyDbfs: energy))
        }
        points = parsed
    }

    private static func number(_ value: Value?) -> Double? {
        let number: Double?
        switch value {
        case .double(let value): number = value
        case .int(let value): number = Double(value)
        default: return nil
        }
        return number?.isFinite == true ? number : nil
    }

    func energy(at hz: Double) -> Double? {
        guard let first = points.first, let last = points.last,
              hz >= first.centerHz, hz <= last.centerHz else { return nil }
        if hz == last.centerHz { return last.energyDbfs }
        for (a, b) in zip(points, points.dropFirst()) where hz >= a.centerHz && hz < b.centerHz {
            let fraction = log(hz / a.centerHz) / log(b.centerHz / a.centerHz)
            return a.energyDbfs + fraction * (b.energyDbfs - a.energyDbfs)
        }
        return nil
    }
}

struct SpectralTargetCurveComparison: Codable, Equatable, Sendable {
    struct Band: Codable, Equatable, Sendable {
        let centerHz: Double
        let targetEnergyDbfs: Double?
        let deltaDb: Double?
        let unavailableReason: String?
    }

    let targetCurve: [SpectralTargetCurve.Point]
    let bands: [Band]
    let complete: Bool
    let limitations: [String]

    init(analysis: SpectralAnalysisResult, curve: SpectralTargetCurve) {
        targetCurve = curve.points
        let floor = analysis.analysisPolicy?.config.floorDbfs ?? AudioFeatureExtractionEngine.Config.default.floorDbfs
        bands = analysis.bands.map { band in
            let target = curve.energy(at: band.centerHz)
            let reason: String?
            if target == nil { reason = "outside_target_span" }
            else if !band.measured { reason = "unmeasured_band" }
            else if band.energyDb <= floor { reason = "at_analysis_floor" }
            else if target! <= floor { reason = "target_at_analysis_floor" }
            else { reason = nil }
            return Band(centerHz: band.centerHz, targetEnergyDbfs: target,
                        deltaDb: reason == nil ? target! - band.energyDb : nil,
                        unavailableReason: reason)
        }
        complete = analysis.complete && !bands.isEmpty && bands.allSatisfy { $0.deltaDb != nil }
        limitations = ["absolute_band_energy_not_eq_gain", "not_level_normalized",
                       "no_extrapolation", "no_quality_or_applied_eq_claim"]
    }
}
