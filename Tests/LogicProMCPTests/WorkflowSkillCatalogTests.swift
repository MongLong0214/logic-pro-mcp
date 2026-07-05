import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func workflowResourceObject(_ uri: String) async throws -> [String: Any] {
    let result = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
    return try #require(sharedJSONObject(sharedResourceText(result)))
}

private func workflowResourceThrows(_ uri: String) async -> Bool {
    do {
        _ = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
        return false
    } catch {
        return true
    }
}

private var workflowRepoRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Suite("Workflow skills pack — linter")
struct WorkflowSkillLinterTests {
    @Test("linter rejects stale tool and resource references")
    func staleReferencesRejected() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows()[0]
        workflow.allowedTools = ["logic_missing"]
        workflow.allowedResources = ["logic://missing"]

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "unknown_tool" })
        #expect(issues.contains { $0.code == "unknown_resource" })
    }

    @Test("linter rejects unknown commands in steps and confirmations")
    func unknownCommandsRejected() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.requiredConfirmations = [
            WorkflowConfirmation(level: "L1", requiredFor: ["midi_import"], message: "stale command name"),
        ]
        workflow.steps = workflow.steps.map { step in
            guard step.mutates else { return step }
            return WorkflowStep(
                id: step.id,
                title: step.title,
                operationType: step.operationType,
                tool: "logic_midi",
                command: "midi_import",
                resource: nil,
                mutates: true,
                requiresConfirmationLevel: "L1",
                expectedResponseFields: step.expectedResponseFields,
                stopConditions: step.stopConditions
            )
        }

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.filter { $0.code == "unknown_command" }.count >= 2,
                "midi_import is not a real command and must fail in both required_for and step.command: \(issues)")
    }

    @Test("mutating tool steps must name their command")
    func mutatingStepsRequireCommand() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.steps = workflow.steps.map { step in
            guard step.mutates else { return step }
            return WorkflowStep(
                id: step.id,
                title: step.title,
                operationType: step.operationType,
                tool: step.tool,
                command: nil,
                resource: nil,
                mutates: true,
                requiresConfirmationLevel: step.requiresConfirmationLevel,
                expectedResponseFields: step.expectedResponseFields,
                stopConditions: step.stopConditions
            )
        }

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "mutating_step_missing_command" })
    }

    @Test("mutating workflows require confirmation metadata and failure modes")
    func mutatingWorkflowGuardrails() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.requiredConfirmations = []
        workflow.failureModes = []

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "mutating_missing_confirmation" })
        #expect(issues.contains { $0.code == "mutating_missing_failure_modes" })
    }

    @Test("mutation_kind must agree with step mutability in both directions")
    func mutationKindConsistencyLinted() {
        var liar = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        liar.mutationKind = .readOnly
        let readOnlyLie = WorkflowSkillLinter.validate([liar]).issues
        #expect(readOnlyLie.contains { $0.code == "mutation_kind_mismatch" })

        var hollow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.readiness.project" }!
        hollow.mutationKind = .guardedMutation
        let guardedLie = WorkflowSkillLinter.validate([hollow]).issues
        #expect(guardedLie.contains { $0.code == "mutation_kind_mismatch" })
    }

    @Test("confirmation levels are restricted to L1 and L2")
    func confirmationLevelsValidated() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.requiredConfirmations = [
            WorkflowConfirmation(level: "L9", requiredFor: ["import_file"], message: "bogus level"),
        ]

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "invalid_confirmation_level" })
    }

    @Test("mutating steps must be covered by a declared confirmation")
    func mutatingStepConfirmationCoverage() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.requiredConfirmations = [
            WorkflowConfirmation(level: "L2", requiredFor: ["record_sequence"], message: "covers a different level"),
        ]

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "mutating_step_not_covered_by_confirmation" },
                "step level L1 is undeclared: \(issues)")
    }

    @Test("confirmation coverage is an exact (level, command) pair")
    func confirmationCoverageIsPairwise() {
        // import_file is confirmed — but only at L1, while the step demands
        // L2. Independent set-based checks would pass this; pair validation
        // must reject it.
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.requiredConfirmations = [
            WorkflowConfirmation(level: "L1", requiredFor: ["import_file"], message: "right command, wrong level"),
            WorkflowConfirmation(level: "L2", requiredFor: ["record_sequence"], message: "right level, wrong command"),
        ]
        workflow.steps = workflow.steps.map { step in
            guard step.mutates else { return step }
            return WorkflowStep(
                id: step.id,
                title: step.title,
                operationType: step.operationType,
                tool: step.tool,
                command: step.command,
                resource: nil,
                mutates: true,
                requiresConfirmationLevel: "L2",
                expectedResponseFields: step.expectedResponseFields,
                stopConditions: step.stopConditions
            )
        }

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "mutating_step_not_covered_by_confirmation" },
                "L2 step with import_file confirmed only at L1 must fail: \(issues)")
    }

    @Test("dependency roots must be well-formed logic:// URIs")
    func dependencyRootsValidated() {
        #expect(WorkflowSkillCatalog.isValidDependencyRoot("logic://stock-plugins"))
        #expect(!WorkflowSkillCatalog.isValidDependencyRoot("logic:"))
        #expect(!WorkflowSkillCatalog.isValidDependencyRoot("logic:/"))
        #expect(!WorkflowSkillCatalog.isValidDependencyRoot("logic://"))
        #expect(!WorkflowSkillCatalog.isValidDependencyRoot("http://evil"))
        #expect(!WorkflowSkillCatalog.refCoveredByDependencies("logic://anything/at/all", dependsOn: ["logic:"]),
                "a bare scheme must not cover the whole URI space")

        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.readiness.project" }!
        workflow = WorkflowSkill(
            id: workflow.id,
            title: workflow.title,
            intent: workflow.intent,
            scope: workflow.scope,
            prerequisites: workflow.prerequisites,
            allowedTools: workflow.allowedTools,
            allowedResources: workflow.allowedResources,
            requiredConfirmations: workflow.requiredConfirmations,
            stateChecks: workflow.stateChecks,
            steps: workflow.steps,
            verification: workflow.verification,
            failureModes: workflow.failureModes,
            rollbackOrRecovery: workflow.rollbackOrRecovery,
            evidenceLevel: workflow.evidenceLevel,
            productionReady: workflow.productionReady,
            dependsOn: ["logic:"],
            limitations: workflow.limitations,
            mutationKind: workflow.mutationKind,
            dependenciesResolved: nil,
            unresolvedResources: nil
        )
        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "invalid_dependency" })
    }

    @Test("production-ready mutating workflows must be live verified")
    func productionReadyRequiresLiveEvidence() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.productionReady = true
        workflow.evidenceLevel = .deterministic

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "production_mutation_without_live_evidence" })
    }

    @Test("live_verified workflows must reference an evidence file")
    func liveVerifiedRequiresEvidenceFile() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.evidenceLevel = .liveVerified

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "live_verified_missing_evidence_file" })
    }

    @Test("undeclared external resources fail the lint; declared ones pass")
    func externalDependencyDeclarationRequired() {
        let undeclared = WorkflowSkillLinter.validate(
            WorkflowSkillCatalog.defaultWorkflows().filter { $0.id == "logic.workflow.plugins.stock_chain_plan" },
            staticResourceURIs: ["logic://mixer"],
            templateURIs: []
        )
        #expect(undeclared.isValid, "stock URIs are declared via depends_on and must pass: \(undeclared.issues)")

        var stripped = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.plugins.stock_chain_plan" }!
        stripped = WorkflowSkill(
            id: stripped.id,
            title: stripped.title,
            intent: stripped.intent,
            scope: stripped.scope,
            prerequisites: stripped.prerequisites,
            allowedTools: stripped.allowedTools,
            allowedResources: stripped.allowedResources,
            requiredConfirmations: stripped.requiredConfirmations,
            stateChecks: stripped.stateChecks,
            steps: stripped.steps,
            verification: stripped.verification,
            failureModes: stripped.failureModes,
            rollbackOrRecovery: stripped.rollbackOrRecovery,
            evidenceLevel: stripped.evidenceLevel,
            productionReady: stripped.productionReady,
            dependsOn: [],
            limitations: stripped.limitations,
            mutationKind: stripped.mutationKind,
            dependenciesResolved: nil,
            unresolvedResources: nil
        )
        let issues = WorkflowSkillLinter.validate(
            [stripped],
            staticResourceURIs: ["logic://mixer"],
            templateURIs: []
        ).issues
        #expect(issues.contains { $0.code == "unknown_resource" },
                "without depends_on, phantom stock URIs must fail the lint")
    }
}

