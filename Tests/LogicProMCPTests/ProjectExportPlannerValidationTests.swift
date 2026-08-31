import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Project export planner")
struct ProjectExportPlannerValidationTests {
    @Test("run_id is deterministic, prefixed, and input-sensitive")
    func runIDContractIsStable() throws {
        let project = try makeExportPlannerProject(named: "RunID Song")
        let outputRoot = try makeExportPlannerDirectory()
        let params: [String: Value] = [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce"), .string("preview")]),
        ]

        let a = try ProjectExportPlanner.plan(params: params)
        let b = try ProjectExportPlanner.plan(params: params)
        #expect(a.runID.hasPrefix("export-"))
        #expect(a.runID.count > "export-".count)
        #expect(a.runID == b.runID)

        let otherRoot = try makeExportPlannerDirectory()
        let c = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(project.path)]),
            "output_root": .string(otherRoot.path),
            "artifacts": .array([.string("bounce"), .string("preview")]),
        ])
        #expect(c.runID != a.runID)

        let otherProject = try makeExportPlannerProject(named: "Other Song")
        let d = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(otherProject.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce"), .string("preview")]),
        ])
        #expect(d.runID != a.runID)
    }

    @Test("missing but well-formed project path degrades the plan without throwing")
    func missingProjectDegradesPlan() throws {
        let outputRoot = try makeExportPlannerDirectory()
        let missing = outputRoot.appendingPathComponent("Missing-Song.logicx").path

        let plan = try ProjectExportPlanner.plan(params: [
            "project": .string(missing),
            "output_root": .string(outputRoot.path),
            "artifact": .string("bounce"),
        ])

        #expect(plan.status == "degraded")
        let project = try #require(plan.projects.first)
        #expect(project.validationStatus == "invalid")
        #expect(project.validationIssues.contains("project_path_not_found"))
        #expect(!project.validationIssues.contains("project_path_must_be_absolute_logicx"))
    }

    @Test("dispatcher fails closed on invalid export_plan params")
    func dispatcherFailsClosedOnInvalidParams() async throws {
        let router = ChannelRouter()
        let keyCmd = MockChannel(id: .midiKeyCommands)
        await router.register(keyCmd)

        let result = await ProjectDispatcher.handle(
            command: "export_plan",
            params: [
                "projects": .array([.string("/tmp/Nope.logicx")]),
                "output_root": .string("relative/out"),
            ],
            router: router,
            cache: StateCache()
        )

        #expect(result.isError!)
        #expect(sharedToolText(result).contains("invalid_params"))
        #expect(await keyCmd.executedOps.isEmpty)
    }

    @Test("dispatcher fails closed on empty projects array")
    func dispatcherFailsClosedOnEmptyProjects() async throws {
        let router = ChannelRouter()
        let keyCmd = MockChannel(id: .midiKeyCommands)
        await router.register(keyCmd)

        let result = await ProjectDispatcher.handle(
            command: "export_plan",
            params: [
                "projects": .array([]),
                "output_root": .string("/tmp/out"),
            ],
            router: router,
            cache: StateCache()
        )

        #expect(result.isError!)
        #expect(sharedToolText(result).contains("invalid_params"))
        #expect(await keyCmd.executedOps.isEmpty)
    }

    @Test("non-empty existing artifact flags overwrite but not zero-byte and reports true size")
    func nonEmptyExistingArtifactRisk() throws {
        let project = try makeExportPlannerProject(named: "NonEmpty Song")
        let outputRoot = try makeExportPlannerDirectory()
        let existingArtifact = outputRoot.appendingPathComponent("NonEmpty-Song-bounce.wav")
        try Data([0x01, 0x02]).write(to: existingArtifact)

        let plan = try ProjectExportPlanner.plan(params: [
            "project": .string(project.path),
            "output_root": .string(outputRoot.path),
            "artifact": .string("bounce"),
        ])

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        #expect(artifact.verification.exists)
        #expect(artifact.verification.fileSizeBytes == 2)
        #expect(artifact.verification.wouldOverwrite)
        #expect(artifact.verification.issues.contains("artifact_would_overwrite"))
        #expect(!artifact.verification.issues.contains("artifact_zero_bytes"))
        #expect(!artifact.verification.issues.contains("artifact_size_unreadable"))
    }

    @Test("single project param is trimmed so it matches the array branch normalization")
    func singleProjectParamIsTrimmed() throws {
        let project = try makeExportPlannerProject(named: "Trim Song")
        let outputRoot = try makeExportPlannerDirectory()

        let trimmed = try ProjectExportPlanner.plan(params: [
            "project": .string(project.path),
            "output_root": .string(outputRoot.path),
            "artifact": .string("bounce"),
        ])
        let padded = try ProjectExportPlanner.plan(params: [
            "project": .string("  \(project.path)  "),
            "output_root": .string(outputRoot.path),
            "artifact": .string("bounce"),
        ])

        #expect(trimmed.projects.first?.projectPath == project.path)
        #expect(padded.projects.first?.projectPath == project.path)
        #expect(trimmed.runID == padded.runID)
        #expect(padded.projects.first?.validationStatus == "valid")
    }

    @Test("output_root resolving to a system location via traversal is rejected")
    func outputRootSystemTraversalRejected() {
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string("/tmp/Nope.logicx"),
                "output_root": .string("/Users/x/../../etc/out"),
            ])
        }
    }

    @Test("output_root resolving through a symlinked system location is rejected")
    func outputRootSymlinkedSystemLocationRejected() throws {
        let tempRoot = try makeExportPlannerDirectory()
        let symlink = tempRoot.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "/etc")

        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string("/tmp/Nope.logicx"),
                "output_root": .string(symlink.path),
            ])
        }
    }

    @Test("existing regular-file output_root is rejected")
    func outputRootExistingFileRejected() throws {
        let project = try makeExportPlannerProject(named: "File Root Song")
        let tempRoot = try makeExportPlannerDirectory()
        let fileRoot = tempRoot.appendingPathComponent("exports.txt")
        try Data("not a directory".utf8).write(to: fileRoot)

        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string(project.path),
                "output_root": .string(fileRoot.path),
            ])
        }
    }

    @Test("filesystem-root output_root is rejected")
    func outputRootFilesystemRootRejected() {
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string("/tmp/Nope.logicx"),
                "output_root": .string("/"),
            ])
        }
    }

    @Test("unsupported naming_policy is rejected instead of being silently ignored")
    func unsupportedNamingPolicyRejected() throws {
        let project = try makeExportPlannerProject(named: "Naming Policy Song")
        let outputRoot = try makeExportPlannerDirectory()

        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "naming_policy": .string("flat-kind-only"),
            ])
        }
    }
}
