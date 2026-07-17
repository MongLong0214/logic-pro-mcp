import AppKit
import Foundation
import CoreGraphics
import MCP

struct SystemDispatcher: OperationTraceDispatching {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicSystem)

    typealias SupportBundleExporter = @Sendable (
        URL,
        @Sendable () async -> Void
    ) async throws -> SupportBundleBuilder.Result

    struct LogicHealthObservation: Sendable, Equatable {
        struct VariantAvailability: Sendable, Equatable {
            let variant: LogicProVariant
            let bundleID: String
            let installed: Bool
            let running: Bool
        }

        let running: Bool
        let version: String
        let bundleID: String
        let variant: LogicProVariant
        let uiLocale: String
        let processMetadataResolved: Bool
        let variants: [VariantAvailability]
    }

    private struct HealthResponse: Encodable {
        struct VariantAvailabilitySection: Encodable {
            let variant: String
            let bundleID: String
            let installed: Bool
            let running: Bool

            enum CodingKeys: String, CodingKey {
                case variant
                case bundleID = "bundle_id"
                case installed
                case running
            }
        }

        struct MCUSection: Encodable {
            let connected: Bool
            let registeredAsDevice: Bool
            let lastFeedbackAt: Date?
            let feedbackStale: Bool
            let portName: String

            enum CodingKeys: String, CodingKey {
                case connected
                case registeredAsDevice = "registered_as_device"
                case lastFeedbackAt = "last_feedback_at"
                case feedbackStale = "feedback_stale"
                case portName = "port_name"
            }
        }

        struct ChannelSection: Encodable {
            let channel: String
            let available: Bool
            let ready: Bool
            let latencyMs: Double?
            let detail: String
            let verificationStatus: String

            enum CodingKeys: String, CodingKey {
                case channel
                case available
                case ready
                case latencyMs = "latency_ms"
                case detail
                case verificationStatus = "verification_status"
            }
        }

        struct CacheSection: Encodable {
            let pollMode: String
            let transportAgeSec: Double
            let trackCount: Int
            let project: String

            enum CodingKeys: String, CodingKey {
                case pollMode = "poll_mode"
                case transportAgeSec = "transport_age_sec"
                case trackCount = "track_count"
                case project
            }
        }

        struct PermissionsSection: Encodable {
            let accessibility: Bool
            let automation: Bool
            let automationGranted: Bool?
            let accessibilityStatus: String
            let automationStatus: String
            let automationVerifiable: Bool
            // #188: Automation → System Events is a distinct TCC target that the
            // MIDI import / tempo-dialog paths require; surfacing it stops a green
            // Logic-Pro automation line from hiding a denied System Events target.
            let automationSystemEvents: Bool
            let automationSystemEventsStatus: String
            let postEventAccess: Bool   // T5: CGPreflightPostEventAccess() — required for CGEvent.post

            enum CodingKeys: String, CodingKey {
                case accessibility
                case automation
                case automationGranted = "automation_granted"
                case accessibilityStatus = "accessibility_status"
                case automationStatus = "automation_status"
                case automationVerifiable = "automation_verifiable"
                case automationSystemEvents = "automation_system_events"
                case automationSystemEventsStatus = "automation_system_events_status"
                case postEventAccess = "post_event_access"
            }
        }

        struct ProcessSection: Encodable {
            let memoryMb: Double
            let cpuPercent: Double
            let uptimeSec: Int
            let cpuPercentStatus: String
            let cpuPercentUnits: String
            let cpuSampleWindowSec: Double

            enum CodingKeys: String, CodingKey {
                case memoryMb = "memory_mb"
                case cpuPercent = "cpu_percent"
                case uptimeSec = "uptime_sec"
                case cpuPercentStatus = "cpu_percent_status"
                case cpuPercentUnits = "cpu_percent_units"
                case cpuSampleWindowSec = "cpu_sample_window_sec"
            }
        }

        let logicProRunning: Bool
        let logicProHasWindow: Bool
        let logicProHasDocument: Bool
        let logicProVersion: String
        let logicProBundleID: String
        let logicProVariant: String
        let logicProUILocale: String
        let logicProVariants: [VariantAvailabilitySection]
        let processMetadataResolved: Bool
        let mcu: MCUSection
        let channels: [ChannelSection]
        let cache: CacheSection
        let permissions: PermissionsSection
        let process: ProcessSection

        enum CodingKeys: String, CodingKey {
            case logicProRunning = "logic_pro_running"
            case logicProHasWindow = "logic_pro_has_window"
            case logicProHasDocument = "logic_pro_has_document"
            case logicProVersion = "logic_pro_version"
            case logicProBundleID = "logic_pro_bundle_id"
            case logicProVariant = "logic_pro_variant"
            case logicProUILocale = "logic_pro_ui_locale"
            case logicProVariants = "logic_pro_variants"
            case processMetadataResolved = "process_metadata_resolved"
            case mcu
            case channels
            case cache
            case permissions
            case process
        }
    }

    static let tool = Tool(
        name: "logic_system",
        description: """
            Diagnostics, help, and saga coordination for the Logic Pro MCP server. \
            Commands: health, permissions, refresh_cache, export_support_bundle, saga_preflight, \
            saga_execute, saga_status, saga_cancel, list_recent_traces, get_trace, clear_traces, \
            help. \
            Params by command: \
            help -> { category: String } (returns full param docs for a dispatcher); \
            refresh_cache -> {} (force AX re-poll); \
            list_recent_traces -> { limit?: Int }; \
            get_trace -> { trace_id: String }; \
            clear_traces -> { confirmed: Bool }; \
            export_support_bundle -> { dir?: String } (local files only; never uploaded); \
            saga_preflight/saga_execute -> { steps: [step], idempotency_key: String }; \
            saga_status/saga_cancel -> { idempotency_key: String }. \
            Saga work is ordered best-effort work with compensation; it does not promise \
            all-or-nothing completion or durable recovery. The journal is session-only and \
            cleared when the server session ends, including process restart. \
            Others -> {}
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("System command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        poller: StatePoller? = nil,
        supportBundleExporter: SupportBundleExporter? = nil,
        targetRegistry: TargetRegistry = TargetRegistry(),
        dialogPresent: @escaping @Sendable () -> Bool = { false },
        sagaJournal: SagaJournal = SagaJournal(),
        mutationGate: LogicMutationGate? = nil,
        sagaAfterJournalBegin: (@Sendable () async -> Void)? = nil,
        sagaRefreshAfterWrite: (@Sendable () async -> Void)? = nil,
        logicHealthObservation: @Sendable () -> LogicHealthObservation = {
            productionLogicHealthObservation()
        },
        // ADR-002 F5 — live AX track-header reader forwarded to the saga
        // executor so target_ref track/mixer steps fail closed on out-of-band
        // reorder. nil by default (saga surface tests stay deterministic);
        // production dispatch supplies the real reader.
        liveTrackName: (@Sendable (Int) -> String?)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil,
        // LPMCP-PRD-004 — independent live AX reads for saga before-state,
        // verification, and compensation proof. nil by default so unit call
        // sites stay deterministic; that default is `.unavailable`, i.e. the
        // saga fails closed at before-state capture rather than reading the
        // stale-able cache mirror. Production dispatch supplies `.production`.
        sagaLiveReadback: SagaLiveReadback? = nil
    ) async -> CallTool.Result {
        switch command {
        case "list_recent_traces", "get_trace", "clear_traces":
            guard let traceResult = await handleTraceCommand(command: command, params: params) else {
                return unknownCommandResult(command)
            }
            return traceResult

        case "health":
            let report = await router.healthReport()
            var entries: [HealthResponse.ChannelSection] = []
            for (id, health) in report.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                entries.append(
                    .init(
                        channel: id.rawValue,
                        available: health.available,
                        ready: health.ready,
                        latencyMs: health.latencyMs.map { Double(String(format: "%.1f", $0)) ?? $0 },
                        detail: health.detail,
                        verificationStatus: health.verificationStatus.rawValue
                    )
                )
            }
            let snap = await cache.snapshot()
            let mcu = await cache.getMCUConnection()
            let permissions = PermissionChecker.check()
            let process = ProcessUtils.currentProcessMetrics()
            let lastFeedbackAge = mcu.lastFeedbackAt.map { Date().timeIntervalSince($0) }
            // Single source of truth shared with `project.is_running` so the
            // two signals can never disagree. AppleScript availability is
            // already surfaced separately in the `channels` array; mixing it
            // into the running-state bit made the two truths drift.
            let logicObservation = logicHealthObservation()
            let logicProHasWindow = ProcessUtils.hasVisibleWindow()
            let logicProHasDocument = await cache.getHasDocument()
            let health = HealthResponse(
                logicProRunning: logicObservation.running,
                logicProHasWindow: logicProHasWindow,
                logicProHasDocument: logicProHasDocument,
                logicProVersion: logicObservation.version,
                logicProBundleID: logicObservation.bundleID,
                logicProVariant: logicObservation.variant.rawValue,
                logicProUILocale: logicObservation.uiLocale,
                logicProVariants: logicObservation.variants.map {
                    .init(
                        variant: $0.variant.rawValue,
                        bundleID: $0.bundleID,
                        installed: $0.installed,
                        running: $0.running
                    )
                },
                processMetadataResolved: logicObservation.processMetadataResolved,
                mcu: .init(
                    connected: mcu.isConnected,
                    registeredAsDevice: mcu.registeredAsDevice,
                    lastFeedbackAt: mcu.lastFeedbackAt,
                    feedbackStale: mcu.isConnected && (lastFeedbackAge ?? .infinity) > 5.0,
                    portName: mcu.portName
                ),
                channels: entries,
                cache: .init(
                    pollMode: snap.pollMode,
                    transportAgeSec: Double(String(format: "%.1f", snap.transportAge)) ?? snap.transportAge,
                    trackCount: snap.trackCount,
                    project: snap.projectName
                ),
                permissions: .init(
                    accessibility: permissions.accessibility,
                    automation: permissions.automationLogicPro,
                    automationGranted: permissions.automationVerifiable ? permissions.automationLogicPro : nil,
                    accessibilityStatus: permissions.accessibilityState.rawValue,
                    automationStatus: permissions.automationState.rawValue,
                    automationVerifiable: permissions.automationVerifiable,
                    automationSystemEvents: permissions.automationSystemEvents,
                    automationSystemEventsStatus: permissions.systemEventsAutomationState.rawValue,
                    postEventAccess: CGPreflightPostEventAccess()
                ),
                process: .init(
                    memoryMb: Double(String(format: "%.1f", process.memoryMB)) ?? process.memoryMB,
                    cpuPercent: Double(String(format: "%.1f", process.cpuPercent)) ?? process.cpuPercent,
                    uptimeSec: process.uptimeSec,
                    cpuPercentStatus: process.cpuPercentStatus,
                    cpuPercentUnits: process.cpuPercentUnits,
                    cpuSampleWindowSec: Double(String(format: "%.3f", process.cpuSampleWindowSec))
                        ?? process.cpuSampleWindowSec
                )
            )
            let json = encodeJSON(health)
            return toolTextResult(json)

        case "permissions":
            let status = PermissionChecker.check()
            return toolTextResult(status.summary)

        case "refresh_cache":
            await cache.recordToolAccess()
            if let poller {
                await poller.refreshNow()
                return toolTextResult("State refresh completed via AX fallback poller.")
            }
            return toolTextResult("State refresh triggered. Cache will be updated on next poll cycle.")

        case "export_support_bundle":
            let createdAt = Date()
            let directory: URL
            if let raw = params["dir"] {
                // PRD-011: no arbitrary absolute targets. The requested
                // directory must resolve INSIDE the dedicated support-bundle
                // root (a relative subpath, or an absolute path already under
                // the root) — symlinks in existing ancestors are resolved
                // before the containment check so a link cannot escape it.
                guard let path = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty,
                      let contained = Self.resolvedSupportBundleDirectory(requested: path) else {
                    return toolInvalidParamsResult(
                        "export_support_bundle 'dir' must resolve inside the support-bundle root "
                            + "(~/Library/Logs/LogicProMCP/support-bundles) — pass a relative subpath "
                            + "or omit 'dir' for an auto-named bundle"
                    )
                }
                directory = contained
            } else {
                directory = defaultSupportBundleDirectory(createdAt: createdAt)
            }
            let traceID = await startTraceIfEnabled(command: command)
            do {
                let result: SupportBundleBuilder.Result
                if let supportBundleExporter {
                    result = try await supportBundleExporter(directory) {
                        await recordWriteBoundary(traceID)
                    }
                } else {
                    result = try await exportSupportBundle(
                        to: directory,
                        createdAt: createdAt,
                        router: router,
                        onFirstWrite: { await recordWriteBoundary(traceID) }
                    )
                }
                // PRD-011 TOCTOU close: the pre-write containment check ran
                // against the requested path, but a symlink/mount planted
                // between that check and directory creation could leave the
                // materialized bundle outside the root. Re-resolve the CREATED
                // directory through realpath; if it escaped, delete it and fail
                // closed rather than reporting a State A for an out-of-root write.
                guard Self.createdBundleDirectoryIsContained(result.directory) else {
                    try? FileManager.default.removeItem(at: result.directory)
                    return await finalizeTrace(
                        toolTextResult(
                            HonestContract.encodeStateC(
                                error: .supportBundleExportFailed,
                                hint: "support bundle directory escaped the containment root "
                                    + "after creation; refused",
                                extras: ["write_attempted": true]
                            ),
                            isError: true
                        ),
                        traceID: traceID
                    )
                }
                return await finalizeTrace(
                    toolTextResult(HonestContract.encodeStateA(extras: [
                        "bundle_path": result.directory.path,
                        "files": result.files.map { ["name": $0.name, "sha256": $0.sha256] },
                    ])),
                    traceID: traceID
                )
            } catch {
                return await finalizeTrace(
                    toolTextResult(
                        HonestContract.encodeStateC(
                            error: .supportBundleExportFailed,
                            hint: "Support bundle could not be written to the requested local directory"
                        ),
                        isError: true
                    ),
                    traceID: traceID
                )
            }

        case "saga_preflight":
            let plan: SagaPlan
            do {
                plan = try SagaWire.plan(from: params)
            } catch {
                return SagaWire.invalidParams(error)
            }
            let journalIssues: [[String: Any]]
            switch await sagaJournal.disposition(for: plan) {
            case .conflict:
                journalIssues = [[
                    "code": HonestContract.FailureError.idempotencyKeyConflict.rawValue,
                ]]
            case .capacityExceeded:
                journalIssues = [[
                    "code": HonestContract.FailureError.sagaJournalCapacityExceeded.rawValue,
                ]]
            case .cancellationRequested, .cancelled:
                journalIssues = [[
                    "code": HonestContract.FailureError.unsupportedState.rawValue,
                ]]
            case .outcomeEvicted(let terminal):
                // LPMCP-PRD-005: unlike `.completed` (where execute hands back
                // the stored body and preflight stays ok), an evicted body means
                // execute WILL refuse — so preflight must say so up front.
                journalIssues = [[
                    "code": HonestContract.FailureError.sagaOutcomeUnavailable.rawValue,
                    "terminal_kind": terminal.rawValue,
                ]]
            case .available, .inProgress, .completed:
                journalIssues = []
            }
            let executor = ProductionSagaStepExecutor(
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                dialogPresent: dialogPresent,
                liveReadback: sagaLiveReadback ?? .unavailable,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            )
            let preflight = await MutationSaga(
                targetRegistry: targetRegistry,
                routeAvailable: Self.sagaRouteProbe(router: router)
            ).preflight(plan)
            let availability = await executor.captureBeforeStateAvailability(plan: plan)
            let availabilityIssues = SagaWire.availabilityIssues(availability, plan: plan)
            let issues = preflight.issues.map(SagaWire.preflightIssue)
                + availabilityIssues
                + journalIssues
            let body = SagaWire.sessionFields
                .merging(SagaWire.journalMetricsFields(await sagaJournal.metrics())) { _, new in new }
                .merging([
                    "ok": issues.isEmpty,
                    "issues": issues,
                    "before_state_availability": SagaWire.availabilityObjects(
                        availability,
                        plan: plan
                    ),
                    "writes_performed": 0,
                ]) { _, new in new }
            return toolTextResult(HonestContract.jsonString(body))

        case "saga_execute":
            let traceID = await startTraceIfEnabled(command: command)
            let plan: SagaPlan
            do {
                plan = try SagaWire.plan(from: params)
            } catch {
                return await finalizeTrace(SagaWire.invalidParams(error), traceID: traceID)
            }
            switch await sagaJournal.begin(plan) {
            case .inProgress:
                return await finalizeTrace(
                    SagaWire.scopedStateC(
                        .sagaInProgress,
                        hint: "A saga with this idempotency_key is still running",
                        extras: ["idempotency_key": plan.idempotencyKey]
                    ),
                    traceID: traceID
                )
            case .cancellationRequested:
                return await finalizeTrace(
                    SagaWire.scopedStateC(
                        .sagaInProgress,
                        hint: "Cancellation is pending for this saga",
                        extras: ["idempotency_key": plan.idempotencyKey]
                    ),
                    traceID: traceID
                )
            case .cancelled:
                return await finalizeTrace(
                    SagaWire.scopedStateC(
                        .unsupportedState,
                        hint: "The saga was cancelled and cannot be executed",
                        extras: ["idempotency_key": plan.idempotencyKey]
                    ),
                    traceID: traceID
                )
            case .completed(let outcome):
                let duplicate = SagaWire.duplicateOutcome(outcome)
                return await finalizeTrace(
                    toolTextResult(duplicate.body, isError: duplicate.isError),
                    traceID: traceID
                )
            case .conflict:
                return await finalizeTrace(
                    SagaWire.idempotencyConflict(plan.idempotencyKey),
                    traceID: traceID
                )
            case .capacityExceeded:
                return await finalizeTrace(
                    SagaWire.journalCapacityExceeded(plan.idempotencyKey),
                    traceID: traceID
                )
            case .outcomeEvicted(let terminal):
                // LPMCP-PRD-005: this key already ran to a terminal state in
                // this session. Returning here — before any executor exists —
                // is what makes "an evicted body never re-fires a write"
                // structural rather than a promise.
                return await finalizeTrace(
                    SagaWire.outcomeUnavailable(plan.idempotencyKey, terminal: terminal),
                    traceID: traceID
                )
            case .started(let journalClaim):
                await sagaAfterJournalBegin?()
                let mutationClaim: LogicMutationGate.Claim?
                if let mutationGate {
                    guard let acquired = mutationGate.tryAcquire(
                        operation: OperationID.systemSagaExecute.rawValue,
                        reclaimPolicy: .releaseOnly
                    ) else {
                        let result = SagaWire.scopedStateC(
                                .mutatingOperationInProgress,
                                hint: "Saga execution is waiting for the active mutation to finish",
                                extras: [
                                    "idempotency_key": plan.idempotencyKey,
                                    "active_operation": mutationGate.currentOperation()
                                        as Any? ?? NSNull(),
                                    "safe_to_retry": true,
                                    "write_attempted": false,
                                ]
                        )
                        await sagaJournal.finishGateRefusal(
                            journalClaim,
                            cancellationOutcome: SagaWire.storedOutcome(from: result)
                        )
                        return await finalizeTrace(result, traceID: traceID)
                    }
                    mutationClaim = acquired
                } else {
                    mutationClaim = nil
                }
                defer {
                    if let mutationClaim { mutationGate?.release(mutationClaim) }
                }
                let executor = ProductionSagaStepExecutor(
                    router: router,
                    cache: cache,
                    targetRegistry: targetRegistry,
                    dialogPresent: dialogPresent,
                    liveReadback: sagaLiveReadback ?? .unavailable,
                    liveTrackName: liveTrackName,
                    liveTrackNames: liveTrackNames,
                    // ADR-004 / issue #287 — qualification-only fault seam. nil
                    // in normal operation; engages only when the operator sets
                    // LOGIC_PRO_MCP_FAULT_INJECT=partial_state to qualify real
                    // reverse-order compensation. Never a product code path.
                    faultSeam: SagaPartialStateFaultSeam.resolve(
                        environment: ProcessInfo.processInfo.environment,
                        stepCount: plan.steps.count
                    )
                )
                let saga = MutationSaga(
                    targetRegistry: targetRegistry,
                    routeAvailable: Self.sagaRouteProbe(router: router)
                )
                let preflight = await saga.preflight(plan)
                let availability = await executor.captureBeforeStateAvailability(plan: plan)
                let availabilityIssues = SagaWire.availabilityIssues(availability, plan: plan)
                if !preflight.issues.isEmpty || !availabilityIssues.isEmpty {
                    let result = SagaWire.scopedStateC(
                        SagaWire.executionFailureError(
                            preflightIssues: preflight.issues,
                            availabilityIssues: availabilityIssues
                        ),
                        hint: "Saga preflight rejected the plan",
                        extras: [
                            "idempotency_key": plan.idempotencyKey,
                            "duplicate": false,
                            "issues": preflight.issues.map(SagaWire.preflightIssue)
                                + availabilityIssues,
                            "before_state_availability": SagaWire.availabilityObjects(
                                availability,
                                plan: plan
                            ),
                        ]
                    )
                    await sagaJournal.completeBeforeWrite(
                        journalClaim,
                        outcome: SagaWire.storedOutcome(from: result)
                    )
                    return await finalizeTrace(result, traceID: traceID)
                }
                let refreshAfterWrite: @Sendable () async -> Void
                if let sagaRefreshAfterWrite {
                    refreshAfterWrite = sagaRefreshAfterWrite
                } else if let poller {
                    refreshAfterWrite = { await poller.refreshNow() }
                } else {
                    refreshAfterWrite = {}
                }
                let surfaceExecutor = SagaSurfaceStepExecutor(
                    base: executor,
                    refreshAfterWrite: refreshAfterWrite
                )
                let parentBoundary = SagaFirstWriteBoundary()
                let onWriteBoundary: @Sendable () async -> Void = {
                    guard let traceID else { return }
                    await parentBoundary.cross {
                        await OperationTraceStore.shared.record(
                            traceID,
                            phase: .writeBoundaryCrossed
                        )
                    }
                }
                let outcome = await OperationTraceParentBoundary.$onWriteBoundary.withValue(
                    onWriteBoundary
                ) {
                    await saga.execute(
                        plan,
                        executor: surfaceExecutor,
                        cancellationRequested: {
                            await sagaJournal.record(for: plan.idempotencyKey) == .cancellationRequested
                        }
                    )
                }
                let completed = SagaWire.storedOutcome(plan: plan, outcome: outcome)
                if await sagaJournal.complete(journalClaim, outcome: completed) {
                    return await finalizeTrace(
                        toolTextResult(completed.body, isError: completed.isError),
                        traceID: traceID
                    )
                }
                guard await sagaJournal.record(for: plan.idempotencyKey) == .cancellationRequested else {
                    return await finalizeTrace(
                        toolTextResult(completed.body, isError: completed.isError),
                        traceID: traceID
                    )
                }
                let finalOutcome = outcome.state == .completed
                    ? await saga.cancel(outcome: outcome, executor: surfaceExecutor)
                    : outcome
                let stored = SagaWire.storedOutcome(plan: plan, outcome: finalOutcome)
                await sagaJournal.completeCancellation(
                    journalClaim,
                    outcome: stored,
                    verified: SagaWire.cancellationVerified(finalOutcome)
                )
                return await finalizeTrace(
                    toolTextResult(stored.body, isError: stored.isError),
                    traceID: traceID
                )
            }

        case "saga_status":
            let idempotencyKey: String
            do {
                idempotencyKey = try SagaWire.idempotencyKey(from: params)
            } catch {
                return SagaWire.invalidParams(error)
            }
            guard let record = await sagaJournal.record(for: idempotencyKey) else {
                return SagaWire.scopedStateC(
                    .elementNotFound,
                    hint: "No saga journal record exists for this idempotency_key",
                    extras: ["idempotency_key": idempotencyKey]
                )
            }
            let details: [String: Any]
            switch record {
            case .inProgress:
                details = ["status": "in_progress"]
            case .cancellationRequested:
                details = ["status": "cancellation_requested"]
            case .cancelled(let outcome, let verified):
                details = [
                    "status": "cancelled",
                    "verified": verified,
                    "outcome_retained": true,
                    "outcome": SagaWire.jsonObject(outcome.body),
                ]
            case .completed(let outcome):
                details = [
                    "status": "completed",
                    "outcome_retained": true,
                    "outcome": SagaWire.jsonObject(outcome.body),
                ]
            case .outcomeEvicted(let terminal):
                // LPMCP-PRD-005: `status` still names the terminal path the key
                // took — the replay-protection record is intact. `outcome` is
                // ABSENT (not null, not a stand-in) and `outcome_retained:false`
                // says why. `verified` is likewise absent for an evicted
                // cancellation: it lived in the body, and inventing one would be
                // the exact dishonesty this record exists to prevent.
                details = ["status": terminal.rawValue, "outcome_retained": false]
            }
            return toolTextResult(HonestContract.jsonString(
                SagaWire.sessionFields
                    .merging(SagaWire.journalMetricsFields(await sagaJournal.metrics())) {
                        _, new in new
                    }
                    .merging([
                        "idempotency_key": idempotencyKey,
                        "record": details,
                    ]) { _, new in new }
            ))

        case "saga_cancel":
            let traceID = await startTraceIfEnabled(command: command)
            let idempotencyKey: String
            do {
                idempotencyKey = try SagaWire.idempotencyKey(from: params)
            } catch {
                return await finalizeTrace(SagaWire.invalidParams(error), traceID: traceID)
            }
            let result: CallTool.Result
            switch await sagaJournal.cancel(idempotencyKey: idempotencyKey) {
            case .notFound:
                result = SagaWire.scopedStateC(
                    .elementNotFound,
                    hint: "No saga journal record exists for this idempotency_key",
                    extras: ["idempotency_key": idempotencyKey]
                )
            case .completed:
                result = SagaWire.scopedStateC(
                    .unsupportedState,
                    hint: "The saga is already completed",
                    extras: ["idempotency_key": idempotencyKey]
                )
            case .outcomeEvicted(let terminal):
                // LPMCP-PRD-005: the key IS known and terminal — answering
                // `element_not_found` here would deny a record we still hold.
                result = SagaWire.outcomeUnavailable(idempotencyKey, terminal: terminal)
            case .requested, .alreadyRequested:
                result = toolTextResult(HonestContract.encodeStateB(
                    reason: .sagaCancellationPending,
                    extras: SagaWire.sessionFields.merging([
                        "idempotency_key": idempotencyKey,
                        "status": "cancellation_requested",
                    ]) { _, new in new }
                ))
            case .cancelled(let outcome, let verified):
                let extras = SagaWire.sessionFields.merging([
                    "idempotency_key": idempotencyKey,
                    "status": "cancelled",
                    "outcome": SagaWire.jsonObject(outcome.body),
                ]) { _, new in new }
                result = verified
                    ? toolTextResult(HonestContract.encodeStateA(extras: extras))
                    : toolTextResult(HonestContract.encodeStateB(
                        reason: .sagaReconciliationRequired,
                        extras: extras
                    ))
            }
            return await finalizeTrace(result, traceID: traceID)

        case "help":
            // #219: an unknown category used to fall through to full help with
            // isError:false, hiding client typos. An absent category still means
            // "full help", but a present-but-unrecognized category now returns a
            // typed `unknown_category` State C that lists the valid categories.
            if let requested = params["category"]?.stringValue,
               !Self.validHelpCategories.contains(requested) {
                let body = HonestContract.encodeStateC(
                    error: .unknownCategory,
                    hint: "Unknown help category '\(requested)'. "
                        + "Valid categories: \(Self.validHelpCategories.joined(separator: ", ")).",
                    extras: [
                        "requested_category": requested,
                        "valid_categories": Self.validHelpCategories,
                    ]
                )
                return toolTextResult(body, isError: true)
            }
            let category = stringParam(params, "category", default: "all")
            let helpText = Self.helpText(for: category)
            return toolTextResult(helpText)

        default:
            return unknownCommandResult(command)
        }
    }

    static func productionLogicHealthObservation() -> LogicHealthObservation {
        let runtime = LogicProTarget.Runtime.production
        let variants = LogicProTarget.knownVariants.map { variant in
            let running = !runtime.runningApplications(variant.bundleID).isEmpty
            return LogicHealthObservation.VariantAvailability(
                variant: variant,
                bundleID: variant.bundleID,
                installed: running || runtime.installedApplicationURL(variant.bundleID) != nil,
                running: running
            )
        }
        guard let application = LogicProTarget.runningApplication(runtime: runtime),
              let bundleID = application.bundleIdentifier,
              let variant = LogicProVariant.from(bundleID: bundleID) else {
            return LogicHealthObservation(
                running: false,
                version: "unknown",
                bundleID: "unknown",
                variant: .unknown,
                uiLocale: "unknown",
                processMetadataResolved: false,
                variants: variants
            )
        }
        let version = application.bundleURL
            .flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let pid = application.processIdentifier
        let uiLocale = AXLogicProElements.logicUILocaleIdentifier(runtime: .init(
            logicProPID: { pid },
            ax: .production
        )) ?? "unknown"
        return LogicHealthObservation(
            running: true,
            version: version,
            bundleID: bundleID,
            variant: variant,
            uiLocale: uiLocale,
            processMetadataResolved: true,
            variants: variants
        )
    }

    /// PRD-011: the ONLY directory support bundles may be written under.
    /// Overridable for tests via environment (never in production launchd
    /// plists) so containment behavior is provable against a temp root.
    static var supportBundleRoot: URL {
        // PRD-011: the root override is a TEST-ONLY hook (DEBUG builds), never
        // honored in a release binary — otherwise a hostile environment could
        // repoint the containment root in production and defeat the whole
        // guard. Release builds always use the fixed user Logs location.
        #if DEBUG
        if let override = ProcessInfo.processInfo
            .environment["LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"],
            !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LogicProMCP/support-bundles", isDirectory: true)
            .standardizedFileURL
    }

    /// PRD-015 (ADR-005 #288): the directory the `clear_traces` audit receipt is
    /// written under, OUTSIDE the in-process trace store it records the clearing
    /// of. Overridable for tests via a DEBUG-only environment hook (never
    /// honored in a release binary, mirroring `supportBundleRoot`) so the
    /// fail-closed / append-only behavior is provable against a temp root.
    static var auditLogRoot: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo
            .environment["LOGIC_MCP_AUDIT_LOG_ROOT_OVERRIDE"],
            !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LogicProMCP/audit", isDirectory: true)
            .standardizedFileURL
    }

    /// PRD-015 receipt schema tag. Bumped only on a breaking field change so a
    /// consumer can branch on the version rather than sniff individual keys.
    static let traceClearReceiptSchema = "logic_pro_mcp_trace_clear_receipt.v1"

    /// The append-only audit log the `clear_traces` receipt is appended to.
    static var traceClearReceiptURL: URL {
        auditLogRoot.appendingPathComponent("trace-clear.log", isDirectory: false)
    }

    private enum TraceClearReceiptError: Error {
        case encodingFailed
        case openFailed(errno: Int32)
        case writeFailed
        /// The audit directory resolved OUTSIDE its intended parent (symlink
        /// planted for the final component) — the receipt must never be
        /// diverted out of the containment root, so the clear is refused.
        case auditDirectoryEscaped
    }

    /// PRD-015 receipt fields — counts + timestamps ONLY, never trace contents,
    /// paths, or params, so the log itself leaks nothing about the evidence it
    /// records the destruction of. `authorization` records the boundary that
    /// sanctioned the clear so a future operator-approval integration can slot
    /// in without a schema bump.
    ///
    /// `trace_count_at_receipt` is deliberately named for what it can honestly
    /// promise: the count SNAPSHOT taken when this line was written, one actor
    /// hop before the store was drained. When `actualClearedCount` is supplied
    /// the line is an amendment (see `appendTraceClearAmendment`) and carries
    /// the drain's true number alongside the snapshot it corrects. Schema stays
    /// `.v1`: both fields are additive and the tag brands the record shape, so
    /// a consumer branching on it keeps parsing every line.
    private static func traceClearReceiptFields(
        traceCountAtReceipt: Int,
        actualClearedCount: Int? = nil
    ) -> [String: Any] {
        var receipt: [String: Any] = [
            "schema": traceClearReceiptSchema,
            "cleared_at": ISO8601DateFormatter.cacheFormatter.string(from: Date()),
            "trace_count_at_receipt": traceCountAtReceipt,
            "authorization": "mcp_confirmed_param",
            "server_version": ServerConfig.serverVersion,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        if let actualClearedCount {
            receipt["amends"] = true
            receipt["actual_cleared_count"] = actualClearedCount
        }
        return receipt
    }

    /// PRD-015: append ONE JSON line to the durable audit log. The line survives
    /// the store clear (it lives outside it). Opened `O_APPEND` (never
    /// truncated); the directory is created and containment-checked fail-closed
    /// (any error propagates so the caller refuses the clear). Returns the
    /// receipt file path for the response body.
    ///
    /// Unbounded append is ACCEPTED, not an oversight. Each line is a fixed,
    /// receipt-sized record and `clear_traces` is an l2-confirmed operator
    /// action, so the log grows with human-scale invocation frequency, not with
    /// traffic. Rotation/pruning is deliberately out of scope: a rotator that
    /// can delete receipt lines is itself an evidence-destruction surface —
    /// precisely the failure mode this receipt exists to close.
    private static func appendTraceClearAuditLine(_ receipt: [String: Any]) throws -> String {
        let root = auditLogRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The directory now EXISTS, so re-resolve it through realpath BEFORE
        // any write: a symlink planted for the audit dir would otherwise divert
        // the receipt — and with it the whole evidence trail — outside the
        // intended root, which is indistinguishable from having no receipt.
        guard auditDirectoryIsContained(root) else {
            throw TraceClearReceiptError.auditDirectoryEscaped
        }
        let receiptURL = traceClearReceiptURL
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw TraceClearReceiptError.encodingFailed
        }
        let bytes = Array((line + "\n").utf8)
        let fd = open(receiptURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw TraceClearReceiptError.openFailed(errno: errno) }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw TraceClearReceiptError.writeFailed }
        return receiptURL.path
    }

    /// PRD-015: record a trace clear, written BEFORE the store is drained so a
    /// clear can never destroy evidence without a surviving durable record.
    private static func appendTraceClearReceipt(traceCountAtReceipt: Int) throws -> String {
        try appendTraceClearAuditLine(
            traceClearReceiptFields(traceCountAtReceipt: traceCountAtReceipt)
        )
    }

    /// PRD-015: amend an already-durable receipt whose snapshot count the atomic
    /// drain then contradicted. The first line is NEVER rewritten — the log
    /// tells the truth by growing, never by editing history, which is the only
    /// form of honesty an append-only audit trail can offer. The amendment is
    /// self-describing (`amends:true` + `actual_cleared_count`) so a consumer
    /// reading lines in order lands on the true count without ambiguity.
    @discardableResult
    static func appendTraceClearAmendment(
        traceCountAtReceipt: Int,
        actualClearedCount: Int
    ) throws -> String {
        try appendTraceClearAuditLine(
            traceClearReceiptFields(
                traceCountAtReceipt: traceCountAtReceipt,
                actualClearedCount: actualClearedCount
            )
        )
    }

    /// PRD-015 symlink hardening: the audit directory must resolve INSIDE its
    /// intended parent — production `~/Library/Logs/LogicProMCP`, or the
    /// DEBUG override root's parent when the test hook is set. Mirrors the
    /// support-bundle containment check (`createdBundleDirectoryIsContained`):
    /// realpath BOTH sides, then require the directory to resolve strictly
    /// under the parent. Because `realpath` follows the final component while
    /// the parent is resolved independently, a symlink planted for the audit
    /// dir resolves outside the parent and is caught. Fail-closed when either
    /// side cannot be canonicalized — an unresolved path is never contained.
    static func auditDirectoryIsContained(_ directory: URL) -> Bool {
        guard let parentPath = realpathResolvedPath(directory.deletingLastPathComponent()),
              let resolved = realpathResolvedPath(directory) else { return false }
        return resolved.hasPrefix(parentPath + "/")
            && !resolved.split(separator: "/").contains("..")
    }

    /// Resolves a caller-requested bundle directory strictly inside the
    /// support-bundle root, or nil. Relative subpaths resolve against the
    /// root; absolute paths must already be under it. `..` is collapsed by
    /// standardization and every EXISTING ancestor is resolved through
    /// `realpath` (Foundation's `resolvingSymlinksInPath()` leaves symlinked
    /// ancestors unresolved when the path tail does not exist yet), so
    /// neither dot-dot traversal nor a symlink planted under the root can
    /// escape containment. The result must be STRICTLY inside (the root
    /// itself is not a valid bundle directory).
    static func resolvedSupportBundleDirectory(requested: String) -> URL? {
        // Fail closed if either root or candidate cannot be canonicalized.
        guard let rootPath = realpathResolvedPath(supportBundleRoot) else { return nil }
        let candidate: URL = requested.hasPrefix("/")
            ? URL(fileURLWithPath: requested, isDirectory: true)
            : supportBundleRoot.appendingPathComponent(requested, isDirectory: true)
        guard let resolvedPath = realpathResolvedPath(candidate) else { return nil }
        // String-level containment on realpath output — URL standardization
        // is deliberately avoided post-realpath because Foundation strips the
        // /private prefix only for EXISTING paths, which makes root/candidate
        // canonical forms diverge when the candidate tail does not exist yet.
        guard resolvedPath.hasPrefix(rootPath + "/"),
              !resolvedPath.split(separator: "/").contains("..") else {
            return nil
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    /// PRD-011 TOCTOU close: after the bundle directory is created, re-resolve
    /// it through realpath and confirm it is still strictly inside the root —
    /// a symlink or mount planted between the pre-write check and creation
    /// cannot leave a bundle outside the containment root. Returns false if
    /// the created directory escaped (caller must refuse and not write).
    static func createdBundleDirectoryIsContained(_ directory: URL) -> Bool {
        guard let rootPath = realpathResolvedPath(supportBundleRoot),
              let resolved = realpathResolvedPath(directory) else { return false }
        return resolved.hasPrefix(rootPath + "/")
            && !resolved.split(separator: "/").contains("..")
    }

    /// realpath-resolves the deepest EXISTING prefix of `url` (following every
    /// symlink in it) and re-appends the not-yet-existing tail literally.
    /// Returns a plain path string so both sides of the containment check use
    /// the same canonical form.
    /// Returns nil (fail-closed) when the deepest existing prefix cannot be
    /// canonicalized — an unresolved path must never be treated as contained.
    private static func realpathResolvedPath(_ url: URL) -> String? {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.pathComponents.count > 1 {
            tail.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        guard let raw = realpath(existing.path, nil) else { return nil }
        var base = String(cString: raw)
        free(raw)
        for component in tail.reversed() {
            base += "/" + component
        }
        return base
    }

    private static func defaultSupportBundleDirectory(createdAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return supportBundleRoot
            .appendingPathComponent(
                "\(formatter.string(from: createdAt))-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
    }

    private static func exportSupportBundle(
        to directory: URL,
        createdAt: Date,
        router: ChannelRouter,
        onFirstWrite: @escaping @Sendable () async -> Void
    ) async throws -> SupportBundleBuilder.Result {
        let approvalStore = ManualValidationStore()
        let approvals = await approvalStore.list()
        let manualStoreHealth = await approvalStore.health()
        let doctor = try await SupportBundleBuilder.runBlocking {
            SetupDoctor.generate(
                arguments: [CommandLine.arguments.first ?? "LogicProMCP", "doctor", "--json"],
                permissionStatus: PermissionChecker.check(),
                approvals: approvals,
                manualStoreHealth: manualStoreHealth
            )
        }
        let channels = await router.healthReport().sorted { $0.key.rawValue < $1.key.rawValue }.map {
            SupportBundleBuilder.ChannelMetadata(
                id: $0.key.rawValue,
                available: $0.value.available,
                ready: $0.value.ready,
                verificationStatus: $0.value.verificationStatus.rawValue
            )
        }
        let process = ProcessUtils.currentProcessMetrics()
        let target = LogicProTarget.current
        let input = SupportBundleBuilder.Input(
            createdAt: createdAt,
            serverVersion: ServerConfig.serverVersion,
            serverCommit: "unknown",
            logic: .init(
                version: ProcessUtils.logicProVersion() ?? "unknown",
                variant: target.variantLabel,
                locale: AXLogicProElements.logicUILocaleIdentifier() ?? "unknown"
            ),
            qualificationReference: "not_available",
            traces: await OperationTraceStore.shared.recent(limit: .max),
            doctorReport: doctor,
            metadata: .init(
                process: .init(uptimeSec: process.uptimeSec, memoryMb: process.memoryMB),
                channels: channels
            )
        )
        return try await SupportBundleBuilder().build(input, at: directory, onFirstWrite: onFirstWrite)
    }

    /// ADR-004 preflight route probe: every reversible-allowlist operation
    /// executes through the accessibility channel, so a plan is routable only
    /// while that channel reports available. Checked before step 1 so a dead
    /// channel cannot strand a half-applied plan.
    private static func sagaRouteProbe(
        router: ChannelRouter
    ) -> @Sendable (OperationID) async -> Bool {
        { _ in
            await router.healthReport()[.accessibility]?.available ?? false
        }
    }

    private static func unknownCommandResult(_ command: String) -> CallTool.Result {
        unhandledCommandResult(command, label: "system")
    }

    private static func handleTraceCommand(
        command: String,
        params: [String: Value]
    ) async -> CallTool.Result? {
        switch command {
        case "list_recent_traces":
            let limit: Int
            if params["limit"] == nil {
                limit = OperationTraceStore.defaultMaximumTraceCount
            } else if let requested = intParamOrNil(params, "limit") {
                limit = min(max(0, requested), OperationTraceStore.defaultMaximumTraceCount)
            } else {
                return toolInvalidParamsResult("list_recent_traces 'limit' must be an integer")
            }
            guard FeatureFlags.adr005OperationTrace else {
                return toolTextResult(HonestContract.jsonString([
                    "note": "trace_disabled",
                    "trace_disabled": true,
                    "traces": [],
                ]))
            }
            let traces = await OperationTraceStore.shared.recent(limit: limit)
            let summaries: [[String: Any]] = traces.map { trace in
                var summary: [String: Any] = [
                    "trace_id": trace.traceID.rawValue,
                    "operation_id": trace.operationID,
                    "phase_count": trace.events.count,
                ]
                if let state = trace.events.reversed().compactMap({
                    $0.attributes["readback_state"]
                }).first {
                    summary["readback_state"] = state
                }
                return summary
            }
            return toolTextResult(HonestContract.jsonString(["traces": summaries]))

        case "get_trace":
            guard let rawID = params["trace_id"]?.stringValue else {
                return toolInvalidParamsResult("get_trace requires string 'trace_id'")
            }
            guard TraceID.isValid(rawID) else {
                return toolInvalidParamsResult("get_trace 'trace_id' is malformed")
            }
            guard FeatureFlags.adr005OperationTrace else {
                return toolStateCResult(
                    .notSupported,
                    hint: "Operation tracing is on by default; it was disabled with LOGIC_MCP_ADR005_OPERATION_TRACE=0",
                    extras: [
                        "operation": "system.get_trace",
                        "trace_disabled": true,
                        "write_attempted": false,
                    ]
                )
            }
            guard let trace = await OperationTraceStore.shared.trace(TraceID(rawValue: rawID)) else {
                return toolStateCResult(
                    .elementNotFound,
                    hint: "No operation trace exists for the requested trace_id"
                )
            }
            let events: [[String: Any]] = trace.events.map { event in
                [
                    "phase": event.phase.rawValue,
                    "timestamp": ISO8601DateFormatter.cacheFormatter.string(from: event.wallClock),
                    "attributes": event.attributes,
                ]
            }
            return toolTextResult(HonestContract.jsonString([
                "trace_id": trace.traceID.rawValue,
                "operation_id": trace.operationID,
                "events": events,
            ]))

        case "clear_traces":
            // ADR-003: the confirmed-gate requirement is the registry's
            // ConfirmationPolicy (l2), not a dispatcher-local rule. If the
            // registry entry ever went missing the gate stays required —
            // over-gating is the safe drift direction; the census test pins
            // the entry so the requirement cannot silently relax.
            let clearTracesConfirmation = OperationRegistry.spec(
                tool: ToolID.logicSystem.rawValue,
                command: "clear_traces"
            )?.confirmation ?? .l2
            if DestructivePolicy.level(of: clearTracesConfirmation) >= .l2 {
                switch strictBoolParam(params, "confirmed") {
                case .value(true):
                    break
                case .invalid(let hint):
                    return toolInvalidParamsResult("clear_traces \(hint)")
                case .missing, .value(false):
                    return toolInvalidParamsResult(
                        "clear_traces requires 'confirmed:true' because it destroys in-process diagnostic evidence"
                    )
                }
            }
            guard FeatureFlags.adr005OperationTrace else {
                // PRD-014: a no-op clear must never claim success — tracing
                // is disabled, nothing was cleared, and the catalog advertises
                // these operations as experimental in this configuration.
                return toolTextResult(
                    HonestContract.encodeStateC(
                        error: .traceDisabled,
                        hint: "Operation tracing is on by default; it was disabled with "
                            + "LOGIC_MCP_ADR005_OPERATION_TRACE=0, so nothing was cleared. "
                            + "Unset the variable (or set it to any value other than \"0\") to record and manage traces.",
                        extras: ["trace_disabled": true, "write_attempted": false]
                    ),
                    isError: true
                )
            }
            // PRD-015 (ADR-005 #288): the authorization boundary for this
            // destructive op stays `confirmed:true` — this is a LOCAL,
            // single-user MCP server, so the durable boundary is (a) the
            // registry's l2 confirmation gate checked above and (b) an
            // append-only audit receipt written OUTSIDE the cleared store,
            // below. `authorization` is recorded in the receipt so a future
            // operator-approval integration slots in without a schema change.
            //
            // Fail closed: snapshot the count, then write the receipt BEFORE
            // clearing. If the receipt cannot be written the store is left
            // intact and a typed State C is returned — never destroy evidence
            // without a surviving durable record of the clear.
            //
            // The snapshot and the drain are two actor hops with file IO
            // between them, so a trace started in that window would make the
            // receipt's count wrong. The ordering is NOT relaxed to fix that
            // (receipt-before-destruction is the whole guarantee); instead the
            // drain is atomic and reports what it ACTUALLY removed, and any
            // divergence is amended with a second append-only line below.
            let countAtReceipt = await OperationTraceStore.shared.traceCount
            let receiptPath: String
            do {
                receiptPath = try appendTraceClearReceipt(traceCountAtReceipt: countAtReceipt)
            } catch {
                return toolStateCResult(
                    .traceClearReceiptFailed,
                    hint: "clear_traces refused: the durable audit receipt could not be written; "
                        + "the trace store was left intact. Fix the audit-log location and retry.",
                    // The receipt write WAS attempted (and failed); what the
                    // caller needs to know is that the STORE is untouched.
                    extras: ["store_cleared": false]
                )
            }
            let actualCleared = await OperationTraceStore.shared.clearReturningCount()
            if actualCleared != countAtReceipt {
                // The receipt is already durable and is never rewritten. If the
                // amendment itself cannot be written the clear has ALREADY
                // happened, so State C would be a lie — report the true count
                // and leave a warning rather than claim nothing was cleared.
                do {
                    try appendTraceClearAmendment(
                        traceCountAtReceipt: countAtReceipt,
                        actualClearedCount: actualCleared
                    )
                } catch {
                    Log.warn(
                        "clear_traces receipt amendment could not be appended: the durable "
                            + "receipt records \(countAtReceipt) trace(s) at snapshot but "
                            + "\(actualCleared) were actually cleared",
                        subsystem: .server
                    )
                }
            }
            return toolTextResult(HonestContract.jsonString([
                "success": true,
                "receipt_path": receiptPath,
                // The drain's true number, not the earlier snapshot.
                "cleared_trace_count": actualCleared,
            ]))

        default:
            return nil
        }
    }

    // MARK: - Help text

    /// Accepted `help` categories. `"all"` (and an absent category) returns the
    /// full help; every other entry maps to a dispatcher-specific section in
    /// `helpText(for:)`. Kept in lockstep with that switch by
    /// `testValidHelpCategoriesStayInLockstepWithHelpText` so a new dispatcher
    /// section can't drift out of the accepted set.
    static let validHelpCategories = [
        "all", "transport", "tracks", "mixer", "midi", "edit", "navigate", "project",
        "audio", "plugins", "system",
    ]

    private static func helpText(for category: String) -> String {
        switch category {
        case "transport":
            return """
                logic_transport commands:
                  play              -> {} — Start playback
                  stop              -> {} — Stop playback
                  record            -> {} — Start recording
                  pause             -> {} — Pause playback
                  rewind            -> {} — Rewind
                  fast_forward      -> {} — Fast forward
                  toggle_cycle      -> {} — Toggle cycle/loop mode
                  toggle_metronome  -> {} — Toggle metronome
                  toggle_count_in   -> {} — Toggle count-in
                  toggle_autopunch  -> {} — Toggle Autopunch
                  set_tempo         -> { tempo: Float } — Set BPM (5-999)
                  goto_position     -> { bar: Int (1..9999) } or { position: String } — bar.beat.sub.tick or HH:MM:SS:FF SMPTE
                  set_cycle_range   -> { start: Int, end: Int } — Bar numbers (UNSUPPORTED/best-effort: Logic 12.x exposes no numeric cycle-locator fields; fails closed with State C not_implemented, cannot verify a write)

                Read state via resource: logic://transport/state
                """

        case "tracks":
            return """
                logic_tracks commands:
                  select            -> { index: Int } or { name: String }
                  create_audio      -> {} — New audio track
                  create_instrument -> {} — New software instrument track
                  create_drummer    -> {} — New Drummer track
                  create_external_midi -> {} — New external MIDI track
                  delete            -> { index: Int }
                  duplicate         -> { index: Int }
                  rename            -> { index: Int, name: String }
                  mute              -> { index: Int, enabled: Bool }
                  solo              -> { index: Int, enabled: Bool }
                  arm               -> { index: Int, enabled: Bool } — idempotent (reads checkbox state)
                  arm_only          -> { index: Int } — disarms others, arms target; returns error on partial disarm failure
                  record_sequence   -> { bar?: Int, notes: "pitch,offsetMs,durMs[,vel[,ch]];...", tempo?: Float }
                                       v3.0.8 SMF-import: generates a MIDI file, forces playhead to bar 1, imports via AX menu.
                                       Creates a new track per call; if Logic imports GM Device / External MIDI lanes,
                                       returns audibility_unverified instead of claiming audible success.
                                       Response: { created_track, recorded_to_track, instrument }. `instrument` is always
                                       `"not-attempted"` (or `"ignored:<legacy instrument_path>"` for clients still sending the
                                       removed param). Callers that want a specific patch call set_instrument separately on a Software Instrument track — see
                                       CHANGELOG v3.0.8 for the selectTrackViaAX limitation on fresh SMF-created tracks.
                  set_automation    -> { index: Int, mode: String } (read/write/touch/latch/trim; independent readback required for State A)
                  set_instrument    -> { index: Int, path: String } OR { index: Int, category: String, preset: String }
                  list_library      -> {} — Read currently visible Library columns
                  scan_library      -> { mode?: "ax"|"disk"|"both" } — disk (default) dedupes user/app-bundle Instrument .patch candidates; ax runs legacy live Panel scan; both returns diff
                  resolve_path      -> { path: String } — Cache-backed Library lookup
                  scan_plugin_presets -> { submenuOpenDelayMs?: Int } — Focused plugin Setting-menu scan

                Read state via resources: logic://tracks, logic://tracks/{index}
                """

        case "mixer":
            return """
                logic_mixer commands:
                  set_volume        -> { track: Int, value: Float } (0.0-1.0)
                  set_pan           -> { track: Int, value: Float } (-1.0 to 1.0)
                  set_master_volume -> { value: Float }
                  set_plugin_param  -> { track: Int, insert: 0, param: Int, value: Float } — selected track via Scripter

                Read state via resource: logic://mixer
                """

        case "midi":
            return """
                logic_midi commands:
                  send_note         -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }
                  send_chord        -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }
                  send_cc           -> { controller: Int, value: Int, channel: Int }
                  send_program_change -> { program: Int, channel: Int }
                  send_pitch_bend   -> { value: Int, channel: Int } (0 to 16383, center=8192)
                  send_aftertouch   -> { value: Int, channel: Int }
                  send_sysex        -> { bytes: [Int] } or { data: String } (≤1024 bytes)
                  play_sequence     -> { notes: "pitch,offsetMs,durMs[,vel[,ch]];..." } — tight rhythm (≤256 events)
                  list_ports        -> {} — same data as logic://midi/ports (prefer resource for polling)
                  create_virtual_port -> { name: String }
                  step_input        -> { note: Int, duration: String|Int }
                  mmc_play          -> {}
                  mmc_stop          -> {}
                  mmc_record        -> {}
                  mmc_locate        -> { bar: Int } or { time: "HH:MM:SS:FF" }

                Read ports via resource: logic://midi/ports
                """

        case "edit":
            return """
                logic_edit commands:
                  undo              -> {} — Undo last action
                  redo              -> {} — Redo last undone action
                  cut               -> {} — Cut selection
                  copy              -> {} — Copy selection
                  paste             -> {} — Paste at playhead
                  delete            -> {} — Delete selection
                  select_all        -> {} — Select all
                  split             -> {} — Split at playhead
                  join              -> {} — Join selected regions
                  quantize          -> { value: String } ("1/4", "1/8", "1/16")
                  bounce_in_place   -> {} — Bounce selection to audio
                  normalize         -> {} — Normalize audio
                  duplicate         -> {} — Duplicate selection
                  toggle_step_input -> {} — Toggle Step Input Keyboard
                """

        case "navigate":
            return """
                logic_navigate commands:
                  goto_bar          -> { bar: Int }
                  goto_marker       -> { index: Int } or { name: String }
                  create_marker     -> { name: String }
                  delete_marker     -> { index: Int }
                  rename_marker     -> { index: Int, name: String } — independent readback required for State A
                  zoom_to_fit       -> {}
                  set_zoom          -> { level: String } ("in", "out", "fit")
                  toggle_view       -> { view: String } (mixer, piano_roll, score,
                                       step_editor, library, inspector, automation)
                """

        case "project":
            return """
                logic_project commands:
                  new               -> {} — Create new project
                  open              -> { path: String } — Open .logicx file
                  save              -> {} — Save current project
                  save_as           -> { path: String } — Save to new path
                  close             -> {} — Close project
                  bounce            -> {} — Open bounce dialog after audit preflight;
                                       export blockers return export_readiness_blocked
                  get_regions       -> {} — Read visible arrange regions with complete=false scope metadata
                  export_plan       -> { projects, output_root, artifacts? } — Dry-run export manifest plan
                  launch            -> {} — Launch Logic Pro
                  quit              -> {} — Quit Logic Pro

                Read project info via resource: logic://project/info
                """

        case "audio":
            return """
                logic_audio commands:
                  analyze_file      -> { path: String, output_root?: String,
                                         min_duration_seconds?: Float,
                                         expected_duration_seconds?: Float,
                                         max_duration_drift_seconds?: Float,
                                         min_file_size_bytes?: Int,
                                         max_input_file_size_bytes?: Int,
                                         max_input_duration_seconds?: Float,
                                         max_decoded_frames?: Int,
                                         max_peak_dbfs?: Float,
                                         near_silence_dbfs?: Float,
                                         max_silence_ratio?: Float,
                                         expected_sample_rate?: Int,
                                         expected_channel_count?: Int }
                                       Read-only analysis of an absolute audio artifact path.
                """

        case "plugins":
            return """
                logic_plugins commands:
                  get_inventory     -> { track: Int } — Read a drift-safe insert chain
                  set_param_verified -> { track: Int, insert: Int, plugin: String,
                                          param: String, value: Float, unit: String,
                                          mode: "duplicate_applyback",
                                          project_expected_path: String }
                  insert_verified   -> { track: Int, insert: Int,
                                         plugin: "Gain"|"Channel EQ"|"Compressor",
                                         mode: "duplicate_applyback",
                                         project_expected_path: String }

                Verified writes return State A only after AX readback matches.
                """

        case "system":
            return """
                logic_system commands:
                  health            -> {} — Channel status + cache info
                  permissions       -> {} — macOS permission status
                  refresh_cache     -> {} — Force AX re-poll
                  export_support_bundle -> { dir?: String } — Write privacy-safe local diagnostics; never upload
                  list_recent_traces -> { limit?: Int } — List recent in-process operation traces
                  get_trace         -> { trace_id: String } — Read one in-process operation trace
                  clear_traces      -> { confirmed: Bool } — Clear diagnostic evidence; requires confirmed:true
                  saga_preflight    -> { steps: [step], idempotency_key: String } — Validate and inspect before-state availability; writes 0
                  saga_execute      -> { steps: [step], idempotency_key: String } — Execute ordered steps with evidence and compensation
                  saga_status       -> { idempotency_key: String } — Read the session journal
                  saga_cancel       -> { idempotency_key: String } — Request cancellation; State B until unwind is journaled, then terminal status carries its outcome
                  help              -> { category: String } — Param docs per category

                step = { operation_id: String, target_ref?: String, params: Object,
                         expected_inverse: { operation_id: String, value_parameter: String } }

                Saga execution is ordered best-effort work with compensation. It does not promise
                all-or-nothing completion or durable recovery. The session journal is cleared when
                the server session ends, including process restart.

                Categories: transport, tracks, mixer, midi, edit, navigate, project, audio, plugins, system

                Read health via resource: logic://system/health

                Manual channel approval CLI:
                  LogicProMCP --approve-channel MIDIKeyCommands
                  LogicProMCP --approve-channel Scripter
                  LogicProMCP --list-approvals
                  LogicProMCP --revoke-channel <channel>
                """

        default:
            return """
                Logic Pro MCP — 10 dispatcher tools + \(ResourceProvider.resources.count) resources + \(ResourceProvider.templates.count) templates

                Tools (actions):
                  logic_transport  — Transport control (play, stop, record, tempo...)
                  logic_tracks     — Track management (create, mute, solo, arm...)
                  logic_mixer      — Mixer control (volume, pan, plugins...)
                  logic_midi       — MIDI operations (notes, CC, MMC...)
                  logic_edit       — Editing (undo, cut, quantize...)
                  logic_navigate   — Navigation + views (markers, zoom, toggle views...)
                  logic_project    — Project lifecycle (open, save, bounce...)
                  logic_audio      — Read-only audio artifact analysis
                  logic_system     — Diagnostics + help
                  logic_plugins    — Verified plugin apply-back (inventory, set_param_verified, insert_verified)

                Resources (reads — zero tool cost):
                  logic://system/health         — System health
                  logic://transport/state       — Transport state
                  logic://tracks                — All tracks
                  logic://mixer                 — Mixer state
                  logic://markers               — All project markers
                  logic://project/info          — Project info
                  logic://project/audit         — Read-only project/session audit
                  logic://project/cleanup-plan  — Read-only serializable cleanup plan
                  logic://midi/ports            — MIDI ports
                  logic://mcu/state             — MCU control-surface state (readable even when disconnected)
                  logic://library/inventory     — Cached Library tree JSON
                  logic://stock-plugins         — Stock plugin intelligence catalog
                  logic://stock-plugins/census  — Stock plugin census metadata
                  logic://stock-plugins/capabilities — Stock plugin catalog capabilities
                  logic://stock-instruments     — Stock instrument intelligence catalog
                  logic://session-players       — Session Player + Drummer catalog
                  logic://workflow-skills       — Validated workflow skills pack
                  logic://workflow-skills/schema — Workflow skill schema

                Resource templates:
                  logic://tracks/{index}          — Single track detail
                  logic://tracks/{index}/regions  — Regions on a single track
                  logic://mixer/{strip}           — Single channel strip
                  logic://stock-plugins/{id}      — Stock plugin detail
                  logic://stock-plugins/search?query={query} — Stock plugin search
                  logic://stock-instruments/{id}  — Stock instrument detail
                  logic://stock-instruments/search?query={query} — Stock instrument search
                  logic://session-players/{id}    — Session Player detail
                  logic://workflow-plans/session?prompt={prompt} — Dry-run session plan
                  logic://workflow-skills/{id}    — Workflow skill detail
                  logic://workflow-skills/search?query={query} — Workflow skill search
                  logic://system/operations       — Registry-generated operation catalog

                Use: logic_system(command: "help", params: {category: "transport"})
                for detailed command docs per category.
                """
        }
    }
}
