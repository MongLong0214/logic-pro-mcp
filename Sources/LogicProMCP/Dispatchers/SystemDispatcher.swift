import AppKit
import Foundation
import CoreGraphics
import MCP

struct SystemDispatcher: OperationTraceDispatching {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicSystem)

    /// Consent-first refusal for `setup_arm_key`. Returns a State C result when the
    /// request does not carry explicit `consent:"true"`, else nil. The server
    /// calls this BEFORE strict-param validation, the mutation gate, the operation
    /// trace, and any app activation, so the one-time Key Commands configuration is
    /// never touched — not even probed — without consent (#413).
    static func setupArmConsentRequiredResult(_ params: [String: Value]) -> CallTool.Result? {
        guard params["consent"]?.stringValue != "true" else { return nil }
        return toolTextResult(HonestContract.encodeStateC(
            error: .consentRequired,
            hint: "One-time setup changes Logic's Key Commands configuration so tracks can arm "
                + "coordinate-free. The server drives the Key Commands window on your behalf (no mouse). "
                + "Re-run with consent:\"true\" to proceed.",
            extras: ["stage": "consent", "write_source": "none",
                     "write_attempted": false, "configuration_write_attempted": false]
        ), isError: true)
    }

    /// Environment variable that overrides `setup_arm_key`'s server-side deadline
    /// (in whole milliseconds). Unset uses the default `DeadlineClass.long`; a
    /// valid value shortens the REAL `runWithDeadline` deadline so a genuine
    /// timeout can be exercised on the actual path (no injected sleep or seam).
    static let setupDeadlineEnvVar = "LOGIC_PRO_MCP_SETUP_DEADLINE_MS"

    enum SetupDeadlineOverride: Equatable {
        case unset
        case seconds(Double)
        case invalid(String)
    }

    /// Parse `LOGIC_PRO_MCP_SETUP_DEADLINE_MS`. Unset/empty → `.unset` (default
    /// deadline); a POSITIVE integer of milliseconds → `.seconds`; anything else
    /// (non-numeric, zero, negative, or overflowing `Int`) → `.invalid`, so setup
    /// fails closed rather than silently falling back to the default (#413).
    static func parseSetupDeadlineOverride(_ raw: String?) -> SetupDeadlineOverride {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return .unset
        }
        guard let ms = Int(trimmed), ms > 0 else { return .invalid(trimmed) }
        return .seconds(Double(ms) / 1000.0)
    }

    /// State C fail-closed envelope for a malformed `LOGIC_PRO_MCP_SETUP_DEADLINE_MS`.
    /// Returned BEFORE the mutation gate, trace, or any Logic activation — zero side
    /// effects — so a bad override never silently runs at the default deadline.
    static func setupArmDeadlineConfigInvalidResult(raw: String) -> CallTool.Result {
        toolTextResult(HonestContract.encodeStateC(
            error: .armKeyConfigInvalid,
            hint: "\(setupDeadlineEnvVar) must be a positive integer number of milliseconds; \"\(raw)\" "
                + "is not valid. Unset it to use the default deadline, or set a value like 8000. No Key "
                + "Commands change was attempted.",
            extras: ["stage": "setup_deadline_config_invalid", "write_source": "none",
                     "write_attempted": false, "configuration_write_attempted": false]
        ), isError: true)
    }

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
            struct PortCensus: Encodable {
                let state: String
                let endpointCount: Int?
                let hasForeignEndpoint: Bool?
                let reason: String?

                enum CodingKeys: String, CodingKey {
                    case state
                    case endpointCount = "endpoint_count"
                    case hasForeignEndpoint = "has_foreign_endpoint"
                    case reason
                }

                func encode(to encoder: any Encoder) throws {
                    var values = encoder.container(keyedBy: CodingKeys.self)
                    try values.encode(state, forKey: .state)
                    try values.encodeIfPresent(endpointCount, forKey: .endpointCount)
                    try values.encodeIfPresent(hasForeignEndpoint, forKey: .hasForeignEndpoint)
                    try values.encodeIfPresent(reason, forKey: .reason)
                }
            }

            let connected: Bool
            let registeredAsDevice: Bool
            let lastFeedbackAt: Date?
            let feedbackStale: Bool
            let portName: String
            let portCensus: PortCensus

            enum CodingKeys: String, CodingKey {
                case connected
                case registeredAsDevice = "registered_as_device"
                case lastFeedbackAt = "last_feedback_at"
                case feedbackStale = "feedback_stale"
                case portName = "port_name"
                case portCensus = "port_census"
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
        let logicProProjectChooserVisible: Bool
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
            case logicProProjectChooserVisible = "logic_pro_project_chooser_visible"
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
            setup_arm_key, help. \
            Params by command: \
            help -> { category: String } (returns full param docs for a dispatcher); \
            refresh_cache -> {} (force AX re-poll); \
            list_recent_traces -> { limit?: Int }; \
            get_trace -> { trace_id: String }; \
            clear_traces -> { confirmed: Bool }; \
            export_support_bundle -> { dir?: String } (local files only; never uploaded); \
            saga_preflight/saga_execute -> { steps: [step], idempotency_key: String }; \
            saga_status/saga_cancel -> { idempotency_key: String }; \
            setup_arm_key -> { consent: "true" } (one-time consent-gated Key Commands GUI \
            drive that assigns the coordinate-free record-arm chord; no mouse). \
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
        projectChooserVisible: @Sendable () -> Bool = {
            AccessibilityChannel.exactEmptyProjectChooserIsVisible()
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
        sagaLiveReadback: SagaLiveReadback? = nil,
        // #412: the shared absolute saga lifecycle deadline, computed once at
        // the server dispatch entry so the in-closure abandon race and the outer
        // transport timer derive from ONE instant. nil when the dispatcher is
        // driven directly (tests / non-server): the saga path then derives its
        // own instant from the registry budget.
        sagaLifecycleDeadline: ContinuousClock.Instant? = nil,
        // #413 — the consent-gated record-arm key-command assignment. nil-free
        // default wires the production engine (its functional verifier drives the
        // real arm actuator); tests inject a canned Outcome to exercise the
        // envelope mapping without a live Key Commands GUI.
        armKeySetup: @escaping @Sendable (
            Bool, CGKeyCode, CGEventFlags
        ) -> ArmKeyCommandSetup.Outcome = { consent, keyCode, modifiers in
            // #413: live mutation-gate ownership from the operation's trace context.
            // A successor that reclaimed the gate makes this false, so the engine
            // stops every forward key/AX mutation immediately. Defaults
            // true when driven off-server (tests / no gate held).
            let ownsGate: @Sendable () -> Bool = { OperationTraceContext.current?.ownsGate() ?? true }
            return ArmKeyCommandSetup.run(
                consent: consent,
                keyCode: keyCode,
                modifiers: modifiers,
                runtime: .production(
                    verifyArmFlip: { code, flags in
                        // The verify probe posts real chords, so it observes the same
                        // deadline AND gate-ownership boundary as the GUI drive — no
                        // key after the deadline or after the gate was reclaimed (#413).
                        AccessibilityChannel.armSetupVerify(
                            keyCode: code, modifiers: flags,
                            isCancelled: { Task.isCancelled || !ownsGate() }
                        )
                    },
                    ownsGate: ownsGate
                )
            )
        }
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
                logicProProjectChooserVisible: projectChooserVisible(),
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
                    portName: mcu.portName,
                    portCensus: .init(
                        state: mcu.portCensus.state.rawValue,
                        endpointCount: mcu.portCensus.endpointCount,
                        hasForeignEndpoint: mcu.portCensus.hasForeignEndpoint,
                        reason: mcu.portCensus.reason
                    )
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
            // The human-readable summary is what an operator wants to read, but a caller needs the
            // states themselves — `health` has always returned them and this command had not, which
            // left it violating its own declared outputSchema (#544).
            let status = PermissionChecker.check()
            // The prose stays the text: `SemanticOracleTable.systemPermissions` grades this operation by
            // asserting its four exact lines, so encoding JSON here would RED a correct answer in
            // qualification while every unit test stayed green. The states go beside it.
            return toolTextResult(
                text: status.summary,
                structured: .object([
                    "operation": .string("system.permissions"),
                    "accessibility": .string(status.accessibilityState.rawValue),
                    "automation_logic_pro": .string(status.automationState.rawValue),
                    "automation_system_events": .string(status.systemEventsAutomationState.rawValue),
                    "post_event": .string(status.postEventAccessState.rawValue),
                    // Deliberately not a plain Bool: "undetermined" is not "permission denied", and a
                    // client reading a single flag would have to treat them the same. `false` is reserved
                    // for a MEASURED denial on at least one of the four states above; when nothing was
                    // denied but something could not be verified, the key is present with a JSON `null` —
                    // not omitted — so a caller that only checks presence still sees it and must read the
                    // per-check states to learn why. See `Self.allGrantedValue`.
                    "all_granted": Self.allGrantedValue(for: status),
                    "summary": .string(status.summary),
                ])
            )

        case "refresh_cache":
            await cache.recordToolAccess()
            // Whether the poller actually ran is the difference between a refresh that HAPPENED and one
            // that was only scheduled. A caller that reads state next has to tell them apart, so it is
            // a field rather than a difference in prose.
            // Same reason as `permissions`: the oracle for this operation compares the WHOLE body to one
            // of these sentences, so the sentence stays the text.
            if let poller {
                // `refreshNow()` reports whether the cache actually advanced (at least one section was
                // written), not merely that the call returned — the poller can run and legitimately write
                // nothing (no visible Logic window yet, or an occluding dialog holds the cache steady).
                // `refreshed:true` for a poll that touched nothing would be a claim this call never
                // observed (#544 review MAJOR); the prose text is unchanged either way because the
                // mechanism ("routed through the AX fallback poller") is true regardless of the outcome.
                let advanced = await poller.refreshNow()
                let message = "State refresh completed via AX fallback poller."
                return toolTextResult(text: message, structured: .object([
                    "operation": .string("system.refresh_cache"),
                    "refreshed": .bool(advanced),
                    "source": .string("ax_fallback_poller"),
                    "message": .string(message),
                ]))
            }
            let message = "State refresh triggered. Cache will be updated on next poll cycle."
            return toolTextResult(text: message, structured: .object([
                "operation": .string("system.refresh_cache"),
                "refreshed": .bool(false),
                // Not "next_poll_cycle": no poller is attached, so this call never started — and
                // never scheduled — a future poll cycle. Naming one it did not start would be a
                // claim about a mechanism that is not wired up (#544 review MINOR).
                "source": .string("none"),
                "message": .string(message),
            ]))

        case "setup_arm_key":
            // Consent-first: refuse before the trace, the mutation gate, or any
            // app activation if explicit consent is absent (the server also gates
            // this ahead of strict-param validation). The one-time Key Commands
            // configuration is the only coordinate-free way to record-enable a
            // track (the track-header Record AXPress is a no-op; the command ships
            // unassigned and Logic 12.2+ blocks programmatic import).
            if let refusal = Self.setupArmConsentRequiredResult(params) { return refusal }
            let armTraceID = await startTraceIfEnabled(command: command)
            let keyCode: CGKeyCode
            let modifiers: CGEventFlags
            switch AccessibilityChannel.resolveArmChord() {
            case .resolved(let code, let flags):
                keyCode = code
                modifiers = flags
            case .invalidKeyCode(let raw):
                return await finalizeTrace(toolTextResult(HonestContract.encodeStateC(
                    error: .armKeyConfigInvalid,
                    hint: "LOGIC_PRO_MCP_ARM_KEYCODE '\(raw)' is not a valid decimal keycode.",
                    extras: ["stage": "resolve_chord", "write_source": "none",
                             "write_attempted": false, "configuration_write_attempted": false]
                ), isError: true), traceID: armTraceID)
            case .invalidModifierToken(let token):
                return await finalizeTrace(toolTextResult(HonestContract.encodeStateC(
                    error: .armKeyConfigInvalid,
                    hint: "LOGIC_PRO_MCP_ARM_KEY_MODIFIERS has an unknown modifier token '\(token)'.",
                    extras: ["stage": "resolve_chord", "write_source": "none",
                             "write_attempted": false, "configuration_write_attempted": false]
                ), isError: true), traceID: armTraceID)
            }
            let chordText = ArmKeyCommandSetup.chordLabel(keyCode: keyCode, modifiers: modifiers)
            let armResult: CallTool.Result
            switch armKeySetup(true, keyCode, modifiers) {
            case .consentRequired:
                armResult = toolTextResult(HonestContract.encodeStateC(
                    error: .consentRequired,
                    hint: "One-time setup assigns Logic's \"\(ArmKeyCommandSetup.commandName)\" command to "
                        + "\(chordText) so tracks arm coordinate-free. Re-run with consent:\"true\" to proceed.",
                    extras: ["stage": "consent", "chord": chordText, "write_source": "none",
                             "write_attempted": false, "configuration_write_attempted": false]
                ), isError: true)
            case .configInvalid(let hint):
                armResult = toolTextResult(HonestContract.encodeStateC(
                    error: .armKeyConfigInvalid,
                    hint: hint,
                    extras: ["stage": "arm_key_config_invalid", "chord": chordText, "write_source": "none",
                             "write_attempted": false, "configuration_write_attempted": false]
                ), isError: true)
            case .alreadyConfigured(let evidence):
                armResult = toolTextResult(HonestContract.encodeStateA(extras: evidence.extras.merging([
                    "chord": chordText,
                    "command": ArmKeyCommandSetup.commandName,
                    "verified": true,
                    "detail": "Key-command mapping already configured and functionally verified; no "
                        + "key-command configuration write performed. Verification mutation was observed "
                        + "and restored.",
                ]) { _, new in new }))
            case .configuredAndVerified(let evidence):
                armResult = toolTextResult(HonestContract.encodeStateA(extras: evidence.extras.merging([
                    "chord": chordText,
                    "command": ArmKeyCommandSetup.commandName,
                    "verified": true,
                    "detail": "Key command assigned via the Key Commands GUI and confirmed by a live "
                        + "record-arm flip.",
                ]) { _, new in new }))
            case .configuredUnverified(let why, let evidence):
                // Nothing observed the assignment on this path (no track to test),
                // so this must NOT claim "assigned" — report the steps ran but the
                // assignment is unproven.
                armResult = toolTextResult(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: evidence.extras.merging([
                        "chord": chordText,
                        "command": ArmKeyCommandSetup.commandName,
                        "detail": "Setup steps ran, but the assignment is UNPROVEN — \(why).",
                    ]) { _, new in new }
                ))
            case .failed(let stage, let hint, let evidence):
                armResult = toolTextResult(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: hint,
                    extras: evidence.extras.merging([
                        "stage": stage,
                        "chord": chordText,
                        "write_attempted": evidence.configurationWriteAttempted,
                    ]) { _, new in new }
                ), isError: true)
            }
            return await finalizeTrace(armResult, traceID: armTraceID)

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
                // #412: the mutation gate release is skipped ONLY when the
                // lifecycle timeout actually terminalized the saga as a timeout.
                // A healthy saga (work child finalized, or the timeout
                // fired-but-terminalized-nothing) always releases immediately —
                // no false 15s pin. A genuinely abandoned saga is force-marked +
                // grace-reclaimed, never released immediately (which would race
                // an orphan write) and never pinned permanently.
                let sagaAbandonedByTimeout = SagaAbandonFlag()
                defer {
                    if let mutationClaim, !sagaAbandonedByTimeout.value {
                        mutationGate?.release(mutationClaim)
                    }
                }
                // ADR-004 / issue #287 — qualification-only fault seam. #399 (CEO
                // audit P0): the seam and its wiring are compiled solely in debug
                // via `QUALIFICATION_FAULT_SEAM`. The release executor is
                // constructed with no seam, so `LOGIC_PRO_MCP_FAULT_INJECT` in the
                // process environment cannot engage any fault here.
                #if QUALIFICATION_FAULT_SEAM
                let executor = ProductionSagaStepExecutor(
                    router: router,
                    cache: cache,
                    targetRegistry: targetRegistry,
                    dialogPresent: dialogPresent,
                    liveReadback: sagaLiveReadback ?? .unavailable,
                    liveTrackName: liveTrackName,
                    liveTrackNames: liveTrackNames,
                    faultSeam: SagaPartialStateFaultSeam.resolve(
                        environment: ProcessInfo.processInfo.environment,
                        stepCount: plan.steps.count
                    )
                )
                #else
                let executor = ProductionSagaStepExecutor(
                    router: router,
                    cache: cache,
                    targetRegistry: targetRegistry,
                    dialogPresent: dialogPresent,
                    liveReadback: sagaLiveReadback ?? .unavailable,
                    liveTrackName: liveTrackName,
                    liveTrackNames: liveTrackNames
                )
                #endif
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
                // #412: ONE shared absolute lifecycle deadline. Server dispatch
                // supplies it (shared with the outer transport timer); a
                // direct/test call derives it from the registry budget.
                let lifecycleBudgetSeconds = OperationRegistry.spec(
                    tool: ToolID.logicSystem.rawValue,
                    command: "saga_execute"
                )?.deadline.seconds ?? DeadlineClass.long.seconds
                let lifecycleDeadline = sagaLifecycleDeadline
                    ?? ContinuousClock.now.advanced(by: .seconds(lifecycleBudgetSeconds))
                let deadlineReached: @Sendable () -> Bool = {
                    ContinuousClock.now >= lifecycleDeadline
                }
                let timeoutBody = SagaWire.sagaWedgeTimeout(
                    idempotencyKey: plan.idempotencyKey,
                    seconds: lifecycleBudgetSeconds,
                    gateReclaimAfterSec: LogicProServer.mutationGateReclaimGraceSeconds
                )

                // #412: the saga lifecycle runs in an UNSTRUCTURED work child
                // (never awaited at scope exit — a wedged synchronous AX call
                // cannot be cancelled, so awaiting it would defeat the deadline)
                // raced against a lifecycle DispatchWorkItem at
                // `lifecycleDeadline`. Both finishers terminalize through the
                // SAME claim/generation-guarded journal API
                // (`finalizeReturningWinner`), so whoever wins the finalize also
                // determines the client body — response bytes == journal terminal
                // bytes. Abandon side effects fire ONLY when the timeout actually
                // terminalized the saga as a timeout, and BEFORE the continuation
                // resumes so the dispatcher `defer` above observes the flag.
                let outerTraceContext = OperationTraceContext.current
                let raceResult: CallTool.Result = await withCheckedContinuation { continuation in
                    let race = SagaDeadlineRace()
                    let timeoutHandle = SagaTimeoutHandle()
                    // Unstructured but NOT detached: `Task { }` inherits the caller's
                    // task-local values (the ADR feature-flag overrides the saga
                    // preflight reads, and the trace context) while still running
                    // independently, so the dispatcher returns via the race without
                    // awaiting a wedged child. `Task.detached` would sever the flags
                    // and fail the saga closed as feature-disabled.
                    let workTask = Task(priority: .userInitiated) {
                        await OperationTraceContext.$current.withValue(outerTraceContext) {
                            let outcome = await OperationTraceParentBoundary.$onWriteBoundary.withValue(
                                onWriteBoundary
                            ) {
                                await saga.execute(
                                    plan,
                                    executor: surfaceExecutor,
                                    cancellationRequested: {
                                        if deadlineReached() { return true }
                                        return await sagaJournal.record(for: plan.idempotencyKey)
                                            == .cancellationRequested
                                    },
                                    deadlineReached: deadlineReached
                                )
                            }
                            // Preserve the prior behavior: a cancel that raced in
                            // after the saga's last checkpoint (so it completed)
                            // compensates the applied writes before terminalizing.
                            let finalOutcome: SagaOutcome
                            if await sagaJournal.record(for: plan.idempotencyKey)
                                == .cancellationRequested,
                               outcome.state == .completed {
                                finalOutcome = await saga.cancel(
                                    outcome: outcome,
                                    executor: surfaceExecutor,
                                    deadlineReached: deadlineReached
                                )
                            } else {
                                finalOutcome = outcome
                            }
                            let proposed = SagaWire.storedOutcome(plan: plan, outcome: finalOutcome)
                            let (winner, _) = await sagaJournal.finalizeReturningWinner(
                                journalClaim,
                                proposed: proposed,
                                verifiedIfCancelled: SagaWire.cancellationVerified(finalOutcome)
                            )
                            let didWin = race.resume(
                                continuation,
                                returning: toolTextResult(winner.body, isError: winner.isError)
                            )
                            if didWin { timeoutHandle.cancel() }
                        }
                    }
                    let timeoutItem = DispatchWorkItem {
                        Task {
                            let (winner, didTerminalizeTimeout) = await sagaJournal.completeOnTimeout(
                                journalClaim,
                                outcome: timeoutBody
                            )
                            race.resume(
                                continuation,
                                returning: toolTextResult(winner.body, isError: winner.isError)
                            ) {
                                // #412: abandon side effects fire only when THIS
                                // timeout actually terminalized the journal as a
                                // timeout — NOT merely because it won the resume
                                // race. If the work child already finalized
                                // (success or otherwise) and this timeout only won
                                // the race, the saga is done: pinning the gate
                                // would be a false abandon. Ordered BEFORE the
                                // continuation resumes, so the abandon flag is
                                // visible to the dispatcher `defer`.
                                guard didTerminalizeTimeout else { return }
                                sagaAbandonedByTimeout.set(true)
                                if let mutationClaim {
                                    mutationGate?.markTimedOut(mutationClaim, force: true)
                                }
                                workTask.cancel()
                            }
                        }
                    }
                    timeoutHandle.set(timeoutItem)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + LogicProServer.secondsFromNow(until: lifecycleDeadline),
                        execute: timeoutItem
                    )
                }
                return await finalizeTrace(raceResult, traceID: traceID)
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

    /// Maps the MEASURED tri-state permission aggregate (`PermissionStatus.aggregateState`,
    /// #544 review MAJOR) to the `all_granted` JSON value the `permissions` command emits:
    /// `.bool(false)` only when something was ACTIVELY DENIED, `.null` when nothing was denied
    /// but something is undetermined (never conflated with a denial), `.bool(true)` only when
    /// every check came back granted. Pure and stateless so the mapping — not just the
    /// underlying tri-state — can be pinned by a test without driving `handle` against live TCC.
    static func allGrantedValue(for status: PermissionChecker.PermissionStatus) -> Value {
        switch status.aggregateState {
        case .granted: return .bool(true)
        case .notGranted: return .bool(false)
        case .notVerifiable: return .null
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
        case writeFailed
        // Open/create/directory/durability failures propagate as SecureFD.FDError
        // and are caught by the clear_traces handler's fail-closed catch.
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
    /// the store clear (it lives outside it). The audit directory chain is
    /// materialized and the log opened + appended strictly through SecureFD
    /// (fd-relative, no-follow, identity-checked); the write is never a truncate,
    /// and any failure propagates so the caller refuses the clear (fail-closed).
    /// Returns the receipt file path for the response body.
    ///
    /// Unbounded append is ACCEPTED, not an oversight. Each line is a fixed,
    /// receipt-sized record and `clear_traces` is an l2-confirmed operator
    /// action, so the log grows with human-scale invocation frequency, not with
    /// traffic. Rotation/pruning is deliberately out of scope: a rotator that
    /// can delete receipt lines is itself an evidence-destruction surface —
    /// precisely the failure mode this receipt exists to close.
    private static func appendTraceClearAuditLine(_ receipt: [String: Any]) throws -> String {
        let receiptURL = traceClearReceiptURL
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw TraceClearReceiptError.encodingFailed
        }
        let bytes = Array((line + "\n").utf8)

        // Materialize + open + append strictly through SecureFD (fd-relative,
        // no-follow). The audit directory chain is created with no-follow opens
        // so a symlink planted for any component fails closed instead of
        // diverting the receipt outside the intended root; the log is bound with
        // O_NOFOLLOW + regular-file + st_nlink==1 so a symlink or hardlink at the
        // final component is refused; and the line is flushed to stable storage
        // before returning (the receipt is written one actor hop before the store
        // is drained, so it must be durable first). This replaces the earlier
        // create-then-realpath-check-then-open-by-path path, whose containment
        // check ran AFTER the directory was created — a check-after-use that the
        // fd-relative walk removes.
        #if DEBUG
        // TEST-ONLY: the audit-root override relocates the receipt under a temp
        // base; bridge it to SecureFD's trusted-base seam (tests root the override
        // under temporaryDirectory). Release honors neither the override nor the
        // seam (production base is home). Save + restore the prior value rather
        // than force-nil so a concurrent test's override is not clobbered.
        let priorTestBaseOverride = SecureFD._testBaseOverride
        let auditOverride = ProcessInfo.processInfo
            .environment["LOGIC_MCP_AUDIT_LOG_ROOT_OVERRIDE"]
        if let auditOverride, !auditOverride.isEmpty {
            SecureFD._testBaseOverride = FileManager.default.temporaryDirectory
        }
        defer { SecureFD._testBaseOverride = priorTestBaseOverride }
        #endif

        let (baseFD, relative) = try SecureFD.openTrustedBase(for: receiptURL)
        defer { close(baseFD) }
        // openTrustedBase guarantees the target is strictly under the base, so
        // `relative` is non-empty; this guard is defensive (unreachable in practice).
        guard let logName = relative.last else { throw TraceClearReceiptError.encodingFailed }
        let dirFD = try SecureFD.ensureDirectory(
            baseFD: baseFD, components: Array(relative.dropLast()), mode: 0o700
        )
        defer { close(dirFD) }

        // Dual first-bind: create the log exclusively the first time; if a
        // concurrent creator won the race (EEXIST) fall back to a no-follow
        // append. Both paths refuse a symlink or hardlink at the name.
        let fileFD: Int32
        let isFreshCreate: Bool
        do {
            let fd = try SecureFD.createFile(parentFD: dirFD, name: logName, mode: 0o600)
            // The exclusive-create fd opens at offset 0 WITHOUT O_APPEND; switch
            // it to append before writing so this write lands at EOF atomically,
            // exactly like the fallback path. Otherwise a concurrent clear that
            // created-then-appended in the window before this write would be
            // clobbered by a write at offset 0 — silently losing an audit line
            // (the pre-SecureFD open used O_APPEND on both create and existing).
            // Set append on the caller fd, not in the shared createFile primitive,
            // whose create-at-0 semantics other callers (support-bundle) rely on.
            let flags = fcntl(fd, F_GETFL)
            guard flags != -1, fcntl(fd, F_SETFL, flags | O_APPEND) != -1 else {
                close(fd); throw TraceClearReceiptError.writeFailed
            }
            (fileFD, isFreshCreate) = (fd, true)
        } catch SecureFD.FDError.componentOpenFailed(_, let e) where e == EEXIST {
            (fileFD, isFreshCreate) = (try SecureFD.openAppend(parentFD: dirFD, name: logName), false)
        }
        defer { close(fileFD) }

        let written = bytes.withUnsafeBytes { Darwin.write(fileFD, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw TraceClearReceiptError.writeFailed }
        try SecureFD.fullfsync(fileFD)   // receipt CONTENT durable before the drain
        // On the first-ever create, also flush the parent directory so the new
        // receipt's DIRECTORY ENTRY is durable, not just its data (a later append
        // reuses an existing entry and needs none). Intermediate components created
        // by ensureDirectory on a first-ever run rely on the filesystem's metadata
        // commit (transactional on APFS); the protected trace store is in-memory,
        // so a crash that loses an un-synced entry also loses the store — no
        // durable "cleared-but-unreceipted" state can result.
        if isFreshCreate {
            guard fsync(dirFD) == 0 else { throw TraceClearReceiptError.writeFailed }
        }
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
                  set_eq_band_verified -> { track: Int, insert: Int, band: String,
                                             parameter: String, value: Float,
                                             unit: "raw_ax_value"|"Hz"|"dB"|"Q",
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
                  logic_plugins    — Verified plugin apply-back (inventory, set_param_verified, set_eq_band_verified, insert_verified)

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

// MARK: - #412 saga abandon-race primitives

/// #412: a small `Sendable` flag the lifecycle-timeout handler sets ONLY when it
/// actually terminalized the saga as a timeout, read by the dispatcher `defer`
/// to decide whether to release the mutation gate. A healthy saga leaves it
/// false → immediate release; an abandoned saga sets it true → the gate is
/// force-marked and grace-reclaimed instead of released.
final class SagaAbandonFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// #412: the first-writer-wins single-resume guard for the saga abandon race,
/// shaped like `LogicProServer.DeadlineRace` but with a `beforeResume` hook. The
/// winner runs `beforeResume` UNDER the lock, BEFORE the continuation is
/// resumed, so a timeout winner's abandon side effects (the gate flag the
/// dispatcher `defer` reads) are ordered ahead of the resume that lets the
/// `defer` run — closing the race between the two.
final class SagaDeadlineRace: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    @discardableResult
    func resume(
        _ continuation: CheckedContinuation<CallTool.Result, Never>,
        returning result: CallTool.Result,
        beforeResume: () -> Void = {}
    ) -> Bool {
        lock.lock()
        if resumed {
            lock.unlock()
            return false
        }
        resumed = true
        beforeResume()
        lock.unlock()
        continuation.resume(returning: result)
        return true
    }
}

/// #412: cancel-safe handle for the lifecycle timeout `DispatchWorkItem`,
/// mirroring `LogicProServer.DeadlineTimeoutHandle` — the work child cancels the
/// pending timeout on a healthy win without a reference cycle, and a `cancel()`
/// that races `set()` still cancels the work item.
final class SagaTimeoutHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: DispatchWorkItem?
    private var cancelled = false

    func set(_ task: DispatchWorkItem) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