@Suite("Workflow skills pack — catalog")
struct WorkflowSkillCatalogTests {
    @Test("template matching resolves concrete and templated references")
    func templateMatching() {
        let templates: Set<String> = [
            "logic://tracks/{index}/regions",
            "logic://mixer/{strip}",
            "logic://stock-plugins/{id}",
            "logic://stock-plugins/search?query={query}",
            "logic://workflow-plans/session?prompt={prompt}",
        ]

        #expect(WorkflowSkillCatalog.resourceRefResolves("logic://mixer/{strip}", staticURIs: [], templateURIs: templates))
        #expect(WorkflowSkillCatalog.resourceRefResolves("logic://mixer/3", staticURIs: [], templateURIs: templates))
        #expect(WorkflowSkillCatalog.resourceRefResolves("logic://tracks/0/regions", staticURIs: [], templateURIs: templates))
        #expect(WorkflowSkillCatalog.resourceRefResolves("logic://stock-plugins/logic.stock.effect.gain", staticURIs: [], templateURIs: templates))
        #expect(WorkflowSkillCatalog.resourceRefResolves("logic://stock-plugins/search?query=reverb", staticURIs: [], templateURIs: templates))
        #expect(WorkflowSkillCatalog.resourceRefResolves("logic://workflow-plans/session?prompt=16-bar-funk", staticURIs: [], templateURIs: templates))
        #expect(!WorkflowSkillCatalog.resourceRefResolves("logic://stock-plugins", staticURIs: [], templateURIs: templates))
        #expect(!WorkflowSkillCatalog.resourceRefResolves("logic://mixer/3/extra", staticURIs: [], templateURIs: templates))
        #expect(!WorkflowSkillCatalog.resourceRefResolves("logic://stock-plugins/search?other=x", staticURIs: [], templateURIs: templates))
        #expect(!WorkflowSkillCatalog.resourceRefResolves("logic://workflow-plans/session?other=x", staticURIs: [], templateURIs: templates))
        #expect(!WorkflowSkillCatalog.resourceRefResolves("logic://mixer/3/", staticURIs: [], templateURIs: templates),
                "trailing slash must fail closed")
        #expect(!WorkflowSkillCatalog.resourceRefResolves("logic://mixer//3", staticURIs: [], templateURIs: templates),
                "doubled slash must fail closed")
        // Bare /search structurally matches the {id} template — and the live
        // surface does serve it (empty-query search), so it must resolve.
        #expect(WorkflowSkillCatalog.resourceRefResolves("logic://stock-plugins/search", staticURIs: [], templateURIs: templates))
    }

    @Test("default workflow pack validates and stays honest about unresolved dependencies")
    func defaultPackValidates() throws {
        let snapshot = WorkflowSkillCatalog.defaultSnapshot()

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.workflowCount >= 6)
        #expect(snapshot.validation.isValid, "workflow pack should validate: \(snapshot.validation.issues)")

        let stockSurfacePresent = WorkflowSkillCatalog.currentStaticResourceURIs().contains("logic://stock-plugins")
        let stock = snapshot.workflows.first { $0.id == "logic.workflow.plugins.stock_chain_plan" }
        #expect((stock?.dependsOn.contains("logic://stock-plugins"))!)
        #expect(stock?.mutationKind == .readOnly)
        #expect(stock?.dependenciesResolved == stockSurfacePresent,
                "stock dependency honesty must follow the actual served resource surface")
        if stockSurfacePresent {
            #expect(stock?.unresolvedResources == nil)
        } else {
            #expect((stock?.unresolvedResources?.allSatisfy { $0.hasPrefix("logic://stock-plugins") })!)
        }

        let liveInsert = snapshot.workflows.first { $0.id == "logic.workflow.plugins.stock_insert_gain_live_verified" }
        #expect(liveInsert?.mutationKind == .guardedMutation)
        #expect(liveInsert?.evidenceLevel == .liveVerified)
        #expect((liveInsert?.productionReady)!)
        #expect(liveInsert?.dependenciesResolved == stockSurfacePresent)
        #expect(liveInsert?.verification.liveEvidenceFile == "CHANGELOG.md")
        #expect((liveInsert?.requiredConfirmations.contains { $0.level == "L2" })!)

        let readiness = snapshot.workflows.first { $0.id == "logic.workflow.readiness.project" }
        #expect((readiness?.dependenciesResolved)!)
        #expect(readiness?.unresolvedResources == nil)

        let exportPlan = try #require(snapshot.workflows.first { $0.id == "logic.workflow.export.batch_plan" })
        #expect(exportPlan.mutationKind == .readOnly)
        #expect(exportPlan.productionReady)
        #expect(exportPlan.evidenceLevel == .deterministic)
        #expect(exportPlan.steps.contains { $0.tool == "logic_project" && $0.command == "export_plan" })
    }

    @Test("default workflows declare required fields that match served top-level resource shapes")
    func defaultWorkflowRequiredFieldsMatchResourceShapes() {
        let workflows = WorkflowSkillCatalog.defaultWorkflows()

        func workflow(_ id: String) throws -> WorkflowSkill {
            try #require(workflows.first { $0.id == id }, "missing workflow \(id)")
        }
        func stepFields(_ workflow: WorkflowSkill, _ stepID: String) throws -> [String] {
            try #require(workflow.steps.first { $0.id == stepID }, "missing step \(stepID)").expectedResponseFields
        }
        func checkFields(_ workflow: WorkflowSkill, _ checkID: String) throws -> [String] {
            try #require(workflow.stateChecks.first { $0.id == checkID }, "missing state check \(checkID)").requiredFields
        }

        let midi = try! workflow("logic.workflow.midi.idea_sketch")
        #expect(try! checkFields(midi, "regions_before").isEmpty)
        #expect(try! stepFields(midi, "regions_after").isEmpty)

        let markers = try! workflow("logic.workflow.arrangement.marker_plan")
        #expect(try! stepFields(markers, "read_markers") == ["data"])

        let stockPlan = try! workflow("logic.workflow.plugins.stock_chain_plan")
        #expect(try! stepFields(stockPlan, "read_catalog") == ["entries", "validation"])

        let guardedInsert = try! workflow("logic.workflow.plugins.stock_insert_gain_live_verified")
        #expect(try! stepFields(guardedInsert, "read_gain_catalog") == ["entry", "validation"])
        #expect(try! stepFields(guardedInsert, "read_mixer_slots") == ["strips", "data_source"])
        #expect(try! stepFields(guardedInsert, "read_strip_after_insert") == ["strip"])

        let exportPlan = try! workflow("logic.workflow.export.batch_plan")
        #expect(try! stepFields(exportPlan, "plan_exports") == ["schema", "projects", "baseline_verification", "required_confirmations"])
        let sessionPlan = try! workflow("logic.workflow.composition.session_plan")
        #expect(try! stepFields(sessionPlan, "read_session_plan") == ["schema", "parsed_intent", "sections", "chord_plan", "track_plan", "workflow_steps"])
        #expect(sessionPlan.mutationKind == .readOnly)
        #expect(sessionPlan.productionReady)

    }

    @Test("dependencies resolve once the stock plugin surface exists")
    func dependenciesResolveWithStockSurface() {
        let augmentedStatics = WorkflowSkillCatalog.currentStaticResourceURIs().union(["logic://stock-plugins"])
        let augmentedTemplates = WorkflowSkillCatalog.currentTemplateURIs().union([
            "logic://stock-plugins/{id}",
            "logic://stock-plugins/search?query={query}",
        ])
        let snapshot = WorkflowSkillCatalog.snapshot(
            staticResourceURIs: augmentedStatics,
            templateURIs: augmentedTemplates
        )

        #expect(snapshot.validation.isValid)
        #expect(snapshot.workflows.allSatisfy { $0.dependenciesResolved == true },
                "with #14 merged, every workflow must resolve: \(snapshot.workflows.compactMap(\.unresolvedResources))")
    }

    @Test("every mutating step in the default pack names a real public command")
    func defaultPackCommandsAreReal() {
        for workflow in WorkflowSkillCatalog.defaultWorkflows() {
            for step in workflow.steps where step.mutates {
                let tool = try? #require(step.tool)
                let command = try? #require(step.command)
                if let tool, let command {
                    #expect((WorkflowSkillCatalog.publicCommands[tool]?.contains(command))!,
                            "\(workflow.id) step \(step.id) references \(tool).\(command)")
                }
            }
        }
    }

    @Test("live evidence files referenced by the default pack exist in the repo")
    func liveEvidenceFilesExist() throws {
        for workflow in WorkflowSkillCatalog.defaultWorkflows() {
            guard let evidence = workflow.verification.liveEvidenceFile else { continue }
            let path = workflowRepoRoot.appendingPathComponent(evidence).path
            #expect(FileManager.default.fileExists(atPath: path),
                    "\(workflow.id) references missing evidence file \(evidence)")
        }
    }

    @Test("schema fields mirror the WorkflowSkill coding keys")
    func schemaMatchesCodingKeys() {
        let schema = WorkflowSkillCatalog.schema()
        let fields = schema["fields"] as? [String]
        #expect(fields == WorkflowSkill.CodingKeys.allCases.map(\.rawValue))
        #expect((schema["confirmation_levels"] as? [String]) == ["L1", "L2"])
        #expect(((schema["lint_rules"] as? [String])?.contains("unknown_command"))!)
        #expect(((schema["lint_rules"] as? [String])?.contains("invalid_dependency"))!)
    }
}

