import Foundation

/// Routes tool operations to the appropriate channel with fallback chains.
///
/// Each tool operation has a primary channel and optional fallbacks.
/// If the primary channel fails or is unavailable, the router tries
/// each fallback in order.
actor ChannelRouter {
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

    private static let transportToggleOpsAllowingAXElementFallback: Set<String> = [
        "transport.play",
        "transport.stop",
        "transport.record",
        "transport.toggle_cycle",
        "transport.toggle_metronome",
        "transport.toggle_count_in",
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
        channels[channel.id] = channel
    }

    func startAll() async -> StartReport {
        var started: [ChannelID] = []
        var failures: [ChannelID: String] = [:]
        var degraded: [ChannelID: String] = [:]

        for (id, channel) in channels {
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
    func route(operation: String, params: [String: String] = [:]) async -> ChannelResult {
        guard let chain = Self.routingTable[operation] else {
            return .error("Unknown operation: \(operation)")
        }

        // Operations with empty chain don't need a channel
        if chain.isEmpty {
            return .success("No channel required for \(operation)")
        }

        var lastError: String = "No channels available"
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

            let result = await channel.execute(operation: operation, params: params)
            switch result {
            case .success:
                Log.debug("\(operation) succeeded via \(channelID.rawValue)", subsystem: "router")
                return result
            case .error(let msg):
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
        // channel's port is unwired" semantic — see Boomer BOOMER-6 / U,
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
            transportToggleOpsAllowingAXElementFallback.contains(operation) &&
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
