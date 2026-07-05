import Foundation
import MCP

/// Issue #27 Phase 2 — GUARDED EXECUTION of the export plan that Phase 1
/// (#99, `export_plan`) only described as a dry run.
///
/// The executor re-runs `ProjectExportPlanner` to obtain the authoritative
/// manifest (so the contract a caller reviewed in `export_plan` is the contract
/// that executes), then walks each project artifact through a fail-closed state
/// machine:
///
///   1. `confirmed == true` is mandatory — otherwise NOTHING is opened, bounced,
///      or written, and the run reports `confirmation_required` (State-C-shaped:
///      `success:false`).
///   2. Artifacts the plan reported as already present + verifiable on disk are
///      SKIPPED (idempotent — this is what makes `export_resume` resumable).
///   3. For every artifact that still needs producing: open the project,
///      read back the OBSERVED front-document identity and require it to match
///      the planned project path (fail closed on mismatch — never bounce the
///      wrong project), trigger the bounce, poll (bounded) for the artifact file
///      to appear, then verify it with `AudioAnalyzer` (exists + non-zero +
///      non-silent + sane duration).
///   4. Honest Contract per artifact:
///        State A — bounce fired AND on-disk verification PASSED.
///        State B — bounce fired but the artifact could not be verified
///                  (never appeared / analyzer warn/fail) — success uncertain.
///        State C — a hard failure (open/identity/bounce route error, or the
///                  plan itself was degraded for this artifact).
///   5. The collision policy from the plan is honoured: under `fail_if_exists`
///      an artifact the plan flagged `would_overwrite` is NEVER overwritten —
///      it fails closed (State C) instead of bouncing over an existing file.
///
/// Every live side effect (open / bounce / close) and every readback
/// (front-document identity, audio analysis, file polling) goes through an
/// injectable seam, so the state machine, the resume/idempotency logic, and the
/// fail-closed gates are fully unit-testable with fake channels, an injected
/// `FileManager`, fixture WAV files, and a stub identity provider — no live
/// Logic required to test the logic.
enum ProjectExportExecutor {
    static let schema = "logic_pro_mcp_export_run.v1"
    static let bounceHelperTimeout: TimeInterval = 300

    /// Bounded poll budget for an artifact file to appear after a bounce fires.
    /// Injectable via `Options` so tests don't actually sleep.
    static let defaultPollAttempts = 60
    static let defaultPollIntervalNanos: UInt64 = 500_000_000

    // MARK: - Injectable seams

    /// Reads the OBSERVED front-document project path from live Logic. Mirrors
    /// the verified-plugin identity gate seam (`FrontDocumentPathProvider`) so
    /// the readback authority is the same one the open/save lifecycle relies on.
    /// Returns nil when no front document can be read.
    typealias IdentityReadback = @Sendable () async -> String?

    /// Analyze an on-disk artifact. Defaults to `AudioAnalyzer.analyzeFile`; the
    /// `policy` carries the output-root containment + non-silence/duration gates.
    typealias ArtifactAnalyzer = @Sendable (_ path: String, _ policy: AudioAnalyzer.AnalysisPolicy) -> AudioAnalyzer.Result

    typealias BounceHelperResult = ProjectExportBounceHelperResult
    typealias BounceToPath = @Sendable (_ artifactPath: String) async -> BounceHelperResult
    typealias BounceHelperProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> BoundedProcessRunner.Result
    typealias RunResult = ProjectExportRunResult
    typealias RunProject = ProjectExportRunProject
    typealias RunArtifact = ProjectExportRunArtifact
    typealias ArtifactEvidence = ProjectExportArtifactEvidence

    /// `@unchecked Sendable` mirrors `AudioAnalyzer.Runtime`: the only
    /// non-Sendable member is `FileManager`, which Apple documents as safe to
    /// share across threads for the read-only `fileExists` use here.
    struct Options: @unchecked Sendable {
        var identityReadback: IdentityReadback
        var analyze: ArtifactAnalyzer
        var fileManager: FileManager
        var pollAttempts: Int
        var pollIntervalNanos: UInt64
        var sleep: @Sendable (UInt64) async -> Void
        /// Minimum sane duration (seconds) for a produced artifact. A bounce that
        /// yields a sub-tick file is treated as not-verified (State B).
        var minimumDurationSeconds: Double
        /// Live path-directed bounce. nil keeps the legacy router-bounce seam so
        /// the deterministic unit tests never shell out to the UI helper.
        var bounceToPath: BounceToPath?
        /// Blocking-dialog preflight for the per-project batch open (audit P2 #18).
        /// Defaults to `{ false }` so hermetic unit tests never trip the preflight;
        /// `.live()` wires it to the real AX dialog probe.
        var dialogPresent: @Sendable () -> Bool = { false }

        static func live() -> Options {
            Options(
                identityReadback: { await AppleScriptChannel.currentDocumentPath() },
                analyze: { path, policy in AudioAnalyzer.analyzeFile(path: path, policy: policy) },
                fileManager: .default,
                pollAttempts: defaultPollAttempts,
                pollIntervalNanos: defaultPollIntervalNanos,
                sleep: { try? await Task.sleep(nanoseconds: $0) },
                minimumDurationSeconds: 0.05,
                bounceToPath: { artifactPath in await ProjectExportExecutor.runBounceHelper(artifactPath: artifactPath) },
                dialogPresent: { AXLogicProElements.dialogPresent() }
            )
        }
    }

    // MARK: - Entry point

