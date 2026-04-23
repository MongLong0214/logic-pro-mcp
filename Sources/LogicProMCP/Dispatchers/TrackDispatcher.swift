import Foundation
import MCP

struct TrackDispatcher {
    static let tool = Tool(
        name: "logic_tracks",
        description: "Track actions in Logic Pro. Commands: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, arm_only, record_sequence, set_automation, set_instrument, list_library, scan_library, resolve_path, scan_plugin_presets. Params: select -> { index: Int } or { name: String }; rename/mute/solo/arm/arm_only/set_automation/set_instrument ALL require explicit { index: Int (≥0) }; mute/solo/arm -> also { enabled: Bool }; arm_only disarms all others + arms target, returns error on partial disarm failure; record_sequence -> { bar?: Int (default 1), notes: \"pitch,offsetMs,durMs[,vel[,ch]];...\", tempo?: Float } v2.3 SMF-import path: generates a Standard MIDI File server-side, forces playhead to bar 1, imports via AX menu — byte-exact timing, creates a new track each call; create_* -> {}; delete/duplicate -> { index: Int }; set_automation -> { mode: read|write|touch|latch|trim|off }; set_instrument -> { path: String } or { category: String, preset: String } — path mode preferred; scan_library -> { mode?: \"ax\"|\"disk\"|\"both\" } (default ax — live Library Panel; disk reads ~/Music/Logic Pro Library.bundle for 5,400+ leaves with Panel-taxonomy remap; both returns diff summary); resolve_path -> { path: String } cache-backed read-only; scan_plugin_presets -> { submenuOpenDelayMs?: Int }.",
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
            // Prefer index (accepts int/double/string), else match by name. If
            // `index` is supplied but not a valid non-negative integer, fail
            // closed — silently falling back to track 0 on a malformed
            // request would corrupt the wrong track.
            if params["index"] != nil || params["track"] != nil {
                guard let index = intParamOrNil(params, "index", "track") else {
                    return toolTextResult(
                        "select 'index' must be a non-negative integer (non-numeric or missing value rejected)",
                        isError: true
                    )
                }
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
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("delete requires explicit 'index' (Int ≥ 0)", isError: true)
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(index)]
            )
            guard selectResult.isSuccess else {
                return toolTextResult(selectResult.message, isError: true)
            }
            let result = await router.route(operation: "track.delete")
            return toolTextResult(result)

