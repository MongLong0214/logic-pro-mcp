import Foundation

enum WorkflowEvidenceLevel: String, Codable, CaseIterable, Sendable {
    case deterministic
    case liveVerified = "live_verified"
    case documentationOnly = "documentation_only"
    case experimental
}

enum WorkflowMutationKind: String, Codable, Sendable {
    case readOnly = "read_only"
    case guardedMutation = "guarded_mutation"
}

struct WorkflowConfirmation: Codable, Sendable, Equatable {
    let level: String
    let requiredFor: [String]
    let message: String

    enum CodingKeys: String, CodingKey {
        case level
        case requiredFor = "required_for"
        case message
    }
}

struct WorkflowStateCheck: Codable, Sendable, Equatable {
    let id: String
    let resource: String
    let requiredFields: [String]
    let stopIfMissing: Bool
    let description: String

    enum CodingKeys: String, CodingKey {
        case id
        case resource
        case requiredFields = "required_fields"
        case stopIfMissing = "stop_if_missing"
        case description
    }
}

struct WorkflowStep: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let operationType: String
    let tool: String?
    let resource: String?
    let mutates: Bool
    let requiresConfirmationLevel: String?
    let expectedResponseFields: [String]
    let stopConditions: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case operationType = "operation_type"
        case tool
        case resource
        case mutates
        case requiresConfirmationLevel = "requires_confirmation_level"
        case expectedResponseFields = "expected_response_fields"
        case stopConditions = "stop_conditions"
    }
}

struct WorkflowVerification: Codable, Sendable, Equatable {
    let evidence: [String]
    let successFields: [String]
    let liveEvidenceFile: String?

    enum CodingKeys: String, CodingKey {
        case evidence
        case successFields = "success_fields"
        case liveEvidenceFile = "live_evidence_file"
    }
}

struct WorkflowSkill: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let intent: String
    let scope: String
    let prerequisites: [String]
    var allowedTools: [String]
    var allowedResources: [String]
    var requiredConfirmations: [WorkflowConfirmation]
    let stateChecks: [WorkflowStateCheck]
    let steps: [WorkflowStep]
    let verification: WorkflowVerification
    var failureModes: [String]
    let rollbackOrRecovery: String
    var evidenceLevel: WorkflowEvidenceLevel
    var productionReady: Bool
    let dependsOn: [String]
    let limitations: [String]
    let mutationKind: WorkflowMutationKind

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case intent
        case scope
        case prerequisites
        case allowedTools = "allowed_tools"
        case allowedResources = "allowed_resources"
        case requiredConfirmations = "required_confirmations"
        case stateChecks = "state_checks"
        case steps
        case verification
        case failureModes = "failure_modes"
        case rollbackOrRecovery = "rollback_or_recovery"
        case evidenceLevel = "evidence_level"
        case productionReady = "production_ready"
        case dependsOn = "depends_on"
        case limitations
        case mutationKind = "mutation_kind"
    }
}

struct WorkflowLintIssue: Codable, Sendable, Equatable {
    let code: String
    let path: String
    let message: String
}

struct WorkflowLintResult: Codable, Sendable, Equatable {
    let isValid: Bool
    let issues: [WorkflowLintIssue]

    enum CodingKeys: String, CodingKey {
        case isValid = "is_valid"
        case issues
    }
}

struct WorkflowSkillSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let workflowCount: Int
    let validation: WorkflowLintResult
    let workflows: [WorkflowSkill]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case workflowCount = "workflow_count"
        case validation
        case workflows
    }
}

