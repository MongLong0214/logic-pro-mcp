import Foundation
import MCP

struct MixerDispatcher: OperationTraceDispatching {
    /// The bank directions `bank` takes; the operation registry's parameter contract reads the same
    /// list (#957).
    static let bankDirections = ["left", "right"]

    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicMixer)
    static let notExposedCommands: Set<String> = [
        "set_send", "set_output", "set_input", "toggle_eq", "reset_strip", "bypass_plugin",
    ]

    static let tool = commandTool(
        name: "logic_mixer",
        description: "set_send_mode_verified -> {target_ref: mix_..., project_ref?: prj_..., ordinal: Int >= 0, mode: post_pan|post_fader|pre_fader, expected_current: same}. Requires the complete checked native mode menu and exact occupied control/source under stopped transport. One owned mode leaf preserves destination/raw level/bypass/Independent Pan/population, then independently verifies the new mode; no-op sends no mode leaf. Missing/ambiguous/unreadable evidence refuses, unknown after is State B with no guessed inverse. No physical screen-slot, canonical, Saga or general mode claim. set_send_level_verified -> {target_ref: mix_..., project_ref?: prj_..., ordinal: Int >= 0, level_db: String, expected_current: String}. Only qualified semantic -95/-95.0, -6/-6.0 and -∞ are accepted; no universal range or raw conversion. A changing call uses the exact occupied knob and its owned numeric editor under stopped transport, checked routing/mode/raw/bypass/control/population custody, then independent same-knob readback. Equal desired/current is zero-click; unknown after is State B with no guessed inverse. No Saga or physical screen-slot inference. get_send_bypass_verified -> {target_ref: mix_..., project_ref?: prj_..., ordinal: Int >= 0} independently reads the exact occupied send checkbox, checked route, raw level and checked non-routing titles; it reports the actual checkbox action names/status. set_send_bypass_verified -> same target/ordinal plus bypassed: literal Bool and expected_current: literal Bool. A changing call requires stopped transport and one supported exact-checkbox AXPress with independent strict Boolean after-read and protected control/source/population. Already equal is a verified zero-press no-op. Unknown or changed after-state is State B, with no guessed inverse; no track/index selectors or physical screen-slot inference. set_send_output_verified -> {target_ref: mix_..., project_ref?: prj_..., ordinal: Int >= 0, destination: {kind: physical, ports: [a,b]} | {kind: stereo_output} | {kind: bus, number: 1..256} | {kind: no_send}, expected_current: physical/stereo/bus shape, replace_existing: true} addresses an occupied send at its exact source-census ordinal. Explicit fresh sole-empty creation instead requires expected_current:{kind:no_send}, replace_existing:false and destination:{kind:stereo_output}; ambiguous empty slots refuse. A bus requires an existing receiver and a clear observed loop path before popup acquisition and again at the final press; unreadable dependencies refuse. no_send removes only a completely observed singleton occupied send: State A requires original-header source renewal, one independently observed empty anchor and preserved physical population. No Send is distinct from No Output. Fresh creation requires a retained original-header association, exact current empty control/path, checked No Send before and independent occupied Stereo after; the returned send_ordinal_after is observed, not reused from the empty slot. No public removed-send inverse is accepted. Replacement State A requires fresh checked after evidence and preserved unique slot/level/bypass/raw non-routing checkmarks. Retired source renewal requires its original retained header and a complete singleton correspondence; fresh references are required for explicit occupied-route inverse. Source/focus loss or unknown after-state is unverified; no automatic inverse or ordinal/name adoption after retirement. Other Send levels, Aux creation and format conversion are not supported. " +
        "set_input_bus_verified -> {target_ref: mix_..., project_ref?: prj_..., destination: {kind: bus, number: 1..256}, expected_current: same shape, replace_existing: true} replaces only a checked bus input on an exact physical-output sink with every send observed empty and stopped transport. No track/index fallback, general partial-graph write, physical input, aux creation or format conversion. State A requires agreeing checked before/after input menus, checked physical output and unchanged population; popup and typed renewal custody are checked separately. After source retirement, fresh references are required for any explicit inverse; no automatic undo. " +
        "get_input_bus_verified -> {target_ref: mix_..., project_ref?: prj_...} is bus_only: reads a checked Bus 1..256 input from the exact retained physical Mixer source. No track/index selectors, input setter, values, destinations or physical-input classification. Two agreeing owned menu-checkmark reads and original source custody after cleanup are required; owned popup cleanup is attempted and reported separately; no destination leaf is pressed. Popup/focus restoration is reported separately; lost source custody after Cancel refuses. No receiver identity, graph completeness, atomic snapshot or native qualification claim. get_send_destination_verified -> {target_ref: mix_..., project_ref?: prj_..., ordinal: Int >= 0} reads the checked destination of the retained occupied send at the source census ordinal in logic://mixer send_slots, not its screen slot number. Empty/unsupported/unreadable sends refuse before navigation. Bus, stereo output and physical pairs only; no destination leaf, level or bypass write, endpoint/receiver edge or graph completeness claim. Popup/focus restoration is reported separately. get_output_verified -> {target_ref: mix_..., project_ref?: prj_...} reads the current checked output of the exact physical Mixer source by opening and cancelling its popup. No indices, values or destinations. State A is two agreeing host checkmark reads under preserved source/menu custody, not a routing graph or atomic snapshot. No audio write; popup/focus restoration is reported separately and may be not_restored. Mixer actions in Logic Pro. Commands: set_send_mode_verified, set_send_level_verified, get_send_bypass_verified, set_send_bypass_verified, set_send_output_verified, set_input_bus_verified, get_input_bus_verified, get_send_destination_verified, get_output_verified, set_volume, set_pan, set_master_volume, set_plugin_param, insert_plugin, bank, set_output_verified. BREAKING since v3.3.0: every mutating command requires explicit `track` (Int ≥ 0) — pre-v3.3.0 missing `track` defaulted to 0 and silently mutated the first track; this now returns an error. Params: set_volume -> { track: Int (required, ≥ 0), value: Float (0.0..1.0) } verified against the visible mixer strip via AX readback; set_pan -> { track: Int (required, ≥ 0), value: Float (-1.0..1.0) } verified against the visible mixer strip via AX readback; set_master_volume -> { value: Float (0.0..1.0) } — the master fader has no AX track-header equivalent, so MCU echo is the ONLY readback: State A only when a fresh echo lands, otherwise honest State B echo_timeout with readback_source:mcu_echo + a surface_limitation note (non-deterministic, not a recoverable failure); bank -> { direction: \"left\"|\"right\" (required), count?: Int (1..31, default 1) } moves the MCU fader-bank window by eight strips per step and is MCU-only; each step is one press followed by its own readback, the MCU LCD upper row that names the eight visible strips, and the walk stops at the first step that did not move (banks_moved/banks_requested/bank_presses_sent/step_windows): State A (verify_source:mcu_lcd_upper_row, window_before/window_after/strips) only when every step got a fresh upper-row write that differs from that step's snapshot, State B noop_unobservable when the first step redraws unchanged (identical six-character names cannot confirm a move) or echo_timeout when no redraw arrives, State B readback_mismatch when some steps moved and the next redrew unchanged (the end of the mixer in that direction), and State C readback_unavailable with write_attempted:false BEFORE any press when the upper row has never been received on this server; set_plugin_param -> { track: Int (required, ≥ 0), insert: Int (required, currently only 0), param: Int (required, ≥ 0), value: Float (required) } on the selected track via Scripter; insert_plugin -> { track: Int, slot: Int, plugin_name: Gain|Compressor|Channel EQ, confirmed: true, configuration?: String } via AX mixer slot with readback. The last segment of Logic's plug-in menu is the CHANNEL CONFIGURATION (Stereo, Mono, Mono->Stereo, Dual Mono), which belongs to the strip and not to the request, so it is read off the menu this call opens: the spec's preference wins when the strip offers it, a menu with exactly one entry has no choice to make, and several entries with none preferred are REFUSED rather than picking a channel layout on the operator's behalf. Supply `configuration` to choose in that case — it is honoured only when the strip actually offers it, and a value the strip lacks fails closed instead of silently falling back. The refusal lists what the strip offered, so the legal values come back from the failure. set_output_verified -> { track: Int (>= 0) or target_ref: String (trk_/mix_), destination: {kind:\"bus\", number:1..256} | {kind:\"physical\", ports:[a,b]} | {kind:\"stereo_output\"}, expected_current?: same shape or {kind:\"no_output\"} } also accepts destination no_output only for a current held physical source in the Stereo Output/No Output pair, with mandatory matching expected_current. It sets one visible Mixer strip's output through its output popup and reads the SAME strip's output slot back: State A (verify_source ax_output_slot, before, after, changed, strip_count_before/after, menu_path, popup_menu_state) only when the slot reads the destination and the strip count did not move; other already-in-place destinations are State A changed:false with nothing pressed; No Output no-op remains unsupported. Refused with nothing pressed (State C): No Output changes outside that bounded pair or without the retained output-only approval in canonical execution (unsupported_state; legacy No Output destination is invalid_params), current output unreadable or unclassifiable (readback_unavailable) or No Output outside that bounded pair (unsupported_state), expected_current differs (stale_snapshot), transport playing/recording (unsupported_state) or unreadable (transport_state_unknown), a bus assignment that would close a loop (routing_cycle) or whose loop check meets a strip that does not say where its signal goes (routing_dependency_unknown), a bus no other strip reads as its input (bus_has_no_receiver: Logic would create an aux, and this command has no creation authority). Refused with the popup closed and nothing selected: a destination the popup does not offer as exactly one entry under its own submenu (element_not_found destination_not_offered, ambiguous_target_name when a title repeats, or menu_not_read when an entry on the way did not read); for a bus, the loop and receiver checks made again with the popup open, right before the press (read_with_popup_open). After the press: slot unreadable is State B readback_unavailable, a different destination State B readback_mismatch, and a strip count that moved State C unexpected_side_effect (strip_created) with nothing cleaned up. There is no undo. To restore, call again with the reply's before as destination and its after as expected_current; that call is checked like any other, so it can be refused (the old bus with no other strip reading it any more is bus_has_no_receiver) or end in State C when the strip count moves (a physical pair no strip used before). ADR-002 (on by default; disable with LOGIC_MCP_ADR002_TARGET_REF=0): set_volume and set_pan ALSO accept a session-stable { target_ref: String } from logic://tracks (trk_…) or logic://mixer (mix_…) that resolves to the addressed mixer strip in place of explicit track/index; a trk_ reference combined with track/index must agree or the op fails closed (stale_target_reference); a physical mix_ reference must not be combined with track/index because its Arrange association is not established; when the kill-switch is set, any supplied target_ref fails closed with target_ref_unavailable; omit target_ref to use the explicit track/index path.",
        commandDescription: "Mixer command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        targetRegistry: TargetRegistry? = nil,
        // ADR-002 F5 — live AX track-header reader for the mutation-boundary
        // identity cross-check. Deliberately nil by default so the deterministic
        // test suite never reaches into live AX; production wires the real reader
        // at the single dispatch chokepoint (server + saga). When nil the guard
        // is a no-op — but the target_ref path is only reachable behind the
        // off-by-default flag, and every production entry point supplies it.
        liveTrackName: (@Sendable (Int) -> String?)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil,
        verifiedGate: VerifiedOpGate = .shared
    ) async -> CallTool.Result {
        if let projectFailure = await TargetRefResolver.validateProjectReference(
            params,
            targetRegistry: targetRegistry,
            operation: "mixer.\(command)"
        ) {
            return projectFailure
        }

        switch command {
        case "set_send_level_verified":
            let operation = "mixer.set_send_level_verified"
            guard params.keys.allSatisfy({ ["target_ref", "project_ref", "ordinal", "level_db", "expected_current"].contains($0) }),
                  params["target_ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let ordinal = intParamOrNil(params, "ordinal"), ordinal >= 0,
                  let desired = params["level_db"]?.stringValue, AccessibilityChannel.sendLevelToken(desired) != nil,
                  let expected = params["expected_current"]?.stringValue, AccessibilityChannel.sendLevelToken(expected) != nil else {
                return toolInvalidParamsResult("An exact physical Mixer target_ref, occupied census ordinal and qualified text levels (-95, -6, -∞, optionally .0) are required")
            }
            guard verifiedGate.tryAcquire() else {
                return toolTextResult(.error(HonestContract.encodeStateC(error: .verifiedOpInProgress,
                    extras: ["operation": operation, "write_attempted": false])))
            }
            defer { verifiedGate.release() }
            switch await TargetRefResolver.resolveMutationIndex(params, targetRegistry: targetRegistry, cache: cache,
                operation: operation, invalidIndexResult: toolInvalidParamsResult("A physical Mixer target_ref is required"),
                acceptedKinds: [.mixerStrip]) {
            case .failure(let result): return result
            case .success(let resolved):
                guard let physical = resolved.binding?.physicalMixerStrip, let reference = resolved.reference else {
                    return TargetRefResolver.staleTargetReferenceResult(params["target_ref"]?.stringValue, operation: operation)
                }
                let traceID = await startTraceIfEnabled(command: command)
                let result = await withWriteBoundaryArmed(traceID) {
                    await AXMixerStripBinding.$current.withValue(physical) {
                        await routedTextResult(router, operation: operation, params: ["ordinal": String(ordinal),
                            "level_db": desired, "expected_current": expected])
                    }
                }
                return await finalizeTrace(TargetRefResolver.addEvidence(reference,
                    fingerprint: resolved.binding?.observedFingerprint, to: result), traceID: traceID)
            }
        case "get_send_bypass_verified", "set_send_bypass_verified":
            let writing = command == "set_send_bypass_verified", operation = "mixer.\(command)"
            let allowed = writing ? ["target_ref", "project_ref", "ordinal", "bypassed", "expected_current"]
                : ["target_ref", "project_ref", "ordinal"]
            guard params.keys.allSatisfy({ allowed.contains($0) }),
                  params["target_ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let ordinal = intParamOrNil(params, "ordinal"), ordinal >= 0 else {
                return toolInvalidParamsResult("An exact physical Mixer target_ref and occupied source-census ordinal are required")
            }
            var channelParams = ["ordinal": String(ordinal)]
            if writing {
                guard case .value(let desired) = strictBoolParam(params, "bypassed"),
                      case .value(let expected) = strictBoolParam(params, "expected_current") else {
                    return toolInvalidParamsResult("bypassed and expected_current must be literal Booleans")
                }
                channelParams["bypassed"] = desired ? "true" : "false"
                channelParams["expected_current"] = expected ? "true" : "false"
            }
            guard verifiedGate.tryAcquire() else {
                return toolTextResult(.error(HonestContract.encodeStateC(error: .verifiedOpInProgress,
                    extras: ["operation": operation, "write_attempted": false])))
            }
            defer { verifiedGate.release() }
            switch await TargetRefResolver.resolveMutationIndex(params, targetRegistry: targetRegistry,
                cache: cache, operation: operation, invalidIndexResult: toolInvalidParamsResult("A physical Mixer target_ref is required"),
                acceptedKinds: [.mixerStrip]) {
            case .failure(let result): return result
            case .success(let resolved):
                guard let physical = resolved.binding?.physicalMixerStrip, let reference = resolved.reference,
                      let targetRegistry else {
                    return TargetRefResolver.staleTargetReferenceResult(params["target_ref"]?.stringValue, operation: operation)
                }
                let traceID = writing ? await startTraceIfEnabled(command: command) : nil
                let routedParams = channelParams
                let work: @Sendable () async -> CallTool.Result = {
                    await AXMixerStripBinding.$current.withValue(physical) {
                        await routedTextResult(router, operation: operation, params: routedParams)
                    }
                }
                let result = writing ? await withWriteBoundaryArmed(traceID) { await work() } : await work()
                return await finalizeTrace(TargetRefResolver.addEvidence(reference,
                    fingerprint: resolved.binding?.observedFingerprint, to: result), traceID: traceID)
            }
        case "set_send_mode_verified":
            let operation = "mixer.set_send_mode_verified"
            guard params.keys.allSatisfy({ ["target_ref", "project_ref", "ordinal", "mode", "expected_current"].contains($0) }),
                  params["target_ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let ordinal = intParamOrNil(params, "ordinal"), ordinal >= 0,
                  let desired = params["mode"]?.stringValue, AccessibilityChannel.SendMode(rawValue: desired) != nil,
                  let expected = params["expected_current"]?.stringValue, AccessibilityChannel.SendMode(rawValue: expected) != nil else {
                return toolInvalidParamsResult("set_send_mode_verified requires an exact physical Mixer target_ref, source-census ordinal and explicit post_pan/post_fader/pre_fader mode and expected_current")
            }
            guard verifiedGate.tryAcquire() else {
                return toolTextResult(.error(HonestContract.encodeStateC(error: .verifiedOpInProgress,
                    hint: "Another verified UI acquisition is in progress.", extras: ["operation": operation, "write_attempted": false])))
            }
            defer { verifiedGate.release() }
            switch await TargetRefResolver.resolveMutationIndex(params, targetRegistry: targetRegistry,
                cache: cache, operation: operation, invalidIndexResult: toolInvalidParamsResult("An exact physical Mixer target_ref is required"),
                acceptedKinds: [.mixerStrip]) {
            case .failure(let result): return result
            case .success(let resolved):
                guard let physical = resolved.binding?.physicalMixerStrip, let reference = resolved.reference,
                      let targetRegistry,
                      let pair = await cache.retainedMixerAssociation(reference: reference, source: physical,
                        snapshot: await targetRegistry.currentSnapshot) else {
                    return toolTextResult(.error(HonestContract.encodeStateC(error: .staleSnapshot,
                        hint: "The exact occupied Send needs its retained original-header association; acquire a fresh selected-source inspection.",
                        extras: ["operation": operation, "write_attempted": false])))
                }
                let traceID = await startTraceIfEnabled(command: command)
                let result = await withWriteBoundaryArmed(traceID) {
                    await AXMixerStripBinding.$current.withValue(physical) {
                        await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                            await routedTextResult(router, operation: operation, params: ["ordinal": String(ordinal),
                                "mode": desired, "expected_current": expected])
                        }
                    }
                }
                return await finalizeTrace(TargetRefResolver.addEvidence(reference,
                    fingerprint: resolved.binding?.observedFingerprint, to: result), traceID: traceID)
            }
        case "set_send_output_verified":
            let operation = "mixer.set_send_output_verified"
            let allowed = ["target_ref", "project_ref", "ordinal", "destination", "expected_current", "replace_existing"]
            func isOutputSink(_ assignment: OutputAssignment) -> Bool {
                switch assignment { case .stereoOutput, .physical, .bus: true; default: false }
            }
            let removing = params["destination"] == .object(["kind": .string("no_send")])
            let destination = params["destination"].flatMap { Self.outputAssignmentParam($0, field: "destination").assignment }
            let creating = params["expected_current"] == .object(["kind": .string("no_send")])
                && params["replace_existing"] == .bool(false) && destination == .stereoOutput
            let expected = params["expected_current"].flatMap { Self.outputAssignmentParam($0, field: "expected_current").assignment }
            guard params.keys.allSatisfy({ allowed.contains($0) }),
                  params["target_ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let ordinal = intParamOrNil(params, "ordinal"), ordinal >= 0,
                  creating || { if case .value(true) = strictBoolParam(params, "replace_existing") { return true }; return false }(),
                  params["destination"] != nil,
                  removing || destination.map(isOutputSink) == true,
                  creating || expected.map(isOutputSink) == true else {
                return toolInvalidParamsResult("set_send_output_verified requires an exact physical Mixer target_ref and source-census ordinal: occupied physical/stereo/existing-bus replacement requires replace_existing:true; fresh sole-empty Stereo creation requires expected_current:no_send and replace_existing:false")
            }
            guard verifiedGate.tryAcquire() else {
                return toolTextResult(.error(HonestContract.encodeStateC(error: .verifiedOpInProgress,
                    hint: "Another verified UI acquisition is in progress.",
                    extras: ["operation": operation, "write_attempted": false])))
            }
            defer { verifiedGate.release() }
            switch await TargetRefResolver.resolveMutationIndex(params, targetRegistry: targetRegistry,
                cache: cache, operation: operation,
                invalidIndexResult: toolInvalidParamsResult("An exact physical Mixer target_ref is required"),
                acceptedKinds: [.mixerStrip]) {
            case .failure(let result): return result
            case .success(let resolved):
                guard let physical = resolved.binding?.physicalMixerStrip, let reference = resolved.reference,
                      let targetRegistry else {
                    return TargetRefResolver.staleTargetReferenceResult(params["target_ref"]?.stringValue, operation: operation)
                }
                let cachedPair = await cache.retainedMixerAssociation(reference: reference, source: physical,
                    snapshot: await targetRegistry.currentSnapshot)
                let pair: AccessibilityChannel.HeldSelectionAssociation.Pair?
                let currentPhysical: AXMixerStripBinding.Binding
                if let checked = SendRemovalSagaAdapter.checkedSourcePair {
                    if let renewal = SendRemovalSagaAdapter.checkedReadRenewal {
                        guard renewal.original.matches(physical), renewal.originalTrack.matches(checked.track),
                              renewal.pair.track.matches(checked.track), renewal.pair.strip.matches(checked.strip),
                              cachedPair.map({ $0.strip.matches(physical) && $0.track.matches(checked.track) }) ?? true,
                              renewal.permits(runtime: checked.track.runtime) else {
                            return TargetRefResolver.staleTargetReferenceResult(reference.rawValue, operation: operation)
                        }
                        // A genuine owned input-read receipt carries this request
                        // to its original header's current physical source only.
                        // Resolution, cache, TTL and the original ref stay untouched.
                        currentPhysical = renewal.pair.strip
                    } else {
                        guard checked.strip.matches(physical),
                          cachedPair.map({ $0.strip.matches(checked.strip) && $0.track.matches(checked.track) }) ?? true,
                          checked.track.currentIndex() != nil,
                          physical.currentIndex(runtime: checked.track.runtime) != nil,
                          (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                        return TargetRefResolver.staleTargetReferenceResult(reference.rawValue, operation: operation)
                        }
                        currentPhysical = physical
                    }
                    // Request-local history only. The native writer still proves
                    // the source/control and independently renews its own effect.
                    // No cache entry, TTL, reference or unstarted plan is renewed.
                    pair = checked
                } else { pair = cachedPair; currentPhysical = physical }
                if creating, pair == nil {
                    return toolTextResult(.error(HonestContract.encodeStateC(error: .staleSnapshot,
                        hint: "Fresh-empty creation requires its retained original-header association; acquire a fresh selected-source inspection.",
                        extras: ["operation": operation, "write_attempted": false])))
                }
                if case .bus = destination, destination != expected, pair == nil {
                    return toolTextResult(.error(HonestContract.encodeStateC(error: .staleSnapshot,
                        hint: "A changed existing-bus send requires its retained original-header association; acquire a fresh selected-source inspection before retrying.",
                        extras: ["operation": operation, "write_attempted": false])))
                }
                let traceID = await startTraceIfEnabled(command: command)
                let routed = await withWriteBoundaryArmed(traceID) {
                    await AXMixerStripBinding.$current.withValue(currentPhysical) {
                        await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                            await routedTextResult(router, operation: operation, params: ["send_ordinal": String(ordinal),
                                "destination": removing ? "no_send" : destination?.token ?? "",
                                "expected_current": creating ? "no_send" : expected?.token ?? "",
                                "replace_existing": creating ? "false" : "true"])
                        }
                    }
                }
                return await finalizeTrace(TargetRefResolver.addEvidence(reference,
                    fingerprint: resolved.binding?.observedFingerprint, to: routed), traceID: traceID)
            }
        case "set_input_bus_verified":
            let operation = "mixer.set_input_bus_verified"
            let allowed = ["target_ref", "project_ref", "destination", "expected_current", "replace_existing"]
            guard params.keys.allSatisfy({ allowed.contains($0) }),
                  params["target_ref"]?.stringValue?.isEmpty == false,
                  case .value(true) = strictBoolParam(params, "replace_existing"),
                  let rawDestination = params["destination"], let rawExpected = params["expected_current"],
                  case .bus(let destination)? = Self.outputAssignmentParam(rawDestination, field: "destination").assignment,
                  case .bus(let expected)? = Self.outputAssignmentParam(rawExpected, field: "expected_current").assignment else {
                return toolInvalidParamsResult("set_input_bus_verified requires only a physical Mixer target_ref, Bus 1..256 destination and expected_current, and replace_existing:true")
            }
            guard verifiedGate.tryAcquire() else {
                return toolTextResult(.error(HonestContract.encodeStateC(error: .verifiedOpInProgress,
                    hint: "Another verified UI acquisition is in progress.",
                    extras: ["operation": operation, "write_attempted": false])))
            }
            defer { verifiedGate.release() }
            switch await TargetRefResolver.resolveMutationIndex(params, targetRegistry: targetRegistry,
                cache: cache, operation: operation,
                invalidIndexResult: toolInvalidParamsResult("A physical Mixer target_ref is required"),
                acceptedKinds: [.mixerStrip]) {
            case .failure(let result): return result
            case .success(let resolved):
                guard let physical = resolved.binding?.physicalMixerStrip, let reference = resolved.reference,
                      let targetRegistry else {
                    return TargetRefResolver.staleTargetReferenceResult(params["target_ref"]?.stringValue, operation: operation)
                }
                let pair = await cache.retainedMixerAssociation(reference: reference, source: physical,
                    snapshot: await targetRegistry.currentSnapshot)
                let traceID = await startTraceIfEnabled(command: command)
                let routed = await withWriteBoundaryArmed(traceID) {
                    await AXMixerStripBinding.$current.withValue(physical) {
                        await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                            await routedTextResult(router, operation: operation, params: [
                                "destination": OutputAssignment.bus(destination).token,
                                "expected_current": OutputAssignment.bus(expected).token, "replace_existing": "true"])
                        }
                    }
                }
                return await finalizeTrace(TargetRefResolver.addEvidence(reference,
                    fingerprint: resolved.binding?.observedFingerprint, to: routed), traceID: traceID)
            }
        case "get_output_verified", "get_input_bus_verified", "get_send_destination_verified":
            let operation = "mixer.\(command)"
            let isSend = command == "get_send_destination_verified"
            let allowed = isSend ? ["target_ref", "project_ref", "ordinal"] : ["target_ref", "project_ref"]
            guard params.keys.allSatisfy({ allowed.contains($0) }),
                  params["target_ref"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return toolInvalidParamsResult("\(command) requires a current physical Mixer target_ref; no track/index selectors or write inputs are accepted")
            }
            let ordinal = isSend ? intParamOrNil(params,"ordinal") : nil
            guard !isSend || ordinal.map({ $0 >= 0 }) == true else {
                return toolInvalidParamsResult("get_send_destination_verified requires a nonnegative integer ordinal from send_slots")
            }
            guard verifiedGate.tryAcquire() else {
                return toolTextResult(.error(HonestContract.encodeStateC(error: .verifiedOpInProgress,
                    hint: "Another verified UI acquisition is in progress.",
                    extras: ["operation": operation, "write_attempted": false])))
            }
            defer { verifiedGate.release() }
            switch await TargetRefResolver.resolveMutationIndex(params, targetRegistry: targetRegistry,
                cache: cache, operation: operation,
                invalidIndexResult: toolInvalidParamsResult("\(command) requires a physical Mixer target_ref"),
                acceptedKinds: [.mixerStrip]) {
            case .failure(let result): return result
            case .success(let resolved):
                guard let physical = resolved.binding?.physicalMixerStrip, let targetRegistry,
                      let reference = resolved.reference else {
                    return TargetRefResolver.staleTargetReferenceResult(params["target_ref"]?.stringValue, operation: operation)
                }
                let inputAssociation = command == "get_input_bus_verified"
                    ? await cache.retainedMixerAssociation(reference: reference, source: physical,
                        snapshot: await targetRegistry.currentSnapshot) : nil
                let read = await AXMixerStripBinding.$current.withValue(physical) {
                    await AXMixerStripBinding.$outputAssociation.withValue(
                        command == "get_input_bus_verified" ? inputAssociation : AXMixerStripBinding.outputAssociation) {
                        await router.route(operation: operation, params: ordinal.map { ["ordinal":String($0)] } ?? [:])
                    }
                }
                guard !Task.isCancelled, await targetRegistry.resolve(reference) != nil,
                      await TargetRefResolver.validateProjectReference(params, targetRegistry: targetRegistry, operation: operation) == nil else {
                    return toolTextResult(AccessibilityChannel.outputReadContextFailure(read, operation: operation))
                }
                return TargetRefResolver.addEvidence(reference, fingerprint: resolved.binding?.observedFingerprint,
                    to: toolTextResult(read))
            }
        case "set_volume":
            // RB-1.a (2026-05-08 enterprise review): pre-fix this defaulted
            // missing `track` to 0, so a malformed caller silently mutated
            // the first track's fader. Mixer writes are not undoable from
            // the operator's seat — missing/invalid target now fails closed.
            let index: Int
            let resolvedReference: TargetReference?
            let resolvedFingerprint: String?
            let physical: AXMixerStripBinding.Binding?
            switch await TargetRefResolver.resolveMutationIndex(
                params,
                targetRegistry: targetRegistry,
                cache: cache,
                operation: "mixer.set_volume",
                indexKeys: ["track", "index"],
                invalidIndexResult: toolInvalidParamsResult(
                    "set_volume requires explicit 'track' or non-conflicting 'index' (Int >= 0)"
                ),
                acceptedKinds: [.track, .mixerStrip],
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            ) {
            case .success(let resolved):
                index = resolved.index
                resolvedReference = resolved.reference
                resolvedFingerprint = resolved.binding?.observedFingerprint
                physical = resolved.binding?.physicalMixerStrip
            case .failure(let result):
                return result
            }
            guard let volume = doubleParamOrNil(params, "value", "volume") else {
                return toolInvalidParamsResult(
                    "set_volume requires explicit numeric 'value' or 'volume'"
                )
            }
            guard (0.0...1.0).contains(volume) else {
                return toolInvalidParamsResult(
                    "set_volume 'volume' must be in 0.0..1.0 (got \(volume))"
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let routed = await withWriteBoundaryArmed(traceID) {
                await AXMixerStripBinding.$current.withValue(physical) {
                    await routedTextResult(router, operation: "mixer.set_volume", params: [
                    "index": String(index),
                    "volume": String(volume),
                    ])
                }
            }
            let result = TargetRefResolver.addEvidence(
                resolvedReference,
                fingerprint: resolvedFingerprint,
                to: routed
            )
            return await finalizeTrace(result, traceID: traceID)

        case "set_pan":
            // RB-1.a — same fail-closed treatment as set_volume.
            let index: Int
            let resolvedReference: TargetReference?
            let resolvedFingerprint: String?
            let physical: AXMixerStripBinding.Binding?
            switch await TargetRefResolver.resolveMutationIndex(
                params,
                targetRegistry: targetRegistry,
                cache: cache,
                operation: "mixer.set_pan",
                indexKeys: ["track", "index"],
                invalidIndexResult: toolInvalidParamsResult(
                    "set_pan requires explicit 'track' or non-conflicting 'index' (Int >= 0)"
                ),
                acceptedKinds: [.track, .mixerStrip],
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            ) {
            case .success(let resolved):
                index = resolved.index
                resolvedReference = resolved.reference
                resolvedFingerprint = resolved.binding?.observedFingerprint
                physical = resolved.binding?.physicalMixerStrip
            case .failure(let result):
                return result
            }
            guard let pan = doubleParamOrNil(params, "value", "pan") else {
                return toolInvalidParamsResult(
                    "set_pan requires explicit numeric 'value' or 'pan'"
                )
            }
            guard (-1.0...1.0).contains(pan) else {
                return toolInvalidParamsResult(
                    "set_pan 'value' must be in -1.0..1.0 (got \(pan))"
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let routed = await withWriteBoundaryArmed(traceID) {
                await AXMixerStripBinding.$current.withValue(physical) {
                    await routedTextResult(router, operation: "mixer.set_pan", params: [
                    "index": String(index),
                    "pan": String(pan),
                    ])
                }
            }
            let result = TargetRefResolver.addEvidence(
                resolvedReference,
                fingerprint: resolvedFingerprint,
                to: routed
            )
            return await finalizeTrace(result, traceID: traceID)

        case "set_send":
            return notExposedCommandResult(
                operation: "mixer.set_send",
                reason: "targeted send/bus control is not yet deterministic"
            )

        case "set_output":
            // #291 R2 keeps this answering not-exposed rather than aliasing it: the verified command
            // takes a typed `destination` object this one never had, so an alias would give an old
            // name a new contract instead of a working implementation of the old one.
            return notExposedCommandResult(operation: "mixer.set_output")

        case "set_output_verified":
            let index: Int
            let resolvedReference: TargetReference?
            let resolvedFingerprint: String?
            let physical: AXMixerStripBinding.Binding?
            var trackAssociation: AccessibilityChannel.HeldSelectionAssociation.Pair?
            switch await TargetRefResolver.resolveMutationIndex(
                params,
                targetRegistry: targetRegistry,
                cache: cache,
                operation: "mixer.set_output_verified",
                indexKeys: ["track", "index"],
                invalidIndexResult: toolInvalidParamsResult(
                    "set_output_verified requires explicit 'track' or non-conflicting 'index' (Int >= 0), "
                        + "or a 'target_ref'"
                ),
                acceptedKinds: [.track, .mixerStrip],
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            ) {
            case .success(let resolved):
                index = resolved.index
                resolvedReference = resolved.reference
                resolvedFingerprint = resolved.binding?.observedFingerprint
                if let reference = resolved.reference, resolved.binding?.kind == .track {
                    guard let track = resolved.binding?.physicalTrack, let targetRegistry,
                          let pair = await cache.retainedTrackMixerAssociation(reference: reference,
                            track: track, snapshot: await targetRegistry.currentSnapshot) else {
                        return TargetRefResolver.staleTargetReferenceResult(reference.rawValue,
                            operation: "mixer.set_output_verified",
                            hint: "The track reference has no current retained physical Mixer association. Capture an actual association or use a fresh physical Mixer reference; nothing was pressed.")
                    }
                    physical = pair.strip
                    trackAssociation = pair
                } else {
                    physical = resolved.binding?.physicalMixerStrip
                }
            case .failure(let result):
                return result
            }
            guard let rawDestination = params["destination"] else {
                return toolInvalidParamsResult(
                    "set_output_verified requires 'destination': {kind:\"bus\", number:N}, "
                        + "{kind:\"physical\", ports:[a,b]}, {kind:\"stereo_output\"}, or bounded physical-source {kind:\"no_output\"}"
                )
            }
            let parsedDestination = Self.outputAssignmentParam(rawDestination, field: "destination")
            guard let destination = parsedDestination.assignment else {
                return toolInvalidParamsResult(parsedDestination.problem ?? "invalid 'destination'")
            }
            var routedParams = ["destination": destination.token]
            if let rawExpected = params["expected_current"] {
                let parsedExpected = Self.outputAssignmentParam(rawExpected, field: "expected_current")
                guard let expected = parsedExpected.assignment else {
                    return toolInvalidParamsResult(parsedExpected.problem ?? "invalid 'expected_current'")
                }
                routedParams["expected_current"] = expected.token
            }
            routedParams["index"] = String(index)
            let outputAssociation: AccessibilityChannel.HeldSelectionAssociation.Pair?
            if let trackAssociation {
                outputAssociation = trackAssociation
            } else if let physical, let resolvedReference, let targetRegistry {
                outputAssociation = await cache.retainedMixerAssociation(reference: resolvedReference,
                    source: physical, snapshot: await targetRegistry.currentSnapshot)
            } else { outputAssociation = nil }
            let traceID = await startTraceIfEnabled(command: command)
            let routed = await withWriteBoundaryArmed(traceID) {
                await AXMixerStripBinding.$current.withValue(physical) {
                    await AXMixerStripBinding.$outputAssociation.withValue(outputAssociation) {
                        await routedTextResult(router, operation: "mixer.set_output_verified", params: routedParams)
                    }
                }
            }
            let result = TargetRefResolver.addEvidence(
                resolvedReference,
                fingerprint: resolvedFingerprint,
                to: routed
            )
            return await finalizeTrace(result, traceID: traceID)

        case "set_input":
            return notExposedCommandResult(operation: "mixer.set_input")

        case "set_master_volume":
            guard let volume = doubleParamOrNil(params, "value", "volume") else {
                return toolInvalidParamsResult(
                    "set_master_volume requires explicit numeric 'value' or 'volume'"
                )
            }
            guard (0.0...1.0).contains(volume) else {
                return toolInvalidParamsResult(
                    "set_master_volume 'value' must be in 0.0..1.0 (got \(volume))"
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await routedTextResult(router, operation: "mixer.set_master_volume", params: [
                    "volume": String(volume),
                ])
            }
            return await finalizeTrace(result, traceID: traceID)

        case "bank":
            // #862: a bank step is a Mackie Control button press whose only readback is the MCU LCD
            // upper row, so the operation is MCU-only like set_master_volume. Both params are
            // settled BEFORE the trace starts: a refusal here must not read as an attempted write.
            let direction = stringParam(params, "direction")
            guard Self.bankDirections.contains(direction) else {
                return toolInvalidParamsResult(
                    "bank requires 'direction' of exactly \"left\" or \"right\" (got \"\(direction)\")",
                    extras: ["operation": "mixer.bank"]
                )
            }
            // A missing `count` means one step. A PRESENT but unparseable count is refused rather
            // than defaulted: `intParamOrNil` returns nil for both cases, and letting garbage
            // collapse to 1 would press the bank button on a request the caller did not make.
            let count: Int
            if params["count"] == nil {
                count = 1
            } else {
                guard let parsed = intParamOrNil(params, "count"), (1...31).contains(parsed) else {
                    return toolInvalidParamsResult(
                        "bank 'count' must be an Int in 1...31 (default 1 when omitted)",
                        extras: ["operation": "mixer.bank"]
                    )
                }
                count = parsed
            }
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await routedTextResult(router, operation: "mixer.bank", params: [
                    "direction": direction,
                    "count": String(count),
                ])
            }
            return await finalizeTrace(result, traceID: traceID)

        case "toggle_eq":
            return notExposedCommandResult(operation: "mixer.toggle_eq")

        case "reset_strip":
            return notExposedCommandResult(operation: "mixer.reset_strip")

        case "insert_plugin":
            guard let track = intParamOrNil(params, "track", "track_index", "index"), track >= 0 else {
                return toolInvalidParamsResult(
                    "insert_plugin requires explicit non-conflicting 'track', 'track_index', or 'index' (Int >= 0)"
                )
            }
            guard let slot = intParamOrNil(params, "slot", "insert"), slot >= 0 else {
                return toolInvalidParamsResult(
                    "insert_plugin requires explicit non-conflicting 'slot' or 'insert' (Int >= 0)"
                )
            }
            let pluginName = stringParam(params, "plugin_name", "plugin", "name")
            guard let spec = AccessibilityChannel.pluginInsertSpec(named: pluginName) else {
                return toolInvalidParamsResult(
                    "insert_plugin unsupported plugin '\(pluginName)'. Supported stock plugins: Gain, Compressor, Channel EQ",
                    extras: ["operation": "mixer.insert_plugin"]
                )
            }
            switch strictBoolParam(params, "confirmed") {
            case .missing, .value(false):
                // ADR-003: the prompt level comes from the registry's
                // ConfirmationPolicy, never a local literal. Falls back to the
                // stricter "L2" only if the registry entry ever went missing
                // (over-prompting is the safe drift direction; the census test
                // pins the entry so this cannot silently relax).
                let level = DestructivePolicy.promptLabel(
                    of: OperationRegistry.spec(
                        tool: ToolID.logicMixer.rawValue,
                        command: "insert_plugin"
                    )?.confirmation ?? .l2
                ) ?? "L2"
                return toolTextResult(
                    DestructivePolicy.terminalConfirmationResponse(
                        command: "insert_plugin",
                        level: level
                    ),
                    isError: true
                )
            case .value(true):
                break
            case .invalid(let hint):
                return toolInvalidParamsResult("insert_plugin \(hint)")
            }
            let traceID = await startTraceIfEnabled(command: command)
            let channelResult = await withWriteBoundaryArmed(traceID) {
                var routed: [String: String] = [
                    "track": String(track),
                    "slot": String(slot),
                    "plugin_name": spec.canonicalName,
                ]
                // #871 — forward the caller's channel configuration. This map is built EXPLICITLY
                // rather than passed through, which is why the parameter reached the registry's
                // allow-list and the channel's reader and still did nothing on the first live run:
                // a param the dispatcher does not name is a param the channel never sees.
                let configuration = stringParam(params, "configuration", "channel_configuration")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !configuration.isEmpty {
                    routed["configuration"] = configuration
                }
                return await router.route(operation: "plugin.insert", params: routed)
            }
            if FeatureFlags.adr002TargetRef, channelResultIsVerified(channelResult) {
                await targetRegistry?.bumpTopologyGeneration()
            }
            let result = toolTextResult(channelResult)
            return await finalizeTrace(result, traceID: traceID)

        case "bypass_plugin":
            // Still removed from the public surface: no verified AX/MCU
            // readback path exists for bypass writes yet.
            return notExposedCommandResult(
                operation: "mixer.bypass_plugin",
                reason: "no verified readback path for bypass writes yet; use set_plugin_param via Scripter on the selected track instead"
            )

        case "set_plugin_param":
            // RB-1.a — pre-fix `track`, `insert`, `param` all defaulted to 0
            // via intParam, and `value` defaulted to 0.0 via doubleParam.
            // A malformed caller could write `value=0.0` to insert 0/param 0
            // of track 0 (often the master/first track) without ever knowing.
            // All four are now explicit-required.
            guard let track = intParamOrNil(params, "track"), track >= 0 else {
                return toolInvalidParamsResult(
                    "set_plugin_param requires explicit 'track' (Int >= 0)"
                )
            }
            guard let insert = intParamOrNil(params, "insert"), insert >= 0 else {
                return toolInvalidParamsResult(
                    "set_plugin_param requires explicit 'insert' (Int >= 0; currently only 0 supported)"
                )
            }
            guard insert == 0 else {
                return toolInvalidParamsResult(
                    "set_plugin_param currently supports only insert: 0 on the selected track via Scripter"
                )
            }
            guard let paramIndex = intParamOrNil(params, "param"), paramIndex >= 0 else {
                return toolInvalidParamsResult(
                    "set_plugin_param requires explicit 'param' (Int >= 0)"
                )
            }
            // Phase 6 P1 (RB-1.a): parse `value` STRICTLY and validate range +
            // param bound BEFORE the track.select side effect. Numeric strings
            // remain accepted for client compatibility, but malformed values
            // must never fall through to a track.select side effect.
            guard let value = doubleParamOrNil(params, "value") else {
                return toolInvalidParamsResult(
                    "set_plugin_param requires explicit numeric 'value'"
                )
            }
            guard (0.0...1.0).contains(value) else {
                return toolInvalidParamsResult(
                    "set_plugin_param 'value' must be in 0.0...1.0 (got \(value))"
                )
            }
            // Scripter addresses params 0–17 (CC 102–119); reject out-of-range
            // before selecting a track so a bad param index has no side effect.
            guard paramIndex <= 17 else {
                return toolInvalidParamsResult(
                    "set_plugin_param 'param' must be 0...17 (Scripter CC range); got \(paramIndex)"
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let selectResult = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "track.select",
                    params: ["index": String(track)]
                )
            }
            guard selectResult.isSuccess else {
                return await finalizeTrace(
                    toolTextResult(selectResult.message, isError: true),
                    traceID: traceID
                )
            }
            guard channelResultIsVerified(selectResult) else {
                return await finalizeTrace(toolStateCResult(
                    .readbackMismatch,
                    hint: "set_plugin_param refused: track \(track) selection unverified (State B). Cannot safely write plugin parameter to an unverified selected track.",
                    extras: [
                        "operation": "mixer.set_plugin_param",
                        "requested_track": track,
                        "select_response": selectResult.message,
                    ]
                ), traceID: traceID)
            }
            let result = await routedTextResult(router, operation: "plugin.set_param", params: [
                "track": String(track),
                "insert": String(insert),
                "param": String(paramIndex),
                "value": String(value),
            ])
            return await finalizeTrace(result, traceID: traceID)

        default:
            return Self.unhandledCommandResult(command, label: "mixer")
        }
    }

    /// #291 R2 — a `{kind, number|ports}` object as an `OutputAssignment`, or what is wrong with it.
    /// Unknown keys are refused rather than ignored, so a misspelt `ports` is not read as a bus.
    static func outputAssignmentParam(
        _ value: Value,
        field: String
    ) -> (assignment: OutputAssignment?, problem: String?) {
        guard let object = value.objectValue else {
            return (nil, "'\(field)' must be an object: {kind, number} or {kind, ports}")
        }
        let unknown = Set(object.keys).subtracting(["kind", "number", "ports"])
        guard unknown.isEmpty else {
            return (nil, "'\(field)' has unknown key(s): \(unknown.sorted().joined(separator: ", "))")
        }
        guard let kind = object["kind"]?.stringValue else {
            return (nil, "'\(field)' needs a string 'kind'")
        }
        func integer(_ raw: Value) -> Int? {
            if let int = raw.intValue { return int }
            if let double = raw.doubleValue, double.isFinite { return Int(exactly: double) }
            return nil
        }
        var number: Int?
        if let raw = object["number"] {
            guard let parsed = integer(raw) else { return (nil, "'\(field).number' must be an integer") }
            number = parsed
        }
        var ports: [Int]?
        if let raw = object["ports"] {
            guard let array = raw.arrayValue else { return (nil, "'\(field).ports' must be an array") }
            let parsed = array.compactMap(integer)
            guard parsed.count == array.count else {
                return (nil, "'\(field).ports' must hold integers only")
            }
            ports = parsed
        }
        let made = OutputAssignment.make(kind: kind, number: number, ports: ports)
        if let problem = made.problem {
            return (nil, "'\(field)': \(problem)")
        }
        return (made.value, nil)
    }
}
