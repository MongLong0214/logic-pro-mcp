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
    let command: String?
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
        case command
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
    var steps: [WorkflowStep]
    let verification: WorkflowVerification
    var failureModes: [String]
    let rollbackOrRecovery: String
    var evidenceLevel: WorkflowEvidenceLevel
    var productionReady: Bool
    let dependsOn: [String]
    let limitations: [String]
    var mutationKind: WorkflowMutationKind
    /// Snapshot-computed honesty fields: whether every referenced resource is
    /// servable by *this* server build, and which ones are not. A recipe can
    /// be production-quality while its declared external dependencies (e.g.
    /// the #14 stock plugin catalog) are absent from the running build;
    /// clients must check `dependencies_resolved` before executing.
    var dependenciesResolved: Bool?
    var unresolvedResources: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
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
        case dependenciesResolved = "dependencies_resolved"
        case unresolvedResources = "unresolved_resources"
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
    static let allowedConfirmationLevels: Set<String> = ["L1", "L2"]

    static func validate(
        _ workflows: [WorkflowSkill],
        toolNames: Set<String> = WorkflowSkillCatalog.currentToolNames(),
        commandCensus: [String: Set<String>] = WorkflowSkillCatalog.publicCommands,
        staticResourceURIs: Set<String> = WorkflowSkillCatalog.currentStaticResourceURIs(),
        templateURIs: Set<String> = WorkflowSkillCatalog.currentTemplateURIs()
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
            for (depIndex, dep) in workflow.dependsOn.enumerated()
                where !WorkflowSkillCatalog.isValidDependencyRoot(dep) {
                issues.append(issue(
                    "invalid_dependency",
                    "\(base).depends_on[\(depIndex)]",
                    "dependency \(dep) must be a logic://<host> URI root"
                ))
            }
            validateResourceRefs(
                workflow.allowedResources,
                workflow: workflow,
                path: "\(base).allowed_resources",
                staticResourceURIs: staticResourceURIs,
                templateURIs: templateURIs,
                issues: &issues
            )
            for (checkIndex, check) in workflow.stateChecks.enumerated() {
                validateResourceRefs(
                    [check.resource],
                    workflow: workflow,
                    path: "\(base).state_checks[\(checkIndex)].resource",
                    staticResourceURIs: staticResourceURIs,
                    templateURIs: templateURIs,
                    issues: &issues
                )
            }

            let workflowCommands = Set(commandCensus
                .filter { workflow.allowedTools.contains($0.key) }
                .flatMap(\.value))
            for (confirmationIndex, confirmation) in workflow.requiredConfirmations.enumerated() {
                if !allowedConfirmationLevels.contains(confirmation.level) {
                    issues.append(issue(
                        "invalid_confirmation_level",
                        "\(base).required_confirmations[\(confirmationIndex)].level",
                        "confirmation level must be one of \(allowedConfirmationLevels.sorted().joined(separator: ", "))"
                    ))
                }
                for command in confirmation.requiredFor where !workflowCommands.contains(command) {
                    issues.append(issue(
                        "unknown_command",
                        "\(base).required_confirmations[\(confirmationIndex)].required_for",
                        "command \(command) is not a public command of the workflow's allowed tools"
                    ))
                }
            }

            let hasMutatingStep = workflow.steps.contains { $0.mutates }
            let mutating = workflow.mutationKind == .guardedMutation || hasMutatingStep
            if workflow.mutationKind == .readOnly && hasMutatingStep {
                issues.append(issue(
                    "mutation_kind_mismatch",
                    "\(base).mutation_kind",
                    "read_only workflows must not contain mutating steps"
                ))
            }
            if workflow.mutationKind == .guardedMutation && !hasMutatingStep {
                issues.append(issue(
                    "mutation_kind_mismatch",
                    "\(base).mutation_kind",
                    "guarded_mutation workflows must contain at least one mutating step"
                ))
            }
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
            if workflow.evidenceLevel == .liveVerified && (workflow.verification.liveEvidenceFile?.isEmpty ?? true) {
                issues.append(issue(
                    "live_verified_missing_evidence_file",
                    "\(base).verification.live_evidence_file",
                    "live_verified workflows must reference their evidence file"
                ))
            }

            for (stepIndex, step) in workflow.steps.enumerated() {
                let stepPath = "\(base).steps[\(stepIndex)]"
                if let tool = step.tool, !toolNames.contains(tool) {
                    issues.append(issue("unknown_tool", "\(stepPath).tool", "unknown MCP tool \(tool)"))
                }
                if let tool = step.tool {
                    if let command = step.command {
                        if let known = commandCensus[tool], !known.contains(command) {
                            issues.append(issue(
                                "unknown_command",
                                "\(stepPath).command",
                                "\(command) is not a public command of \(tool)"
                            ))
                        }
                    } else if step.mutates {
                        issues.append(issue(
                            "mutating_step_missing_command",
                            stepPath,
                            "mutating tool steps must name the exact public command"
                        ))
                    }
                }
                if let resource = step.resource {
                    validateResourceRefs(
                        [resource],
                        workflow: workflow,
                        path: "\(stepPath).resource",
                        staticResourceURIs: staticResourceURIs,
                        templateURIs: templateURIs,
                        issues: &issues
                    )
                }
                if step.mutates {
                    if let level = step.requiresConfirmationLevel, !level.isEmpty {
                        if !allowedConfirmationLevels.contains(level) {
                            issues.append(issue(
                                "invalid_confirmation_level",
                                "\(stepPath).requires_confirmation_level",
                                "confirmation level must be one of \(allowedConfirmationLevels.sorted().joined(separator: ", "))"
                            ))
                        } else {
                            // Coverage is validated as an exact (level, command)
                            // pair: a command confirmed at L1 does not license an
                            // L2 step, and vice versa.
                            let sameLevel = workflow.requiredConfirmations.filter { $0.level == level }
                            if sameLevel.isEmpty {
                                issues.append(issue(
                                    "mutating_step_not_covered_by_confirmation",
                                    stepPath,
                                    "step confirmation level \(level) is not declared in required_confirmations"
                                ))
                            } else if let command = step.command,
                                      !sameLevel.contains(where: { $0.requiredFor.contains(command) }) {
                                issues.append(issue(
                                    "mutating_step_not_covered_by_confirmation",
                                    stepPath,
                                    "mutating command \(command) is not listed in a level-\(level) required_confirmations entry"
                                ))
                            }
                        }
                    } else {
                        issues.append(issue("mutating_step_missing_confirmation", stepPath, "mutating steps need confirmation level"))
                    }
                }
                if step.expectedResponseFields.isEmpty {
                    issues.append(issue("step_missing_success_fields", stepPath, "steps must name response fields to inspect"))
                }
            }
        }

        return WorkflowLintResult(isValid: issues.isEmpty, issues: issues)
    }

    /// A resource reference passes when it is servable by this build (exact
    /// static URI, a registered template, or a concrete instantiation of a
    /// registered template) or when it is covered by the workflow's declared
    /// external dependencies (`depends_on`). Anything else is a stale
    /// reference and fails the lint — there is no hand-maintained allowlist
    /// of phantom URIs.
    private static func validateResourceRefs(
        _ refs: [String],
        workflow: WorkflowSkill,
        path: String,
        staticResourceURIs: Set<String>,
        templateURIs: Set<String>,
        issues: inout [WorkflowLintIssue]
    ) {
        for ref in refs {
            if WorkflowSkillCatalog.resourceRefResolves(ref, staticURIs: staticResourceURIs, templateURIs: templateURIs) {
                continue
            }
            if WorkflowSkillCatalog.refCoveredByDependencies(ref, dependsOn: workflow.dependsOn) {
                continue
            }
            issues.append(issue("unknown_resource", path, "unknown MCP resource \(ref) (not servable and not declared in depends_on)"))
        }
    }

    private static func issue(_ code: String, _ path: String, _ message: String) -> WorkflowLintIssue {
        WorkflowLintIssue(code: code, path: path, message: message)
    }
}