enum WorkflowSkillLinter {
    static func validate(
        _ workflows: [WorkflowSkill],
        toolNames: Set<String> = WorkflowSkillCatalog.currentToolNames(),
        resourceURIs: Set<String> = WorkflowSkillCatalog.currentResourceURIs()
    ) -> WorkflowLintResult {
        var issues: [WorkflowLintIssue] = []
        var seen = Set<String>()

        for (index, workflow) in workflows.enumerated() {
            let base = "workflows[\(index)]"
            if !seen.insert(workflow.id).inserted {
                issues.append(issue("duplicate_id", "\(base).id", "duplicate workflow id \(workflow.id)"))
            }
            if workflow.title.isEmpty || workflow.intent.isEmpty || workflow.scope.isEmpty {
                issues.append(issue("missing_required_field", base, "title, intent, and scope are required"))
            }
            for tool in workflow.allowedTools where !toolNames.contains(tool) {
                issues.append(issue("unknown_tool", "\(base).allowed_tools", "unknown MCP tool \(tool)"))
            }
            for resource in workflow.allowedResources where !resourceURIs.contains(resource) {
                issues.append(issue("unknown_resource", "\(base).allowed_resources", "unknown MCP resource \(resource)"))
            }
            for (checkIndex, check) in workflow.stateChecks.enumerated()
                where !resourceURIs.contains(check.resource) {
                issues.append(issue("unknown_resource", "\(base).state_checks[\(checkIndex)].resource", "unknown MCP resource \(check.resource)"))
            }
            let mutating = workflow.mutationKind == .guardedMutation || workflow.steps.contains { $0.mutates }
            if mutating && workflow.requiredConfirmations.isEmpty {
                issues.append(issue("mutating_missing_confirmation", "\(base).required_confirmations", "mutating workflows require confirmation metadata"))
            }
            if mutating && workflow.failureModes.isEmpty {
                issues.append(issue("mutating_missing_failure_modes", "\(base).failure_modes", "mutating workflows require explicit failure modes"))
            }
            if workflow.productionReady && mutating && workflow.evidenceLevel != .liveVerified {
                issues.append(issue(
                    "production_mutation_without_live_evidence",
                    "\(base).evidence_level",
                    "production-ready mutating workflows must be live_verified"
                ))
            }
            for (stepIndex, step) in workflow.steps.enumerated() {
                if let tool = step.tool, !toolNames.contains(tool) {
                    issues.append(issue("unknown_tool", "\(base).steps[\(stepIndex)].tool", "unknown MCP tool \(tool)"))
                }
                if let resource = step.resource, !resourceURIs.contains(resource) {
                    issues.append(issue("unknown_resource", "\(base).steps[\(stepIndex)].resource", "unknown MCP resource \(resource)"))
                }
                if step.mutates && (step.requiresConfirmationLevel?.isEmpty ?? true) {
                    issues.append(issue("mutating_step_missing_confirmation", "\(base).steps[\(stepIndex)]", "mutating steps need confirmation level"))
                }
                if step.expectedResponseFields.isEmpty {
                    issues.append(issue("step_missing_success_fields", "\(base).steps[\(stepIndex)]", "steps must name response fields to inspect"))
                }
            }
        }

        return WorkflowLintResult(isValid: issues.isEmpty, issues: issues)
    }

    private static func issue(_ code: String, _ path: String, _ message: String) -> WorkflowLintIssue {
        WorkflowLintIssue(code: code, path: path, message: message)
    }
}

enum WorkflowSkillCatalog {
    static func defaultSnapshot(now: Date = Date()) -> WorkflowSkillSnapshot {
        let workflows = defaultWorkflows()
        let validation = WorkflowSkillLinter.validate(workflows)
        return WorkflowSkillSnapshot(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter.cacheFormatter.string(from: now),
            workflowCount: workflows.count,
            validation: validation,
            workflows: workflows
        )
    }

    static func defaultWorkflows() -> [WorkflowSkill] {
        [
            projectReadiness(),
            midiIdeaSketch(),
            arrangementMarkerPlan(),
            gainStagingPrep(),
            stockPluginChainPlan(),
            stockPluginGuardedInsert(),
            bounceReadiness(),
        ]
    }

    static func workflow(id: String, snapshot: WorkflowSkillSnapshot = defaultSnapshot()) -> WorkflowSkill? {
        snapshot.workflows.first { $0.id == id }
    }

