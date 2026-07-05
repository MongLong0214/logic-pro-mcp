import AVFoundation
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// MARK: - Issue #125 regression — bounce needs NO record-enabled track
//
// Issue #125: "Logic Bounce flow blocked by a 'No Recording Track specified'
// modal." That modal was an ENVIRONMENTAL demo-harness artifact — the
// workspace AX-menu-click helper drove a code path that needed a
// record-enabled track. The SHIPPED bounce
// (`ProjectExportExecutor` -> `Scripts/logic_bounce.py` via Cmd+B) bounces the
// project/section and does NOT require a record-enabled track.
//
// These tests pin the SHIPPED export/bounce contract against the *actual*
// injectable seam used in production: `Options.bounceToPath` (the path-directed
// Cmd+B helper). The legacy router-bounce seam (`bounceToPath == nil`) is
// already covered by `ProjectExportExecutionTests`; here we exercise the
// production seam so a regression that re-couples bounce success to a
// record-enabled track — or that silently mishandles the bounce RESULT — is
// caught.
//
// The contract this file guards:
//   1. The produce path opens the project, verifies front-document identity,
//      then drives the bounce. It routes ONLY `project.open` (and, in the
//      legacy seam, `project.bounce`). It NEVER routes a record-enable /
//      record-arm operation, and there is no precondition gate on a
//      record-enabled track.
//   2. A successful injected bounce -> on-disk-verified artifact -> State A
//      (verified == true). Success is driven by the real bounce OUTCOME (the
//      produced + analyzed file), never by track record-enablement.
// MARK: - Fixtures

/// Write a real, non-silent stereo WAV so `AudioAnalyzer` verification PASSES.
@discardableResult
private func writeIssue125ToneWav(at url: URL, durationSeconds: Double = 0.2) throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let sampleRate = 44_100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let channelData = buffer.floatChannelData!
    for channel in 0..<2 {
        for frame in 0..<Int(frameCount) {
            channelData[channel][frame] = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate) * 0.5)
        }
    }
    try file.write(from: buffer)
    return url
}

private func makeIssue125TempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("logicpromcp-issue125-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeIssue125Project(in dir: URL, named name: String) throws -> URL {
    let url = dir.appendingPathComponent(name).appendingPathExtension("logicx")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Deterministic artifact path the planner resolves for a display name + kind.
private func issue125PlannedArtifactPath(outputRoot: URL, displayName: String, kind: String) -> String {
    let sanitized = displayName.unicodeScalars.map { scalar -> Character in
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return allowed.contains(scalar) ? Character(scalar) : Character("-")
    }
    let safe = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return outputRoot.appendingPathComponent("\(safe.isEmpty ? "project" : safe)-\(kind).wav")
        .standardizedFileURL.path
}

/// Thread-safe recorder of every router operation the executor drives. Lets a
/// `@Sendable` channel closure append op names without a data race so we can
/// assert NO record-enable / record-arm op is ever routed during a bounce.
private final class OpRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ops: [String] = []
    func record(_ op: String) { lock.lock(); ops.append(op); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return ops }
}

private actor Issue125Channel: Channel {
    nonisolated let id: ChannelID
    private let onExecute: @Sendable (String, [String: String]) async -> ChannelResult

    init(id: ChannelID, onExecute: @escaping @Sendable (String, [String: String]) async -> ChannelResult) {
        self.id = id
        self.onExecute = onExecute
    }

    func start() async throws {}
    func stop() async {}
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        await onExecute(operation, params)
    }
    func healthCheck() async -> ChannelHealth { .healthy(detail: "issue125-fake") }
}

/// Router that records every routed op. `project.open` succeeds; `project.bounce`
/// (legacy seam, unused when `bounceToPath` is injected) just succeeds. No op
/// here arms or record-enables a track.
private func makeIssue125Router(recorder: OpRecorder) async -> ChannelRouter {
    let router = ChannelRouter()
    let appleScript = Issue125Channel(id: .appleScript) { op, _ in
        recorder.record(op)
        return .success("opened via \(op)")
    }
    let keyCmd = Issue125Channel(id: .midiKeyCommands) { op, _ in
        recorder.record(op)
        return .success("ok")
    }
    await router.register(appleScript)
    await router.register(keyCmd)
    return router
}

private func shippedBounceOptions(
    identity: @escaping @Sendable () async -> String?,
    bounce: @escaping ProjectExportExecutor.BounceToPath
) -> ProjectExportExecutor.Options {
    ProjectExportExecutor.Options(
        identityReadback: identity,
        analyze: { path, policy in AudioAnalyzer.analyzeFile(path: path, policy: policy) },
        fileManager: .default,
        pollAttempts: 5,
        pollIntervalNanos: 1_000,
        sleep: { _ in },
        minimumDurationSeconds: 0.05,
        bounceToPath: bounce
    )
}

@Suite("Issue #125 — shipped bounce needs no record-enabled track")
struct Issue125BouncePreconditionTests {

