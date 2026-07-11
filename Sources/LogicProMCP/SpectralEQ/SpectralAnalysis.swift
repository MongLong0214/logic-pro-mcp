import Foundation

struct SpectralBand: Codable, Equatable, Sendable {
    let centerHz: Double
    let energyDb: Double
}

struct SpectralResonance: Codable, Equatable, Sendable {
    let hz: Double
    let gainDb: Double
    let q: Double
}

enum SourceClassification: String, Codable, Sendable {
    case vocal
    case drums
    case bass
    case fullMix
    case unknown
}

struct SpectralAnalysisResult: Codable, Equatable, Sendable {
    let analysisRef: String
    let bands: [SpectralBand]
    let resonances: [SpectralResonance]
    let classification: SourceClassification
    let confidence: Double
    let complete: Bool
    let partialReason: String?

    init(
        analysisRef: String,
        bands: [SpectralBand],
        resonances: [SpectralResonance],
        classification: SourceClassification,
        confidence: Double,
        complete: Bool,
        partialReason: String?
    ) {
        self.analysisRef = analysisRef
        self.bands = bands
        self.resonances = resonances
        self.classification = classification
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.complete = complete
        self.partialReason = complete ? nil : partialReason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            analysisRef: try values.decode(String.self, forKey: .analysisRef),
            bands: try values.decode([SpectralBand].self, forKey: .bands),
            resonances: try values.decode([SpectralResonance].self, forKey: .resonances),
            classification: try values.decode(SourceClassification.self, forKey: .classification),
            confidence: try values.decode(Double.self, forKey: .confidence),
            complete: try values.decode(Bool.self, forKey: .complete),
            partialReason: try values.decodeIfPresent(String.self, forKey: .partialReason)
        )
    }
}

enum AnalysisJobState: String, Codable, Sendable {
    case queued
    case decoding
    case analyzing
    case completed
    case failed
    case cancelled
}

struct AnalysisJob: Codable, Equatable, Sendable {
    let ref: String
    let state: AnalysisJobState
    let progress: Double
}

func advance(_ job: AnalysisJob, to state: AnalysisJobState) -> AnalysisJob? {
    switch (job.state, state) {
    case (.queued, .decoding),
         (.decoding, .analyzing),
         (.analyzing, .completed),
         (.analyzing, .failed),
         (.analyzing, .cancelled):
        return AnalysisJob(ref: job.ref, state: state, progress: job.progress)
    default:
        return nil
    }
}