        case "duplicate":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("duplicate requires explicit 'index' (Int ≥ 0)", isError: true)
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(index)]
            )
            guard selectResult.isSuccess else {
                return toolTextResult(selectResult.message, isError: true)
            }
            let result = await router.route(operation: "track.duplicate")
            return toolTextResult(result)

        case "rename":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("rename requires explicit 'index' (Int ≥ 0)", isError: true)
            }
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
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("mute requires explicit 'index' (Int ≥ 0)", isError: true)
            }
            let enabled = boolParam(params, "enabled", default: true)
            let result = await router.route(
                operation: "track.set_mute",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "solo":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("solo requires explicit 'index' (Int ≥ 0)", isError: true)
            }
            let enabled = boolParam(params, "enabled", default: true)
            let result = await router.route(
                operation: "track.set_solo",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "arm":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("arm requires explicit 'index' (Int ≥ 0)", isError: true)
            }
            let enabled = boolParam(params, "enabled", default: true)
            let result = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "record_sequence":
            return await handleRecordSequenceSMF(params: params, router: router, cache: cache)

        case "arm_only":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("arm_only requires explicit 'index' (Int ≥ 0)", isError: true)
            }
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
            // If the primary arm action failed, return an explicit error instead
            // of a structured success payload. Partial-disarm visibility still
            // available in the error detail.
            let detail = armResult.message.replacingOccurrences(of: "\"", with: "\\\"")
            guard armResult.isSuccess else {
                return toolTextResult(
                    "arm_only failed: target arm rejected — \(armResult.message); disarmed=\(disarmed) failedDisarm=\(failedDisarm)",
                    isError: true
                )
            }
            // Report partial disarm failures explicitly — the target arm
            // succeeded, but some other tracks may still be armed.
            if !failedDisarm.isEmpty {
                return toolTextResult(
                    "arm_only partial: target \(index) armed, but these tracks failed to disarm: \(failedDisarm) (disarmed: \(disarmed))",
                    isError: true
                )
            }
            return toolTextResult(.success(
                "{\"armed\":\(index),\"armedSuccess\":true,\"disarmed\":\(disarmed),\"failedDisarm\":[],\"detail\":\"\(detail)\"}"
            ))

        case "set_color":
            return toolTextResult("set_color is not exposed in the production MCP contract", isError: true)

        case "set_automation":
            guard let index = intParamOrNil(params, "index", "track"), index >= 0 else {
                return toolTextResult("set_automation requires explicit 'index' (Int ≥ 0)", isError: true)
            }
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
            guard let index = intParamOrNil(params, "index"), index >= 0 else {
                return toolTextResult("set_instrument requires explicit 'index' (Int ≥ 0)", isError: true)
            }
            let category = stringParam(params, "category")
            let preset = stringParam(params, "preset")
            let path = stringParam(params, "path")
            guard !path.isEmpty || (!category.isEmpty && !preset.isEmpty) else {
                return toolTextResult(
                    "set_instrument requires 'path' or both 'category' + 'preset'",
                    isError: true
                )
            }
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
            // v3.0.7: forward `mode` param (ax|disk|both) to the scan handler.
            // Previously dropped on the floor — v3.0.6 mode routing was dead.
            var scanParams: [String: String] = [:]
            let mode = stringParam(params, "mode")
            if !mode.isEmpty {
                scanParams["mode"] = mode
            }
            let result = await router.route(
                operation: "library.scan_all",
                params: scanParams
            )
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

    // MARK: - record_sequence SMF-import implementation

    /// Generate a Standard MIDI File from the notes spec, write to /tmp/LogicProMCP/,
    /// then import into the current project via AX menu navigation. Logic always
    /// creates a NEW MIDI track for the imported content (verified OQ-3).
    static func handleRecordSequenceSMF(
        params: [String: MCP.Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        guard await cache.getHasDocument() else {
            return toolTextResult("record_sequence: No project open", isError: true)
        }
        let bar = intParam(params, "bar", default: 1)
        let notes = stringParam(params, "notes")
        guard !notes.isEmpty else {
            return toolTextResult(
                "record_sequence requires 'notes' (semicolon-separated 'pitch,offsetMs,durMs[,vel[,ch]]')",
                isError: true
            )
        }

        let project = await cache.getProject()
        let cacheTempo = project.tempo > 0 ? project.tempo : 120.0
        let tempo = doubleParam(params, "tempo", default: cacheTempo)
        let events = parseNotesToSMFEvents(notes: notes, tempo: tempo)
        guard !events.isEmpty else {
            return toolTextResult(
                "record_sequence: could not parse any valid notes from '\(notes)'",
                isError: true
            )
        }

        let tempDir = "/tmp/LogicProMCP"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let path = "\(tempDir)/\(UUID().uuidString).mid"
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }

        // Logic's MIDI File import strips leading empty delta before the first
        // channel event (region gets placed at bar 1 regardless of SMF offset).
        // SMFWriter counters this by emitting a padding CC#110 @ tick 0 when
        // bar > 1, so the first note lands at the requested bar inside a
        // region that spans bar 1 → bar+length. The region is cosmetically
        // longer than the notes, but note timing is exact with zero drift.
        do {
            let data = try SMFWriter.generate(
                events: events,
                bar: bar,
                tempo: tempo,
                timeSignature: (4, 4)
            )
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return toolTextResult("record_sequence: SMF generation failed: \(error)", isError: true)
        }

        // Logic Pro's MIDI File Import anchors the imported region to the
        // CURRENT playhead position. SMF Strategy D encodes the bar offset
        // inside the file (relative to tick 0), so the playhead must be at
        // bar 1 before import — otherwise notes land at playhead + offset,
        // not at the requested bar. A silent failure here would produce a
        // success response with content at the wrong position, so the goto
        // is a hard precondition: hasDocument is already true (guarded
        // above), so the goto-dialog is enabled on any non-empty project,
        // and on an empty project the playhead is already at bar 1 and the
        // slider fallback succeeds trivially.
        let gotoResult = await router.route(
            operation: "transport.goto_position",
            params: ["bar": "1"]
        )
        guard gotoResult.isSuccess else {
            return toolTextResult(
                "record_sequence failed to reset playhead to bar 1 (required for accurate import): \(gotoResult.message)",
                isError: true
            )
        }

        let tracksBefore = await cache.getTracks().count
        let importResult = await router.route(
            operation: "midi.import_file",
            params: ["path": path]
        )
        guard importResult.isSuccess else {
            return toolTextResult(
                "record_sequence failed at midi.import_file: \(importResult.message)",
                isError: true
            )
        }

        // Poll for the new track to appear (AX cache lag averages ~300-400ms;
        // we wait up to 2s with 100ms granularity so slower machines still
        // succeed while fast imports return quickly). If the cache never sees
        // the new track within the window, treat this as a verification
        // failure — the import may have silently misbehaved, and returning
        // success with a fabricated track index would lie to the caller.
        var tracksAfter = tracksBefore
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            tracksAfter = await cache.getTracks().count
            if tracksAfter > tracksBefore { break }
        }
        guard tracksAfter > tracksBefore else {
            return toolTextResult(
                "record_sequence: new track never appeared in Logic (tracks before: \(tracksBefore), after: \(tracksAfter) over 2s). Import may have failed silently; check Logic Pro UI and retry.",
                isError: true
            )
        }

        let createdTrack = tracksAfter - 1

        // v3.0.2: Auto-load a Software Instrument on the imported track so the
        // region is audible on playback. SMF import sometimes leaves the new
        // track without a software-instrument plugin (shows up as silent MIDI),
        // which defeats the whole "generate music then play it" workflow. The
        // caller can override the preset via `instrument_path` — otherwise we
        // default to `Synthesizer/Bass`, a safe audible built-in.
        let instrumentPath = stringParam(params, "instrument_path", "instrument",
                                         default: "Synthesizer/Bass")
        let selectResult = await router.route(
            operation: "track.select",
            params: ["index": "\(createdTrack)"]
        )
        var instrumentStatus = "skipped"
        if selectResult.isSuccess {
            let setResult = await router.route(
                operation: "track.set_instrument",
                params: ["index": "\(createdTrack)", "path": instrumentPath]
            )
            instrumentStatus = setResult.isSuccess ? "loaded:\(instrumentPath)" : "failed:\(setResult.message)"
        }

        return toolTextResult(.success(
            "{\"recorded_to_track\":\(createdTrack),\"created_track\":\(createdTrack),\"bar\":\(bar),\"note_count\":\(events.count),\"method\":\"smf_import\",\"instrument\":\"\(instrumentStatus)\"}"
        ))
    }

    private static func parseNotesToSMFEvents(notes: String, tempo: Double) -> [SMFWriter.NoteEvent] {
        NoteSequenceParser.parse(notes).map { note in
            let ticks = SMFWriter.msToTicks(
                offsetMs: note.offsetMs,
                durationMs: note.durationMs,
                tempo: tempo
            )
            return SMFWriter.NoteEvent(
                pitch: note.pitch,
                offsetTicks: ticks.offsetTicks,
                durationTicks: ticks.durationTicks,
                velocity: note.velocity,
                channel: note.channel
            )
        }
    }
}
