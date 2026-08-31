import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Project export planner")
struct ProjectExportPlannerTests {
    @Test("builds a dry-run export manifest without executing workflow steps")
    func dryRunManifestPlan() throws {
        let project = try makeExportPlannerProject(named: "Planner Song")
        let outputRoot = try makeExportPlannerDirectory()

        // PR99-T2: snapshot the output dir to prove the dry run mutates no files,
        // rather than trusting the hardcoded `executed: false` flag.
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: outputRoot.path))

        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("stem"), .string("bounce")]),
        ], stemSubjects: .scanned(
            projectPath: project.path,
            subjects: [ProjectExportStemSubject(index: 0, name: "Planner Piano")]
        ))

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: outputRoot.path))
        #expect(before == after)

        #expect(plan.schema == "logic_pro_mcp_export_manifest.v1")
        #expect(plan.status == "planned")
        #expect(plan.executionMode == "dry_run_only")
        #expect(plan.projectCount == 1)
        #expect(plan.projects.first?.validationStatus == "valid")
        #expect(plan.projects.first?.manifestStatus == "pending")
        // C3: run-window anchor is present and non-empty so the advertised
        // mtime_within_run_window gate has something to bound against.
        #expect(!plan.generatedAt.isEmpty)
        #expect(plan.baselineVerification.contains("mtime_within_run_window"))
        let l2 = try #require(plan.requiredConfirmations.first { $0.level == "L2" })
        #expect(l2.requiredFor.contains("open"))
        #expect(l2.requiredFor.contains("bounce"))
        #expect(l2.requiredFor.contains("export_run"))
        #expect(!l2.requiredFor.contains("close"))
        #expect(!plan.requiredConfirmations.contains { $0.requiredFor.contains("close") })
        #expect(!plan.unsupportedOrBlockedSteps.map(\.operation).contains("export_run"))
        #expect(plan.unsupportedOrBlockedSteps.map(\.operation).contains("export_resume"))
        #expect(plan.unsupportedOrBlockedSteps.map(\.operation) == ["cloud_delivery", "export_resume"])
        #expect(plan.baselineVerification.contains("artifact_exists"))
        #expect(plan.baselineVerification.contains("no_silent_overwrite"))

        let artifacts = try #require(plan.projects.first?.expectedArtifacts)
        #expect(artifacts.map(\.kind) == ["bounce", "stem"])
        let firstArtifact = try #require(artifacts.first)
        #expect(firstArtifact.path.hasSuffix("/Planner-Song-bounce.wav"))
        #expect(artifacts.allSatisfy { $0.verification.pathUnderOutputRoot })
        #expect(artifacts.allSatisfy { $0.status == "pending" })
        // PR99-T2: no .wav was actually written for the planned artifact.
        #expect(!FileManager.default.fileExists(atPath: firstArtifact.path))

        let steps = try #require(plan.projects.first?.workflowSteps)
        #expect(steps.allSatisfy { !$0.executed })
        let openStep = try #require(steps.first { $0.command == "open" })
        let bounceStep = try #require(steps.first { $0.command == "bounce" })
        let stemStep = try #require(steps.first { $0.id == "project_0_stem_export" })
        #expect(openStep.requiresConfirmationLevel == "L2")
        #expect(bounceStep.requiresConfirmationLevel == "L2")
        #expect(stemStep.requiresConfirmationLevel == "L2")
        #expect(!steps.contains { $0.command == "close" })
        #expect(stemStep.command == nil)
        #expect(stemStep.title.contains("no standalone stem command"))
        #expect(steps.map(\.command) == ["open", "bounce", nil])
    }

    @Test("#369: surfaces the bounce step's execution preconditions in the manifest")
    func surfacesBounceExecutionPreconditions() throws {
        let project = try makeExportPlannerProject(named: "Precondition Song")
        let outputRoot = try makeExportPlannerDirectory()

        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("stem")]),
        ], stemSubjects: .scanned(
            projectPath: project.path,
            subjects: [ProjectExportStemSubject(index: 0, name: "Populated Piano")]
        ))

        // The plan must no longer be silent about what the run needs: every
        // precondition names the execution command it gates.
        #expect(plan.executionPreconditions.map(\.requirement)
            == ["accessibility_export_panel"])
        #expect(plan.executionPreconditions.allSatisfy { $0.appliesToCommands == ["export_run"] })
        #expect(plan.executionPreconditions.allSatisfy { !$0.verifyWith.isEmpty })

        let panel = try #require(
            plan.executionPreconditions.first { $0.requirement == "accessibility_export_panel" }
        )
        #expect(panel.detail.contains("One File per Track"))
        #expect(panel.detail.contains("does not use project.bounce"))
        #expect(panel.detail.contains("keyboard-driven bounce helper"))
        #expect(panel.detail.contains("no output format is selected or promised"))
        #expect(panel.detail.contains("execution-time precondition"))
    }

    @Test("#369: execution preconditions encode with snake_case keys and survive round-trip")
    func executionPreconditionsEncodeWithSnakeCaseKeys() throws {
        let project = try makeExportPlannerProject(named: "Encode Song")
        let outputRoot = try makeExportPlannerDirectory()
        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
        ])

        let data = try JSONEncoder().encode(plan)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let preconditions = try #require(object["execution_preconditions"] as? [[String: Any]])
        #expect(preconditions.count == 4)
        let first = try #require(preconditions.first)
        #expect(first["requirement"] as? String == "automation_permission")
        #expect(first["applies_to_commands"] as? [String] == ["bounce"])
        let verifyWith = try #require(first["verify_with"] as? String)
        #expect(!verifyWith.isEmpty)

        // Round-trips back into the model unchanged.
        let decoded = try JSONDecoder().decode(ProjectExportPlan.self, from: data)
        #expect(decoded.executionPreconditions == plan.executionPreconditions)
    }

    @Test("reports collision and zero-byte artifact risks without mutating files")
    func collisionAndZeroByteRisks() throws {
        let project = try makeExportPlannerProject(named: "Collision Song")
        let outputRoot = try makeExportPlannerDirectory()
        let existingArtifact = outputRoot.appendingPathComponent("Collision-Song-bounce.wav")
        try Data().write(to: existingArtifact)

        let plan = try ProjectExportPlanner.plan(params: [
            "project": .string(project.path),
            "output_root": .string(outputRoot.path),
            "artifact": .string("bounce"),
        ])

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        #expect(plan.status == "degraded")
        #expect(artifact.status == "existing")
        #expect(artifact.verification.exists)
        #expect(artifact.verification.fileSizeBytes == 0)
        #expect(artifact.verification.wouldOverwrite)
        #expect(artifact.verification.issues.contains("artifact_would_overwrite"))
        #expect(artifact.verification.issues.contains("artifact_zero_bytes"))
    }

    @Test("rejects invalid parameter shapes before producing a plan")
    func rejectsInvalidParams() {
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string("/tmp/Nope.logicx"),
                "output_root": .string("relative/out"),
            ])
        }
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string("/tmp/Nope.logicx"),
                "output_root": .string("/tmp/out"),
                "artifacts": .array([.string("cloud_upload")]),
            ])
        }
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "projects": .array([]),
                "output_root": .string("/tmp/out"),
            ])
        }
    }

    @Test("dispatcher returns manifest JSON and never routes channels")
    func dispatcherDoesNotRoute() async throws {
        let project = try makeExportPlannerProject(named: "Dispatcher Song")
        let outputRoot = try makeExportPlannerDirectory()
        let router = ChannelRouter()
        let keyCmd = MockChannel(id: .midiKeyCommands)
        let appleScript = MockChannel(id: .appleScript)
        await router.register(keyCmd)
        await router.register(appleScript)

        let before = Set(try FileManager.default.contentsOfDirectory(atPath: outputRoot.path))
        let result = await ProjectDispatcher.handle(
            command: "export_plan",
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
            ],
            router: router,
            cache: StateCache()
        )
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: outputRoot.path))
        #expect(before == after)

        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
        let data = try #require(sharedToolText(result).data(using: .utf8))
        let plan = try JSONDecoder().decode(ProjectExportPlan.self, from: data)
        #expect(plan.schema == ProjectExportPlanner.schema)
        #expect(plan.executionMode == "dry_run_only")
        #expect(await keyCmd.executedOps.isEmpty)
        #expect(await appleScript.executedOps.isEmpty)
    }

    @Test("manifest advertises only the steps export_run actually executes")
    func manifestOnlyAdvertisesExecutableRunSteps() throws {
        let project = try makeExportPlannerProject(named: "Executable Song")
        let outputRoot = try makeExportPlannerDirectory()

        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
        ])

        let steps = try #require(plan.projects.first?.workflowSteps)
        #expect(steps.map(\.command) == ["open", "bounce"])
        #expect(!plan.requiredConfirmations.contains { $0.requiredFor.contains("close") })
    }
}
