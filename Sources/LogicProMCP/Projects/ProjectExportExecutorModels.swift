import Foundation

struct ProjectExportRunResult: Codable, Sendable, Equatable {
    let schema: String
    let runID: String
    let mode: String
    let confirmed: Bool
    let status: String
    let outputRoot: String
    let collisionPolicy: String
    let projectCount: Int
    let artifactsTotal: Int
    let artifactsVerified: Int
    let artifactsSkipped: Int
    let artifactsUncertain: Int
    let artifactsFailed: Int
    let projects: [ProjectExportRunProject]
    let nextSafeAction: String

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case mode
        case confirmed
        case status
        case outputRoot = "output_root"
        case collisionPolicy = "collision_policy"
        case projectCount = "project_count"
        case artifactsTotal = "artifacts_total"
        case artifactsVerified = "artifacts_verified"
        case artifactsSkipped = "artifacts_skipped"
        case artifactsUncertain = "artifacts_uncertain"
        case artifactsFailed = "artifacts_failed"
        case projects
        case nextSafeAction = "next_safe_action"
    }
}

struct ProjectExportRunProject: Codable, Sendable, Equatable {
    let index: Int
    let projectPath: String
    let displayName: String
    let observedProjectPath: String?
    let identityVerified: Bool
    let opened: Bool
    let artifacts: [ProjectExportRunArtifact]

    enum CodingKeys: String, CodingKey {
        case index
        case projectPath = "project_path"
        case displayName = "display_name"
        case observedProjectPath = "observed_project_path"
        case identityVerified = "identity_verified"
        case opened
        case artifacts
    }
}

struct ProjectExportRunArtifact: Codable, Sendable, Equatable {
    let kind: String
    let path: String
    let state: String
    let verified: Bool
    let bounceFired: Bool
    /// Whether the export actuator was reached. State-C panel refusals keep
    /// this false so callers can distinguish a safe refusal from a failed
    /// post-click verification.
    let writeAttempted: Bool
    let error: String?
    let reason: String?
    let evidence: ProjectExportArtifactEvidence?
    /// Present for a late-bound stem result. This is the requested populated
    /// track, not an inference from an output filename.
    let subject: ProjectExportStemSubject?
    /// Files observed in the before/after directory delta and analyzed after
    /// export. They are intentionally separate from `subject`: the current AX
    /// route has no evidence that a particular filename belongs to a track or
    /// that an entry created after the before snapshot was produced by Logic
    /// rather than a concurrent writer.
    let observedStemOutputs: [ProjectExportObservedStemOutput]?

    enum CodingKeys: String, CodingKey {
        case kind
        case path
        case state
        case verified
        case bounceFired = "bounce_fired"
        case writeAttempted = "write_attempted"
        case error
        case reason
        case evidence
        case subject
        case observedStemOutputs = "observed_stem_outputs"
    }

    init(
        kind: String,
        path: String,
        state: String,
        verified: Bool,
        bounceFired: Bool,
        writeAttempted: Bool,
        error: String?,
        reason: String?,
        evidence: ProjectExportArtifactEvidence?,
        subject: ProjectExportStemSubject? = nil,
        observedStemOutputs: [ProjectExportObservedStemOutput]? = nil
    ) {
        self.kind = kind
        self.path = path
        self.state = state
        self.verified = verified
        self.bounceFired = bounceFired
        self.writeAttempted = writeAttempted
        self.error = error
        self.reason = reason
        self.evidence = evidence
        self.subject = subject
        self.observedStemOutputs = observedStemOutputs
    }
}

struct ProjectExportObservedStemOutput: Codable, Sendable, Equatable {
    let path: String
    let verified: Bool
    let reason: String?
    let evidence: ProjectExportArtifactEvidence
}

struct ProjectExportArtifactEvidence: Codable, Sendable, Equatable {
    let exists: Bool
    let fileSizeBytes: Int64
    let durationSeconds: Double
    let sampleRate: Int
    let channelCount: Int
    let silenceRatio: Double
    let peakDbfs: Double
    let verificationStatus: String
    let verificationReasons: [String]
    let source: String

    enum CodingKeys: String, CodingKey {
        case exists
        case fileSizeBytes = "file_size_bytes"
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
        case silenceRatio = "silence_ratio"
        case peakDbfs = "peak_dbfs"
        case verificationStatus = "verification_status"
        case verificationReasons = "verification_reasons"
        case source
    }

    init(from analysis: AudioAnalyzer.Result, source: String) {
        self.exists = analysis.exists
        self.fileSizeBytes = analysis.fileSizeBytes
        self.durationSeconds = analysis.durationSeconds
        self.sampleRate = analysis.sampleRate
        self.channelCount = analysis.channelCount
        self.silenceRatio = analysis.silenceRatio
        self.peakDbfs = analysis.peakDbfs
        self.verificationStatus = analysis.verification.status.rawValue
        self.verificationReasons = analysis.verification.reasons
        self.source = source
    }
}
