import Foundation
import MCP

struct TrackDispatcher {
    static let tool = Tool(
        name: "logic_tracks",
        description: "Track actions in Logic Pro. Commands: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, arm_only, record_sequence, set_automation, set_instrument, list_library, scan_library, resolve_path, scan_plugin_presets. Params: select -> { index: Int } or { name: String }; rename -> { index: Int, name: String }; mute/solo/arm -> { index: Int, enabled: Bool }; arm_only -> { index: Int } (disarms others, arms target — fixes multi-armed duplicate-record bug); record_sequence -> { index: Int, bar?: Int, notes: \"pitch,offsetMs,durMs[,vel[,ch]];...\" } (one-shot select+arm_only+record+play+stop); create_* -> {}; delete/duplicate -> { index: Int }; set_automation -> { index: Int, mode: String }; set_instrument -> { index: Int, path?: String } or { index: Int, category: String, preset: String } — path mode preferred; scan_library -> {}; resolve_path -> { path: String } cache-backed read-only; scan_plugin_presets -> { submenuOpenDelayMs?: Int }.",
        inputSchema: commandParamsToolSchema(commandDescription: "Track command to execute")
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "select":
            // Prefer index (accepts int/double/string via intParam), else match by name.
            if params["index"] != nil || params["track"] != nil {
                let index = intParam(params, "index", "track", default: 0)
                guard index >= 0 else {
                    return toolTextResult(
                        "select 'index' must be ≥ 0 (got \(index)) — Logic doesn't have negative track indices",
                        isError: true
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
                return toolTextResult("No track found matching '\(name)'", isError: true)
            }
            return toolTextResult("select requires 'index' or 'name' param", isError: true)

        case "create_audio":
            let result = await router.route(operation: "track.create_audio")
            return toolTextResult(result)

        case "create_instrument":
            let result = await router.route(operation: "track.create_instrument")
            return toolTextResult(result)

        case "create_drummer":
            let result = await router.route(operation: "track.create_drummer")
            return toolTextResult(result)

        case "create_external_midi":
            let result = await router.route(operation: "track.create_external_midi")
            return toolTextResult(result)

        case "delete":
            if params["index"] != nil || params["track"] != nil {
                let index = intParam(params, "index", "track", default: 0)
                let result = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                guard result.isSuccess else {
                    return toolTextResult(result.message, isError: true)
                }
            }
            let result = await router.route(operation: "track.delete")
            return toolTextResult(result)

        case "duplicate":
            if params["index"] != nil || params["track"] != nil {
                let index = intParam(params, "index", "track", default: 0)
                let selectResult = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                guard selectResult.isSuccess else {
                    return toolTextResult(selectResult.message, isError: true)
                }
            }
            let result = await router.route(operation: "track.duplicate")
            return toolTextResult(result)

        case "rename":
            let index = intParam(params, "index", "track", default: 0)
            let name = stringParam(params, "name")
            guard !name.isEmpty else {
                return toolTextResult("rename requires 'name' parameter", isError: true)
            }
            let result = await router.route(
                operation: "track.rename",
                params: ["index": String(index), "name": name]
            )
            return toolTextResult(result)

        case "mute":
            let index = intParam(params, "index", "track", default: 0)
            let enabled = boolParam(params, "enabled", default: true)
            let result = await router.route(
                operation: "track.set_mute",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "solo":
            let index = intParam(params, "index", "track", default: 0)
            let enabled = boolParam(params, "enabled", default: true)
            let result = await router.route(
                operation: "track.set_solo",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "arm":
            let index = intParam(params, "index", "track", default: 0)
            let enabled = boolParam(params, "enabled", default: true)
            let result = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "record_sequence":
            // One-shot composition helper:
            //   1. Select the target track
            //   2. Disarm every other track + arm this one
            //   3. Goto bar 1 (or caller-provided bar)
            //   4. Start recording
            //   5. Play MIDI sequence with tight server-side timing
            //   6. Stop
            // Covers the entire "record one bar on one track" user story in a
            // single call — the recurring source of bugs was doing these steps
            // individually and racing/duplicating.
            let index = intParam(params, "index", "track", default: 0)
            let bar = intParam(params, "bar", default: 1)
            let notes = stringParam(params, "notes")
            guard !notes.isEmpty else {
                return toolTextResult(
                    "record_sequence requires 'notes' (semicolon-separated 'pitch,offsetMs,durMs[,vel[,ch]]')",
                    isError: true
                )
            }
            // Step 1 + 2: select + arm_only
            let tracks = await cache.getTracks()
            for t in tracks where t.id != index && t.isArmed {
                _ = await router.route(
                    operation: "track.set_arm",
                    params: ["index": String(t.id), "enabled": "false"]
                )
            }
            _ = await router.route(
                operation: "track.select",
                params: ["index": String(index)]
            )
            _ = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "enabled": "true"]
            )
            // Step 3: goto bar
            _ = await router.route(
                operation: "transport.goto_position",
                params: ["position": "\(bar).1.1.1"]
            )
            // Step 4: start record
            _ = await router.route(operation: "transport.record")
            // Tiny settle so Logic is actually in record state before MIDI flows.
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Step 5: play sequence
            let playResult = await router.route(
                operation: "midi.play_sequence",
                params: ["notes": notes]
            )
            // Step 6: stop
            _ = await router.route(operation: "transport.stop")
            return toolTextResult(.success(
                "{\"recorded_to_track\":\(index),\"bar\":\(bar),\"play_result\":\"\(playResult.message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
            ))

        case "arm_only":
            let index = intParam(params, "index", "track", default: 0)
            let tracks = await cache.getTracks()
            var disarmed: [Int] = []
            var failedDisarm: [Int] = []
            for t in tracks where t.id != index && t.isArmed {
                let r = await router.route(
                    operation: "track.set_arm",
                    params: ["index": String(t.id), "enabled": "false"]
                )
                if r.isSuccess { disarmed.append(t.id) } else { failedDisarm.append(t.id) }
            }
            let armResult = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "enabled": "true"]
            )
            let detail = armResult.message.replacingOccurrences(of: "\"", with: "\\\"")
            return toolTextResult(.success(
                "{\"armed\":\(index),\"armedSuccess\":\(armResult.isSuccess),\"disarmed\":\(disarmed),\"failedDisarm\":\(failedDisarm),\"detail\":\"\(detail)\"}"
            ))

        case "set_color":
            return toolTextResult("set_color is not exposed in the production MCP contract", isError: true)

        case "set_automation":
            let index = intParam(params, "index", "track", default: 0)
            let mode = stringParam(params, "mode", default: "read")
            let validModes = ["read", "write", "touch", "latch", "trim", "off"]
            guard validModes.contains(mode) else {
                return toolTextResult(
                    "set_automation 'mode' must be one of \(validModes.joined(separator: ", ")) (got '\(mode)')",
                    isError: true
                )
            }
            let result = await router.route(
                operation: "track.set_automation",
                params: ["index": String(index), "mode": mode]
            )
            return toolTextResult(result)

        case "set_instrument":
            let index = intParam(params, "index", default: 0)
            let category = stringParam(params, "category")
            let preset = stringParam(params, "preset")
            let path = stringParam(params, "path")
            var routeParams: [String: String] = ["index": String(index)]
            if !path.isEmpty { routeParams["path"] = path }
            if !category.isEmpty { routeParams["category"] = category }
            if !preset.isEmpty { routeParams["preset"] = preset }
            let result = await router.route(
                operation: "track.set_instrument",
                params: routeParams
            )
            return toolTextResult(result)

        case "resolve_path":
            let path = stringParam(params, "path")
            if path.isEmpty {
                return toolTextResult("Missing 'path' parameter", isError: true)
            }
            let result = await router.route(
                operation: "library.resolve_path",
                params: ["path": path]
            )
            return toolTextResult(result)

        case "list_library", "library":
            let result = await router.route(operation: "library.list")
            return toolTextResult(result)

        case "scan_library":
            let result = await router.route(operation: "library.scan_all")
            return toolTextResult(result)

        case "scan_plugin_presets":
            // F2 minimal — scans the currently-focused plugin window's Setting menu.
            let settleMs = intParam(params, "submenuOpenDelayMs", default: 250)
            let result = await router.route(
                operation: "plugin.scan_presets",
                params: ["submenuOpenDelayMs": String(settleMs)]
            )
            return toolTextResult(result)

        default:
            return toolTextResult(
                "Unknown track command: \(command). Available: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, arm_only, record_sequence, set_automation, set_instrument, list_library, scan_library, resolve_path, scan_plugin_presets",
                isError: true
            )
        }
    }
}