    @Test("shipped bounceToPath seam produces a verified artifact with NO record-track precondition")
    func shippedBounceProducesVerifiedArtifactWithoutRecordTrack() async throws {
        let projDir = try makeIssue125TempDir()
        let outputRoot = try makeIssue125TempDir()
        let project = try makeIssue125Project(in: projDir, named: "Bounce No Record Song")
        let bouncePath = issue125PlannedArtifactPath(
            outputRoot: outputRoot,
            displayName: "Bounce No Record Song",
            kind: "bounce"
        )

        let recorder = OpRecorder()
        let router = await makeIssue125Router(recorder: recorder)

        let bounceAifPath = (bouncePath as NSString).deletingPathExtension + ".aif"

        let options = shippedBounceOptions(identity: { project.path }) { artifactPath in
            let produced = (artifactPath as NSString).deletingPathExtension + ".aif"
            try? writeIssue125ToneWav(at: URL(fileURLWithPath: produced))
            return .success(produced)
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

        // Success is driven by the bounce OUTCOME (produced + analyzed file).
        #expect(run.status == "completed")
        #expect(run.artifactsVerified == 1)
        #expect(run.artifactsFailed == 0)
        #expect(run.artifactsUncertain == 0)

        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "A")
        // verified is Bool (not Optional) here; assert directly.
        #expect(artifact.verified)
        #expect(artifact.bounceFired)
        #expect(artifact.error == nil)
        #expect(artifact.path == bounceAifPath)
        let evidence = try #require(artifact.evidence)
        #expect(evidence.verificationStatus == "pass")
        #expect(FileManager.default.fileExists(atPath: bounceAifPath))

        // The crux of #125: the only mutating op routed is project.open. The
        // bounce went through the path-directed helper, and NOTHING armed or
        // record-enabled a track. Guard against a regression re-introducing a
        // record-arm precondition into the bounce path.
        let ops = recorder.all
        #expect(ops.contains("project.open"))
        let recordOps = ops.filter {
            $0.lowercased().contains("record") || $0.lowercased().contains("arm")
        }
        // recordOps.isEmpty is Bool; force-unwrap-free direct assertion (the
        // value is non-Optional, so this is NOT a swift-testing dead assertion).
        #expect(recordOps.isEmpty)
    }

    @Test("a failed shipped bounce yields an honest State C error, never a false success")
    func failedShippedBounceFailsClosedHonestly() async throws {
        let projDir = try makeIssue125TempDir()
        let outputRoot = try makeIssue125TempDir()
        let project = try makeIssue125Project(in: projDir, named: "Bounce Fails Honest Song")
        let bouncePath = issue125PlannedArtifactPath(
            outputRoot: outputRoot,
            displayName: "Bounce Fails Honest Song",
            kind: "bounce"
        )

        let recorder = OpRecorder()
        let router = await makeIssue125Router(recorder: recorder)

        let options = shippedBounceOptions(identity: { project.path }) { _ in
            .failure("bounce_dialog_did_not_appear")
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
        #expect(run.artifactsFailed == 1)
        #expect(run.artifactsVerified == 0)

        let artifact = try #require(run.projects.first?.artifacts.first)
        #expect(artifact.state == "C")
        #expect(!artifact.verified)
        #expect(!artifact.bounceFired)
        let error = try #require(artifact.error)
        #expect(error.contains("bounce_helper_failed"))
        #expect(error.contains("bounce_dialog_did_not_appear"))
        // No false artifact materialized on disk.
        #expect(!FileManager.default.fileExists(atPath: bouncePath))

        // Even on the failure path, the executor never reaches for a record-arm
        // op — the failure is about the bounce outcome, not a missing record track.
        let recordOps = recorder.all.filter {
            $0.lowercased().contains("record") || $0.lowercased().contains("arm")
        }
        #expect(recordOps.isEmpty)
    }

    @Test("a post-click shipped bounce failure preserves bounceFired so retries stay honest")
    func postClickShippedBounceFailurePreservesBounceFired() async throws {
        let projDir = try makeIssue125TempDir()
        let outputRoot = try makeIssue125TempDir()
        let project = try makeIssue125Project(in: projDir, named: "Bounce Post Click Honest Song")

        let recorder = OpRecorder()
        let router = await makeIssue125Router(recorder: recorder)

        let options = shippedBounceOptions(identity: { project.path }) { _ in
            .failure("artifact_not_produced_in_staging", bounceFired: true)
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
        #expect(!artifact.verified)
        #expect(artifact.bounceFired)
        let error = try #require(artifact.error)
        #expect(error.contains("bounce_helper_failed"))
        #expect(error.contains("artifact_not_produced_in_staging"))

        let recordOps = recorder.all.filter {
            $0.lowercased().contains("record") || $0.lowercased().contains("arm")
        }
        #expect(recordOps.isEmpty)
    }

    @Test("shipped bounce rejects helper artifact paths that change the planned stem")
    func shippedBounceRejectsUnexpectedArtifactStem() async throws {
        let projDir = try makeIssue125TempDir()
        let outputRoot = try makeIssue125TempDir()
        let project = try makeIssue125Project(in: projDir, named: "Bounce Wrong Stem Song")

        let recorder = OpRecorder()
        let router = await makeIssue125Router(recorder: recorder)
        let wrongPath = outputRoot.appendingPathComponent("Other-Song-bounce.aif").path

        let options = shippedBounceOptions(identity: { project.path }) { _ in
            try? writeIssue125ToneWav(at: URL(fileURLWithPath: wrongPath))
            return .success(wrongPath)
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
        #expect((artifact.error?.contains("bounce_helper_unexpected_artifact_path"))!)
    }
}
