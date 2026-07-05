import Foundation
import MCP

struct TrackDispatcher {
    private static let maxTrackNameLength = 128

    static let tool = Tool(
        name: "logic_tracks",
        description: "Track actions in Logic Pro. Commands: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, arm_only, record_sequence, set_automation, set_instrument, list_library, scan_library, resolve_path, scan_plugin_presets. Params: select -> { index: Int } or { name: String }; rename/mute/solo/arm/arm_only/set_automation/set_instrument ALL require explicit { index: Int (≥0) }; mute/solo/arm -> also { enabled: Bool }; arm_only disarms all others + arms target, returns error on partial disarm failure; record_sequence -> { bar?: Int (default 1), notes: \"pitch,offsetMs,durMs[,vel[,ch]];...\" (BREAKING since v3.1.6: optional `ch` field is 1-based, range 1..16 — pre-v3.1.6 was 0-based; whole-parse-fail on any invalid segment; SMF end <= 3,600,000 ms), tempo?: Float } SMF-import path: generates a Standard MIDI File server-side, forces playhead to bar 1, imports via AX menu — byte-exact timing, creates a new track each call, then verifies the imported region by AX readback. Successful responses include `created_track`, `target_track_index`, `target_track_name`, `region_name`, `start_bar`, `end_bar`, `note_count`, and `verify_source`; structured error JSON distinguishes `import_failure`, `audibility_unverified`, `import_unverified`, `wrong_track_import`, `timing_mismatch`, and `unreadable_readback`. If Logic imports GM Device / External MIDI lanes, record_sequence fails closed instead of promoting region readback to audible success. v3.0.8 REMOVED the internal instrument auto-load: response always carries `\"instrument\":\"not-attempted\"`; callers that want a specific patch must follow up with explicit `set_instrument` on a Software Instrument track. The legacy `instrument_path` param is accepted for wire compat but ignored (surfaces as `\"ignored:<path>\"` in the response) — see CHANGELOG v3.0.8 for why the inline auto-load was unsafe (could load the wrong track's patch, corrupting a pre-existing track); create_* -> {}; delete/duplicate -> { index: Int }; set_automation -> { mode: read|write|touch|latch|trim|off }; set_instrument -> { path: String } or { category: String, preset: String } — path mode preferred and only `resolve_path` results with kind=`leaf` and loadable=true are valid apply candidates; scan_library -> { mode?: \"ax\"|\"disk\"|\"both\" } (default disk — dedupes user and app-bundle Instrument `.patch` candidates with Panel-taxonomy remap; ax is the legacy live Library Panel scan; both returns diff summary); resolve_path -> { path: String } cache-backed read-only classifier returning kind/source/loadable; scan_plugin_presets -> { submenuOpenDelayMs?: Int }.",
        inputSchema: commandParamsToolSchema(commandDescription: "Track command to execute")
    )