enum WorkflowSkillCatalog {
    static func defaultSnapshot(now: Date = Date()) -> WorkflowSkillSnapshot {
        snapshot(now: now)
    }

    static func snapshot(
        now: Date = Date(),
        staticResourceURIs: Set<String> = currentStaticResourceURIs(),
        templateURIs: Set<String> = currentTemplateURIs()
    ) -> WorkflowSkillSnapshot {
        let workflows = defaultWorkflows().map { workflow in
            var resolved = workflow
            let unresolved = referencedResources(of: workflow).filter {
                !resourceRefResolves($0, staticURIs: staticResourceURIs, templateURIs: templateURIs)
            }
            resolved.dependenciesResolved = unresolved.isEmpty
            resolved.unresolvedResources = unresolved.isEmpty ? nil : unresolved.sorted()
            return resolved
        }
        let validation = WorkflowSkillLinter.validate(
            workflows,
            staticResourceURIs: staticResourceURIs,
            templateURIs: templateURIs
        )
        return WorkflowSkillSnapshot(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter.cacheFormatter.string(from: now),
            workflowCount: workflows.count,
            validation: validation,
            workflows: workflows
        )
    }

    static func referencedResources(of workflow: WorkflowSkill) -> [String] {
        var refs = Set(workflow.allowedResources)
        refs.formUnion(workflow.stateChecks.map(\.resource))
        refs.formUnion(workflow.steps.compactMap(\.resource))
        return Array(refs)
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
            "fields": WorkflowSkill.CodingKeys.allCases.map(\.rawValue),
            "computed_fields": [
                "dependencies_resolved",
                "unresolved_resources",
            ],
            "evidence_levels": WorkflowEvidenceLevel.allCases.map(\.rawValue),
            "mutation_kinds": [
                WorkflowMutationKind.readOnly.rawValue,
                WorkflowMutationKind.guardedMutation.rawValue,
            ],
            "confirmation_levels": WorkflowSkillLinter.allowedConfirmationLevels.sorted(),
            "lint_rules": [
                "duplicate_id",
                "missing_required_field",
                "unknown_tool",
                "unknown_command",
                "unknown_resource",
                "invalid_dependency",
                "invalid_confirmation_level",
                "mutation_kind_mismatch",
                "mutating_missing_confirmation",
                "mutating_missing_failure_modes",
                "mutating_step_missing_command",
                "mutating_step_missing_confirmation",
                "mutating_step_not_covered_by_confirmation",
                "production_mutation_without_live_evidence",
                "live_verified_missing_evidence_file",
                "step_missing_success_fields",
            ],
            "resources": [
                "logic://workflow-skills",
                "logic://workflow-skills/{id}",
                "logic://workflow-skills/search?query={query}",
                "logic://workflow-skills/schema",
            ],
            "read_only_surface": true,
        ]
    }

    static func currentToolNames() -> Set<String> {
        Set(publicCommands.keys)
    }

    /// Public command census per MCP tool. Error-only stubs ("not exposed in
    /// the production MCP contract") are deliberately excluded — a census
    /// command must actually execute, not merely parse. Kept in lockstep with
    /// the dispatcher `case` labels by `WorkflowCommandCensusTests`, which
    /// reads the dispatcher sources and fails when a census command
    /// disappears or degrades into a not-exposed stub.
    static let publicCommands: [String: Set<String>] = [
        "logic_transport": [
            "play", "stop", "record", "pause", "rewind", "fast_forward",
            "toggle_cycle", "toggle_metronome", "toggle_count_in",
            "set_tempo", "goto_position", "set_cycle_range",
        ],
        "logic_tracks": [
            "select", "create_audio", "create_instrument", "create_drummer",
            "create_external_midi", "delete", "duplicate", "rename",
            "mute", "solo", "arm", "arm_only", "record_sequence",
            "set_automation", "set_instrument",
            "resolve_path", "list_library", "scan_library", "scan_plugin_presets",
        ],
        "logic_mixer": [
            "set_volume", "set_pan", "set_master_volume",
            "insert_plugin", "set_plugin_param",
        ],
        "logic_midi": [
            "send_note", "send_chord", "play_sequence", "send_cc",
            "send_program_change", "send_pitch_bend", "send_aftertouch",
            "send_sysex", "import_file", "create_virtual_port",
            "mmc_play", "mmc_stop", "mmc_record", "mmc_locate", "step_input",
        ],
        "logic_edit": [
            "undo", "redo", "cut", "copy", "paste", "delete", "select_all",
            "split", "join", "quantize", "bounce_in_place", "normalize",
            "duplicate", "toggle_step_input",
        ],
        "logic_navigate": [
            "goto_bar", "goto_marker", "create_marker", "delete_marker",
            "rename_marker", "zoom_to_fit", "set_zoom", "toggle_view",
        ],
        "logic_project": [
            "new", "open", "save", "save_as", "close", "bounce",
            "is_running", "get_regions", "launch", "quit",
        ],
        "logic_system": [
            "health", "permissions", "refresh_cache", "help",
        ],
    ]

    static func currentStaticResourceURIs() -> Set<String> {
        Set(ResourceProvider.resources.map(\.uri))
    }

    static func currentTemplateURIs() -> Set<String> {
        Set(ResourceProvider.templates.map(\.uriTemplate))
    }

    // MARK: - Resource reference resolution

    static func resourceRefResolves(_ ref: String, staticURIs: Set<String>, templateURIs: Set<String>) -> Bool {
        if staticURIs.contains(ref) || templateURIs.contains(ref) { return true }
        return templateURIs.contains { template in refMatchesTemplate(ref, template: template) }
    }

    /// Declared external dependency roots must be well-formed `logic://host`
    /// URIs (optionally with a path). Bare schemes like `logic:` would
    /// otherwise cover the entire URI space and neuter the lint.
    static func isValidDependencyRoot(_ dep: String) -> Bool {
        dep.range(of: "^logic://[a-z0-9-]+(/[A-Za-z0-9._/-]+)?$", options: .regularExpression) != nil
    }

    static func refCoveredByDependencies(_ ref: String, dependsOn: [String]) -> Bool {
        dependsOn.filter(isValidDependencyRoot).contains { dep in
            ref == dep || ref.hasPrefix(dep + "/") || ref.hasPrefix(dep + "?")
        }
    }

    /// Matches a concrete or templated reference against a registered
    /// template URI. `{placeholder}` segments and query values match any
    /// non-empty concrete value (or an identical placeholder).
    static func refMatchesTemplate(_ ref: String, template: String) -> Bool {
        let refParts = ref.split(separator: "?", maxSplits: 1).map(String.init)
        let templateParts = template.split(separator: "?", maxSplits: 1).map(String.init)
        guard pathMatches(refParts[0], templatePath: templateParts[0]) else { return false }
        switch (refParts.count > 1 ? refParts[1] : nil, templateParts.count > 1 ? templateParts[1] : nil) {
        case (nil, nil):
            return true
        case let (refQuery?, templateQuery?):
            return queryMatches(refQuery, templateQuery: templateQuery)
        default:
            return false
        }
    }

    private static func pathMatches(_ refPath: String, templatePath: String) -> Bool {
        // Empty subsequences are kept so refs with doubled or trailing
        // slashes ("logic://mixer//3", "logic://mixer/3/") fail closed
        // instead of collapsing onto a template.
        let refSegments = refPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let templateSegments = templatePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard refSegments.count == templateSegments.count else { return false }
        return zip(refSegments, templateSegments).allSatisfy { refSegment, templateSegment in
            isPlaceholder(templateSegment) ? !refSegment.isEmpty : refSegment == templateSegment
        }
    }

    private static func queryMatches(_ refQuery: String, templateQuery: String) -> Bool {
        let refPairs = refQuery.split(separator: "&").map(String.init).sorted()
        let templatePairs = templateQuery.split(separator: "&").map(String.init).sorted()
        guard refPairs.count == templatePairs.count else { return false }
        return zip(refPairs, templatePairs).allSatisfy { refPair, templatePair in
            let refKV = refPair.split(separator: "=", maxSplits: 1).map(String.init)
            let templateKV = templatePair.split(separator: "=", maxSplits: 1).map(String.init)
            guard refKV.first == templateKV.first else { return false }
            let templateValue = templateKV.count > 1 ? templateKV[1] : ""
            let refValue = refKV.count > 1 ? refKV[1] : ""
            return isPlaceholder(templateValue) ? !refValue.isEmpty : refValue == templateValue
        }
    }

    private static func isPlaceholder(_ segment: String) -> Bool {
        segment.hasPrefix("{") && segment.hasSuffix("}") && segment.count > 2
    }

    // MARK: - Workflows

    private static func projectReadiness() -> WorkflowSkill {
        makeWorkflow(
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
        makeWorkflow(
            id: "logic.workflow.midi.idea_sketch",
            title: "MIDI Idea Sketch",
            intent: "Create or import a small MIDI idea only after the target track and project state are explicit.",
            scope: "May write MIDI to a caller-specified target after confirmation; never guesses track 0.",
            prerequisites: ["Open project", "Explicit target track", "User confirmation for MIDI mutation"],
            allowedTools: ["logic_tracks", "logic_midi"],
            allowedResources: ["logic://tracks", "logic://tracks/{index}/regions", "logic://project/info"],
            requiredConfirmations: [
                WorkflowConfirmation(level: "L1", requiredFor: ["import_file", "record_sequence"], message: "Confirm target track and MIDI content before writing."),
            ],
            stateChecks: [
                stateCheck("tracks", "logic://tracks", ["data"], true),
                stateCheck("regions_before", "logic://tracks/{index}/regions", ["regions"], false),
            ],
            steps: [
                readStep("read_tracks", "Read tracks before target selection", "logic://tracks", ["data"]),
                toolStep("write_midi", "Import MIDI file for the explicit target", "logic_midi", command: "import_file", true, "L1", ["success", "verified"], ["unverified target", "invalid channel"]),
                readStep("regions_after", "Read regions after write", "logic://tracks/{index}/regions", ["regions"]),
            ],
            verification: WorkflowVerification(evidence: ["before_regions", "after_regions", "tool_envelope"], successFields: ["region_count_delta", "verified"], liveEvidenceFile: nil),
            failureModes: ["target track missing", "selection unverified", "MIDI import rejected", "post-write region readback unavailable"],
            rollbackOrRecovery: "Manual recovery: undo in Logic if write succeeded but follow-up verification is inconclusive.",
            evidenceLevel: .deterministic,
            productionReady: false,
            dependsOn: [],
            limitations: [
                "Not production-ready until a scoped live mutation run is recorded.",
                "logic_tracks record_sequence is the alternative guarded write for captured sequences; it carries the same L1 confirmation requirement.",
            ],
            mutationKind: .guardedMutation
        )
    }

    private static func arrangementMarkerPlan() -> WorkflowSkill {
        makeWorkflow(
            id: "logic.workflow.arrangement.marker_plan",
            title: "Arrangement Marker Plan",
            intent: "Plan and verify marker positions without relying on stale parser assumptions.",
            scope: "Read-first marker planning; mutation remains guarded and optional.",
            prerequisites: ["Open project", "Marker resource readable"],
            allowedTools: ["logic_navigate"],
            allowedResources: ["logic://markers", "logic://transport/state"],
            requiredConfirmations: [
                WorkflowConfirmation(level: "L1", requiredFor: ["create_marker", "rename_marker"], message: "Confirm marker names and positions before writing."),
            ],
            stateChecks: [stateCheck("markers", "logic://markers", ["data"], false)],
            steps: [
                readStep("read_markers", "Read current markers", "logic://markers", ["data", "position_source"]),
                toolStep("optional_write", "Optionally create a marker at the playhead", "logic_navigate", command: "create_marker", true, "L1", ["success", "verified"], ["unsupported marker mutation", "position parse failure"]),
            ],
            verification: WorkflowVerification(evidence: ["marker_resource_before_after"], successFields: ["canonical_position", "verified"], liveEvidenceFile: nil),
            failureModes: ["marker resource unavailable", "position parser rejects input", "post-write readback unavailable"],
            rollbackOrRecovery: "Manual recovery in Logic marker list.",
            evidenceLevel: .deterministic,
            productionReady: false,
            dependsOn: [],
            limitations: [
                "delete_marker and indexed goto_marker are keycmd-only on Logic 12.2 (manual MIDI Learn binding required; see SETUP §4.1) and are intentionally not part of this recipe.",
            ],
            mutationKind: .guardedMutation
        )
    }

    private static func gainStagingPrep() -> WorkflowSkill {
        makeWorkflow(
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
                toolStep("optional_level_write", "Optionally write volume with explicit track", "logic_mixer", command: "set_volume", true, "L1", ["success", "verified", "reason"], ["target unverified", "readback unavailable"]),
                readStep("read_strip_after", "Read target strip after write", "logic://mixer/{strip}", ["data_source", "strip"]),
            ],
            verification: WorkflowVerification(evidence: ["mixer_before_after", "honest_contract_envelope"], successFields: ["verified", "data_source"], liveEvidenceFile: nil),
            failureModes: ["mixer_not_visible", "cache_stale", "track selection unverified", "echo timeout"],
            rollbackOrRecovery: "Manual recovery: restore previous fader/pan value from before evidence.",
            evidenceLevel: .deterministic,
            productionReady: false,
            dependsOn: [],
            limitations: [
                "Stops instead of writing when provenance is insufficient.",
                "set_pan is a relative V-Pot write on the MCU path (pan_write_mode: relative_vpot); do not treat it as an absolute target setter.",
            ],
            mutationKind: .guardedMutation
        )
    }

    private static func stockPluginChainPlan() -> WorkflowSkill {
        makeWorkflow(
            id: "logic.workflow.plugins.stock_chain_plan",
            title: "Stock Plugin Chain Planning",
            intent: "Plan stock plugin chains from verified catalog metadata without claiming insertion success.",
            scope: "Planning-only in this release; no plugin insertion is executed.",
            prerequisites: ["Stock plugin catalog resource readable", "Mixer slot state available if planning against a track"],
            allowedTools: [],
            allowedResources: ["logic://stock-plugins", "logic://stock-plugins/{id}", "logic://stock-plugins/search?query={query}", "logic://mixer"],
            requiredConfirmations: [],
            stateChecks: [
                stateCheck("catalog", "logic://stock-plugins", ["entries", "validation"], true),
                stateCheck("mixer", "logic://mixer", ["strips"], false),
            ],
            steps: [
                readStep("read_catalog", "Read stock plugin catalog", "logic://stock-plugins", ["entries", "availability_state"]),
                readStep("search_catalog", "Search catalog for user intent", "logic://stock-plugins/search?query={query}", ["entries"]),
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
        makeWorkflow(
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
                "logic://stock-plugins/{id}",
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
                    command: "insert_plugin",
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
        makeWorkflow(
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
            limitations: ["Does not perform a bounce/export; project.bounce is keycmd-only on Logic 12.2."],
            mutationKind: .readOnly
        )
    }

    // MARK: - Builders

    private static func makeWorkflow(
        id: String,
        title: String,
        intent: String,
        scope: String,
        prerequisites: [String],
        allowedTools: [String],
        allowedResources: [String],
        requiredConfirmations: [WorkflowConfirmation],
        stateChecks: [WorkflowStateCheck],
        steps: [WorkflowStep],
        verification: WorkflowVerification,
        failureModes: [String],
        rollbackOrRecovery: String,
        evidenceLevel: WorkflowEvidenceLevel,
        productionReady: Bool,
        dependsOn: [String],
        limitations: [String],
        mutationKind: WorkflowMutationKind
    ) -> WorkflowSkill {
        WorkflowSkill(
            id: id,
            title: title,
            intent: intent,
            scope: scope,
            prerequisites: prerequisites,
            allowedTools: allowedTools,
            allowedResources: allowedResources,
            requiredConfirmations: requiredConfirmations,
            stateChecks: stateChecks,
            steps: steps,
            verification: verification,
            failureModes: failureModes,
            rollbackOrRecovery: rollbackOrRecovery,
            evidenceLevel: evidenceLevel,
            productionReady: productionReady,
            dependsOn: dependsOn,
            limitations: limitations,
            mutationKind: mutationKind,
            dependenciesResolved: nil,
            unresolvedResources: nil
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
            command: nil,
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
        command: String,
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
            command: command,
            resource: nil,
            mutates: mutates,
            requiresConfirmationLevel: level,
            expectedResponseFields: fields,
            stopConditions: stops
        )
    }
}
