import Foundation

struct ProjectExportPlan: Codable, Sendable, Equatable {
    let schema: String
    let runID: String
    let generatedAt: String
    let status: String
    let executionMode: String
    let outputRoot: String
    let collisionPolicy: String
    let namingPolicy: String
    let projectCount: Int
    let projects: [ProjectExportPlanProject]
    let requiredConfirmations: [ProjectExportConfirmation]
    let unsupportedOrBlockedSteps: [ProjectExportBlockedStep]
    let executionPreconditions: [ProjectExportPrecondition]
    let baselineVerification: [String]
    let enhancementPath: [String]
    let nextSafeAction: String

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case generatedAt = "generated_at"
        case status
        case executionMode = "execution_mode"
        case outputRoot = "output_root"
        case collisionPolicy = "collision_policy"
        case namingPolicy = "naming_policy"
        case projectCount = "project_count"
        case projects
        case requiredConfirmations = "required_confirmations"
        case unsupportedOrBlockedSteps = "unsupported_or_blocked_steps"
        case executionPreconditions = "execution_preconditions"
        case baselineVerification = "baseline_verification"
        case enhancementPath = "enhancement_path"
        case nextSafeAction = "next_safe_action"
    }
}

struct ProjectExportPlanProject: Codable, Sendable, Equatable {
    let index: Int
    let projectPath: String
    let displayName: String
    let validationStatus: String
    let validationIssues: [String]
    let expectedArtifacts: [ProjectExportPlanArtifact]
    let workflowSteps: [ProjectExportWorkflowStep]
    let manifestStatus: String

    enum CodingKeys: String, CodingKey {
        case index
        case projectPath = "project_path"
        case displayName = "display_name"
        case validationStatus = "validation_status"
        case validationIssues = "validation_issues"
        case expectedArtifacts = "expected_artifacts"
        case workflowSteps = "workflow_steps"
        case manifestStatus = "manifest_status"
    }
}

struct ProjectExportPlanArtifact: Codable, Sendable, Equatable {
    let kind: String
    let path: String
    let status: String
    let verification: ProjectExportArtifactVerification
    let analysis: [String: String]
    /// Present only for `stem`: Logic writes an unknown number of files into
    /// this directory, rather than the one known `path` the other kinds use.
    let destination: String?
    /// The identity-backed populated-track subjects this stem request
    /// addresses. Stem planning refuses rather than emitting a degraded plan
    /// when the fresh complete region inventory cannot establish this list.
    let subjects: [ProjectExportStemSubject]?
    /// `true` for stems. Logic, not the planner, assigns the eventual file
    /// names, so callers must not interpret `path` as a file path in that case.
    let filenamesLateBound: Bool?
    /// Human-readable explanation for a late-bound planning refusal.
    let planningReason: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case path
        case status
        case verification
        case analysis
        case destination
        case subjects
        case filenamesLateBound = "filenames_late_bound"
        case planningReason = "planning_reason"
    }
}

/// A stem-export subject deliberately identifies the track, not a predicted
/// output filename. Logic's filename disambiguation is not measured enough to
/// make a filename promise at plan time.
struct ProjectExportStemSubject: Codable, Sendable, Equatable {
    let index: Int
    let name: String
}

struct ProjectExportArtifactVerification: Codable, Sendable, Equatable {
    let exists: Bool
    let fileSizeBytes: Int64?
    let mtime: String?
    let pathUnderOutputRoot: Bool
    let wouldOverwrite: Bool
    let issues: [String]
    /// For late-bound stems, this is the number of existing audio files in the
    /// destination directory. It is nil for ordinary one-path artifacts.
    let existingAudioFileCount: Int?

    enum CodingKeys: String, CodingKey {
        case exists
        case fileSizeBytes = "file_size_bytes"
        case mtime
        case pathUnderOutputRoot = "path_under_output_root"
        case wouldOverwrite = "would_overwrite"
        case issues
        case existingAudioFileCount = "existing_audio_file_count"
    }
}

struct ProjectExportWorkflowStep: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let tool: String?
    let command: String?
    let mutates: Bool
    let executed: Bool
    let requiresConfirmationLevel: String?
    let stopConditions: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tool
        case command
        case mutates
        case executed
        case requiresConfirmationLevel = "requires_confirmation_level"
        case stopConditions = "stop_conditions"
    }
}

struct ProjectExportConfirmation: Codable, Sendable, Equatable {
    let level: String
    let requiredFor: [String]
    let message: String

    enum CodingKeys: String, CodingKey {
        case level
        case requiredFor = "required_for"
        case message
    }
}

struct ProjectExportBlockedStep: Codable, Sendable, Equatable {
    let operation: String
    let reason: String
    let safeAlternative: String

    enum CodingKeys: String, CodingKey {
        case operation
        case reason
        case safeAlternative = "safe_alternative"
    }
}

/// A machine-readable execution dependency of a workflow step, surfaced in the
/// dry-run plan so a caller can tell from the manifest what the run needs BEFORE
/// it fails at that step (#369): the plan otherwise validates as `valid` with no
/// mention of the bounce step's live requirements. These are invariant facts
/// about what execution needs, not a live probe — verify satisfaction with the
/// `verify_with` command.
struct ProjectExportPrecondition: Codable, Sendable, Equatable {
    let requirement: String
    let appliesToCommands: [String]
    let detail: String
    let verifyWith: String

    enum CodingKeys: String, CodingKey {
        case requirement
        case appliesToCommands = "applies_to_commands"
        case detail
        case verifyWith = "verify_with"
    }
}
