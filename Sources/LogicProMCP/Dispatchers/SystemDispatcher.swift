import Foundation
import CoreGraphics
import MCP

struct SystemDispatcher: OperationTraceDispatching {
    typealias SupportBundleExporter = @Sendable (
        URL,
        @Sendable () async -> Void
    ) async throws -> SupportBundleBuilder.Result
    private struct HealthResponse: Encodable {
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
            saga_execute, saga_status, saga_cancel, help. \
            Params by command: \
            help -> { category: String } (returns full param docs for a dispatcher); \
            refresh_cache -> {} (force AX re-poll); \
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
        sagaRefreshAfterWrite: (@Sendable () async -> Void)? = nil
    ) async -> CallTool.Result {
        if FeatureFlags.adr005OperationTrace,
           let traceResult = await handleTraceCommand(command: command, params: params) {
            return traceResult
        }

        switch command {
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
            let logicProRunning = ProcessUtils.isLogicProRunning
            let logicProHasWindow = ProcessUtils.hasVisibleWindow()
            let logicProHasDocument = await cache.getHasDocument()
            let resolvedTarget = LogicProTarget.current
            let health = HealthResponse(
                logicProRunning: logicProRunning,
                logicProHasWindow: logicProHasWindow,
                logicProHasDocument: logicProHasDocument,
                logicProVersion: ProcessUtils.logicProVersion() ?? "unknown",
                logicProBundleID: resolvedTarget.bundleID,
                logicProVariant: resolvedTarget.variantLabel,
                processMetadataResolved: resolvedTarget.processMetadataResolved,
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
                guard let path = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty,
                      path.hasPrefix("/") else {
                    return toolInvalidParamsResult("export_support_bundle 'dir' must be an absolute path")
                }
                directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
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
            case .available, .inProgress, .completed:
                journalIssues = []
            }
            let executor = ProductionSagaStepExecutor(
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                dialogPresent: dialogPresent
            )
            let preflight = await MutationSaga(targetRegistry: targetRegistry).preflight(plan)
            let availability = await executor.captureBeforeStateAvailability(plan: plan)
            let availabilityIssues = SagaWire.availabilityIssues(availability, plan: plan)
            let issues = preflight.issues.map(SagaWire.preflightIssue)
                + availabilityIssues
                + journalIssues
            let body = SagaWire.sessionFields.merging([
                "ok": issues.isEmpty,
                "issues": issues,
                "before_state_availability": SagaWire.availabilityObjects(availability, plan: plan),
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
            case .started(let journalClaim):
                let mutationClaim: LogicMutationGate.Claim?
                if let mutationGate {
                    guard let acquired = mutationGate.tryAcquire(
                        operation: OperationID.systemSagaExecute.rawValue,
                        reclaimPolicy: .releaseOnly
                    ) else {
                        await sagaJournal.abandon(journalClaim)
                        return await finalizeTrace(
                            SagaWire.scopedStateC(
                                .mutatingOperationInProgress,
                                hint: "Saga execution is waiting for the active mutation to finish",
                                extras: [
                                    "idempotency_key": plan.idempotencyKey,
                                    "active_operation": mutationGate.currentOperation()
                                        as Any? ?? NSNull(),
                                    "safe_to_retry": true,
                                    "write_attempted": false,
                                ]
                            ),
                            traceID: traceID
                        )
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
                    dialogPresent: dialogPresent
                )
                let saga = MutationSaga(targetRegistry: targetRegistry)
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
                    await sagaJournal.complete(
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
                    await saga.execute(plan, executor: surfaceExecutor)
                }
                let stored = SagaWire.storedOutcome(plan: plan, outcome: outcome)
                await sagaJournal.complete(journalClaim, outcome: stored)
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
            case .completed(let outcome):
                details = ["status": "completed", "outcome": SagaWire.jsonObject(outcome.body)]
            }
            return toolTextResult(HonestContract.jsonString(
                SagaWire.sessionFields.merging([
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
            switch await sagaJournal.record(for: idempotencyKey) {
            case nil:
                result = SagaWire.scopedStateC(
                    .elementNotFound,
                    hint: "No saga journal record exists for this idempotency_key",
                    extras: ["idempotency_key": idempotencyKey]
                )
            case .inProgress:
                result = SagaWire.scopedStateC(
                    .notSupported,
                    hint: "The current saga engine does not expose safe step-boundary cancellation",
                    extras: ["idempotency_key": idempotencyKey]
                )
            case .completed:
                result = SagaWire.scopedStateC(
                    .unsupportedState,
                    hint: "The saga is already completed",
                    extras: ["idempotency_key": idempotencyKey]
                )
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

    private static func defaultSupportBundleDirectory(createdAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LogicProMCP/support-bundles", isDirectory: true)
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
                locale: Locale.current.identifier
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

    private static func unknownCommandResult(_ command: String) -> CallTool.Result {
        toolTextResult(
            "Unknown system command: \(command). Available: health, permissions, refresh_cache, export_support_bundle, saga_preflight, saga_execute, saga_status, saga_cancel, help",
            isError: true
        )
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
            guard let trace = await OperationTraceStore.shared.trace(TraceID(rawValue: rawID)) else {
                return toolStateCResult(
                    .elementNotFound,
                    hint: "No operation trace exists for the requested trace_id"
                )
            }
            let events: [[String: Any]] = trace.events.map { event in
                [
                    "phase": event.phase.rawValue,
                    "timestamp": String(describing: event.timestamp),
                    "attributes": event.attributes,
                ]
            }
            return toolTextResult(HonestContract.jsonString([
                "trace_id": trace.traceID.rawValue,
                "operation_id": trace.operationID,
                "events": events,
            ]))

        case "clear_traces":
            await OperationTraceStore.shared.clear()
            return toolTextResult(HonestContract.jsonString(["success": true]))

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
                  set_automation    -> { index: Int, mode: String } (read/write/touch/latch/trim/off)
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
                  rename_marker     -> { index: Int, name: String } (UNSUPPORTED:
                                       not implemented; returns State C
                                       not_implemented — delete + create to rename)
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
                  saga_preflight    -> { steps: [step], idempotency_key: String } — Validate and inspect before-state availability; writes 0
                  saga_execute      -> { steps: [step], idempotency_key: String } — Execute ordered steps with evidence and compensation
                  saga_status       -> { idempotency_key: String } — Read the session journal
                  saga_cancel       -> { idempotency_key: String } — Typed not_supported with the current engine
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

                Use: logic_system(command: "help", params: {category: "transport"})
                for detailed command docs per category.
                """
        }
    }
}
