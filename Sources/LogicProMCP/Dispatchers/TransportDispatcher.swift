import Foundation
import MCP

struct TransportDispatcher: OperationTraceDispatching {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicTransport)
    /// Logic's public tempo contract. Keep every tempo-writing surface on this one range.
    static let supportedTempoRange: ClosedRange<Double> = 5.0...999.0

    static let tool = Tool(
        name: "logic_transport",
        description: "Control Logic Pro transport. Commands: play, stop, record, pause, rewind, fast_forward, toggle_cycle, toggle_metronome, set_tempo, goto_position, set_cycle_range, toggle_count_in, toggle_autopunch. Params: set_tempo -> { tempo: Float } (5.0-999.0); goto_position -> { bar: Int (1..9999) } or { position: String } where String is bar.beat.sub.tick (e.g. \"9.1.1.1\") or HH:MM:SS:FF SMPTE (e.g. \"00:00:08:12\"); set_cycle_range -> { start: Int, end: Int } (UNSUPPORTED/best-effort: Logic 12.x exposes no numeric cycle-locator fields, so this fails closed with State C not_implemented and CANNOT verify a write); others -> {}.",
        inputSchema: commandParamsToolSchema(commandDescription: "Transport command to execute")
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        dialogPresent: @escaping @Sendable () -> Bool = { false }
    ) async -> CallTool.Result {
        if let operation = modalGuardedTransportOperation(for: command), dialogPresent() {
            let traceID = await startTraceIfEnabled(command: command)
            return await finalizeTrace(
                blockingLogicDialogResult(operation: operation),
                traceID: traceID
            )
        }

        switch command {
        case "play":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await handleVerifiedTransportCommand(
                action: .play,
                router: router,
                sleep: sleep,
                traceID: traceID
            )
            return await finalizeTrace(result, traceID: traceID)

        case "stop":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await verifiedStopResult(
                router: router,
                cache: cache,
                sleep: sleep,
                traceID: traceID
            )
            return await finalizeTrace(result, traceID: traceID)

        case "record":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await handleVerifiedTransportCommand(
                action: .record,
                router: router,
                sleep: sleep,
                traceID: traceID
            )
            return await finalizeTrace(result, traceID: traceID)

        case "pause":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await verifiedPauseResult(
                router: router,
                cache: cache,
                sleep: sleep,
                traceID: traceID
            )
            return await finalizeTrace(result, traceID: traceID)

        case "rewind":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "transport.rewind")
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "fast_forward":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "transport.fast_forward")
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "toggle_cycle":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "transport.toggle_cycle")
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "toggle_metronome":
            let traceID = await startTraceIfEnabled(command: command)
            let beforeTransport = await liveTransportState(router: router, cache: cache)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "transport.toggle_metronome")
            }
            let finalized = await finalizeToggleMetronomeResult(
                result,
                beforeTransport: beforeTransport,
                router: router,
                cache: cache
            )
            return await finalizeTrace(finalized, traceID: traceID)

        case "toggle_count_in":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "transport.toggle_count_in")
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "toggle_autopunch":
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: "transport.toggle_autopunch")
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "set_tempo":
            guard params["tempo"] != nil || params["bpm"] != nil else {
                return toolInvalidParamsResult(
                    "set_tempo requires explicit 'tempo' or 'bpm'"
                )
            }
            guard let tempo = doubleParamOrNil(params, "tempo", "bpm") else {
                return toolInvalidParamsResult(
                    "set_tempo requires numeric 'tempo' or 'bpm'"
                )
            }
            // Logic Pro's tempo range is 5..990 BPM; the schema documents 20..999.
            // Accept a slightly-wider 5..999 to match Logic's actual behavior,
            // reject anything clearly absurd so a typo doesn't silently pass.
            guard Self.supportedTempoRange.contains(tempo) else {
                    return toolInvalidParamsResult(
                        "set_tempo 'tempo' must be in 5..999 (got \(tempo))"
                    )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "transport.set_tempo",
                    params: ["bpm": String(tempo)]
                )
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        case "goto_position":
            // Reject unknown keys before falling back to defaults. Prior to
            // v3.0.0 a legacy `time` alias was silently accepted; callers that
            // never updated their schema would silently seek to bar 1. Now the
            // tool fails closed and surfaces exactly which key was wrong.
            let allowedKeys: Set<String> = ["bar", "position"]
            let unknownKeys = params.keys.filter { !allowedKeys.contains($0) }
            if !unknownKeys.isEmpty {
                let sorted = unknownKeys.sorted().joined(separator: ", ")
                return toolTextResult(
                    "goto_position got unknown param(s): \(sorted). Allowed: \(allowedKeys.sorted().joined(separator: ", ")). The legacy 'time' alias was removed in v3.0.0.",
                    isError: true
                )
            }
            guard params["bar"] != nil || params["position"] != nil else {
                return toolInvalidParamsResult(
                    "goto_position requires explicit 'bar' or 'position'"
                )
            }
            // intParam coerces int/double/string so `{"bar":"5"}` works too.
            if params["bar"] != nil {
                guard let bar = intParamOrNil(params, "bar") else {
                    return toolInvalidParamsResult(
                        "goto_position 'bar' must be an integer in 1..9999"
                    )
                }
                guard (1...9999).contains(bar) else {
                    return toolInvalidParamsResult(
                        "goto_position 'bar' must be in 1..9999 (got \(bar))"
                    )
                }
                let traceID = await startTraceIfEnabled(command: command)
                let finalized = await handleGotoPosition(
                    requestedPosition: "\(bar).1.1.1",
                    router: router,
                    cache: cache,
                    traceID: traceID
                )
                return await finalizeTrace(finalized, traceID: traceID)
            }
            let time = stringParam(params, "position", default: "1.1.1.1")
            // Validate position format before routing. Accept:
            //   Bar/beat: "N.N.N.N" with bar 1..9999, beat 1..16, sub 1..16, tick 1..999
            //   SMPTE:    "HH:MM:SS:FF" with HH 0..23, MM/SS 0..59, FF 0..99
            guard TransportDispatcher.isValidPositionString(time) else {
                return toolInvalidParamsResult(
                    "goto_position 'position' must be bar.beat.sub.tick (e.g. 1.1.1.1) or HH:MM:SS:FF (got '\(time)')"
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let finalized = await handleGotoPosition(
                requestedPosition: time,
                router: router,
                cache: cache,
                traceID: traceID
            )
            return await finalizeTrace(finalized, traceID: traceID)

        case "set_cycle_range":
            guard params["start"] != nil, params["end"] != nil else {
                return toolInvalidParamsResult(
                    "set_cycle_range requires explicit 'start' and 'end'"
                )
            }
            guard let start = intParamOrNil(params, "start"),
                  let end = intParamOrNil(params, "end") else {
                return toolInvalidParamsResult(
                    "set_cycle_range requires integer 'start' and 'end'"
                )
            }
            // Bounds: same window as goto_position.bar (1..9999).
            // Enforce start <= end so a swapped-argument typo surfaces early.
            guard (1...9999).contains(start), (1...9999).contains(end) else {
                return toolInvalidParamsResult(
                    "set_cycle_range 'start' and 'end' must be in 1..9999 (got \(start)..\(end))"
                )
            }
            guard start <= end else {
                return toolInvalidParamsResult(
                    "set_cycle_range 'start' (\(start)) must be <= 'end' (\(end))"
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "transport.set_cycle_range",
                    params: ["start": "\(start).1.1.1", "end": "\(end).1.1.1"]
                )
            }
            return await finalizeTrace(toolTextResult(result), traceID: traceID)

        default:
            return Self.unhandledCommandResult(command, label: "transport")
        }
    }

    private static func modalGuardedTransportOperation(for command: String) -> String? {
        switch command {
        case "play": return "transport.play"
        case "stop": return "transport.stop"
        case "record": return "transport.record"
        case "pause": return "transport.pause"
        case "rewind": return "transport.rewind"
        case "fast_forward": return "transport.fast_forward"
        case "toggle_cycle": return "transport.toggle_cycle"
        case "toggle_metronome": return "transport.toggle_metronome"
        case "set_tempo": return "transport.set_tempo"
        case "goto_position": return "transport.goto_position"
        case "set_cycle_range": return "transport.set_cycle_range"
        case "toggle_count_in": return "transport.toggle_count_in"
        case "toggle_autopunch": return "transport.toggle_autopunch"
        default: return nil
        }
    }

    private static func verifiedStopResult(
        router: ChannelRouter,
        cache: StateCache,
        sleep: @escaping (UInt64) async -> Void,
        traceID: TraceID?
    ) async -> CallTool.Result {
        if let beforeState = await readTransportState(router: router),
           beforeState.isPlaying == false,
           beforeState.isRecording == false {
            // verify_source distinguishes the two verified-stop paths for
            // downstream consumers: `transport_state` = already-stopped, proven by
            // a pure pre-read with no write attempted (this branch);
            // `ax_transport_state` = proven by the post-write AX readback below.
            return toolTextResult(.success(HonestContract.encodeStateA(
                extras: [
                    "operation": "transport.stop",
                    "requested_state": "stopped",
                    "verify_source": "transport_state",
                    "write_attempted": false,
                    "unchanged": true,
                    "observed_before": transportStateSummary(beforeState),
                    "observed_after": transportStateSummary(beforeState)
                ]
            )))
        }

        let writeResult = await withWriteBoundaryArmed(traceID) {
            await router.route(operation: "transport.stop")
        }
        guard writeResult.isSuccess else {
            return toolTextResult(writeResult)
        }
        let writePayload = jsonValue(from: writeResult.message)

        var attempts = 0
        var afterState: TransportState?
        var refreshError: String?
        for attempt in 1...12 {
            attempts = attempt
            let liveRefresh = await ResourceHandlers.readLiveTransportState(router: router)
            guard let liveState = liveRefresh.state else {
                refreshError = liveRefresh.errorCode
                if attempt < 12 { await sleep(100_000_000) }
                continue
            }

            afterState = liveState
            await cache.updateTransport(liveState)
            let observedExtras = stopObservedExtras(
                for: liveState,
                pollAttempts: attempts,
                writePayload: writePayload
            )

            if liveState.isPlaying == false, liveState.isRecording == false {
                return toolTextResult(HonestContract.encodeStateA(extras: observedExtras))
            }

            if attempt < 12 { await sleep(100_000_000) }
        }

        guard let afterState else {
            let cachedState = await cache.getTransport()
            var extras = stopReadbackUnavailableExtras(
                cachedState: cachedState,
                refreshError: refreshError ?? "live_transport_read_failed"
            )
            extras["poll_attempts"] = attempts
            extras["write_result"] = writePayload
            return toolTextResult(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "transport.stop executed, but live transport state could not be refreshed. Focus Logic's Tracks window, dismiss modal or plugin dialogs, then retry or run logic_system refresh_cache.",
                extras: extras
            ), isError: true)
        }

        var observedExtras = stopObservedExtras(
            for: afterState,
            pollAttempts: attempts,
            writePayload: writePayload
        )
        observedExtras["safe_to_retry"] = true
        return toolTextResult(HonestContract.encodeStateC(
            error: .readbackMismatch,
            hint: "transport.stop executed, but live transport state still reports playback or recording",
            extras: observedExtras
        ), isError: true)
    }

    /// Verified `pause` mirroring `verifiedStopResult`: a pause that does not
    /// actually halt the playhead must NEVER report bare success. Logic's pause
    /// stops the running transport, so the verified target is the same as stop —
    /// `isPlaying == false`. Read state first, send pause, then poll
    /// `readTransportState` up to 12x for the playhead to settle; State A only on
    /// a verified stop, State C `readback_mismatch` if it keeps playing.
    private static func verifiedPauseResult(
        router: ChannelRouter,
        cache: StateCache,
        sleep: @escaping (UInt64) async -> Void,
        traceID: TraceID?
    ) async -> CallTool.Result {
        if let beforeState = await readTransportState(router: router),
           beforeState.isPlaying == false {
            return toolTextResult(.success(HonestContract.encodeStateA(
                extras: [
                    "operation": "transport.pause",
                    "requested_state": "paused",
                    "verify_source": "transport_state",
                    "write_attempted": false,
                    "unchanged": true,
                    "observed_before": transportStateSummary(beforeState),
                    "observed_after": transportStateSummary(beforeState)
                ]
            )))
        }

        let writeResult = await withWriteBoundaryArmed(traceID) {
            await router.route(operation: "transport.pause")
        }
        let writePayload = jsonValue(from: writeResult.message)

        var attempts = 0
        var afterState: TransportState?
        for _ in 0..<12 {
            attempts += 1
            if let observed = await readTransportState(router: router) {
                afterState = observed
                await cache.updateTransport(observed)
                if observed.isPlaying == false {
                    return toolTextResult(.success(HonestContract.encodeStateA(extras: [
                        "operation": "transport.pause",
                        "requested_state": "paused",
                        "verify_source": "transport_state",
                        "write_attempted": true,
                        "poll_attempts": attempts,
                        "observed_isPlaying": observed.isPlaying,
                        "observed_isRecording": observed.isRecording,
                        "observed_position": observed.position,
                        "observed_time_position": observed.timePosition,
                        "write_result": writePayload
                    ])))
                }
            }
            await sleep(100_000_000)
        }

        guard writeResult.isSuccess else {
            return toolTextResult(writeResult)
        }

        var extras: [String: Any] = [
            "operation": "transport.pause",
            "requested_state": "paused",
            "verify_source": "transport_state",
            "write_attempted": true,
            "poll_attempts": attempts,
            "write_result": writePayload
        ]
        guard let afterState else {
            return toolTextResult(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "transport.pause executed, but live transport state could not be refreshed. Focus Logic's Tracks window, dismiss modal or plugin dialogs, then retry or run logic_system refresh_cache.",
                extras: extras
            ), isError: true)
        }

        extras["observed_isPlaying"] = afterState.isPlaying
        extras["observed_isRecording"] = afterState.isRecording
        extras["observed_position"] = afterState.position
        extras["observed_time_position"] = afterState.timePosition
        extras["safe_to_retry"] = true
        return toolTextResult(HonestContract.encodeStateC(
            error: .readbackMismatch,
            hint: "transport.pause executed, but live transport state still reports playback",
            extras: extras
        ), isError: true)
    }

    private static func stopReadbackUnavailableExtras(
        cachedState: TransportState,
        refreshError: String?
    ) -> [String: Any] {
        [
            "operation": "transport.stop",
            "requested_state": "stopped",
            "verify_source": "cache_only",
            "cached_source": cachedState.lastUpdated > .distantPast ? "cache" : "default",
            "cache_age_sec": cacheAgeExtra(for: cachedState),
            "refresh_error": refreshError ?? "live_transport_read_failed",
            "safe_to_retry": true,
        ]
    }

    private static func stopObservedExtras(
        for state: TransportState,
        pollAttempts: Int,
        writePayload: Any
    ) -> [String: Any] {
        [
            "operation": "transport.stop",
            "requested_state": "stopped",
            "verify_source": "ax_transport_state",
            "write_attempted": true,
            "poll_attempts": pollAttempts,
            "observed_isPlaying": state.isPlaying,
            "observed_isRecording": state.isRecording,
            "observed_position": state.position,
            "observed_time_position": state.timePosition,
            "write_result": writePayload,
        ]
    }

    private static func cacheAgeExtra(for state: TransportState) -> Any {
        guard state.lastUpdated > .distantPast else {
            return NSNull()
        }
        return max(0, Date().timeIntervalSince(state.lastUpdated))
    }

    /// Accept "bar.beat.sub.tick" (each positive) or "HH:MM:SS:FF" (with
    /// each field within its canonical range). Anything else — including
    /// empty string and malformed tokens like "99:99:99:99" — is rejected.
    static func isValidPositionString(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }

        // Bar/beat format.
        let dots = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if dots.count == 4 {
            guard let bar = Int(dots[0]), (1...9999).contains(bar),
                  let beat = Int(dots[1]), (1...16).contains(beat),
                  let sub = Int(dots[2]), (1...16).contains(sub),
                  let tick = Int(dots[3]), (1...999).contains(tick) else {
                return false
            }
            return true
        }

        // SMPTE format.
        let colons = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if colons.count == 4 {
            guard let h = Int(colons[0]), (0...23).contains(h),
                  let m = Int(colons[1]), (0...59).contains(m),
                  let sec = Int(colons[2]), (0...59).contains(sec),
                  let f = Int(colons[3]), (0...99).contains(f) else {
                return false
            }
            return true
        }

        return false
    }

    /// A Go To Position receipt has two distinct truthful success shapes:
    ///
    /// * a no-op, where a complete pre-write AX read already matched the request and no global
    ///   dialog/input path was entered; or
    /// * an observed movement, where complete pre- and post-write AX reads differ and the latter
    ///   lands on the request.
    ///
    /// A post-write match alone is never enough: it can predate this request.
    private static func handleGotoPosition(
        requestedPosition: String,
        router: ChannelRouter,
        cache: StateCache,
        traceID: TraceID?
    ) async -> CallTool.Result {
        let beforeTransport = await liveTransportState(router: router, cache: cache)
        if let unchanged = gotoPositionUnchangedResult(
            requestedPosition: requestedPosition,
            beforeTransport: beforeTransport
        ) { return unchanged }

        // A failed or partial pre-read is not evidence of absence. It only removes the option to
        // certify a later matching read as this call's effect; the requested operation still runs.
        let result = await withWriteBoundaryArmed(traceID) {
            await router.route(
                operation: "transport.goto_position",
                params: ["position": requestedPosition]
            )
        }
        return await finalizeGotoPositionResult(
            result,
            requestedPosition: requestedPosition,
            beforeTransport: beforeTransport,
            router: router,
            cache: cache
        )
    }

    static func gotoPositionUnchangedResult(
        requestedPosition: String,
        beforeTransport: TransportState?
    ) -> CallTool.Result? {
        guard let beforePosition = completeObservedMusicalPosition(
            from: beforeTransport,
            matching: requestedPosition
        ) else { return nil }

        // This is deliberately an idempotent State A, not a claimed write effect. The complete AX
        // pre-read established that the requested state already held, so callers avoid opening a
        // global-input dialog and see the no-write boundary explicitly.
        return toolTextResult(HonestContract.encodeStateA(extras: [
            "operation": "transport.goto_position",
            "requested": requestedPosition,
            "observed": beforePosition.value,
            "observed_position_components": beforePosition.observedComponents.map(\.rawValue),
            "unobserved_position_components": [],
            "verification_source": "transport_state",
            "write_attempted": false,
            "unchanged": true,
        ]))
    }

    static func completeObservedMusicalPosition(
        from transport: TransportState?,
        matching requestedPosition: String
    ) -> TransportPositionReadback? {
        guard !requestedPosition.contains(":"),
              let readback = transport?.positionReadback,
              Set(readback.observedComponents) == Set(TransportPositionComponent.allCases),
              readback.value == requestedPosition
        else { return nil }
        return readback
    }

    static func completeObservedMusicalPosition(
        _ transport: TransportState?
    ) -> TransportPositionReadback? {
        guard let readback = transport?.positionReadback,
              Set(readback.observedComponents) == Set(TransportPositionComponent.allCases)
        else { return nil }
        return readback
    }

    static func finalizeGotoPositionResult(
        _ result: ChannelResult,
        requestedPosition: String,
        beforeTransport: TransportState?,
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        guard result.isSuccess else {
            return toolTextResult(result)
        }
        // No route-level State A is sufficient by itself for a seek. A future channel may observe
        // its own actuator, but its receipt can still coincide with a playhead that was already at
        // the requested position; this common finalizer owns the cross-route effect requirement.
        guard channelResultIsUnverified(result) || channelResultIsVerified(result) else {
            return toolTextResult(result)
        }
        guard let observedTransport = await liveTransportState(router: router, cache: cache) else {
            return toolTextResult(
                HonestContract.addExtras(
                    ["verification_source": "transport_state"],
                    into: result.message
                ),
                isError: true
            )
        }

        var extras = honestContractExtras(from: result.message)
        // #105: drop any channel-level "keystroke sent; not read back" note —
        // this finalize step IS the authoritative read-back, so carrying that
        // note forward would contradict the verified verdict below.
        extras.removeValue(forKey: "note")
        extras["verification_source"] = "transport_state"
        extras["requested"] = requestedPosition
        // `position` and `timePosition` have display defaults. Only a position readback may name
        // an observed landing in this receipt; otherwise `observed` would falsely report the
        // model's `1.1.1.1` default as an AX read.
        if let positionReadback = observedTransport.positionReadback {
            extras["observed"] = positionReadback.value
            extras["observed_time_position"] = observedTransport.timePosition
        }
        if let beforePositionReadback = beforeTransport?.positionReadback {
            extras["observed_before"] = beforePositionReadback.value
            extras["observed_before_position_components"] = beforePositionReadback.observedComponents.map(\.rawValue)
        }

        // A matching playhead cannot independently verify this request when the dialog channel
        // says its global input target or write boundary was indeterminate. The position remains
        // useful readback evidence, but it is not proof that this call performed the write.
        let channelVerificationWithheld: String? =
            (extras["dialog_input_target"] as? String) == "unknown" ? "dialog_input_target" :
            (extras["fallback_unsafe"] as? Bool) == true ? "fallback_unsafe" :
            (extras["write_attempted_indeterminate"] as? Bool) == true
                ? "write_attempted_indeterminate" : nil

        let requestedMusicalComponents: [TransportPositionComponent] = requestedPosition.contains(":")
            ? []
            : TransportPositionComponent.allCases
        let observedMusicalComponents = observedTransport.positionReadback?.observedComponents ?? []
        let unobservedMusicalComponents = requestedMusicalComponents.filter {
            !observedMusicalComponents.contains($0)
        }
        if !requestedPosition.contains(":") {
            extras["observed_position_components"] = observedMusicalComponents.map(\.rawValue)
            extras["unobserved_position_components"] = unobservedMusicalComponents.map(\.rawValue)
        }

        let beforePosition = completeObservedMusicalPosition(beforeTransport)
        let afterPosition = completeObservedMusicalPosition(observedTransport)
        let observedEffect: Bool
        if !requestedPosition.contains(":"),
           let beforePosition,
           let afterPosition,
           beforePosition.value != requestedPosition,
           afterPosition.value == requestedPosition {
            observedEffect = true
        } else {
            observedEffect = false
        }
        let verificationWithheld = channelVerificationWithheld
            ?? (afterPosition?.value == requestedPosition && !observedEffect
                ? "observed_effect_unavailable" : nil)
        if let verificationWithheld {
            extras["verification_withheld"] = verificationWithheld
        }

        // A matching post-write value is a landing observation, not evidence that this invocation
        // moved the playhead. State A needs a complete AX reading on each side of the write boundary
        // and the observed transition must end at the requested value.
        if verificationWithheld == nil, observedEffect {
            return toolTextResult(HonestContract.encodeStateA(extras: extras))
        }

        let reason: HonestContract.UncertainReason =
            verificationWithheld != nil || requestedPosition.contains(":")
                || !unobservedMusicalComponents.isEmpty || beforePosition == nil
                ? .readbackUnavailable
                : .readbackMismatch
        return toolTextResult(
            HonestContract.encodeStateB(reason: reason, extras: extras),
            isError: true
        )
    }

    private static func finalizeToggleMetronomeResult(
        _ result: ChannelResult,
        beforeTransport: TransportState?,
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        guard result.isSuccess else {
            return toolTextResult(result)
        }
        guard channelResultIsUnverified(result) else {
            return toolTextResult(result)
        }
        guard let beforeTransport,
              let afterTransport = await liveTransportState(router: router, cache: cache) else {
            return toolTextResult(
                HonestContract.addExtras(
                    ["verification_source": "transport_state"],
                    into: result.message
                ),
                isError: true
            )
        }

        var extras = honestContractExtras(from: result.message)
        extras["verification_source"] = "transport_state"
        extras["previous_enabled"] = beforeTransport.isMetronomeEnabled
        extras["requested_enabled"] = !beforeTransport.isMetronomeEnabled
        extras["observed_enabled"] = afterTransport.isMetronomeEnabled

        if beforeTransport.isMetronomeEnabled != afterTransport.isMetronomeEnabled {
            return toolTextResult(HonestContract.encodeStateA(extras: extras))
        }

        return toolTextResult(
            HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras),
            isError: true
        )
    }

    static func liveTransportState(
        router: ChannelRouter,
        cache: StateCache
    ) async -> TransportState? {
        let readback = await router.route(operation: "transport.get_state")
        guard readback.isSuccess,
              let transport = decodeJSONValue(TransportState.self, from: readback.message) else {
            return nil
        }
        await cache.updateTransport(transport)
        return transport
    }

    private enum VerifiedTransportAction: String {
        case play
        case record

        var operation: String { "transport.\(rawValue)" }

        func matches(_ state: TransportState) -> Bool {
            switch self {
            case .play:
                return state.isPlaying
            case .record:
                return state.isPlaying && state.isRecording
            }
        }
    }

    private static func handleVerifiedTransportCommand(
        action: VerifiedTransportAction,
        router: ChannelRouter,
        sleep: @escaping (UInt64) async -> Void,
        traceID: TraceID?
    ) async -> CallTool.Result {
        let beforeState = await readTransportState(router: router)
        if let beforeState, action.matches(beforeState) {
            return toolTextResult(.success(HonestContract.encodeStateA(
                extras: [
                    "operation": action.operation,
                    "verify_source": "transport_state",
                    "write_attempted": false,
                    "unchanged": true,
                    "observed_before": transportStateSummary(beforeState),
                    "observed_after": transportStateSummary(beforeState)
                ]
            )))
        }

        let writeResult = await withWriteBoundaryArmed(traceID) {
            await router.route(operation: action.operation)
        }
        let writePayload = jsonValue(from: writeResult.message)
        var attempts = 0
        var afterState: TransportState?
        for _ in 0..<12 {
            attempts += 1
            if let observed = await readTransportState(router: router) {
                afterState = observed
                if action.matches(observed) {
                    var extras: [String: Any] = [
                        "operation": action.operation,
                        "verify_source": "transport_state",
                        "write_attempted": true,
                        "poll_attempts": attempts,
                        "observed_after": transportStateSummary(observed),
                        "write_result": writePayload
                    ]
                    if let beforeState {
                        extras["observed_before"] = transportStateSummary(beforeState)
                    }
                    if !writeResult.isSuccess {
                        extras["write_result_error"] = writeResult.message
                    }
                    return toolTextResult(.success(HonestContract.encodeStateA(extras: extras)))
                }
            }
            await sleep(100_000_000)
        }

        guard writeResult.isSuccess else {
            return toolTextResult(writeResult)
        }

        var extras: [String: Any] = [
            "operation": action.operation,
            "verify_source": "transport_state",
            "write_attempted": true,
            "poll_attempts": attempts,
            "write_result": writePayload
        ]
        if let beforeState {
            extras["observed_before"] = transportStateSummary(beforeState)
        }
        if let afterState {
            extras["observed_after"] = transportStateSummary(afterState)
            return toolTextResult(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extras
            ), isError: true)
        }
        return toolTextResult(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: extras
        ), isError: true)
    }

    private static func readTransportState(router: ChannelRouter) async -> TransportState? {
        let result = await router.route(operation: "transport.get_state")
        guard result.isSuccess,
              let dict = jsonValue(from: result.message) as? [String: Any] else {
            return nil
        }
        var state = TransportState()
        if let isPlaying = dict["isPlaying"] as? Bool { state.isPlaying = isPlaying }
        if let isRecording = dict["isRecording"] as? Bool { state.isRecording = isRecording }
        if let isPaused = dict["isPaused"] as? Bool { state.isPaused = isPaused }
        if let isCycleEnabled = dict["isCycleEnabled"] as? Bool { state.isCycleEnabled = isCycleEnabled }
        if let isMetronomeEnabled = dict["isMetronomeEnabled"] as? Bool { state.isMetronomeEnabled = isMetronomeEnabled }
        if let tempo = dict["tempo"] as? Double { state.tempo = tempo }
        if let position = dict["position"] as? String { state.position = position }
        if let timePosition = dict["timePosition"] as? String { state.timePosition = timePosition }
        if let sampleRate = dict["sampleRate"] as? Int { state.sampleRate = sampleRate }
        return state
    }

    private static func transportStateSummary(_ state: TransportState) -> [String: Any] {
        [
            "isPlaying": state.isPlaying,
            "isRecording": state.isRecording,
            "position": state.position,
            "tempo": state.tempo
        ]
    }

    private static func jsonValue(from text: String) -> Any {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return text
        }
        return value
    }
}