@Suite("Workflow skills pack — command census")
struct WorkflowCommandCensusTests {
    // Every MCP tool dispatcher. `logic_plugins` was missing before #111,
    // which let the entire tool drift out of the census undetected.
    private static let dispatcherFiles: [String: String] = [
        "logic_transport": "TransportDispatcher.swift",
        "logic_tracks": "TrackDispatcher.swift",
        "logic_mixer": "MixerDispatcher.swift",
        "logic_midi": "MIDIDispatcher.swift",
        "logic_edit": "EditDispatcher.swift",
        "logic_navigate": "NavigateDispatcher.swift",
        "logic_project": "ProjectDispatcher.swift",
        "logic_system": "SystemDispatcher.swift",
        "logic_audio": "AudioDispatcher.swift",
        "logic_plugins": "PluginsDispatcher.swift",
    ]

    // Command-switch labels that intentionally execute an error-only
    // "not exposed in the production MCP contract" stub. They are real labels
    // but must NOT be in the public census.
    private static let notExposedStubs: [String: Set<String>] = [
        "logic_tracks": ["set_color"],
        "logic_mixer": ["set_send", "set_output", "set_input", "toggle_eq", "reset_strip", "bypass_plugin"],
    ]

    // Convenience aliases that route to a censused command via the same
    // `case "canonical", "alias":` label. The alias is not separately public.
    private static let knownAliases: [String: Set<String>] = [
        "logic_tracks": ["library"], // alias of list_library
    ]

