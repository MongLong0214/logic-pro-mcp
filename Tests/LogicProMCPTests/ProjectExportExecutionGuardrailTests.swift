import Foundation
import Testing
@testable import LogicProMCP

@Suite("Project export guardrails")
struct ProjectExportExecutionGuardrailTests {
    @Test("fail_if_exists never overwrites an existing artifact (fails closed)")
    func failIfExistsNeverOverwrites() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Collide Song")
        let bouncePath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Collide Song", kind: "bounce")

        try writeToneWav(at: URL(fileURLWithPath: bouncePath))
        let originalSize = (try FileManager.default.attributesOfItem(atPath: bouncePath)[.size] as? NSNumber)?.int64Value ?? 0

        let openFired = BoolFlag()
        let bounceFired = BoolFlag()
        let router = await makeExportRouter(
            openSideEffect: { openFired.set() },
            bounceSideEffect: {
                bounceFired.set()
                _ = try? writeToneWav(at: URL(fileURLWithPath: bouncePath), durationSeconds: 1.0)
            }
        )
        let options = fastOptions(identity: { project.path })

        let run = await ProjectExportExecutor.run(
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                "artifacts": .array([.string("bounce")]),
                "collision_policy": .string("fail_if_exists"),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options
        )

        #expect(run.status == "failed")
        #expect(run.artifactsFailed == 1)
        #expect(run.artifactsVerified == 0)
        #expect(run.nextSafeAction == "none_terminal")
        let runProject = try #require(run.projects.first)
        #expect(!runProject.opened)
        let artifact = try #require(runProject.artifacts.first)
        #expect(artifact.state == "C")
        #expect(!artifact.verified)
        let error = try #require(artifact.error)
        #expect(error.contains("overwrite_blocked"))
        #expect(!openFired.isSet)
        #expect(!bounceFired.isSet)
        let afterSize = (try FileManager.default.attributesOfItem(atPath: bouncePath)[.size] as? NSNumber)?.int64Value ?? -1
        #expect(afterSize == originalSize)
    }

    @Test("confirmed:false fails closed with confirmation_required and no side effects")
    func confirmedFalseFailsClosed() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Unconfirmed Song")
        let bouncePath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Unconfirmed Song", kind: "bounce")

        let anyChannelOp = BoolFlag()
        let router = await makeExportRouter(bounceSideEffect: {
            anyChannelOp.set()
            _ = try? writeToneWav(at: URL(fileURLWithPath: bouncePath))
        })
        let options = fastOptions(identity: { project.path })

        let run = await ProjectExportExecutor.run(
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                "artifacts": .array([.string("bounce")]),
            ],
            router: router,
            resume: false,
            options: options
        )

        #expect(run.status == "confirmation_required")
        #expect(!run.confirmed)
        #expect(run.artifactsFailed == 1)
        #expect(run.artifactsVerified == 0)
        #expect(run.nextSafeAction == "none_terminal")
        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "C")
        #expect(artifact.error == "confirmation_required")
        #expect(!anyChannelOp.isSet)
        #expect(!FileManager.default.fileExists(atPath: bouncePath))
    }

    @Test("open failure fails closed and never bounces")
    func openFailureFailsClosed() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Unopenable Song")

        let bounceFired = BoolFlag()
        let router = await makeExportRouter(openSucceeds: false, bounceSideEffect: { bounceFired.set() })
        let options = fastOptions(identity: { project.path })

        let run = await ProjectExportExecutor.run(
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                "artifacts": .array([.string("bounce")]),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options
        )

        #expect(run.status == "failed")
        #expect(run.nextSafeAction == "none_terminal")
        let runProject = try #require(run.projects.first)
        #expect(!runProject.opened)
        #expect(!runProject.identityVerified)
        let artifact = try #require(runProject.artifacts.first)
        #expect(artifact.state == "C")
        let error = try #require(artifact.error)
        #expect(error.contains("open_failed"))
        #expect(!bounceFired.isSet)
    }

    @Test("helper-produced artifacts that escape via output-root symlink swap fail closed")
    func helperArtifactOutputRootSymlinkSwapFailsClosed() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let escapedRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Escaped Song")
        let plannedPath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Escaped Song", kind: "bounce")
        let producedPath = (plannedPath as NSString).deletingPathExtension + ".aif"

        let router = await makeExportRouter()
        var options = fastOptions(identity: { project.path })
        options.bounceToPath = { _ in
            try? FileManager.default.removeItem(at: outputRoot)
            try? FileManager.default.createSymbolicLink(at: outputRoot, withDestinationURL: escapedRoot)
            try? writeToneWav(at: URL(fileURLWithPath: producedPath))
            return .success(producedPath)
        }

        let run = await ProjectExportExecutor.run(
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                "artifacts": .array([.string("bounce")]),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: false,
            options: options
        )

        #expect(run.status == "failed")
        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "C")
        #expect(artifact.bounceFired)
        // The surfaced State-C error code is `artifact_path_unsafe:` (the
        // internal reason `unsafe_path` is wrapped by the flow); assert the code
        // the caller actually sees. Prior `unsafe_path` check was dead.
        let artifactError = try #require(artifact.error)
        #expect(artifactError.contains("artifact_path_unsafe"))
    }

    @Test("every non-completed export outcome terminates without a review or retry request")
    func nonCompletedOutcomesAreTerminal() throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Terminal Song")
        let plan = try ProjectExportPlanner.plan(params: [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
        ])

        func artifact(state: String, verified: Bool, bounceFired: Bool) -> ProjectExportRunArtifact {
            ProjectExportRunArtifact(
                kind: "bounce",
                path: outputRoot.appendingPathComponent(UUID().uuidString).path,
                state: state,
                verified: verified,
                bounceFired: bounceFired,
                writeAttempted: bounceFired,
                error: state == "C" ? "bounded_failure" : nil,
                reason: state == "B" ? "readback_unavailable" : nil,
                evidence: nil
            )
        }

        func aggregate(_ artifacts: [ProjectExportRunArtifact]) -> ProjectExportRunResult {
            ProjectExportExecutor.aggregate(
                plan: plan,
                resume: false,
                projects: [
                    ProjectExportRunProject(
                        index: 0,
                        projectPath: project.path,
                        displayName: "Terminal Song",
                        observedProjectPath: project.path,
                        identityVerified: true,
                        opened: true,
                        artifacts: artifacts
                    ),
                ]
            )
        }

        let partial = aggregate([
            artifact(state: "A", verified: true, bounceFired: true),
            artifact(state: "C", verified: false, bounceFired: false),
        ])
        #expect(partial.status == "partial")
        #expect(partial.nextSafeAction == "none_terminal")

        let uncertain = aggregate([
            artifact(state: "B", verified: false, bounceFired: true),
        ])
        #expect(uncertain.status == "uncertain")
        #expect(uncertain.nextSafeAction == "none_terminal")

        let completed = aggregate([
            artifact(state: "A", verified: true, bounceFired: true),
        ])
        #expect(completed.status == "completed")
        #expect(completed.nextSafeAction == "verify_artifacts_with_logic_audio")

        let unsupportedStem = ProjectExportExecutor.unsupportedStemResumeRun(plan: plan)
        #expect(unsupportedStem.nextSafeAction == "none_terminal")
        let unsupportedError = try #require(unsupportedStem.projects.first?.artifacts.first?.error)
        #expect(unsupportedError.hasPrefix("export_resume_unsupported_for_stem:"))
        #expect(!unsupportedError.localizedCaseInsensitiveContains("re-run"))
        #expect(!unsupportedError.localizedCaseInsensitiveContains("retry"))

        let failed = ProjectExportExecutor.failedRun(
            runID: plan.runID,
            mode: "run",
            confirmed: true,
            outputRoot: plan.outputRoot,
            collisionPolicy: plan.collisionPolicy,
            reason: "invalid_params"
        )
        #expect(failed.nextSafeAction == "none_terminal")
        #expect(failed.diagnostic == "invalid_params")
        let failedJSON = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(failed)
        ) as? [String: Any])
        #expect(failedJSON["diagnostic"] as? String == "invalid_params")
    }
}