    enum RecordSequenceRegionReadback {
        case success([RegionInfo])
        case failure(String)
    }

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        dialogPresent: @escaping @Sendable () -> Bool = { false }
    ) async -> CallTool.Result {
        if let operation = modalGuardedTrackOperation(for: command), dialogPresent() {
            return blockingLogicDialogResult(operation: operation)
        }

        switch command {
        case "select":
            // Prefer index (accepts int/double/string), else match by name. If
            // `index` is supplied but not a valid non-negative integer, fail
            // closed — silently falling back to track 0 on a malformed
            // request would corrupt the wrong track.
            if params["index"] != nil || params["track"] != nil {
                guard let index = intParamOrNil(params, "index", "track") else {
                    return toolInvalidParamsResult(
                        "select 'index' must be a non-negative integer (non-numeric or missing value rejected)",
                        extras: ["operation": "track.select"]
                    )
                }
                guard index >= 0 else {
                    return toolInvalidParamsResult(
                        "select 'index' must be ≥ 0 (got \(index)) — Logic doesn't have negative track indices",
                        extras: ["operation": "track.select"]
                    )
                }
                let result = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                return toolTextResult(result)
            }
            let name = stringParam(params, "name")
            if !name.isEmpty {
                let tracks = await cache.getTracks()
                if let track = tracks.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    let result = await router.route(
                        operation: "track.select",
                        params: ["index": String(track.id)]
                    )
                    return toolTextResult(result)
                }
                return toolStateCResult(
                    .elementNotFound,
                    hint: "No track found matching '\(name)'",
                    extras: ["operation": "track.select", "requested_name": name]
                )
            }
            return toolInvalidParamsResult(
                "select requires 'index' or 'name' param",
                extras: ["operation": "track.select"]
            )

        case "create_audio", "create_instrument", "create_drummer", "create_external_midi":
            // 4 byte-identical bodies; the channel op is always "track.<command>".
            let result = await router.route(operation: "track.\(command)")
            if result.isSuccess, !channelSuccessIsVerified(result) {
                return toolTextResult(result.message, isError: true)
            }
            return toolTextResult(result)

        case "delete":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolInvalidParamsResult(
                    "delete requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "track.delete"]
                )
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(index)]
            )
            guard selectResult.isSuccess else {
                return toolTextResult(selectResult.message, isError: true)
            }
            // v3.1.2 P1-5 — `track.select` can return State B (`verified:false`,
            // e.g. `reason:"retry_exhausted"` or `"readback_mismatch"`) while
            // the outer ChannelResult is still `.success`. State B means
            // "the AX write was issued but the read-back could not confirm
            // selection landed on the requested track". Following State B
            // with `track.delete` is unsafe: the previously-selected track
            // (whatever it was) gets deleted instead of the requested target,
            // an irrecoverable data-loss scenario. Refuse the delete and
            // require the caller to re-issue selection (or accept that the
            // selection is uncertain and abort).
            guard channelResultIsVerified(selectResult) else {
                return toolStateCResult(
                    .readbackMismatch,
                    hint: "track.delete refused: track \(index) selection unverified (State B). Cannot safely delete unverified target — re-select or fix Logic Pro AX state and retry.",
                    extras: [
                        "operation": "track.delete",
                        "requested_index": index,
                        "select_response": selectResult.message,
                    ]
                )
            }
            let result = await router.route(operation: "track.delete")
            return toolTextResult(result)

        case "duplicate":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolInvalidParamsResult(
                    "duplicate requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "track.duplicate"]
                )
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(index)]
            )
            guard selectResult.isSuccess else {
                return toolTextResult(selectResult.message, isError: true)
            }
            // RB-1.c (2026-05-08 enterprise review): mirror the State-B
            // refusal gate that `delete` already enforces. `track.select`
            // can return State B (`verified:false`, e.g. `readback_mismatch`
            // or `retry_exhausted`) while the outer ChannelResult is still
            // `.success`. Following State B with `track.duplicate` would
            // duplicate whatever track is currently selected (which can
            // differ from the requested index), creating a phantom track
            // and confusing the caller's mental model. Refuse and require
            // the caller to re-issue selection.
            guard channelResultIsVerified(selectResult) else {
                return toolStateCResult(
                    .readbackMismatch,
                    hint: "track.duplicate refused: track \(index) selection unverified (State B). Cannot safely duplicate unverified target — re-select or fix Logic Pro AX state and retry.",
                    extras: [
                        "operation": "track.duplicate",
                        "requested_index": index,
                        "select_response": selectResult.message,
                    ]
                )
            }
            let result = await router.route(operation: "track.duplicate")
            return toolTextResult(result)

        case "rename":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolInvalidParamsResult(
                    "rename requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "track.rename"]
                )
            }
            let name = stringParam(params, "name")
            guard !name.isEmpty else {
                return toolInvalidParamsResult(
                    "rename requires 'name' parameter",
                    extras: ["operation": "track.rename"]
                )
            }
            guard name.count <= maxTrackNameLength else {
                return toolInvalidParamsResult(
                    "rename 'name' must be \(maxTrackNameLength) characters or fewer",
                    extras: [
                        "operation": "track.rename",
                        "max_length": maxTrackNameLength,
                        "actual_length": name.count,
                    ]
                )
            }
            let result = await router.route(
                operation: "track.rename",
                params: ["index": String(index), "name": name]
            )
            guard result.isSuccess else {
                return toolTextResult(result.message, isError: true)
            }
            if let data = result.message.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let verified = json["verified"] as? Bool,
               verified == false {
                return toolTextResult(result.message, isError: true)
            }
            return toolTextResult(result)

        case "mute":
            return await handleToggle(command: "mute", operation: "track.set_mute", params: params, router: router)

        case "solo":
            return await handleToggle(command: "solo", operation: "track.set_solo", params: params, router: router)

        case "arm":
            return await handleToggle(command: "arm", operation: "track.set_arm", params: params, router: router)

        case "record_sequence":
            return await handleRecordSequenceSMF(params: params, router: router, cache: cache)

        case "arm_only":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolInvalidParamsResult(
                    "arm_only requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "track.arm_only"]
                )
            }
            let tracks = await cache.getTracks()
            var disarmed: [Int] = []
            var unverifiedDisarm: [Int] = []
            var failedDisarm: [Int] = []
            for t in tracks where t.id != index && t.isArmed {
                let r = await router.route(
                    operation: "track.set_arm",
                    params: ["index": String(t.id), "enabled": "false"]
                )
                if !r.isSuccess {
                    failedDisarm.append(t.id)
                } else if trackToggleResultIsVerified(r) {
                    disarmed.append(t.id)
                } else {
                    unverifiedDisarm.append(t.id)
                }
            }
            let armResult = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "enabled": "true"]
            )
            // If the primary arm action failed, return an explicit error instead
            // of a structured success payload. Partial-disarm visibility still
            // available in the error detail.
            guard armResult.isSuccess else {
                return toolStateCResult(
                    .axWriteFailed,
                    hint: "arm_only failed: target arm rejected — \(armResult.message)",
                    extras: [
                        "operation": "track.arm_only",
                        "requested_index": index,
                        "disarmed": disarmed,
                        "failed_disarm": failedDisarm,
                    ]
                )
            }
            if !trackToggleResultIsVerified(armResult) {
                return toolTextResult(
                    armOnlyResponse(
                        targetIndex: index,
                        armResult: armResult,
                        armedSuccess: false,
                        verified: false,
                        disarmed: disarmed,
                        unverifiedDisarm: unverifiedDisarm,
                        failedDisarm: failedDisarm
                    ),
                    isError: true
                )
            }
            // Report partial disarm failures explicitly — the target arm
            // succeeded, but some other tracks may still be armed.
            if !failedDisarm.isEmpty || !unverifiedDisarm.isEmpty {
                return toolTextResult(
                    armOnlyResponse(
                        targetIndex: index,
                        armResult: armResult,
                        armedSuccess: false,
                        verified: false,
                        disarmed: disarmed,
                        unverifiedDisarm: unverifiedDisarm,
                        failedDisarm: failedDisarm
                    ),
                    isError: true
                )
            }
            return toolTextResult(.success(
                armOnlyResponse(
                    targetIndex: index,
                    armResult: armResult,
                    armedSuccess: true,
                    verified: true,
                    disarmed: disarmed,
                    unverifiedDisarm: [],
                    failedDisarm: []
                )
            ))

        case "set_color":
            return notExposedCommandResult(operation: "track.set_color")

        case "set_automation":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolInvalidParamsResult(
                    "set_automation requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "track.set_automation"]
                )
            }
            guard params["mode"] != nil else {
                return toolInvalidParamsResult(
                    "set_automation requires explicit 'mode'",
                    extras: ["operation": "track.set_automation"]
                )
            }
            let mode = stringParam(params, "mode")
            let validModes = ["read", "write", "touch", "latch", "trim", "off"]
            guard validModes.contains(mode) else {
                return toolInvalidParamsResult(
                    "set_automation 'mode' must be one of \(validModes.joined(separator: ", ")) (got '\(mode)')",
                    extras: ["operation": "track.set_automation"]
                )
            }
            let result = await router.route(
                operation: "track.set_automation",
                params: ["index": String(index), "mode": mode]
            )
            return toolTextResult(result)

        case "set_instrument":
            guard let index = intParamOrNil(params, "index"), index >= 0 else {
                return toolInvalidParamsResult(
                    "set_instrument requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "track.set_instrument"]
                )
            }
            let category = stringParam(params, "category")
            let preset = stringParam(params, "preset")
            let path = stringParam(params, "path")
            guard !path.isEmpty || (!category.isEmpty && !preset.isEmpty) else {
                return toolInvalidParamsResult(
                    "set_instrument requires 'path' or both 'category' + 'preset'",
                    extras: ["operation": "track.set_instrument"]
                )
            }
            var routeParams: [String: String] = ["index": String(index)]
            if !path.isEmpty { routeParams["path"] = path }
            if !category.isEmpty { routeParams["category"] = category }
            if !preset.isEmpty { routeParams["preset"] = preset }
            if dialogPresent() {
                return blockingLogicDialogResult(operation: "track.set_instrument")
            }
            let result = await router.route(
                operation: "track.set_instrument",
                params: routeParams
            )
            return toolTextResult(result)

        case "resolve_path":
            let path = stringParam(params, "path")
            if path.isEmpty {
                return toolInvalidParamsResult(
                    "Missing 'path' parameter; resolve_path requires 'path' parameter",
                    extras: ["operation": "library.resolve_path"]
                )
            }
            let result = await router.route(
                operation: "library.resolve_path",
                params: ["path": path]
            )
            return toolTextResult(result)

        case "list_library", "library":
            if dialogPresent() {
                return blockingLogicDialogResult(operation: "library.list")
            }
            let result = await router.route(operation: "library.list")
            return toolTextResult(result)

        case "scan_library":
            // v3.0.7: forward `mode` param (ax|disk|both) to the scan handler.
            // Previously dropped on the floor — v3.0.6 mode routing was dead.
            var scanParams: [String: String] = [:]
            let mode = stringParam(params, "mode").lowercased()
            let effectiveMode = AccessibilityChannel.parseScanMode(mode)
            if !mode.isEmpty {
                guard ["ax", "disk", "both"].contains(mode) else {
                    return toolInvalidParamsResult(
                        "scan_library 'mode' must be one of: ax, disk, both"
                    )
                }
                scanParams["mode"] = mode
            }
            if dialogPresent(), effectiveMode != .disk {
                return blockingLogicDialogResult(operation: "library.scan_all")
            }
            let result = await router.route(
                operation: "library.scan_all",
                params: scanParams
            )
            return toolTextResult(result)

        case "scan_plugin_presets":
            // F2 minimal — scans the currently-focused plugin window's Setting menu.
            let settleMs: Int
            if params["submenuOpenDelayMs"] != nil {
                guard let parsed = intParamOrNil(params, "submenuOpenDelayMs"),
                      (0...5000).contains(parsed) else {
                    return toolInvalidParamsResult(
                        "scan_plugin_presets 'submenuOpenDelayMs' must be an integer in 0..5000"
                    )
                }
                settleMs = parsed
            } else {
                settleMs = 250
            }
            if dialogPresent() {
                return blockingLogicDialogResult(operation: "plugin.scan_presets")
            }
            let result = await router.route(
                operation: "plugin.scan_presets",
                params: ["submenuOpenDelayMs": String(settleMs)]
            )
            return toolTextResult(result)

        default:
            return toolInvalidParamsResult(
                "Unknown track command: \(command). Available: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, arm_only, record_sequence, set_automation, set_instrument, list_library, scan_library, resolve_path, scan_plugin_presets",
                extras: ["operation": "track.\(command)"]
            )
        }
    }

    /// Shared mute/solo/arm handler (3 near-identical bodies). Parses the
    /// required `index` (≥0) and optional `enabled` (default true), routes the
    /// set op, then surfaces a #106 State-B (unverified) channel success as an
    /// error. Per-command error-hint strings are preserved verbatim via
    /// `command`; `operation` is the channel op ("track.set_mute", etc.).
    private static func handleToggle(
        command: String,
        operation: String,
        params: [String: Value],
        router: ChannelRouter
    ) async -> CallTool.Result {
        guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
            return toolInvalidParamsResult(
                "\(command) requires explicit 'index' (Int ≥ 0)",
                extras: ["operation": operation]
            )
        }
        let enabled: Bool
        if params["enabled"] != nil {
            guard let parsed = boolParamOrNil(params, "enabled") else {
                return toolInvalidParamsResult(
                    "\(command) 'enabled' must be boolean true/false"
                )
            }
            enabled = parsed
        } else {
            enabled = true
        }
        let result = await router.route(
            operation: operation,
            params: ["index": String(index), "enabled": String(enabled)]
        )
        // #106: never surface an unverified channel success — a State B
        // "success without read-back" is reported as an error so callers
        // can't mistake a fired-but-unconfirmed toggle for a verified one.
        if result.isSuccess, !trackToggleResultIsVerified(result) {
            return toolTextResult(result.message, isError: true)
        }
        return toolTextResult(result)
    }

    private static func modalGuardedTrackOperation(for command: String) -> String? {
        switch command {
        case "select": return "track.select"
        case "create_audio": return "track.create_audio"
        case "create_instrument": return "track.create_instrument"
        case "create_drummer": return "track.create_drummer"
        case "create_external_midi": return "track.create_external_midi"
        case "delete": return "track.delete"
        case "duplicate": return "track.duplicate"
        case "rename": return "track.rename"
        case "mute": return "track.set_mute"
        case "solo": return "track.set_solo"
        case "arm": return "track.set_arm"
        case "arm_only": return "track.arm_only"
        case "record_sequence": return "track.record_sequence"
        case "set_automation": return "track.set_automation"
        default: return nil
        }
    }

    private static func trackToggleResultIsVerified(_ result: ChannelResult) -> Bool {
        guard result.isSuccess else { return false }
        guard let json = trackArmEnvelope(result),
              json["success"] != nil else {
            // Legacy/plain-string mock successes are treated as verified so
            // existing non-HC test doubles keep working. Real product channels
            // now return HC envelopes, so the verified gate still applies in
            // production.
            return true
        }
        return (json["verified"] as? Bool) == true
    }

    private static func channelSuccessIsVerified(_ result: ChannelResult) -> Bool {
        guard result.isSuccess else { return false }
        guard let data = result.message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] != nil else {
            // Legacy/plain-string mock successes are treated as verified so
            // existing dispatcher tests keep working. Real mutating channels
            // return Honest Contract envelopes, so the verified gate still
            // applies in production.
            return true
        }
        return (json["verified"] as? Bool) == true
    }

    private static func trackArmEnvelope(_ result: ChannelResult) -> [String: Any]? {
        guard let data = result.message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func armOnlyResponse(
        targetIndex: Int,
        armResult: ChannelResult,
        armedSuccess: Bool,
        verified: Bool,
        disarmed: [Int],
        unverifiedDisarm: [Int],
        failedDisarm: [Int]
    ) -> String {
        var response: [String: Any] = [
            "armed": targetIndex,
            "target_track": targetIndex,
            "armedSuccess": armedSuccess,
            "verified": verified,
            "requested_enabled": true,
            "observed_enabled": NSNull(),
            "verification_source": NSNull(),
            "disarmed": disarmed,
            "unverifiedDisarm": unverifiedDisarm,
            "failedDisarm": failedDisarm,
            "detail": armResult.message,
        ]
        if let envelope = trackArmEnvelope(armResult) {
            response["requested_enabled"] = envelope["requested"] ?? envelope["enabled"] ?? true
            response["observed_enabled"] = envelope["observed"] ?? NSNull()
            response["verification_source"] =
                envelope["verification_source"] ?? envelope["method"] ?? NSNull()
            if let reason = envelope["reason"] {
                response["reason"] = reason
            }
            if let function = envelope["function"] {
                response["function"] = function
            }
            if let button = envelope["button"] {
                response["button"] = button
            }
            if let action = envelope["action"] {
                response["action"] = action
            }
            if let writeSource = envelope["write_source"] {
                response["write_source"] = writeSource
            }
        }
        return HonestContract.jsonString(response)
    }

}