    /// Extract the executable command labels from a dispatcher source. Most
    /// dispatchers use a top-level `switch command { ... }`; `EditDispatcher`
    /// also has a command route table for boilerplate-free forwarding. Both
    /// forms are executable surfaces and must stay reconciled with the public
    /// workflow census.
    private static func executableCommandLabels(in source: String) throws -> Set<String> {
        try commandSwitchLabels(in: source).union(routeTableLabels(in: source))
    }

    /// Extract the string labels of the top-level `switch command { ... }`
    /// block in a dispatcher source. Isolated by indentation: the command
    /// switch and its `case` labels sit at the same column; every nested
    /// switch (zoom direction, view name, help category, error-code) is
    /// indented deeper and therefore excluded.
    private static func commandSwitchLabels(in source: String) throws -> Set<String> {
        let lines = source.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        let switchIndex = try #require(
            lines.firstIndex { $0.contains("switch command {") },
            "no `switch command {` in dispatcher source"
        )
        let switchIndent = indent(lines[switchIndex])
        var labels: Set<String> = []
        var i = switchIndex + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineIndent = indent(line)
            // The switch's own closing brace sits at the switch's column.
            if trimmed == "}" && lineIndent == switchIndent { break }
            if lineIndent == switchIndent && trimmed.hasPrefix("case ") {
                // Pull every "literal" token from the (possibly multi-label) case.
                var rest = Substring(trimmed)
                while let open = rest.firstIndex(of: "\"") {
                    let afterOpen = rest.index(after: open)
                    guard let close = rest[afterOpen...].firstIndex(of: "\"") else { break }
                    labels.insert(String(rest[afterOpen..<close]))
                    rest = rest[rest.index(after: close)...]
                }
            }
            i += 1
        }
        return labels
    }

    private static func routeTableLabels(in source: String) -> Set<String> {
        let lines = source.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        guard let tableIndex = lines.firstIndex(where: { $0.contains("routedCommands") && $0.contains("[") }) else {
            return []
        }
        let tableIndent = indent(lines[tableIndex])
        var labels: Set<String> = []
        var i = tableIndex + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineIndent = indent(line)
            if trimmed == "]" && lineIndent == tableIndent { break }
            if trimmed.hasPrefix("\""), let colon = trimmed.firstIndex(of: ":") {
                let prefix = trimmed[..<colon]
                if let close = prefix.dropFirst().firstIndex(of: "\"") {
                    labels.insert(String(prefix[prefix.index(after: prefix.startIndex)..<close]))
                }
            }
            i += 1
        }
        return labels
    }

    private func labels(forTool tool: String) throws -> Set<String> {
        let file = try #require(Self.dispatcherFiles[tool], "no dispatcher source mapped for \(tool)")
        let url = workflowRepoRoot
            .appendingPathComponent("Sources/LogicProMCP/Dispatchers")
            .appendingPathComponent(file)
        let source = try String(contentsOf: url, encoding: .utf8)
        return try Self.executableCommandLabels(in: source)
    }

    @Test("every MCP tool dispatcher is mapped and censused")
    func everyToolMappedAndCensused() {
        // Census keys and dispatcher mappings must cover exactly the same tools.
        let censusTools = Set(WorkflowSkillCatalog.publicCommands.keys)
        let mappedTools = Set(Self.dispatcherFiles.keys)
        let message = "census tools \(censusTools.sorted()) ≠ mapped dispatchers \(mappedTools.sorted())"
        #expect(censusTools == mappedTools, "\(message)")
    }

    @Test("every census command exists as an executable dispatcher label")
    func censusCommandsAreExecutable() throws {
        for (tool, commands) in WorkflowSkillCatalog.publicCommands {
            let dispatcherLabels = try labels(forTool: tool)
            for command in commands.sorted() {
                #expect(dispatcherLabels.contains(command),
                        "census command \(tool).\(command) is not an executable label in its dispatcher")
            }
            // A census command must actually execute, not degrade into a stub.
            let file = Self.dispatcherFiles[tool]!
            let url = workflowRepoRoot
                .appendingPathComponent("Sources/LogicProMCP/Dispatchers")
                .appendingPathComponent(file)
            let source = try String(contentsOf: url, encoding: .utf8)
            for command in commands.sorted() {
                guard let caseRange = source.range(of: "case \"\(command)\"") else { continue }
                let bodyEnd = source.index(caseRange.upperBound, offsetBy: 240, limitedBy: source.endIndex) ?? source.endIndex
                let body = source[caseRange.upperBound..<bodyEnd]
                #expect(!body.contains("not exposed in the production MCP contract"),
                        "census command \(tool).\(command) is a not-exposed stub in \(file)")
            }
        }
    }

    @Test("#111: every dispatcher command label is censused, a known stub, or a known alias")
    func everyDispatcherLabelIsClassified() throws {
        for tool in Self.dispatcherFiles.keys.sorted() {
            let dispatcherLabels = try labels(forTool: tool)
            let census = WorkflowSkillCatalog.publicCommands[tool] ?? []
            let stubs = Self.notExposedStubs[tool] ?? []
            let aliases = Self.knownAliases[tool] ?? []
            let classified = census.union(stubs).union(aliases)
            let unclassified = dispatcherLabels.subtracting(classified)
            let message = "\(tool) exposes command label(s) \(unclassified.sorted()) that are neither in the "
                + "public census, the not-exposed stub list, nor the known-alias list — "
                + "classify them so the workflow census cannot silently drift (#111)"
            #expect(unclassified.isEmpty, "\(message)")
        }
    }

    @Test("declared not-exposed stubs exist and are excluded from the census")
    func notExposedStubsExcluded() throws {
        for (tool, stubs) in Self.notExposedStubs {
            let dispatcherLabels = try labels(forTool: tool)
            for command in stubs.sorted() {
                #expect(dispatcherLabels.contains(command),
                        "declared stub \(tool).\(command) is no longer an executable dispatcher label")
                #expect(!((WorkflowSkillCatalog.publicCommands[tool]?.contains(command))!),
                        "\(tool).\(command) returns a not-exposed error and must not be in the census")
            }
        }
    }

    @Test("#111 regression: logic_plugins and project export/cleanup execution commands are censused")
    func newlyCensusedCommandsPresent() {
        // These were missing before #111 and let the census claim to be the
        // pinned public surface while omitting real production commands.
        #expect(WorkflowSkillCatalog.publicCommands["logic_plugins"]
            == ["get_inventory", "set_param_verified", "insert_verified"])
        let project = WorkflowSkillCatalog.publicCommands["logic_project"] ?? []
        for command in ["export_run", "export_resume", "cleanup_apply"] {
            #expect(project.contains(command),
                    "logic_project.\(command) executes in the dispatcher + is documented in API.md but is missing from the census")
        }
    }
}

