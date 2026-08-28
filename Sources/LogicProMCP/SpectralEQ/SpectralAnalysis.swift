import Foundation

struct SpectralBand: Codable, Equatable, Sendable {
    let centerHz: Double
    let energyDb: Double

    /// False when this band's edges enclose no FFT bin of the window it is stitched from, so its
    /// `energyDb` is the floor sentinel and not a reading.
    ///
    /// Measured 2026-08-28 at 44.1 kHz with the default grid: bands at 20, 25.198 and 40 Hz report
    /// exactly `floorDbfs` for every signal, including white noise — the log-spaced bands are ~3 Hz
    /// wide down there and the 8192-point window resolves 5.383 Hz. `-80 dB` in that position reads
    /// as "this region is silent", which is a false statement about the audio rather than a small
    /// one about the grid.
    ///
    /// Defaults to `true` so a hand-built band in a test is a reading unless it says otherwise.
    var measured: Bool = true

    init(centerHz: Double, energyDb: Double, measured: Bool = true) {
        self.centerHz = centerHz
        self.energyDb = energyDb
        self.measured = measured
    }

    /// Written by hand because Swift's synthesised `init(from:)` does NOT apply a property's
    /// default for a missing key — it requires every non-optional key to be present. Adding
    /// `measured` therefore broke decoding of every document written before it existed, which
    /// `legacyResonanceArrayDecodesWithDefaults` caught on the first run.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        centerHz = try container.decode(Double.self, forKey: .centerHz)
        energyDb = try container.decode(Double.self, forKey: .energyDb)
        measured = try container.decodeIfPresent(Bool.self, forKey: .measured) ?? true
    }
}

struct SpectralResonance: Codable, Equatable, Sendable {
    let hz: Double
    let gainDb: Double
    let q: Double
    // ADR-012 pinned rule: where a peak occupies < 1 log-band its −3 dB bandwidth cannot be
    // resolved, so Q is clamped at the analysis-resolution ceiling and flagged rather
    // than reported as an unbounded value. Consumers must treat a flagged Q as ">= q".
    let resolutionLimited: Bool

    init(hz: Double, gainDb: Double, q: Double, resolutionLimited: Bool = false) {
        self.hz = hz
        self.gainDb = gainDb
        self.q = q
        self.resolutionLimited = resolutionLimited
    }

    // Legacy resonance records predate `resolutionLimited`; decode it leniently so a
    // stored non-empty resonance array without the field still round-trips (defaults false).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hz: try values.decode(Double.self, forKey: .hz),
            gainDb: try values.decode(Double.self, forKey: .gainDb),
            q: try values.decode(Double.self, forKey: .q),
            resolutionLimited: try values.decodeIfPresent(Bool.self, forKey: .resolutionLimited) ?? false
        )
    }
}

enum SourceClassification: String, Codable, Sendable {
    case vocal
    case drums
    case bass
    case fullMix
    case unknown
}

/// ADR-012 pinned channel strategy: analyze each channel independently then energy-average
/// (never sum-to-mono — that cancels out-of-phase stereo). The mode records which
/// averaging path produced the bands so a consumer can reason about phase handling.
enum ChannelMode: String, Codable, Sendable {
    case mono
    case stereoEnergyAverage = "stereo_energy_average"
    case multiChannelEnergyAverage = "multichannel_energy_average"

    init(channelCount: Int) {
        switch channelCount {
        case ..<2: self = .mono
        case 2: self = .stereoEnergyAverage
        default: self = .multiChannelEnergyAverage
        }
    }
}

