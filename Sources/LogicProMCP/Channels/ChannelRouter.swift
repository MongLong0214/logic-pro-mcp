import CoreFoundation
import Foundation

/// Routes tool operations to the appropriate channel with fallback chains.
///
/// Each tool operation has a primary channel and optional fallbacks.
/// If the primary channel fails or is unavailable, the router tries
/// each fallback in order.
actor ChannelRouter {
    /// #1084: project only typed ownership facts from this channel attempt. Never stringify an
    /// arbitrary extras dictionary, hint, title, path or AX error into the operation trace.
    static func frontmostTraceAttributes(from message: String) -> [String: String] {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var attributes: [String: String] = [:]
        if let raw = object["frontmost_preparation"] as? String,
           let preparation = FrontmostGate.Preparation(rawValue: raw) {
            attributes["frontmost_preparation"] = preparation.rawValue
        }
        guard let observation = object["frontmost_observation"] as? [String: Any] else { return attributes }
        if let raw = observation["reason"] as? String,
           let reason = ProcessUtils.KeyboardOwnershipObservation.Reason(rawValue: raw) {
            attributes["frontmost_reason"] = reason.rawValue
        }
        if let raw = observation["focus_read"] as? String,
           let focus = ProcessUtils.KeyboardOwnershipObservation.FocusRead(rawValue: raw) {
            attributes["frontmost_focus_read"] = focus.rawValue
        }
        for (source, target) in [
            ("keyboard_owner_pid", "frontmost_keyboard_owner_pid"),
            ("focused_application_pid", "frontmost_focused_application_pid"),
        ] {
            if let value = diagnosticInteger(observation[source]), (1...Int(Int32.max)).contains(value) {
                attributes[target] = String(value)
            }
        }
        if let layer = diagnosticInteger(observation["keyboard_window_layer"]),
           layer == 0 || layer == LogicOnScreenWindows.modalPanelLevel {
            attributes["frontmost_keyboard_window_layer"] = String(layer)
        }
        if let bundle = ProcessUtils.KeyboardOwnershipObservation.diagnosticBundleID(
            observation["keyboard_owner_bundle_id"] as? String
        ) {
            attributes["frontmost_keyboard_owner_bundle_id"] = bundle
        }
        return attributes
    }

    private static func diagnosticInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        // Exact bounded parsing here is export policy only, not ProcessUtils's ownership parser.
        return Int(number.stringValue)
    }

    struct StartReport: Sendable {
        let started: [ChannelID]
        let failures: [ChannelID: String]
        let degraded: [ChannelID: String]

        var hasFailures: Bool {
            !failures.isEmpty
        }

        var hasDegraded: Bool {
            !degraded.isEmpty
        }
    }

    private var channels: [ChannelID: any Channel] = [:]
    private var channelStartOrder: [ChannelID] = []

    // Operations for which an Accessibility `element_not_found` is provably a
    // PRE-WRITE miss, so a later channel may still run. Three conditions must all
    // hold before an op belongs here, and #460 is why they are written down rather
    // than left implicit:
    //
    //  1. `element_not_found` means the AX control was never located, so no
    //     actuation reached Logic and no partial write can be stranded.
    //  2. The failure is Accessibility-specific — a missing control-bar button or
    //     ruler element — not a rejection of the request itself.
    //  3. Every later candidate expresses the same semantics, so falling through
    //     cannot silently change what the caller asked for.
    //
    // `transport.goto_position` satisfies all three exactly as the toggles do: a
    // missing ruler element moves nothing, and MCU/CoreMIDI/CGEvent all position
    // the playhead. Omitting it stranded a real default-install workflow whose
    // first action was `goto_position` (Discussion #455).
    //
    // An op that can leave a partial write, or whose later candidates differ in
    // meaning, must NOT be added here; it needs per-op recovery instead.
    private static let opsAllowingAXElementNotFoundFallback: Set<String> = [
        "transport.play",
        "transport.stop",
        "transport.record",
        "transport.toggle_cycle",
        "transport.toggle_metronome",
        "transport.toggle_count_in",
        "transport.goto_position",
    ]

    /// Active routing table (v2). `internal` so test-targets can introspect
    /// the table for invariant checks (T4: bypassReadinessOps ⇄ routingTable).
    internal static let routingTable = v2RoutingTable

    /// Operations that are exempt from the runtime-readiness gate
    /// (`health.ready`). These ops live on the KeyCmd channel, whose
    /// `verificationStatus` stays `manual_validation_required` until the
    /// user completes one-time MIDI Learn — the chicken-and-egg lock-in
    /// described in PRD Issue #1 §4.1. The bypass *only* skips the
    /// readiness check; `health.available == false` (port not published)
    /// still produces a `.portUnavailable` State C envelope (terminal,
    /// no fallback).
    ///
    /// Membership is locked by `testBypassReadinessOpsContainsAllSevenKeycmdOps`
    /// and the `routingTable` ⇄ `bypassReadinessOps` invariant in
    /// `testRoutingTableInvariantBypassMatchesKeycmdSuffix` (T5 fully wires
    /// the routingTable side).
    internal static let bypassReadinessOps: Set<String> = [
        "midi.send_cc.keycmd",
        "midi.send_note.keycmd",
        "midi.send_chord.keycmd",
        "midi.send_program_change.keycmd",
        "midi.send_pitch_bend.keycmd",
        "midi.send_aftertouch.keycmd",
        "midi.play_sequence.keycmd",
    ]

    // MARK: - Lifecycle

    func register(_ channel: any Channel) {
        // Re-registering the same id replaces the channel but keeps its original
        // position, so a caller cannot reorder startup by registering twice.
        if channels.updateValue(channel, forKey: channel.id) == nil {
            channelStartOrder.append(channel.id)
        }
    }

    func startAll() async -> StartReport {
        var started: [ChannelID] = []
        var failures: [ChannelID: String] = [:]
        var degraded: [ChannelID: String] = [:]

        for id in channelStartOrder {
            guard let channel = channels[id] else { continue }
            do {
                try await channel.start()
                Log.info("Channel \(id.rawValue) started", subsystem: "router")
                started.append(id)
            } catch {
                Log.warn("Channel \(id.rawValue) failed to start: \(error)", subsystem: "router")
                if ServerConfig.optionalStartupChannels.contains(id) {
                    degraded[id] = String(describing: error)
                } else {
                    failures[id] = String(describing: error)
                }
            }
        }

        return StartReport(
            started: started.sorted { $0.rawValue < $1.rawValue },
            failures: failures,
            degraded: degraded
        )
    }

    func stopAll(excluding excluded: Set<ChannelID> = []) async {
        for (id, channel) in channels where !excluded.contains(id) {
            await channel.stop()
        }
    }

    // MARK: - Routing

    /// Route an operation through its fallback chain.
    /// Returns the result from the first channel that succeeds.

    /// The `error` and `hint` of a HonestContract State C envelope, or nil for anything else.
    ///
    /// Only a refusal that NAMED its cause is worth carrying forward: a bare string, or a success,
    /// tells the next caller nothing it could act on.
    static func typedRefusal(from raw: String) -> (error: String, hint: String)? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["success"] as? Bool) == false,
              let error = object["error"] as? String else {
            return nil
        }
        return (error, (object["hint"] as? String) ?? "")
    }

    // MARK: - Debug: one channel only (#1039)

    static let debugOnlyChannelEnvironmentKey = "LOGIC_MCP_DEBUG_ONLY_CHANNEL"

    /// What a debug build's `LOGIC_MCP_DEBUG_ONLY_CHANNEL` asked for.
    enum DebugOnlyChannel: Equatable, Sendable {
        /// Unset: every chain is walked as the table has it.
        case unrestricted
        /// Every chain keeps this channel alone.
        case only(ChannelID)
        /// Set to something that is not a channel id. Every routed operation is refused rather
        /// than walked in full, so a misspelt name cannot pass for a restriction that held.
        case invalid(String)
    }

    /// #1039 asks for each plain-letter operation to be driven live through CGEventChannel alone,
    /// and three of them (record, cycle, metronome) reach the Accessibility channel first. A debug
    /// build started with `LOGIC_MCP_DEBUG_ONLY_CHANNEL=<ChannelID raw value>` keeps only that
    /// channel in every chain, and refuses an operation whose chain does not hold it. Release
    /// builds never read the variable.
    static let debugOnlyChannel: DebugOnlyChannel = {
        #if DEBUG
        return debugOnlyChannel(from: ProcessInfo.processInfo.environment)
        #else
        return .unrestricted
        #endif
    }()

    static func debugOnlyChannel(from environment: [String: String]) -> DebugOnlyChannel {
        guard let raw = environment[debugOnlyChannelEnvironmentKey] else { return .unrestricted }
        return ChannelID(rawValue: raw).map(DebugOnlyChannel.only) ?? .invalid(raw)
    }

    static let debugPassOperationsEnvironmentKey = "LOGIC_MCP_DEBUG_ONLY_CHANNEL_PASS"

    /// #1029 drives each CGEvent fallback from a prepared state, and the dispatchers read state
    /// through chains that hold no CGEvent rung: pause and resume read `transport.get_state`, and a
    /// setup renames a track. A debug build started with `LOGIC_MCP_DEBUG_ONLY_CHANNEL_PASS` set to a
    /// comma-separated list of operations walks those operations' chains as the table has them,
    /// but only where the chain does not hold the restricted channel, so an operation under test
    /// cannot be widened by naming it. Release builds never read the variable.
    static let debugPassOperations: Set<String> = {
        #if DEBUG
        return debugPassOperations(from: ProcessInfo.processInfo.environment)
        #else
        return []
        #endif
    }()

    static func debugPassOperations(from environment: [String: String]) -> Set<String> {
        guard let raw = environment[debugPassOperationsEnvironmentKey] else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// The chain `route` walks under `restriction`, or the refusal it answers instead. Pure, so the
    /// restriction is tested without the environment.
    static func effectiveChain(
        _ chain: [ChannelID], operation: String, restriction: DebugOnlyChannel,
        pass: Set<String> = []
    ) -> Result<[ChannelID], RoutingRefusal> {
        switch restriction {
        case .unrestricted:
            return .success(chain)
        case let .only(channel):
            let kept = chain.filter { $0 == channel }
            if kept.isEmpty, pass.contains(operation) {
                return .success(chain)
            }
            guard !kept.isEmpty else {
                return .failure(RoutingRefusal(message:
                    "This debug build routes only through \(channel.rawValue) "
                    + "(\(debugOnlyChannelEnvironmentKey)), and \(operation)'s chain does not include it."))
            }
            return .success(kept)
        case let .invalid(raw):
            return .failure(RoutingRefusal(message:
                "\(debugOnlyChannelEnvironmentKey) is set to \(raw), which names no channel; "
                + "nothing was routed."))
        }
    }

    /// An operation whose chain is empty needs no channel and succeeds. A restriction that names
    /// no channel refuses it all the same, since that restriction refuses everything (#1039 review
    /// R1, R-1039-03: `project.is_running`, `system.health` and `system.permissions` answered).
    /// One that keeps a channel leaves it alone: there is no chain for it to narrow.
    static func emptyChainResult(operation: String, restriction: DebugOnlyChannel) -> ChannelResult {
        if case .invalid = restriction,
           case let .failure(refusal) = effectiveChain([], operation: operation, restriction: restriction) {
            return .error(refusal.message)
        }
        return .success("No channel required for \(operation)")
    }

    struct RoutingRefusal: Error, Equatable {
        let message: String
    }

    func route(operation: String, params: [String: String] = [:]) async -> ChannelResult {
        guard let tableChain = Self.routingTable[operation] else {
            return .error("Unknown operation: \(operation)")
        }

        // Operations with empty chain don't need a channel
        if tableChain.isEmpty {
            return Self.emptyChainResult(operation: operation, restriction: Self.debugOnlyChannel)
        }

        let chain: [ChannelID]
        switch Self.effectiveChain(
            tableChain, operation: operation, restriction: Self.debugOnlyChannel, pass: Self.debugPassOperations
        ) {
        case let .success(kept):
            chain = kept
        case let .failure(refusal):
            return .error(refusal.message)
        }

        // ADR-005: no-op unless an active mutation trace registered in this
        // task's context (flag on + mutating op).
        await OperationTraceContext.record(.routeEvaluated, attributes: [
            "chain": chain.map(\.rawValue).joined(separator: ","),
        ])

        var lastError: String = "No channels available"
        // The FIRST typed refusal the router walked past, kept so a later channel's answer can
        // carry it. A preferred channel often knows exactly why it declined — `track.set_arm`'s
        // accessibility rung says "track 0 is exclusively selected, but Logic could not be confirmed
        // frontmost … the key was NOT posted" — and until now that sentence went only to a DEBUG
        // log while the caller received the next channel's vaguer answer. Measured 2026-09-14: that
        // gap cost hours of root-causing an operation that had described its own precondition.
        var walkedPastRefusal: (channel: String, error: String, hint: String)?
        let isBypass = Self.bypassReadinessOps.contains(operation)

        for channelID in chain {
            guard let channel = channels[channelID] else {
                Log.debug("Channel \(channelID.rawValue) not registered, skipping", subsystem: "router")
                continue
            }

            let health = await channel.healthCheck()
            guard health.available else {
                // PRD Issue #1 §4.1 step 7: a bypass op (KeyCmd MIDI send)
                // whose channel reports `available:false` means the virtual
                // port itself is not published — no other channel can supply
                // it. Surface a terminal `.portUnavailable` State C envelope
                // so the LLM agent gets an actionable hint rather than a
                // silent fallthrough into "All channels exhausted".
                if isBypass {
                    Log.debug(
                        "\(operation) bypass op blocked: channel \(channelID.rawValue) unavailable (\(health.detail))",
                        subsystem: "router"
                    )
                    return .error(HonestContract.encodeStateC(
                        error: .portUnavailable,
                        hint: health.detail,
                        extras: ["operation": operation]
                    ))
                }
                Log.debug("Channel \(channelID.rawValue) unhealthy: \(health.detail), trying next", subsystem: "router")
                lastError = "Channel \(channelID.rawValue): \(health.detail)"
                continue
            }
            guard isBypass || health.ready || ServerConfig.allowManualValidationChannels else {
                Log.debug(
                    "Channel \(channelID.rawValue) requires manual validation: \(health.detail), trying next",
                    subsystem: "router"
                )
                lastError = "Channel \(channelID.rawValue) is not runtime-ready: \(health.detail)"
                continue
            }

            await OperationTraceContext.record(.channelStarted, attributes: [
                "channel": channelID.rawValue,
            ])
            // #389: an armed write boundary commits HERE — the first channel
            // that actually executes — and never on a route that resolved no
            // channel. Reads route without an arm, so this is a no-op for them.
            await OperationTraceWriteBoundaryArm.commitIfArmed()
            let result = await channel.execute(operation: operation, params: params)
            var completedAttributes = [
                "channel": channelID.rawValue,
                "outcome": result.isSuccess ? "success" : "error",
            ]
            completedAttributes.merge(Self.frontmostTraceAttributes(from: result.message)) { _, new in new }
            await OperationTraceContext.record(.channelCompleted, attributes: completedAttributes)
            switch result {
            case .success(let message):
                Log.debug("\(operation) succeeded via \(channelID.rawValue)", subsystem: "router")
                // ADDITIVE ONLY. The state, the verified flag and every field the answering channel
                // wrote stay exactly as they were; this appends what the SKIPPED channel said so the
                // caller can see the precondition it named. `addExtras` leaves State C envelopes
                // untouched of its own accord, so a refusal is never decorated with another
                // channel's story.
                guard let walkedPastRefusal else { return result }
                return .success(HonestContract.addExtras([
                    "fallback_from_channel": walkedPastRefusal.channel,
                    "fallback_from_error": walkedPastRefusal.error,
                    "fallback_from_hint": walkedPastRefusal.hint,
                ], into: message))
            case .error(let msg):
                // A channel can deliberately refuse an operation when trying
                // it through another channel would be unsafe (for example, a
                // keystroke whose target focus cannot be proved). This is
                // separate from terminal error-code classification and must
                // preserve the original State C envelope verbatim.
                // This check intentionally precedes terminal-State-C handling, so a marked
                // terminal `element_not_found` would bypass `shouldContinueAfterTerminalStateC`.
                // The two envelopes carrying the marker today — both marker-delete refusals — use
                // `ax_write_failed`, which is NOT terminal, so the ordering changes no current
                // behaviour. Do not reorder this, and do not put the marker on a terminal code,
                // without revisiting that consequence.
                if HonestContract.isFallbackUnsafeStateC(msg) {
                    Log.debug(
                        "\(operation) State C via \(channelID.rawValue) forbids fallback",
                        subsystem: "router"
                    )
                    return result
                }
                // v3.1.2 (P1-1) — terminal State C means no other channel can
                // improve on this answer (`element_not_found`, `invalid_params`,
                // `not_implemented`). Falling through to the next channel
                // would risk a vacuous success on a press-only MCU button or
                // a CGEvent shortcut that targets the wrong UI, masking the
                // honest AX failure. Preserve the original State C envelope
                // in that case instead of wrapping it in the generic
                // "All channels exhausted" message.
                if HonestContract.isTerminalStateC(msg) {
                    if Self.shouldContinueAfterTerminalStateC(operation: operation, channelID: channelID, message: msg) {
                        Log.debug(
                            "\(operation) terminal State C via \(channelID.rawValue) is recoverable by fallback: \(msg)",
                            subsystem: "router"
                        )
                        lastError = msg
                        continue
                    }
                    Log.debug(
                        "\(operation) terminal State C via \(channelID.rawValue), suppressing fallback",
                        subsystem: "router"
                    )
                    return result
                }
                Log.debug("\(operation) failed via \(channelID.rawValue): \(msg), trying next", subsystem: "router")
                if walkedPastRefusal == nil, let typed = Self.typedRefusal(from: msg) {
                    walkedPastRefusal = (channelID.rawValue, typed.error, typed.hint)
                }
                lastError = msg
            }
        }

        // P2 (verified-plugin envelope fidelity) — a single-channel chain has
        // NO fallback target, so when its sole channel already returned a valid
        // Honest Contract State C envelope, masking it behind
        // `channels_exhausted` would strip the State C fidelity the caller needs
        // (write_attempted, rollback_*, target_identity, hc_schema, state:"C").
        // This bites the verified-plugin ops (`plugin.set_param_verified` /
        // `insert_verified`), whose post-write failures `ax_write_failed` and
        // `readback_mismatch` are deliberately kept OUT of `terminalErrorCodes`
        // so MULTI-channel chains (e.g. track.set_mute) can still fall back —
        // but on a single `[.accessibility]` chain that non-terminal classification
        // wrongly routed them into the exhaustion wrapper below. Return the
        // channel's envelope verbatim instead.
        //
        // Scope guards keep this surgical:
        //   • `chain.count == 1` — multi-channel chains keep the
        //     `channels_exhausted` aggregate, so existing fallback semantics
        //     (testNonTerminalStateCStillFallsThrough) are untouched.
        //   • `stateCErrorCode(lastError) != nil` — the "channel never executed"
        //     fallthrough (not registered / unhealthy / not runtime-ready) leaves
        //     `lastError` as a free-form health string, which is naturally
        //     excluded, so the MCU/no-channel exhaustion contract is preserved.
        // Terminal State C is already returned verbatim inside the loop above, so
        // this only ever fires for the non-terminal-but-valid single-channel case.
        if chain.count == 1, HonestContract.stateCErrorCode(lastError) != nil {
            Log.debug(
                "\(operation) single-channel non-terminal State C surfaced verbatim (no fallback target to mask)",
                subsystem: "router"
            )
            return .error(lastError)
        }

        // v3.4.5-rc5 (Issues #10/#11) — wrap the "channels exhausted" fallthrough
        // in a Honest Contract State C envelope so external tooling can branch
        // on a structured error code instead of regex-matching a free-form
        // string. Uses the dedicated `.channelsExhausted` error rather than
        // `.portUnavailable` (which is reserved for the bypass-op "this
        // channel's port is unwired" semantic; see
        // v3.4.5-rc5). `last_error` carries the original chain detail for
        // debugging; `operation` lets the harness route to per-op recovery.
        return .error(HonestContract.encodeStateC(
            error: .channelsExhausted,
            hint: lastError,
            extras: [
                "operation": operation,
                "last_error": lastError,
            ]
        ))
    }

    private static func shouldContinueAfterTerminalStateC(
        operation: String,
        channelID: ChannelID,
        message: String
    ) -> Bool {
        channelID == .accessibility &&
            opsAllowingAXElementNotFoundFallback.contains(operation) &&
            HonestContract.stateCErrorCode(message) == HonestContract.FailureError.elementNotFound.rawValue
    }

    /// Get health status for all registered channels.
    func healthReport() async -> [ChannelID: ChannelHealth] {
        var report: [ChannelID: ChannelHealth] = [:]
        for (id, channel) in channels {
            report[id] = await channel.healthCheck()
        }
        return report
    }
}