@Suite("Workflow skills pack — resources")
struct WorkflowSkillResourceTests {
    @Test("MCP resources expose workflow list, detail, search, and schema")
    func workflowResources() async throws {
        let list = try await workflowResourceObject("logic://workflow-skills")
        #expect(list["schema_version"] as? Int == 1)
        #expect(list["workflow_count"] as? Int ?? 0 >= 6)
        #expect(((list["validation"] as? [String: Any])?["is_valid"] as? Bool)!)

        let detail = try await workflowResourceObject("logic://workflow-skills/logic.workflow.readiness.project")
        #expect((detail["workflow"] as? [String: Any])?["id"] as? String == "logic.workflow.readiness.project")
        #expect(((detail["workflow"] as? [String: Any])?["dependencies_resolved"] as? Bool)!)

        let stockDetail = try await workflowResourceObject("logic://workflow-skills/logic.workflow.plugins.stock_insert_gain_live_verified")
        let stockSurfacePresent = WorkflowSkillCatalog.currentStaticResourceURIs().contains("logic://stock-plugins")
        #expect((stockDetail["workflow"] as? [String: Any])?["dependencies_resolved"] as? Bool == stockSurfacePresent,
                "stock-dependent workflow must disclose dependency state from the actual served surface")
        if stockSurfacePresent {
            #expect((stockDetail["workflow"] as? [String: Any])?["unresolved_resources"] == nil)
        } else {
            #expect(!((((stockDetail["workflow"] as? [String: Any])?["unresolved_resources"] as? [String])?.isEmpty)!))
        }