/// ADR-012 rollout-1 public analysis schema (pinned). `spectralCentroidHz` and
/// `frequencyPeaks` are COMPUTED by `AudioFeatureExtractionEngine` (never placeholders);
/// the defaults on the initializer exist only so unrelated recommendation-layer test
/// fixtures and legacy decoders keep compiling — the engine always populates every field.
/// Deferred fields (percentileSpectrum, spectralRolloffHz, lowMidHighEnergy,
/// dynamicSummary) are explicitly deferred past rollout 1, each gated at its own rollout PR (each gated at its own rollout PR).
struct SpectralAnalysisResult: Codable, Equatable, Sendable {
    let analysisRef: String
    let artifactFingerprint: String
    let sampleRate: Double
    let channelCount: Int
    let durationSeconds: Double
    let windowsAnalyzed: Int
    let channelMode: ChannelMode
    let complete: Bool
    let partialReason: String?
    let bands: [SpectralBand]
    let resonances: [SpectralResonance]
    let spectralCentroidHz: Double?
    let frequencyPeaks: [AudioAnalyzer.FrequencyPeak]
    let classification: SourceClassification
    /// How loud the material is, normalised — NOT how sure the classifier is.
    ///
    /// Measured 2026-08-28: it comes out of `classify` as `min(0.9, (overallDb + 60) / 40)`, a
    /// level gate and nothing else, so every signal above about -20 dBFS scores exactly 0.9
    /// whatever it is. Five of six test signals did, including a pure 1 kHz sine the classifier
    /// called `vocal`. Named `confidence` it is a claim about the classification that the number
    /// cannot support; named this, it is a true statement and the gate it drives — do not
    /// recommend EQ for near-silence — is a reasonable one.
    ///
    /// There is no classification-certainty figure on this type. That is the honest state: adding
    /// one would mean inventing a metric, and the classifier itself is documented as coarse.
    let levelConfidence: Double

    init(
        analysisRef: String,
        bands: [SpectralBand],
        resonances: [SpectralResonance],
        classification: SourceClassification,
        levelConfidence: Double,
        complete: Bool,
        partialReason: String?,
        artifactFingerprint: String = "",
        sampleRate: Double = 0,
        channelCount: Int = 0,
        durationSeconds: Double = 0,
        windowsAnalyzed: Int = 0,
        channelMode: ChannelMode = .mono,
        spectralCentroidHz: Double? = nil,
        frequencyPeaks: [AudioAnalyzer.FrequencyPeak] = []
    ) {
        self.analysisRef = analysisRef
        self.artifactFingerprint = artifactFingerprint
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationSeconds = durationSeconds
        self.windowsAnalyzed = windowsAnalyzed
        self.channelMode = channelMode
        self.bands = bands
        self.resonances = resonances
        self.spectralCentroidHz = spectralCentroidHz
        self.frequencyPeaks = frequencyPeaks
        self.classification = classification
        self.levelConfidence = levelConfidence.isFinite ? min(max(levelConfidence, 0), 1) : 0
        self.complete = complete
        self.partialReason = complete ? nil : partialReason
    }

    /// Accepts the legacy `confidence` key as well as `levelConfidence`.
    ///
    /// The field was renamed because the number is a loudness gate and the old name claimed it was
    /// a statement about the classification. Encoding writes the new name only; decoding takes
    /// either, because analyses stored by a build running with the flag on carry the old one and a
    /// rename is not a reason to stop being able to read them.
    private enum LegacyKeys: String, CodingKey { case confidence }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let level = try values.decodeIfPresent(Double.self, forKey: .levelConfidence)
            ?? legacy.decodeIfPresent(Double.self, forKey: .confidence)
            ?? 0
        self.init(
            analysisRef: try values.decode(String.self, forKey: .analysisRef),
            bands: try values.decode([SpectralBand].self, forKey: .bands),
            resonances: try values.decode([SpectralResonance].self, forKey: .resonances),
            classification: try values.decode(SourceClassification.self, forKey: .classification),
            levelConfidence: level,
            complete: try values.decode(Bool.self, forKey: .complete),
            partialReason: try values.decodeIfPresent(String.self, forKey: .partialReason),
            // New rollout-1 fields decode leniently so legacy skeleton fixtures still round-trip;
            // the engine always emits them in full.
            artifactFingerprint: try values.decodeIfPresent(String.self, forKey: .artifactFingerprint) ?? "",
            sampleRate: try values.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0,
            channelCount: try values.decodeIfPresent(Int.self, forKey: .channelCount) ?? 0,
            durationSeconds: try values.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0,
            windowsAnalyzed: try values.decodeIfPresent(Int.self, forKey: .windowsAnalyzed) ?? 0,
            channelMode: try values.decodeIfPresent(ChannelMode.self, forKey: .channelMode) ?? .mono,
            spectralCentroidHz: try values.decodeIfPresent(Double.self, forKey: .spectralCentroidHz),
            frequencyPeaks: try values.decodeIfPresent([AudioAnalyzer.FrequencyPeak].self, forKey: .frequencyPeaks) ?? []
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