    static func search(query: String, snapshot: WorkflowSkillSnapshot = defaultSnapshot()) -> [WorkflowSkill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snapshot.workflows }
        return snapshot.workflows.filter {
            $0.id.lowercased().contains(q) ||
                $0.title.lowercased().contains(q) ||
                $0.intent.lowercased().contains(q) ||
                $0.limitations.joined(separator: " ").lowercased().contains(q)
        }
    }

    static func schema(now: Date = Date()) -> [String: Any] {
        [
            "schema_version": 1,
            "generated_at": ISO8601DateFormatter.cacheFormatter.string(from: now),
            "required_fields": [
                "id",
                "title",
                "intent",
                "scope",
                "prerequisites",
                "allowed_tools",
                "allowed_resources",
                "state_checks",
                "steps",
                "verification",
                "failure_modes",
                "evidence_level",
            ],
            "evidence_levels": WorkflowEvidenceLevel.allCases.map(\.rawValue),
            "mutation_kinds": [
                WorkflowMutationKind.readOnly.rawValue,
                WorkflowMutationKind.guardedMutation.rawValue,
            ],
            "resources": [
                "logic://workflow-skills",
                "logic://workflow-skills/{id}",
                "logic://workflow-skills/search?query=<text>",
                "logic://workflow-skills/schema",
            ],
            "read_only_surface": true,
        ]
    }

    static func currentToolNames() -> Set<String> {
        [
            "logic_transport",
            "logic_tracks",
            "logic_mixer",
            "logic_midi",
            "logic_edit",
            "logic_navigate",
            "logic_project",
            "logic_system",
        ]
    }

    static func currentResourceURIs() -> Set<String> {
        var uris = Set(ResourceProvider.resources.map(\.uri))
        uris.formUnion(ResourceProvider.templates.map(\.uriTemplate))
        uris.formUnion([
            "logic://stock-plugins/{id}",
            "logic://stock-plugins/logic.stock.effect.gain",
            "logic://stock-plugins/search?query=<text>",
            "logic://workflow-skills/{id}",
            "logic://workflow-skills/search?query=<text>",
        ])
        return uris
    }

    private static func projectReadiness() -> WorkflowSkill {
        WorkflowSkill(
            id: "logic.workflow.readiness.project",
            title: "Project Readiness Check",
            intent: "Confirm Logic Pro, MCP resources, project state, tracks, transport, and mixer provenance before creative work.",
            scope: "Read-only diagnostics; does not mutate project state.",
            prerequisites: ["Logic Pro running", "MCP server reachable", "Accessibility permissions checked"],
            allowedTools: ["logic_system"],
            allowedResources: ["logic://system/health", "logic://project/info", "logic://transport/state", "logic://tracks", "logic://mixer"],
            requiredConfirmations: [],
            stateChecks: [
                stateCheck("health", "logic://system/health", ["channels", "cache"], true),
                stateCheck("project", "logic://project/info", ["data"], false),
                stateCheck("tracks", "logic://tracks", ["data"], false),
            ],
            steps: [
                readStep("health", "Read system health", "logic://system/health", ["channels", "permissions"]),
                readStep("project", "Read project info", "logic://project/info", ["data", "source"]),
                readStep("mixer", "Read mixer provenance", "logic://mixer", ["data_source", "strips"]),
            ],
            verification: WorkflowVerification(evidence: ["resource_json"], successFields: ["validation_status"], liveEvidenceFile: nil),
            failureModes: ["Logic not running", "AX occluded", "mixer_not_visible"],
            rollbackOrRecovery: "No rollback required; read-only workflow.",
            evidenceLevel: .deterministic,
            productionReady: true,
            dependsOn: [],
            limitations: ["Does not open Logic or create a project."],
            mutationKind: .readOnly
        )
    }

    private static func midiIdeaSketch() -> WorkflowSkill {
        WorkflowSkill(
            id: "logic.workflow.midi.idea_sketch",
            title: "MIDI Idea Sketch",
            intent: "Create or import a small MIDI idea only after the target track and project state are explicit.",
            scope: "May write MIDI to a caller-specified target after confirmation; never guesses track 0.",
            prerequisites: ["Open project", "Explicit target track", "User confirmation for MIDI mutation"],
            allowedTools: ["logic_tracks", "logic_midi"],
            allowedResources: ["logic://tracks", "logic://tracks/{index}/regions", "logic://project/info"],
            requiredConfirmations: [
                WorkflowConfirmation(level: "L1", requiredFor: ["midi_import", "record_sequence"], message: "Confirm target track and MIDI content before writing."),
            ],
            stateChecks: [
                stateCheck("tracks", "logic://tracks", ["data"], true),
                stateCheck("regions_before", "logic://tracks/{index}/regions", ["regions"], false),
            ],
            steps: [
                readStep("read_tracks", "Read tracks before target selection", "logic://tracks", ["data"]),
                toolStep("write_midi", "Import or record MIDI on explicit target", "logic_midi", true, "L1", ["success", "verified"], ["unverified target", "invalid channel"]),
                readStep("regions_after", "Read regions after write", "logic://tracks/{index}/regions", ["regions"]),
            ],
            verification: WorkflowVerification(evidence: ["before_regions", "after_regions", "tool_envelope"], successFields: ["region_count_delta", "verified"], liveEvidenceFile: nil),
            failureModes: ["target track missing", "selection unverified", "MIDI import rejected", "post-write region readback unavailable"],
            rollbackOrRecovery: "Manual recovery: undo in Logic if write succeeded but follow-up verification is inconclusive.",
            evidenceLevel: .deterministic,
            productionReady: false,
            dependsOn: [],
            limitations: ["Not production-ready until a scoped live mutation run is recorded."],
            mutationKind: .guardedMutation
        )
    }

    private static func arrangementMarkerPlan() -> WorkflowSkill {
        WorkflowSkill(
            id: "logic.workflow.arrangement.marker_plan",
            title: "Arrangement Marker Plan",
            intent: "Plan and verify marker positions without relying on stale parser assumptions.",
            scope: "Read-first marker planning; mutation remains guarded and optional.",
            prerequisites: ["Open project", "Marker resource readable"],
            allowedTools: ["logic_navigate"],
            allowedResources: ["logic://markers", "logic://transport/state"],
            requiredConfirmations: [
                WorkflowConfirmation(level: "L1", requiredFor: ["marker_mutation"], message: "Confirm marker names and positions before writing."),
            ],
            stateChecks: [stateCheck("markers", "logic://markers", ["data"], false)],
            steps: [
                readStep("read_markers", "Read current markers", "logic://markers", ["data", "position_source"]),
                toolStep("optional_write", "Optionally create supported markers", "logic_navigate", true, "L1", ["success", "verified"], ["unsupported marker mutation", "position parse failure"]),
            ],
            verification: WorkflowVerification(evidence: ["marker_resource_before_after"], successFields: ["canonical_position", "verified"], liveEvidenceFile: nil),
            failureModes: ["marker resource unavailable", "position parser rejects input", "post-write readback unavailable"],
            rollbackOrRecovery: "Manual recovery in Logic marker list.",
            evidenceLevel: .deterministic,
            productionReady: false,
            dependsOn: [],
            limitations: ["Mutation path may be unavailable depending on current public tool surface."],
            mutationKind: .guardedMutation
        )
    }

    private static func gainStagingPrep() -> WorkflowSkill {
        WorkflowSkill(
            id: "logic.workflow.mixer.gain_staging_prep",
            title: "Gain Staging And Mixer Prep",
            intent: "Prepare safe gain-staging recommendations using mixer provenance and explicit target verification.",
            scope: "May call mixer writes only when target and readback conditions are explicit.",
            prerequisites: ["Mixer resource readable", "Explicit track list", "User confirmation for mixer mutations"],
            allowedTools: ["logic_mixer"],
            allowedResources: ["logic://mixer", "logic://mixer/{strip}", "logic://tracks"],
            requiredConfirmations: [
                WorkflowConfirmation(level: "L1", requiredFor: ["set_volume", "set_pan"], message: "Confirm track index and target value before mixer write."),
            ],
            stateChecks: [
                stateCheck("mixer", "logic://mixer", ["data_source", "strips"], true),
                stateCheck("tracks", "logic://tracks", ["data"], true),
            ],
            steps: [
                readStep("read_mixer", "Read mixer provenance", "logic://mixer", ["data_source", "mcu_connected", "strips"]),
                toolStep("optional_level_write", "Optionally write volume/pan with explicit track", "logic_mixer", true, "L1", ["success", "verified", "reason"], ["target unverified", "readback unavailable"]),
                readStep("read_strip_after", "Read target strip after write", "logic://mixer/{strip}", ["data_source", "strip"]),
            ],
            verification: WorkflowVerification(evidence: ["mixer_before_after", "honest_contract_envelope"], successFields: ["verified", "data_source"], liveEvidenceFile: nil),
            failureModes: ["mixer_not_visible", "cache_stale", "track selection unverified", "echo timeout"],
            rollbackOrRecovery: "Manual recovery: restore previous fader/pan value from before evidence.",
            evidenceLevel: .deterministic,
            productionReady: false,
            dependsOn: [],
            limitations: ["Stops instead of writing when provenance is insufficient."],
            mutationKind: .guardedMutation
        )
    }

    private static func stockPluginChainPlan() -> WorkflowSkill {
        WorkflowSkill(
            id: "logic.workflow.plugins.stock_chain_plan",
            title: "Stock Plugin Chain Planning",
            intent: "Plan stock plugin chains from verified catalog metadata without claiming insertion success.",
            scope: "Planning-only in this release; no plugin insertion is executed.",
            prerequisites: ["Stock plugin catalog resource readable", "Mixer slot state available if planning against a track"],
            allowedTools: [],
            allowedResources: ["logic://stock-plugins", "logic://stock-plugins/{id}", "logic://stock-plugins/search?query=<text>", "logic://mixer"],
            requiredConfirmations: [],
            stateChecks: [
                stateCheck("catalog", "logic://stock-plugins", ["entries", "validation"], true),
                stateCheck("mixer", "logic://mixer", ["strips"], false),
            ],
            steps: [
                readStep("read_catalog", "Read stock plugin catalog", "logic://stock-plugins", ["entries", "availability_state"]),
                readStep("search_catalog", "Search catalog for user intent", "logic://stock-plugins/search?query=<text>", ["entries"]),
                readStep("read_mixer_slots", "Read mixer slot state before planning insert order", "logic://mixer", ["strips"]),
            ],
            verification: WorkflowVerification(evidence: ["catalog_entry_truth_labels", "slot_state"], successFields: ["availability_state", "limitations"], liveEvidenceFile: nil),
            failureModes: ["catalog validation failed", "no verified or labelled candidate", "mixer slot state unavailable"],
            rollbackOrRecovery: "No rollback required; planning-only workflow.",
            evidenceLevel: .deterministic,
            productionReady: true,
            dependsOn: ["logic://stock-plugins"],
            limitations: ["Does not insert plugins; clients must not treat inferred entries as verified."],
            mutationKind: .readOnly
        )
    }

    private static func stockPluginGuardedInsert() -> WorkflowSkill {
        WorkflowSkill(
            id: "logic.workflow.plugins.stock_insert_gain_live_verified",
            title: "Live-Verified Gain Insert",
            intent: "Insert Logic's stock Gain plugin only after catalog lookup, explicit track/slot confirmation, empty-slot checks, and AX slot readback.",
            scope: "Guarded mutation for the allowlisted stock Gain plugin; never replaces an occupied slot.",
            prerequisites: [
                "Logic Pro 12.2-compatible project is open",
                "Mixer is visible to Accessibility",
                "Target track and insert slot are explicit",
                "Caller accepts L2 confirmation for insert-chain mutation",
            ],
            allowedTools: ["logic_mixer"],
            allowedResources: [
                "logic://stock-plugins/logic.stock.effect.gain",
                "logic://mixer",
                "logic://mixer/{strip}",
            ],
            requiredConfirmations: [
                WorkflowConfirmation(
                    level: "L2",
                    requiredFor: ["insert_plugin"],
                    message: "Confirm target track, slot, and stock Gain insertion before mutating the insert chain."
                ),
            ],
            stateChecks: [
                stateCheck("gain_catalog", "logic://stock-plugins/logic.stock.effect.gain", ["entry", "validation"], true),
                stateCheck("mixer", "logic://mixer", ["strips", "data_source"], true),
                stateCheck("target_strip", "logic://mixer/{strip}", ["strip"], false),
            ],
            steps: [
                readStep("read_gain_catalog", "Read stock Gain catalog entry", "logic://stock-plugins/logic.stock.effect.gain", ["entry", "availability_state"]),
                readStep("read_mixer_slots", "Read mixer slot state", "logic://mixer", ["strips", "plugins"]),
                toolStep(
                    "confirmed_insert_gain",
                    "Insert stock Gain into an explicit empty slot",
                    "logic_mixer",
                    true,
                    "L2",
                    ["success", "verified", "observed_plugin_name", "verify_source"],
                    ["confirmation missing", "slot_occupied", "readback unavailable", "readback mismatch"]
                ),
                readStep("read_strip_after_insert", "Read target strip after insert", "logic://mixer/{strip}", ["strip", "plugins"]),
            ],
            verification: WorkflowVerification(
                evidence: ["catalog_entry", "confirmation_required_gate", "ax_plugin_slot_readback"],
                successFields: ["verified", "observed_plugin_name", "verify_source"],
                liveEvidenceFile: "docs/tickets/mixer-verification/VERIFICATION-2026-06-09.md"
            ),
            failureModes: [
                "catalog validation failed",
                "mixer_not_visible",
                "target track out of range",
                "slot_occupied",
                "plugin menu selection failed",
                "AX slot readback unavailable",
            ],
            rollbackOrRecovery: "If readback fails after a write attempt, production insert_plugin attempts Logic undo and returns rollback evidence; otherwise manual undo in Logic is the recovery path.",
            evidenceLevel: .liveVerified,
            productionReady: true,
            dependsOn: ["logic://stock-plugins"],
            limitations: [
                "Live evidence is scoped to the existing Logic Pro 12.2 verification run; clients must still require current-session confirmation and readback.",
                "Only Gain, Compressor, and Channel EQ are allowlisted by the underlying tool; this workflow specializes Gain.",
            ],
            mutationKind: .guardedMutation
        )
    }

    private static func bounceReadiness() -> WorkflowSkill {
        WorkflowSkill(
            id: "logic.workflow.bounce.readiness",
            title: "Bounce Readiness Checklist",
            intent: "Check project state before manual bounce/export.",
            scope: "Read-only checklist; export remains manual unless a future tool explicitly supports it.",
            prerequisites: ["Open project", "Project info readable"],
            allowedTools: ["logic_project", "logic_transport"],
            allowedResources: ["logic://project/info", "logic://transport/state", "logic://tracks", "logic://mixer"],
            requiredConfirmations: [],
            stateChecks: [
                stateCheck("project", "logic://project/info", ["data"], true),
                stateCheck("transport", "logic://transport/state", ["data"], true),
                stateCheck("tracks", "logic://tracks", ["data"], false),
            ],
            steps: [
                readStep("read_project", "Read project metadata", "logic://project/info", ["data", "source"]),
                readStep("read_transport", "Read cycle and playhead state", "logic://transport/state", ["data"]),
                readStep("read_tracks", "Read track mute/solo/arm state", "logic://tracks", ["data"]),
            ],
            verification: WorkflowVerification(evidence: ["resource_json"], successFields: ["project_name", "cycle_state", "track_states"], liveEvidenceFile: nil),
            failureModes: ["project info unavailable", "tracks stale", "mixer provenance insufficient"],
            rollbackOrRecovery: "No rollback required; read-only workflow.",
            evidenceLevel: .deterministic,
            productionReady: true,
            dependsOn: [],
            limitations: ["Does not perform a bounce/export."],
            mutationKind: .readOnly
        )
    }

    private static func stateCheck(_ id: String, _ resource: String, _ fields: [String], _ stop: Bool) -> WorkflowStateCheck {
        WorkflowStateCheck(
            id: id,
            resource: resource,
            requiredFields: fields,
            stopIfMissing: stop,
            description: "Read \(resource) and require fields: \(fields.joined(separator: ", "))"
        )
    }

    private static func readStep(_ id: String, _ title: String, _ resource: String, _ fields: [String]) -> WorkflowStep {
        WorkflowStep(
            id: id,
            title: title,
            operationType: "resource_read",
            tool: nil,
            resource: resource,
            mutates: false,
            requiresConfirmationLevel: nil,
            expectedResponseFields: fields,
            stopConditions: ["missing required field", "resource error"]
        )
    }

    private static func toolStep(
        _ id: String,
        _ title: String,
        _ tool: String,
        _ mutates: Bool,
        _ level: String?,
        _ fields: [String],
        _ stops: [String]
    ) -> WorkflowStep {
        WorkflowStep(
            id: id,
            title: title,
            operationType: "tool_call",
            tool: tool,
            resource: nil,
            mutates: mutates,
            requiresConfirmationLevel: level,
            expectedResponseFields: fields,
            stopConditions: stops
        )
    }
}
