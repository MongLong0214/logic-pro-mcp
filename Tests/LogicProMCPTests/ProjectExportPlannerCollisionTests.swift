import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Project export planner")
struct ProjectExportPlannerCollisionTests {
    @Test("plans every project in a batch with distinct per-project indices and namespaced step ids")
    func multiProjectBatchPlan() throws {
        let alpha = try makeExportPlannerProject(named: "Alpha Song")
        let beta = try makeExportPlannerProject(named: "Beta Song")
        let outputRoot = try makeExportPlannerDirectory()

        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(alpha.path), .string(beta.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
        ])

        #expect(plan.projectCount == 2)
        #expect(plan.projects.count == 2)
        let p0 = try #require(plan.projects.first)
        let p1 = try #require(plan.projects.last)
        #expect(p0.index == 0)
        #expect(p1.index == 1)
        #expect(p0.displayName == "Alpha Song")
        #expect(p1.displayName == "Beta Song")
        #expect(p0.projectPath == alpha.path)
        #expect(p1.projectPath == beta.path)
        #expect(p0.workflowSteps.map(\.id) == ["project_0_open", "project_0_bounce_export"])
        #expect(p1.workflowSteps.map(\.id) == ["project_1_open", "project_1_bounce_export"])
        let allIDs = (p0.workflowSteps + p1.workflowSteps).map(\.id)
        #expect(Set(allIDs).count == allIDs.count)
        #expect(try #require(p0.expectedArtifacts.first).path.hasSuffix("/Alpha-Song-bounce.wav"))
        #expect(try #require(p1.expectedArtifacts.first).path.hasSuffix("/Beta-Song-bounce.wav"))
        #expect(!(try #require(p0.expectedArtifacts.first)).verification.issues.contains("artifact_path_collides_in_plan"))
    }

    @Test("two projects with the same basename in different dirs collide and degrade the plan")
    func sameBasenameCrossProjectCollision() throws {
        let dirA = try makeExportPlannerDirectory()
        let dirB = try makeExportPlannerDirectory()
        let songA = dirA.appendingPathComponent("Song").appendingPathExtension("logicx")
        let songB = dirB.appendingPathComponent("Song").appendingPathExtension("logicx")
        try FileManager.default.createDirectory(at: songA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: songB, withIntermediateDirectories: true)
        let outputRoot = try makeExportPlannerDirectory()

        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(songA.path), .string(songB.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
        ])

        #expect(plan.status == "degraded")
        let a0 = try #require(plan.projects.first?.expectedArtifacts.first)
        let a1 = try #require(plan.projects.last?.expectedArtifacts.first)
        #expect(a0.verification.issues.contains("artifact_path_collides_in_plan"))
        #expect(a1.verification.issues.contains("artifact_path_collides_in_plan"))
    }

    @Test("case-only-different basenames collide on the case-insensitive default volume")
    func caseInsensitiveCrossProjectCollision() throws {
        let dirA = try makeExportPlannerDirectory()
        let dirB = try makeExportPlannerDirectory()
        let songA = dirA.appendingPathComponent("Song").appendingPathExtension("logicx")
        let songB = dirB.appendingPathComponent("song").appendingPathExtension("logicx")
        try FileManager.default.createDirectory(at: songA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: songB, withIntermediateDirectories: true)
        let outputRoot = try makeExportPlannerDirectory()

        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(songA.path), .string(songB.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
        ])

        #expect(plan.status == "degraded")
        let a0 = try #require(plan.projects.first?.expectedArtifacts.first)
        let a1 = try #require(plan.projects.last?.expectedArtifacts.first)
        #expect(a0.verification.issues.contains("artifact_path_collides_in_plan"))
        #expect(a1.verification.issues.contains("artifact_path_collides_in_plan"))
    }

    @Test("the same project listed twice collides with itself and degrades the plan")
    func duplicateProjectEntryCollision() throws {
        let project = try makeExportPlannerProject(named: "Dup Song")
        let outputRoot = try makeExportPlannerDirectory()

        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(project.path), .string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
        ])

        #expect(plan.status == "degraded")
        #expect(plan.projects.allSatisfy { project in
            project.expectedArtifacts.allSatisfy {
                $0.verification.issues.contains("artifact_path_collides_in_plan")
            }
        })
    }

    @Test("an existing artifact whose attributes are unreadable is flagged unreadable, not zero-byte")
    func unreadableArtifactSizeIsNotZeroByte() throws {
        let project = try makeExportPlannerProject(named: "Unreadable Song")
        let outputRoot = try makeExportPlannerDirectory()
        let existing = outputRoot.appendingPathComponent("Unreadable-Song-bounce.wav")
        try Data("non-empty".utf8).write(to: existing)

        let plan = try ProjectExportPlanner.plan(
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("bounce"),
            ],
            fileManager: UnreadableAttributesFileManager()
        )

        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        #expect(artifact.verification.exists)
        #expect(artifact.verification.fileSizeBytes == nil)
        #expect(artifact.verification.issues.contains("artifact_size_unreadable"))
        #expect(!artifact.verification.issues.contains("artifact_zero_bytes"))
    }

    @Test("skip_existing suppresses overwrite flagging for a pre-existing artifact")
    func skipExistingCollisionPolicy() throws {
        let project = try makeExportPlannerProject(named: "Skip Song")
        let outputRoot = try makeExportPlannerDirectory()
        let existing = outputRoot.appendingPathComponent("Skip-Song-bounce.wav")
        try Data("non-empty".utf8).write(to: existing)

        let plan = try ProjectExportPlanner.plan(params: [
            "project": .string(project.path),
            "output_root": .string(outputRoot.path),
            "artifact": .string("bounce"),
            "collision_policy": .string("skip_existing"),
        ])
        let artifact = try #require(plan.projects.first?.expectedArtifacts.first)
        #expect(artifact.verification.exists)
        #expect(!artifact.verification.wouldOverwrite)
        #expect(!artifact.verification.issues.contains("artifact_would_overwrite"))
        #expect(plan.collisionPolicy == "skip_existing")
        #expect(plan.status == "planned")
    }

    @Test("invalid collision_policy is rejected")
    func invalidCollisionPolicyRejected() {
        #expect(throws: ExportPlanError.self) {
            _ = try ProjectExportPlanner.plan(params: [
                "project": .string("/tmp/Nope.logicx"),
                "output_root": .string("/tmp/out"),
                "collision_policy": .string("overwrite"),
            ])
        }
    }
}
