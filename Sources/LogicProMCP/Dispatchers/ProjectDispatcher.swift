import Foundation
import MCP

struct ProjectDispatcher {
    struct LifecycleExecution: Sendable {
        let executionError: String?
        let timedOut: Bool
        let terminationStatus: Int32
        let stderrOutput: String
    }

    static let tool = commandTool(
        name: "logic_project",
        description: "Project lifecycle + read-only project state in Logic Pro. Commands: new, open, save, save_as, close, bounce, launch, quit, get_regions, export_plan, export_run, export_resume, audit, cleanup_plan, cleanup_apply. Params: open -> { path: String }; save_as -> { path: String }; close -> { saving?: \"yes\"|\"no\"|\"ask\" }; bounce/launch/quit -> {}; bounce requires confirmation and runs a pre-bounce project audit, returning `export_readiness_blocked` before opening the Bounce dialog if blockers such as `external_midi_regions_bounce_risk` are present; get_regions -> {} (returns JSON array of { name, trackIndex, startBar, endBar, kind, rawHelp } parsed from Logic's arrange area via AX); export_plan -> { projects: [absolute .logicx], output_root: String, artifacts?: [bounce|stem|preview|variant], collision_policy?: fail_if_exists|skip_existing } dry-run only; export_run -> { ...same as export_plan, confirmed: Bool } GUARDED execution (re-plans, opens, verifies project identity by readback, bounces, verifies each artifact on disk via logic_audio, records logic_pro_mcp_export_run.v1 with HC State A/B/C; never overwrites under fail_if_exists); export_resume -> { ...same as export_run } idempotent resume (skips already-present+verified artifacts, produces the rest); audit -> read-only project/session audit JSON; cleanup_plan -> read-only serializable cleanup plan JSON; cleanup_apply -> { step_id: String, confirmed: Bool, names?: \"newA,newB\" (CSV aligned to the step's target track indices) | new_name?: String (single target) } executes ONE supported mutating cleanup-plan step (currently rename_* only) through the existing track.rename path so it inherits AX readback + Honest Contract State A/B/C. Fails closed (State C) when confirmed!=true, the step is unknown/unsupported/non-mutating, the audit shows stale/occluded inventory or a track readback gap, or rename names are missing/mismatched. Deletion steps are unsupported by construction and are always refused; others -> {}.",
        commandDescription: "Project command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        // Single source of truth — use ProcessUtils.isLogicProRunning everywhere
        // (NSRunningApplication-based with multi-fallback). Removed prior OR with
        // PermissionChecker.checkAutomationState() == .granted because permission
        // grant ≠ Logic actually running, and the OR caused state inconsistency
        // vs `system.health` and `transport.toggle_cycle` which use ProcessUtils only.
        isLogicProRunning: () -> Bool = { ProcessUtils.isLogicProRunning },
        executeLifecycleScript: (String) async -> LifecycleExecution = { script in
            await executeAppleScript(script)
        },
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        dialogPresent: @escaping @Sendable () -> Bool = { false },
        cleanupAuditFileReader: LogicProjectFileReader.Runtime = .production,
        // #27 Phase 2 — injectable export-execution seams (identity readback,
        // audio analysis, file polling). Defaults to the live wiring; tests
        // inject fakes so the guarded state machine is unit-testable headless.
        exportOptions: ProjectExportExecutor.Options = .live()
    ) async -> CallTool.Result {
        func destructiveConfirmation(for command: String) -> (confirmed: Bool, error: CallTool.Result?) {
            switch strictBoolParam(params, "confirmed") {
            case .missing:
                return (false, nil)
            case .value(let confirmed):
                return (confirmed, nil)
            case .invalid(let hint):
                audit(command, phase: .rejected, reason: "invalid confirmed")
                return (
                    false,
                    toolInvalidParamsResult("\(command) \(hint)")
                )
            }
        }

        // H-1 (2026-05-08 enterprise review): pre-fix this dispatcher logged
        // `[AUDIT] project.<command> executed` BEFORE param validation,
        // BEFORE the destructive-confirmation gate, and BEFORE the route
        // actually fired. Enterprise audit trails treated rejected calls
        // (e.g. `project.open` with empty path) as if they had run, which
        // both inflated the audit volume and hid genuine failures behind
        // identical log lines.
        //
        // The fix splits the audit signal into three distinct phases that
        // a SIEM can filter on:
        //   - `rejected` — validation refused the call before any side effect
        //   - `confirmation_required` — destructive policy returned the
        //     confirmation envelope; no route was attempted
        //   - `executed` — the underlying route was invoked (success or
        //     hard failure) and any side effect has either landed or been
        //     reported back from the channel
        //
        // Helpers below are intentionally inlined per-case rather than
        // wrapped in a single function so the log is always paired with
        // the immediately-following return — refactors that move the
        // return without moving the audit call would surface as a diff
        // anomaly during review.

        switch command {
        case "export_plan":
            do {
                let plan = try ProjectExportPlanner.plan(params: params)
                // PR99-C5 / C2-nit (HC): use the throwing encoder so an encode
                // failure fails closed (isError=true) via the catch below instead
                // of returning an error-shaped, non-manifest body as a success.
                return toolTextResult(try encodeJSONStrict(plan, compact: true))
            } catch {
                audit(command, phase: .rejected, reason: "invalid export plan")
                return toolInvalidParamsResult(
                    "export_plan invalid_params: \(error)",
                    extras: ["operation": "project.export_plan"]
                )
            }

        case "export_run", "export_resume":
            // #27 Phase 2 — GUARDED EXECUTION. Validate the plan inputs first so
            // a malformed request fails closed with `invalid_params` (rejected,
            // no mutation) exactly like export_plan, instead of reaching the
            // executor. The executor then re-runs the planner itself for the
            // authoritative manifest — the dispatcher's call is purely the
            // caller-input gate.
            do {
                _ = try ProjectExportPlanner.plan(params: params)
            } catch {
                audit(command, phase: .rejected, reason: "invalid export plan")
                return toolInvalidParamsResult(
                    "\(command) invalid_params: \(error)",
                    extras: ["operation": "project.\(command)"]
                )
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.\(command)")
            }
            let run: ProjectExportExecutor.RunResult
            switch strictBoolParam(params, "confirmed") {
            case .invalid(let hint):
                audit(command, phase: .rejected, reason: "invalid confirmed")
                return toolInvalidParamsResult(
                    "\(command) \(hint)",
                    extras: ["operation": "project.\(command)"]
                )
            case .missing, .value(false):
                audit(command, phase: .confirmationRequired)
                run = await ProjectExportExecutor.run(
                    params: params,
                    router: router,
                    resume: command == "export_resume",
                    options: exportOptions
                )
            case .value(true):
                audit(command, phase: .executed)
                run = await ProjectExportExecutor.run(
                    params: params,
                    router: router,
                    resume: command == "export_resume",
                    options: exportOptions
                )
            }
            // Lifecycle cache invalidation: a guarded run opens projects, so the
            // cache may now reflect the LAST opened project. Clear it on any run
            // that actually opened something, matching open/close semantics.
            if run.projects.contains(where: { $0.opened }) {
                await cache.clearProjectState()
            }
            do {
                // HC truthfulness: a run that produced ZERO verified artifacts and
                // had failures (or the confirmation gate) is isError=true on the
                // wire so a client never reads a failed/blocked run as success.
                let body = try encodeJSONStrict(run, compact: true)
                let isError = run.status == "failed" || run.status == "confirmation_required"
                return toolTextResult(body, isError: isError)
            } catch {
                return toolTextResult(
                    "{\"success\":false,\"error\":\"\(command) encode failed: \(jsonStringEscape(error.localizedDescription))\"}",
                    isError: true
                )
            }

        case "new":
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.new")
            }
            audit(command, phase: .executed)
            let result = await router.route(operation: "project.new")
            // v3.1.2 (P0-3) — clear cache on lifecycle success so the next
            // resource read / name-based routing decision sees the fresh
            // project's tracks instead of the previous project's stale list.
            // Without this, `cache.getTracks()` returned 38 tracks for over
            // a minute after `project.new` (live-witnessed); the StatePoller
            // takes up to 3s to overwrite, and resource consumers assumed
            // the data was current. clearProjectState() is idempotent and
            // mutation-free on actor state — safe to call on every success
            // even if the poller would have caught up eventually.
            await invalidateOnSuccess(result, cache: cache)
            return toolTextResult(result)

        case "open":
            let path = stringParam(params, "path")
            guard !path.isEmpty else {
                audit(command, phase: .rejected, reason: "missing path")
                return toolInvalidParamsResult(
                    "open requires 'path' param",
                    extras: ["operation": "project.open"]
                )
            }
            guard AppleScriptSafety.isValidProjectPath(path, requireExisting: true) else {
                audit(command, phase: .rejected, reason: "invalid path")
                return toolInvalidParamsResult(
                    "open requires an existing absolute .logicx project path",
                    extras: ["operation": "project.open"]
                )
            }
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error { return error }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return toolTextResult(response)
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.open")
            }
            audit(command, phase: .executed)
            let result = await router.route(
                operation: "project.open",
                params: ["path": path]
            )
            // v3.1.2 (P0-3) — same cache stale-after-lifecycle bug as `new`.
            await invalidateOnSuccess(result, cache: cache)
            return toolTextResult(result)

