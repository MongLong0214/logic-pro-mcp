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
            return await handleRecordSequenceSMF(params: params, router: router, cache: cache)

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
        // CURRENT playhead position. Strategy D's padding CC encodes the
        // bar offset inside the SMF (relative to tick 0), so we must put
        // the playhead at bar 1 before import — then the caller's notes
        // land at exactly the requested bar inside the region.
        // The dialog-based goto ignores project-length clamping and extends
        // the project as needed. Best-effort: if it fails (empty project,
        // dialog disabled), the playhead is already at bar 1 by default so
        // the fresh-project case still works.
        _ = await router.route(
            operation: "transport.goto_position",
            params: ["bar": "1"]
        )

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

        // 500ms AX settle: track enumeration updates lag import by ~300-400ms empirically.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let tracksAfter = await cache.getTracks().count
        let trackConfirmed = tracksAfter > tracksBefore
        let createdTrack = trackConfirmed ? tracksAfter - 1 : max(-1, tracksBefore - 1)

        return toolTextResult(.success(
            "{\"recorded_to_track\":\(createdTrack),\"created_track\":\(createdTrack),\"track_index_confirmed\":\(trackConfirmed),\"bar\":\(bar),\"note_count\":\(events.count),\"method\":\"smf_import\"}"
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
