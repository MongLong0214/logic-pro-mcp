import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func workflowResourceObject(_ uri: String) async throws -> [String: Any] {
    let result = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
    return try #require(sharedJSONObject(sharedResourceText(result)))
}

@Suite("Workflow skills pack")
struct WorkflowSkillCatalogTests {
    @Test("linter rejects stale tool and resource references")
    func staleReferencesRejected() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows()[0]
        workflow.allowedTools = ["logic_missing"]
        workflow.allowedResources = ["logic://missing"]

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "unknown_tool" })
        #expect(issues.contains { $0.code == "unknown_resource" })
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

    @Test("production-ready mutating workflows must be live verified")
    func productionReadyRequiresLiveEvidence() {
        var workflow = WorkflowSkillCatalog.defaultWorkflows().first { $0.id == "logic.workflow.midi.idea_sketch" }!
        workflow.productionReady = true
        workflow.evidenceLevel = .deterministic

        let issues = WorkflowSkillLinter.validate([workflow]).issues
        #expect(issues.contains { $0.code == "production_mutation_without_live_evidence" })
    }

    @Test("default workflow pack validates and includes stock plugin catalog dependency")
    func defaultPackValidates() {
        let snapshot = WorkflowSkillCatalog.defaultSnapshot()

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.workflowCount >= 6)
        #expect(snapshot.validation.isValid, "workflow pack should validate: \(snapshot.validation.issues)")
        let stock = snapshot.workflows.first { $0.id == "logic.workflow.plugins.stock_chain_plan" }
        #expect(stock?.dependsOn.contains("logic://stock-plugins") == true)
        #expect(stock?.allowedResources.contains("logic://stock-plugins") == true)
        #expect(stock?.mutationKind == .readOnly)

        let liveInsert = snapshot.workflows.first { $0.id == "logic.workflow.plugins.stock_insert_gain_live_verified" }
        #expect(liveInsert?.mutationKind == .guardedMutation)
        #expect(liveInsert?.evidenceLevel == .liveVerified)
        #expect(liveInsert?.productionReady == true)
        #expect(liveInsert?.verification.liveEvidenceFile == "docs/tickets/mixer-verification/VERIFICATION-2026-06-09.md")
        #expect(liveInsert?.requiredConfirmations.contains { $0.level == "L2" } == true)
    }

    @Test("MCP resources expose workflow list, detail, search, and schema")
    func workflowResources() async throws {
        let list = try await workflowResourceObject("logic://workflow-skills")
        #expect(list["schema_version"] as? Int == 1)
        #expect(list["workflow_count"] as? Int ?? 0 >= 6)
        #expect((list["validation"] as? [String: Any])?["is_valid"] as? Bool == true)

        let detail = try await workflowResourceObject("logic://workflow-skills/logic.workflow.readiness.project")
        #expect((detail["workflow"] as? [String: Any])?["id"] as? String == "logic.workflow.readiness.project")

        let search = try await workflowResourceObject("logic://workflow-skills/search?query=plugin")
        #expect((search["workflows"] as? [[String: Any]])?.contains {
            $0["id"] as? String == "logic.workflow.plugins.stock_chain_plan"
        } == true)
        #expect((search["workflows"] as? [[String: Any]])?.contains {
            $0["id"] as? String == "logic.workflow.plugins.stock_insert_gain_live_verified"
        } == true)

        let schema = try await workflowResourceObject("logic://workflow-skills/schema")
        #expect((schema["required_fields"] as? [String])?.contains("state_checks") == true)
        #expect((schema["evidence_levels"] as? [String])?.contains("live_verified") == true)
    }
}