        case "save":
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.save")
            }
            audit(command, phase: .executed)
            // #110: save is an export/bounce prerequisite. The read-back
            // verification lives in the AppleScript channel (the reliable
            // writer, now tried first) so it stays DI-testable like save_as;
            // the dispatcher just routes + surfaces the channel's HC verdict.
            let result = await router.route(operation: "project.save")
            return toolTextResult(result)

        case "save_as":
            let path = stringParam(params, "path")
            guard !path.isEmpty else {
                audit(command, phase: .rejected, reason: "missing path")
                return toolInvalidParamsResult(
                    "save_as requires 'path' param",
                    extras: ["operation": "project.save_as"]
                )
            }
            guard AppleScriptSafety.isValidProjectPath(path, requireExisting: false) else {
                audit(command, phase: .rejected, reason: "invalid path")
                return toolInvalidParamsResult(
                    "save_as requires an absolute .logicx project path",
                    extras: ["operation": "project.save_as"]
                )
            }
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error { return error }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return toolTextResult(response)
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.save_as")
            }
            audit(command, phase: .executed)
            let result = await router.route(
                operation: "project.save_as",
                params: ["path": path]
            )
            return toolTextResult(result)

        case "close":
            let savingRaw = stringParam(params, "saving", default: "yes")
            let saving = ["yes", "no", "ask"].contains(savingRaw) ? savingRaw : "yes"
            if savingRaw != saving {
                audit(command, phase: .rejected, reason: "invalid saving value")
                return toolInvalidParamsResult(
                    "close 'saving' must be one of: yes, no, ask (got: \(savingRaw))",
                    extras: ["operation": "project.close"]
                )
            }
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error { return error }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return toolTextResult(response)
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.close")
            }
            audit(command, phase: .executed)
            let result = await router.route(
                operation: "project.close",
                params: ["saving": saving]
            )
            // v3.1.2 (P0-3) — closing the project leaves the cache stuffed
            // with the just-closed tracks/regions/markers. Clear so resource
            // reads honestly reflect "no project" until the next open.
            await invalidateOnSuccess(result, cache: cache)
            return toolTextResult(result)

        case "bounce":
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error { return error }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return toolTextResult(response)
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.bounce")
            }
            let preflight = await ProjectSessionAudit.buildAudit(cache: cache)
            if let block = bouncePreflightBlock(preflight) {
                audit(command, phase: .rejected, reason: "export readiness blocked")
                return block
            }
            audit(command, phase: .executed)
            let result = await router.route(operation: "project.bounce")
            return toolTextResult(result)

        case "is_running":
            return toolTextResult(isLogicProRunning() ? "true" : "false")

        case "get_regions":
            // Read-only arrange-area inspection. Necessary for programmatic
            // verification of record_sequence region placement — without this
            // the only feedback loop was visual screenshots.
            let result = await router.route(operation: "region.get_regions")
            await refreshRegionCache(from: result, cache: cache)
            return toolTextResult(result)

        case "audit":
            let report = await ProjectSessionAudit.buildAudit(cache: cache)
            do {
                return toolTextResult(try encodeJSONStrict(report, compact: true))
            } catch {
                // Honest Contract: a serialization failure must NOT be returned
                // as a success-shaped body. Fail loud with isError=true.
                return toolTextResult(
                    "{\"error\":\"audit encode failed: \(jsonStringEscape(error.localizedDescription))\"}",
                    isError: true
                )
            }

        case "cleanup_plan":
            let report = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
            do {
                return toolTextResult(try encodeJSONStrict(report, compact: true))
            } catch {
                return toolTextResult(
                    "{\"error\":\"cleanup_plan encode failed: \(jsonStringEscape(error.localizedDescription))\"}",
                    isError: true
                )
            }

        case "cleanup_apply":
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.cleanup_apply")
            }
            return await handleCleanupApply(
                params: params,
                router: router,
                cache: cache,
                auditFileReader: cleanupAuditFileReader
            )

        case "launch":
            if isLogicProRunning() {
                audit(command, phase: .rejected, reason: "already running")
                return toolTextResult("Logic Pro is already running")
            }
            audit(command, phase: .executed)
            return await runLifecycleScript(
                script: "tell application \"Logic Pro\" to activate",
                successMessage: "Logic Pro launched",
                expectedRunning: true,
                actionLabel: "launch",
                execute: executeLifecycleScript,
                isLogicProRunning: isLogicProRunning,
                sleep: sleep
            )

        case "quit":
            let confirmation = destructiveConfirmation(for: command)
            if let error = confirmation.error { return error }
            if !confirmation.confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                audit(command, phase: .confirmationRequired)
                return toolTextResult(response)
            }
            if !isLogicProRunning() {
                audit(command, phase: .rejected, reason: "not running")
                return toolTextResult("Logic Pro is not running")
            }
            if dialogPresent() {
                audit(command, phase: .rejected, reason: "blocking dialog")
                return blockingLogicDialogResult(operation: "project.quit")
            }
            audit(command, phase: .executed)
            return await runLifecycleScript(
                script: "tell application \"Logic Pro\" to quit",
                successMessage: "Logic Pro quit",
                expectedRunning: false,
                actionLabel: "quit",
                execute: executeLifecycleScript,
                isLogicProRunning: isLogicProRunning,
                sleep: sleep
            )

        default:
            return toolInvalidParamsResult(
                "Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, is_running, launch, quit, get_regions, export_plan, export_run, export_resume, audit, cleanup_plan, cleanup_apply",
                extras: ["operation": "project.\(command)"]
            )
        }
    }

    // MARK: - cleanup_apply (#28) — guarded execution of a cleanup-plan step

    /// Guarded execution of exactly ONE cleanup-plan step (#28). The read-only
    /// `audit` + `cleanup_plan` surfaces (shipped in #95) propose steps but never
    /// mutate; this command turns a single supported, mutating step into a real
    /// Logic mutation while inheriting every Honest Contract guarantee of the
    /// underlying tool path.
    ///
    /// Contract:
    ///   1. Re-derive the audit + cleanup plan deterministically from the cache
    ///      (the caller cannot smuggle a stale plan — the step is matched against
    ///      a freshly-built plan).
    ///   2. Find the step by `step_id`.
    ///   3. Fail CLOSED (State C, isError) when any of:
    ///        - `confirmed` is not literally `true`
    ///        - the step id is unknown
    ///        - `supported_by_current_tools == false`
    ///        - `mutates_project == false` (nothing to execute)
    ///        - the audit shows stale/occluded inventory or a track readback gap
    ///   4. For a supported mutating step, dispatch through the EXISTING tool
    ///      path (currently only `track.rename`) so it inherits AX readback +
    ///      HC State A/B/C. The dispatcher does NOT re-implement the readback.
    ///   5. NEVER delete. Deletion steps are `supported_by_current_tools:false`
    ///      by construction (see `ProjectSessionAudit.cleanupPlanSteps`), so the
    ///      unsupported gate already refuses them; a redundant explicit refusal
    ///      guards against any future plan that mislabels a delete as supported.
    static func handleCleanupApply(
        command: String = "cleanup_apply",
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        auditFileReader: LogicProjectFileReader.Runtime = .production
    ) async -> CallTool.Result {
        let stepID = stringParam(params, "step_id", "stepId")
        guard !stepID.isEmpty else {
            audit(command, phase: .rejected, reason: "missing step_id")
            return toolInvalidParamsResult(
                "cleanup_apply requires 'step_id' (an id from logic_project cleanup_plan)"
            )
        }

        // Gate 1 — explicit confirmation. A missing or non-literal-boolean
        // `confirmed` must NOT be coerced; this is a mutating op, so an
        // ambiguous confirmation fails closed rather than executing.
        switch strictBoolParam(params, "confirmed") {
        case .invalid(let hint):
            audit(command, phase: .rejected, reason: "invalid confirmed")
            return toolInvalidParamsResult("cleanup_apply \(hint)")
        case .missing:
            audit(command, phase: .confirmationRequired, reason: stepID)
            return cleanupApplyStateC(
                .invalidParams,
                stepID: stepID,
                hint: "cleanup_apply requires 'confirmed:true' to execute a mutating cleanup step; re-run logic_project cleanup_plan, confirm the step, then retry with confirmed:true."
            )
        case .value(let confirmed):
            guard confirmed else {
                audit(command, phase: .confirmationRequired, reason: stepID)
                return cleanupApplyStateC(
                    .invalidParams,
                    stepID: stepID,
                    hint: "cleanup_apply 'confirmed' was false; the step was not executed. Retry with confirmed:true once the caller has approved it."
                )
            }
        }

        // Gate 2 — re-derive the plan deterministically and locate the step.
        // The caller cannot pass a step body in; only its id. This guarantees
        // execution is gated on the CURRENT audit, not a snapshot the caller
        // may have cached before the project changed underneath them.
        let auditReport = await ProjectSessionAudit.buildAudit(
            cache: cache,
            fileReader: auditFileReader
        )
        guard let step = auditReport.cleanupPlan.first(where: { $0.id == stepID }) else {
            audit(command, phase: .rejected, reason: "unknown step")
            return cleanupApplyStateC(
                .elementNotFound,
                stepID: stepID,
                hint: "cleanup_apply: no cleanup-plan step with id '\(stepID)' in the current audit. The plan is re-derived on every call; re-run logic_project cleanup_plan and use a current step id."
            )
        }

        // Gate 3 — the audit itself must be safe to act on. Stale, occluded, or
        // gap-bearing inventory means the plan's targets may not correspond to
        // the live session, so any rename could hit the wrong track.
        if let blockingHint = cleanupApplyInventoryBlocker(auditReport) {
            audit(command, phase: .rejected, reason: "stale inventory")
            return cleanupApplyStateC(
                .staleSnapshot,
                stepID: stepID,
                hint: blockingHint
            )
        }

        // Gate 4 — non-mutating / unsupported steps are refused. A
        // non-mutating step has nothing to execute; an unsupported step
        // (e.g. delete, marker planning gaps) is not safely executable via
        // the current tool surface.
        guard step.mutatesProject else {
            audit(command, phase: .rejected, reason: "non-mutating step")
            return cleanupApplyStateC(
                .invalidParams,
                stepID: stepID,
                hint: "cleanup_apply: step '\(stepID)' does not mutate the project (\(step.proposedOperation)); there is nothing to execute."
            )
        }
        guard step.supportedByCurrentTools else {
            audit(command, phase: .rejected, reason: "unsupported step")
            return cleanupApplyStateC(
                .notImplemented,
                stepID: stepID,
                hint: "cleanup_apply: step '\(stepID)' is not supported by the current tool surface (supported_by_current_tools=false). Resolve its stop condition (\(step.stopCondition)) and re-derive the plan."
            )
        }

        // Gate 5 — deletion is NEVER executed. By construction no plan step
        // proposes a supported delete, but this explicit refusal makes the
        // invariant impossible to regress: even a future mislabelled delete
        // step fails closed here.
        if cleanupApplyIsDeletion(step) {
            audit(command, phase: .rejected, reason: "deletion refused")
            return cleanupApplyStateC(
                .notImplemented,
                stepID: stepID,
                hint: "cleanup_apply refuses deletion: step '\(stepID)' (tool=\(step.tool ?? "nil") command=\(step.command ?? "nil")) is a destructive delete and is never executed by cleanup_apply."
            )
        }

        // Dispatch — currently only the rename family is executable. Every
        // supported mutating step in the plan is `tool:"logic_tracks"`; the
        // rename command renames duplicate/unnamed tracks. solo/arm toggle
        // steps are deferred (see deferred[] / docs): they need an explicit
        // per-track enabled vector that the read-only plan does not yet carry.
        switch (step.tool, step.command) {
        case ("logic_tracks", "rename"):
            return await applyRenameStep(
                step,
                params: params,
                router: router,
                cache: cache
            )
        default:
            audit(command, phase: .rejected, reason: "no executable path")
            return cleanupApplyStateC(
                .notImplemented,
                stepID: stepID,
                hint: "cleanup_apply: step '\(stepID)' (tool=\(step.tool ?? "nil") command=\(step.command ?? "nil")) has no executable cleanup path yet. Currently only rename_* steps are executable; perform other steps through their named tool directly."
            )
        }
    }

    /// Execute a rename cleanup step through the existing `track.rename` path so
    /// it inherits AX readback + HC State A/B/C. The step's `targetIdentifier`
    /// is `tracks:<i0,i1,...>`; the caller supplies one new name per target via
    /// `names` (CSV) or, for a single target, `new_name`. Mismatched counts fail
    /// closed before any write so a partial rename can't corrupt the session.
    private static func applyRenameStep(
        _ step: ProjectSessionAudit.CleanupPlanStep,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let targets = cleanupApplyTargetIndices(step.targetIdentifier)
        guard !targets.isEmpty else {
            return cleanupApplyStateC(
                .invalidParams,
                stepID: step.id,
                hint: "cleanup_apply: rename step '\(step.id)' has no parseable target track indices in '\(step.targetIdentifier)'."
            )
        }

        let names = cleanupApplyRenameNames(params, targetCount: targets.count)
        guard names.count == targets.count else {
            return cleanupApplyStateC(
                .invalidParams,
                stepID: step.id,
                hint: "cleanup_apply: rename step '\(step.id)' targets \(targets.count) track(s) \(targets); supply exactly that many names via 'names' (CSV) — or 'new_name' for a single target. Got \(names.count)."
            )
        }
        // Reject blank names up-front: track.rename refuses an empty name, but
        // catching it here keeps a multi-target rename all-or-nothing instead of
        // failing partway after some tracks were already renamed.
        if let blankIdx = names.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return cleanupApplyStateC(
                .invalidParams,
                stepID: step.id,
                hint: "cleanup_apply: rename name #\(blankIdx + 1) for step '\(step.id)' is blank; every target needs a non-empty name."
            )
        }

        var renamed: [[String: Any]] = []
        for (target, newName) in zip(targets, names) {
            let result = await TrackDispatcher.handle(
                command: "rename",
                params: ["index": .int(target), "name": .string(newName)],
                router: router,
                cache: cache
            )
            let body = cleanupApplyResultText(result)
            renamed.append([
                "track_index": target,
                "new_name": newName,
                "result": body,
            ])
            // TrackDispatcher.rename already maps State B/C to isError. If any
            // target failed (or came back unverified), stop and surface the
            // underlying HC envelope as State C — do NOT report State A for a
            // batch where a later track could not be confirmed.
            if result.isError == true {
                return cleanupApplyStateC(
                    .readbackMismatch,
                    stepID: step.id,
                    hint: "cleanup_apply: rename step '\(step.id)' stopped at track \(target) — the track.rename path did not confirm a verified rename (State B/C). Re-read logic://tracks and retry.",
                    extras: [
                        "tool": "logic_tracks",
                        "command": "rename",
                        "failed_track_index": target,
                        "applied": renamed,
                        "underlying": body,
                    ]
                )
            }
        }

        // Every target reached verified State A from the underlying rename path.
        return toolTextResult(
            HonestContract.encodeStateA(extras: [
                "op": "project.cleanup_apply",
                "step_id": step.id,
                "tool": "logic_tracks",
                "command": "rename",
                "target_track_indices": targets,
                "applied": renamed,
                "verify_source": "track.rename ax_readback",
            ])
        )
    }

    // MARK: - cleanup_apply helpers

    /// Returns a blocking hint when the audit's inventory is unsafe to act on
    /// (no document, AX occluded, stale track inventory, or a file-vs-AX track
    /// readback gap), else nil. Keeps the stale/occluded/gap gate in one place.
    private static func cleanupApplyInventoryBlocker(_ report: ProjectSessionAudit.AuditReport) -> String? {
        if !report.evidence.hasDocument {
            return "cleanup_apply: no open Logic document is confirmed; refusing to mutate."
        }
        if report.evidence.axOccluded {
            return "cleanup_apply: Accessibility readback is occluded (modal/floating window); the plan's targets cannot be trusted. Dismiss the dialog, re-run the audit, and retry."
        }
        let tracksFreshness = report.evidence.tracks.freshness
        if !tracksFreshness.available || tracksFreshness.stale {
            return "cleanup_apply: track inventory is unread or stale (available=\(tracksFreshness.available), stale=\(tracksFreshness.stale)); re-read logic://tracks before applying a step."
        }
        if report.findings.contains(where: { $0.id == "track_readback_gap" }) {
            return "cleanup_apply: the project file reports more tracks than Accessibility surfaced (track_readback_gap); plan target indices may not match the live arrange. Bring the arrange window forward, re-run the audit, and retry."
        }
        return nil
    }

    /// True when the step is a destructive delete, regardless of how it is
    /// labelled. Belt-and-braces against a future plan that mislabels a delete.
    /// Internal (not private) so the deletion-refusal invariant can be asserted
    /// directly in tests against a synthetic mislabelled delete step.
    static func cleanupApplyIsDeletion(_ step: ProjectSessionAudit.CleanupPlanStep) -> Bool {
        let command = (step.command ?? "").lowercased()
        if command.contains("delete") || command.contains("remove") { return true }
        return step.proposedOperation.lowercased().contains("delete ")
    }

    private static func bouncePreflightBlock(
        _ report: ProjectSessionAudit.AuditReport
    ) -> CallTool.Result? {
        let blockers = report.evidence.exportReadiness.blockers
        guard !blockers.isEmpty else { return nil }
        let blockerFindings = report.findings
            .filter { $0.severity == .blocker }
            .map {
                [
                    "id": $0.id,
                    "category": $0.category,
                    "summary": $0.summary,
                    "resource": $0.evidence.resource,
                    "target": $0.evidence.target ?? "",
                ]
            }
        let payload: [String: Any] = [
            "success": false,
            "verified": false,
            "error": "export_readiness_blocked",
            "failure_stage": "pre_bounce_audit",
            "status": report.evidence.exportReadiness.status,
            "blockers": blockers,
            "blocker_findings": blockerFindings,
            "hint": "logic_project.bounce refused before opening the Bounce dialog because project audit export readiness is blocked. Resolve blockers, then re-run logic_project.audit and bounce.",
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return toolTextResult(
                "{\"success\":false,\"verified\":false,\"error\":\"export_readiness_blocked\",\"failure_stage\":\"pre_bounce_audit\"}",
                isError: true
            )
        }
        return toolTextResult(String(decoding: data, as: UTF8.self), isError: true)
    }

    /// Parse `tracks:0,1,2` (the plan's `target_identifier` form) into sorted,
    /// de-duplicated non-negative indices. Returns [] for any unparseable shape
    /// so the caller fails closed instead of guessing a target.
    static func cleanupApplyTargetIndices(_ identifier: String) -> [Int] {
        let parts = identifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "tracks" else { return [] }
        let csv = parts[1]
        var indices: [Int] = []
        for token in csv.split(separator: ",") {
            guard let value = Int(token.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                return []
            }
            indices.append(value)
        }
        return Array(Set(indices)).sorted()
    }

    /// Resolve the new names for a rename step. `names` (CSV) takes precedence;
    /// `new_name` is a single-target convenience. Returns the parsed list as-is
    /// (count is validated against the target count by the caller).
    private static func cleanupApplyRenameNames(_ params: [String: Value], targetCount: Int) -> [String] {
        if let array = params["names"]?.arrayValue {
            return array.compactMap { $0.stringValue }
        }
        let csv = stringParam(params, "names")
        if !csv.isEmpty {
            return csv.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let single = stringParam(params, "new_name", "name")
        if !single.isEmpty {
            return [single]
        }
        return []
    }

    /// Extract the text body from a CallTool.Result so cleanup_apply can fold
    /// the underlying `track.rename` HC envelope into its own response.
    private static func cleanupApplyResultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    /// Build a State C (hard-failure) Honest Contract envelope for cleanup_apply
    /// with the step id always attached for diagnosis.
    private static func cleanupApplyStateC(
        _ error: HonestContract.FailureError,
        stepID: String,
        hint: String,
        extras: [String: Any] = [:]
    ) -> CallTool.Result {
        var merged: [String: Any] = [
            "op": "project.cleanup_apply",
            "step_id": stepID,
        ]
        for (k, v) in extras { merged[k] = v }
        return toolTextResult(
            HonestContract.encodeStateC(error: error, hint: hint, extras: merged),
            isError: true
        )
    }

    /// v3.1.2 (P0-3) — invalidate cache on successful project lifecycle
    /// transition (`new` / `open` / `close`). Defensive: only fires when the
    /// underlying channel reports success, so a failed AppleScript leaves
    /// the cache untouched (preserves whatever truth the poller had).
    private static func invalidateOnSuccess(_ result: ChannelResult, cache: StateCache) async {
        guard result.isSuccess else { return }
        await cache.clearProjectState()
    }

    private static func refreshRegionCache(from result: ChannelResult, cache: StateCache) async {
        guard result.isSuccess,
              let regions = try? RegionInfo.decodeToolPayload(result.message) else {
            return
        }
        await cache.updateRegions(regions.map { $0.asRegionState() })
    }

    /// H-1 (2026-05-08 enterprise review): audit phases for L1+ project
    /// commands. Splits the prior single `executed` line into three signals
    /// a SIEM can filter on.
    ///
    /// **Contract — v3.4.1 (Boomer P2-3):** `executed` is emitted
    /// **immediately before** `router.route(...)` fires, not after. This
    /// records *invocation intent* rather than *outcome*. The reasons:
    ///   - Outcome lives in the channel response (success / hard error).
    ///   - A post-route audit line would be lost if the AppleScript hung
    ///     or the actor died, exactly when audit visibility matters most.
    ///   - SIEM consumers that want the outcome can correlate the
    ///     `executed` line with the channel response by timestamp +
    ///     command name; the contract gives them both signals.
    /// Concretely: an L1 command that passes validation but fails at the
    /// channel level (Logic not running, AppleScript denied) will still
    /// show `[AUDIT] project.<command> executed` followed by an error
    /// envelope on the wire. That is the intended behaviour.
    enum AuditPhase: String, Sendable {
        /// Validation refused the call before any side effect.
        case rejected
        /// Destructive policy returned the confirmation envelope; no route
        /// was attempted, the caller is expected to retry with `confirmed:true`.
        case confirmationRequired = "confirmation_required"
        /// The underlying route was invoked. Success or hard failure is then
        /// captured in the channel response, not the audit line.
        case executed
    }

    /// Emit an audit line for L1+ commands. No-op for L0 (`is_running`,
    /// `get_regions`, etc.) so read-only ops don't pollute the audit log.
    static func audit(_ command: String, phase: AuditPhase, reason: String? = nil) {
        guard DestructivePolicy.needsAuditLog(for: command) else { return }
        if let reason {
            Log.info("[AUDIT] project.\(command) \(phase.rawValue) — \(reason)", subsystem: "project")
        } else {
            Log.info("[AUDIT] project.\(command) \(phase.rawValue)", subsystem: "project")
        }
    }

    private static func runLifecycleScript(
        script: String,
        successMessage: String,
        expectedRunning: Bool,
        actionLabel: String,
        execute: (String) async -> LifecycleExecution,
        isLogicProRunning: () -> Bool,
        sleep: (UInt64) async -> Void
    ) async -> CallTool.Result {
        let execution = await execute(script)
        if let executionError = execution.executionError {
            return toolTextResult("Failed to \(actionLabel) Logic Pro: \(executionError)", isError: true)
        }
        if execution.timedOut {
            return toolTextResult(
                "Failed to \(actionLabel) Logic Pro: timed out after \(Int(ServerConfig.appleScriptTimeout))s",
                isError: true
            )
        }
        if execution.terminationStatus != 0 {
            let message = execution.stderrOutput.isEmpty
                ? "osascript exited with status \(execution.terminationStatus)"
                : execution.stderrOutput
            return toolTextResult("Failed to \(actionLabel) Logic Pro: \(message)", isError: true)
        }

        let statePolls = Int(max(1, ServerConfig.appleScriptTimeout * 10))
        for _ in 0..<statePolls {
            if isLogicProRunning() == expectedRunning {
                return toolTextResult(successMessage)
            }
            await sleep(100_000_000)
        }

        return toolTextResult(
            "Lifecycle command completed but Logic Pro did not reach expected running state",
            isError: true
        )
    }

    static func executeAppleScript(
        _ script: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")
    ) async -> LifecycleExecution {
        let result = BoundedProcessRunner.run(
            executable: executableURL.path,
            arguments: ["-e", script],
            timeout: ServerConfig.appleScriptTimeout,
            outputLimitBytes: 32 * 1024
        )

        switch result {
        case let .spawnFailed(message):
            return LifecycleExecution(
                executionError: message,
                timedOut: false,
                terminationStatus: -1,
                stderrOutput: ""
            )
        case .timedOut:
            return LifecycleExecution(
                executionError: nil,
                timedOut: true,
                terminationStatus: -1,
                stderrOutput: ""
            )
        case let .completed(output):
            return LifecycleExecution(
                executionError: nil,
                timedOut: false,
                terminationStatus: output.exitCode,
                stderrOutput: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