    /// Execute (or resume) the guarded export. `resume` only changes the
    /// surfaced `mode` string and `next_safe_action` wording — the artifact
    /// state machine is identical: both skip already-present+verified artifacts
    /// and produce the rest. That shared path is what makes `export_run`
    /// re-entrant and `export_resume` idempotent.
    static func run(
        params: [String: Value],
        router: ChannelRouter,
        resume: Bool,
        options: Options
    ) async -> RunResult {
        // (1) Re-run the planner. Caller-facing param errors are surfaced by the
        // dispatcher's planner call BEFORE this executor is reached, so a throw
        // here is unexpected — fail closed with an empty, failed run rather than
        // crash.
        let plan: ProjectExportPlan
        do {
            plan = try ProjectExportPlanner.plan(params: params, fileManager: options.fileManager)
        } catch {
            return failedRun(
                runID: "export-unplanned",
                mode: resume ? "resume" : "run",
                confirmed: false,
                outputRoot: stringParam(params, "output_root", "outputRoot"),
                collisionPolicy: stringParam(params, "collision_policy", default: "fail_if_exists"),
                reason: "plan_failed: \(error)"
            )
        }

        // (2) confirmed gate — fail closed before ANY mutation.
        let confirmed: Bool
        switch strictBoolParam(params, "confirmed") {
        case .value(let value):
            confirmed = value
        case .missing, .invalid:
            confirmed = false
        }
        guard confirmed else {
            return confirmationRequiredRun(plan: plan, resume: resume)
        }

        var runProjects: [RunProject] = []
        for project in plan.projects {
            let runProject = await execute(
                project: project,
                plan: plan,
                router: router,
                options: options
            )
            runProjects.append(runProject)
        }

        return aggregate(plan: plan, resume: resume, projects: runProjects)
    }

    // MARK: - Per-project execution

    private static func execute(
        project: ProjectExportPlanProject,
        plan: ProjectExportPlan,
        router: ChannelRouter,
        options: Options
    ) async -> RunProject {
        // A degraded/invalid project (bad path, intra-plan collision, would-
        // overwrite under fail_if_exists) never gets opened — every artifact
        // fails closed with the plan's own reason.
        guard project.validationStatus == "valid" else {
            let arts = project.expectedArtifacts.map { artifact in
                failedArtifact(artifact, error: "project_invalid: \(project.validationIssues.joined(separator: ","))")
            }
            return RunProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                observedProjectPath: nil,
                identityVerified: false,
                opened: false,
                artifacts: arts
            )
        }

        let preflightArtifacts = project.expectedArtifacts.map {
            preflightArtifactOutcome($0, plan: plan, options: options)
        }
        let needsOpen = preflightArtifacts.contains { $0 == nil }

        guard needsOpen else {
            return RunProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                observedProjectPath: nil,
                identityVerified: false,
                opened: false,
                artifacts: preflightArtifacts.compactMap(\.self)
            )
        }

        // (3a-pre) audit P2 #18 — dialog preflight for the per-project batch open.
        // The dispatcher checks once before the batch, but a modal (a prior
        // project's save/bounce sheet, a crash dialog) can appear mid-batch;
        // driving `project.open` through it is unsafe. Fail closed for every
        // pending artifact instead — mirrors the project_invalid / open_failed
        // fail-closed shape below.
        if options.dialogPresent() {
            let arts = zip(project.expectedArtifacts, preflightArtifacts).map { pair -> RunArtifact in
                let (artifact, preflight) = pair
                if let preflight { return preflight }
                return failedArtifact(
                    artifact,
                    error: "blocking_dialog_present: refused project.open while a modal Logic dialog/sheet is present"
                )
            }
            return RunProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                observedProjectPath: nil,
                identityVerified: false,
                opened: false,
                artifacts: arts
            )
        }

        // (3a) Open the project (existing open path through the router).
        let openResult = await router.route(
            operation: "project.open",
            params: ["path": project.projectPath]
        )
        guard openResult.isSuccess else {
            let arts = zip(project.expectedArtifacts, preflightArtifacts).map { pair -> RunArtifact in
                let (artifact, preflight) = pair
                if let preflight { return preflight }
                return failedArtifact(artifact, error: "open_failed: \(openResult.message)")
            }
            return RunProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                observedProjectPath: nil,
                identityVerified: false,
                opened: false,
                artifacts: arts
            )
        }

        // (3b) Identity readback — the OBSERVED front document MUST match the
        // planned project path or we fail closed for every pending artifact
        // (never bounce the wrong project).
        let observedPath = await options.identityReadback()
        let identityVerified = observedPath.map {
            AppleScriptChannel.projectPathsMatch(project.projectPath, $0)
        } ?? false
        guard identityVerified else {
            let arts = zip(project.expectedArtifacts, preflightArtifacts).map { pair -> RunArtifact in
                let (artifact, preflight) = pair
                if let preflight { return preflight }
                return failedArtifact(
                    artifact,
                    error: observedPath == nil
                        ? "project_identity_mismatch: no front document path could be read"
                        : "project_identity_mismatch: observed=\(observedPath ?? "")"
                )
            }
            return RunProject(
                index: project.index,
                projectPath: project.projectPath,
                displayName: project.displayName,
                observedProjectPath: observedPath,
                identityVerified: false,
                opened: true,
                artifacts: arts
            )
        }

        // (3c) Per-artifact production.
        var arts: [RunArtifact] = []
        for (artifact, preflight) in zip(project.expectedArtifacts, preflightArtifacts) {
            if let preflight {
                arts.append(preflight)
                continue
            }
            let produced = await produce(
                artifact: artifact,
                plan: plan,
                router: router,
                options: options
            )
            arts.append(produced)
        }

        return RunProject(
            index: project.index,
            projectPath: project.projectPath,
            displayName: project.displayName,
            observedProjectPath: observedPath,
            identityVerified: true,
            opened: true,
            artifacts: arts
        )
    }
}
