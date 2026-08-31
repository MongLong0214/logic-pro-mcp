import Foundation
import Testing
@testable import LogicProMCP

@Suite("Project export guarded execution")
struct ProjectExportExecutionTests {
    @Test("full run opens, verifies identity, bounces, and records each artifact as State A")
    func fullRunVerifiesAndRecords() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Run Song")
        let bouncePath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Run Song", kind: "bounce")

        let router = await makeExportRouter(bounceSideEffect: {
            _ = try? writeToneWav(at: URL(fileURLWithPath: bouncePath))
        })
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

        #expect(run.schema == "logic_pro_mcp_export_run.v1")
        #expect(run.confirmed)
        #expect(run.status == "completed")
        #expect(run.artifactsTotal == 1)
        #expect(run.artifactsVerified == 1)
        #expect(run.artifactsFailed == 0)
        #expect(run.artifactsUncertain == 0)

        let runProject = try #require(run.projects.first)
        #expect(runProject.opened)
        #expect(runProject.identityVerified)
        #expect(runProject.observedProjectPath == project.path)

        let artifact = try #require(runProject.artifacts.first)
        #expect(artifact.state == "A")
        #expect(artifact.verified)
        #expect(artifact.bounceFired)
        #expect(artifact.error == nil)
        let evidence = try #require(artifact.evidence)
        #expect(evidence.exists)
        #expect(evidence.fileSizeBytes > 0)
        #expect(evidence.durationSeconds > 0.1)
        #expect(evidence.verificationStatus == "pass")
        #expect(evidence.source == "audio_analyzer")
        // The artifact file actually exists on disk — State A is not fabricated.
        #expect(FileManager.default.fileExists(atPath: bouncePath))
    }

    @Test("resume skips already-present+verified artifacts and produces only the rest")
    func resumeSkipsVerifiedAndCompletesRest() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Resume Song")
        let bouncePath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Resume Song", kind: "bounce")
        let previewPath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Resume Song", kind: "preview")

        // Pre-stage the bounce artifact as a verifiable file — it must be SKIPPED.
        try writeToneWav(at: URL(fileURLWithPath: bouncePath))

        // The bounce route writes whichever known-path artifact is still missing (the preview).
        let router = await makeExportRouter(bounceSideEffect: {
            _ = try? writeToneWav(at: URL(fileURLWithPath: previewPath))
        })
        let options = fastOptions(identity: { project.path })

        let run = await ProjectExportExecutor.run(
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                // skip_existing so the already-present bounce is not a fail_if_exists collision.
                "collision_policy": .string("skip_existing"),
                "artifacts": .array([.string("bounce"), .string("preview")]),
                "confirmed": .bool(true),
            ],
            router: router,
            resume: true,
            options: options
        )

        #expect(run.mode == "resume")
        #expect(run.status == "completed")
        #expect(run.artifactsTotal == 2)
        #expect(run.artifactsSkipped == 1)
        #expect(run.artifactsVerified == 1)

        let artifacts = try #require(run.projects.first?.artifacts)
        let bounce = try #require(artifacts.first { $0.kind == "bounce" })
        let preview = try #require(artifacts.first { $0.kind == "preview" })
        // The already-present bounce was skipped (State A, no bounce fired).
        #expect(bounce.state == "A")
        #expect(bounce.verified)
        #expect(!bounce.bounceFired)
        #expect(bounce.reason == "skipped_already_verified")
        // The missing preview was produced (State A, bounce fired).
        #expect(preview.state == "A")
        #expect(preview.verified)
        #expect(preview.bounceFired)
    }

    @Test("identity mismatch fails closed and never bounces the wrong project")
    func identityMismatchFailsClosed() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Identity Song")
        let bouncePath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Identity Song", kind: "bounce")

        let bounceFired = BoolFlag()
        let router = await makeExportRouter(bounceSideEffect: {
            bounceFired.set()
            _ = try? writeToneWav(at: URL(fileURLWithPath: bouncePath))
        })
        // Front document reports a DIFFERENT project than the one we planned.
        let options = fastOptions(identity: { "/Users/someone/OtherProject.logicx" })

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
        #expect(run.artifactsFailed == 1)
        #expect(run.artifactsVerified == 0)

        let runProject = try #require(run.projects.first)
        #expect(runProject.opened)
        #expect(!runProject.identityVerified)

        let artifact = try #require(runProject.artifacts.first)
        #expect(artifact.state == "C")
        #expect(!artifact.verified)
        #expect(!artifact.bounceFired)
        let error = try #require(artifact.error)
        #expect(error.contains("project_identity_mismatch"))
        // Critically: no bounce was triggered and no file was written.
        #expect(!bounceFired.isSet)
        #expect(!FileManager.default.fileExists(atPath: bouncePath))
    }

    @Test("missing artifact after bounce gives State B (uncertain), not State A")
    func missingArtifactGivesStateB() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Missing Song")

        // Bounce SUCCEEDS at the channel level but writes NOTHING — the artifact
        // never appears. Must NOT be reported as verified.
        let router = await makeExportRouter(bounceSideEffect: { /* intentionally empty */ })
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

        #expect(run.status == "uncertain") // State B evidence is not a hard failure
        #expect(run.artifactsUncertain == 1)
        #expect(run.artifactsVerified == 0)
        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "B")
        #expect(!artifact.verified)
        #expect(artifact.bounceFired)
        #expect(artifact.reason == "artifact_not_observed_within_poll_window")
    }

    @Test("silent artifact after bounce gives State B (uncertain), not State A")
    func silentArtifactGivesStateB() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Silent Song")
        let bouncePath = plannedArtifactPath(outputRoot: outputRoot, displayName: "Silent Song", kind: "bounce")

        // Bounce writes a fully-silent WAV — present + non-zero but analysis fails.
        let router = await makeExportRouter(bounceSideEffect: {
            _ = try? writeSilentWav(at: URL(fileURLWithPath: bouncePath))
        })
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

        #expect(run.artifactsUncertain == 1)
        #expect(run.artifactsVerified == 0)
        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "B")
        #expect(!artifact.verified)
        #expect(artifact.bounceFired)
        let reason = try #require(artifact.reason)
        #expect(reason.contains("artifact_unverified"))
        #expect(reason.contains("near_silent_output"))
        let evidence = try #require(artifact.evidence)
        #expect(evidence.silenceRatio >= 0.98)
    }
}