        let search = try await workflowResourceObject("logic://workflow-skills/search?query=plugin")
        #expect(((search["workflows"] as? [[String: Any]])?.contains {
            $0["id"] as? String == "logic.workflow.plugins.stock_chain_plan"
        })!)
        #expect(((search["workflows"] as? [[String: Any]])?.contains {
            $0["id"] as? String == "logic.workflow.plugins.stock_insert_gain_live_verified"
        })!)

        let exportSearch = try await workflowResourceObject("logic://workflow-skills/search?query=export")
        let exportWorkflows = try #require(exportSearch["workflows"] as? [[String: Any]])
        #expect(exportWorkflows.contains {
            $0["id"] as? String == "logic.workflow.export.batch_plan"
        })

        let compositionSearch = try await workflowResourceObject("logic://workflow-skills/search?query=session")
        let compositionWorkflows = try #require(compositionSearch["workflows"] as? [[String: Any]])
        #expect(compositionWorkflows.contains {
            $0["id"] as? String == "logic.workflow.composition.session_plan"
        })

        let schema = try await workflowResourceObject("logic://workflow-skills/schema")
        #expect(((schema["fields"] as? [String])?.contains("state_checks"))!)
        #expect(((schema["evidence_levels"] as? [String])?.contains("live_verified"))!)
    }

    @Test("workflow skill URI routing fails closed on malformed inputs")
    func workflowRoutingFailsClosed() async {
        let malformed = [
            "logic://workflow-skills?query=x",
            "logic://workflow-skills/%73chema",
            "logic://workflow-skills/search?qu%65ry=plugin",
            "logic://workflow-skills/search?query=%ZZ",
            "logic://workflow-skills/search/extra",
            "logic://workflow-skills/search?other=x",
            "logic://workflow-skills/search?query=plugin&query=marker",
            "logic://workflow-skills/logic.workflow.readiness.project?x=1",
            "logic://workflow-skills/logic.workflow.readiness.project/extra",
            "logic://workflow-skills/unknown.workflow.id",
            "logic://workflow-skills/schema?x=1",
            "logic://workflow-skills//schema",
            "logic://workflow-skills/schema/",
            "logic://workflow-skills/schema#fragment",
            "logic://workflow-skills/search?query=plugin#fragment",
            "logic://workflow-skills/logic.workflow.readiness.project#fragment",
        ]
        for uri in malformed {
            #expect(await workflowResourceThrows(uri), "expected fail-closed read for \(uri)")
        }
    }

    @Test("search query is percent-decoded exactly once")
    func searchQuerySingleDecode() async throws {
        let search = try await workflowResourceObject("logic://workflow-skills/search?query=a%252Bb")
        #expect(search["query"] as? String == "a%2Bb")

        let plus = try await workflowResourceObject("logic://workflow-skills/search?query=a%2Bb")
        #expect(plus["query"] as? String == "a+b")
    }
}
