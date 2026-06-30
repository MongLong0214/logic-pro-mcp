import Foundation
import MCP

struct MixerDispatcher {
    static let tool = commandTool(
        name: "logic_mixer",
        description: "Mixer actions in Logic Pro. Commands: set_volume, set_pan, set_master_volume, set_plugin_param, insert_plugin. BREAKING since v3.3.0: every mutating command requires explicit `track` (Int ≥ 0) — pre-v3.3.0 missing `track` defaulted to 0 and silently mutated the first track; this now returns an error. Params: set_volume -> { track: Int (required, ≥ 0), value: Float (0.0..1.0) } verified against the visible mixer strip via AX readback; set_pan -> { track: Int (required, ≥ 0), value: Float (-1.0..1.0) } verified against the visible mixer strip via AX readback; set_master_volume -> { value: Float (0.0..1.0) } — the master fader has no AX track-header equivalent, so MCU echo is the ONLY readback: State A only when a fresh echo lands, otherwise honest State B echo_timeout with readback_source:mcu_echo + a surface_limitation note (non-deterministic, not a recoverable failure); set_plugin_param -> { track: Int (required, ≥ 0), insert: Int (required, currently only 0), param: Int (required, ≥ 0), value: Float (required) } on the selected track via Scripter; insert_plugin -> { track: Int, slot: Int, plugin_name: Gain|Compressor|Channel EQ, confirmed: true } via AX mixer slot with readback.",
        commandDescription: "Mixer command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "set_volume":
            // RB-1.a (2026-05-08 enterprise review): pre-fix this defaulted
            // missing `track` to 0, so a malformed caller silently mutated
            // the first track's fader. Mixer writes are not undoable from
            // the operator's seat — missing/invalid target now fails closed.
            guard let index = intParamOrNil(params, "track", "index"), index >= 0 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_volume requires explicit 'track' or non-conflicting 'index' (Int >= 0)"
                )
            }
            guard let volume = doubleParamOrNil(params, "value", "volume") else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_volume requires explicit numeric 'value' or 'volume'"
                )
            }
            guard (0.0...1.0).contains(volume) else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_volume 'volume' must be in 0.0..1.0 (got \(volume))"
                )
            }
            return await routedTextResult(router, operation: "mixer.set_volume", params: [
                "index": String(index),
                "volume": String(volume),
            ])

        case "set_pan":
            // RB-1.a — same fail-closed treatment as set_volume.
            guard let index = intParamOrNil(params, "track", "index"), index >= 0 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_pan requires explicit 'track' or non-conflicting 'index' (Int >= 0)"
                )
            }
            guard let pan = doubleParamOrNil(params, "value", "pan") else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_pan requires explicit numeric 'value' or 'pan'"
                )
            }
            guard (-1.0...1.0).contains(pan) else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_pan 'value' must be in -1.0..1.0 (got \(pan))"
                )
            }
            return await routedTextResult(router, operation: "mixer.set_pan", params: [
                "index": String(index),
                "pan": String(pan),
            ])

        case "set_send":
            return notExposedCommandResult(
                operation: "mixer.set_send",
                reason: "targeted send/bus control is not yet deterministic"
            )

        case "set_output":
            return notExposedCommandResult(operation: "mixer.set_output")

        case "set_input":
            return notExposedCommandResult(operation: "mixer.set_input")

        case "set_master_volume":
            guard let volume = doubleParamOrNil(params, "value", "volume") else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_master_volume requires explicit numeric 'value' or 'volume'"
                )
            }
            guard (0.0...1.0).contains(volume) else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_master_volume 'value' must be in 0.0..1.0 (got \(volume))"
                )
            }
            return await routedTextResult(router, operation: "mixer.set_master_volume", params: [
                "volume": String(volume),
            ])

        case "toggle_eq":
            return notExposedCommandResult(operation: "mixer.toggle_eq")

        case "reset_strip":
            return notExposedCommandResult(operation: "mixer.reset_strip")

        case "insert_plugin":
            guard let track = intParamOrNil(params, "track", "track_index", "index"), track >= 0 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "insert_plugin requires explicit non-conflicting 'track', 'track_index', or 'index' (Int >= 0)"
                )
            }
            guard let slot = intParamOrNil(params, "slot", "insert"), slot >= 0 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "insert_plugin requires explicit non-conflicting 'slot' or 'insert' (Int >= 0)"
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
                let response = """
                {"confirmation_required":true,"command":"insert_plugin","level":"L2","message":"insert_plugin changes the channel strip insert chain. Re-call with confirmed:true to insert an allowlisted stock plugin.","confirm_command":"logic_mixer(\\"insert_plugin\\", {\\"track\\": \(track), \\"slot\\": \(slot), \\"plugin_name\\": \\"\(spec.canonicalName)\\", \\"confirmed\\": true})"}
                """
                return toolTextResult(response)
            case .value(true):
                break
            case .invalid(let hint):
                return MIDIDispatcher.invalidParamsResult(hint: "insert_plugin \(hint)")
            }
            return await routedTextResult(router, operation: "plugin.insert", params: [
                "track": String(track),
                "slot": String(slot),
                "plugin_name": spec.canonicalName,
            ])

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
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_plugin_param requires explicit 'track' (Int >= 0)"
                )
            }
            guard let insert = intParamOrNil(params, "insert"), insert >= 0 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_plugin_param requires explicit 'insert' (Int >= 0; currently only 0 supported)"
                )
            }
            guard insert == 0 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_plugin_param currently supports only insert: 0 on the selected track via Scripter"
                )
            }
            guard let paramIndex = intParamOrNil(params, "param"), paramIndex >= 0 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_plugin_param requires explicit 'param' (Int >= 0)"
                )
            }
            // Phase 6 P1 (RB-1.a): parse `value` STRICTLY and validate range +
            // param bound BEFORE the track.select side effect. Numeric strings
            // remain accepted for client compatibility, but malformed values
            // must never fall through to a track.select side effect.
            guard let value = doubleParamOrNil(params, "value") else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_plugin_param requires explicit numeric 'value'"
                )
            }
            guard (0.0...1.0).contains(value) else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_plugin_param 'value' must be in 0.0...1.0 (got \(value))"
                )
            }
            // Scripter addresses params 0–17 (CC 102–119); reject out-of-range
            // before selecting a track so a bad param index has no side effect.
            guard paramIndex <= 17 else {
                return MIDIDispatcher.invalidParamsResult(
                    hint: "set_plugin_param 'param' must be 0...17 (Scripter CC range); got \(paramIndex)"
                )
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(track)]
            )
            guard selectResult.isSuccess else {
                return toolTextResult(selectResult.message, isError: true)
            }
            guard let data = selectResult.message.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let verified = json["verified"] as? Bool, verified == true else {
                return toolStateCResult(
                    .readbackMismatch,
                    hint: "set_plugin_param refused: track \(track) selection unverified (State B). Cannot safely write plugin parameter to an unverified selected track.",
                    extras: [
                        "operation": "mixer.set_plugin_param",
                        "requested_track": track,
                        "select_response": selectResult.message,
                    ]
                )
            }
            return await routedTextResult(router, operation: "plugin.set_param", params: [
                "track": String(track),
                "insert": String(insert),
                "param": String(paramIndex),
                "value": String(value),
            ])

        default:
            return toolInvalidParamsResult(
                "Unknown mixer command: \(command). Available: set_volume, set_pan, set_master_volume, set_plugin_param, insert_plugin",
                extras: ["operation": "mixer.\(command)"]
            )
        }
    }
}
