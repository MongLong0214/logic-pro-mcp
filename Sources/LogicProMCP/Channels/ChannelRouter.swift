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
        "transport.toggle_cycle",
        "transport.toggle_metronome",
        "transport.toggle_count_in",
    ]

    /// V2 routing table: MCU primary for mixer/transport/track state, MIDIKeyCommands for editing.
    /// PRD §4.3 + §4.3.1 contract changes.
    static let v2RoutingTable: [String: [ChannelID]] = [
        // Transport — AX control-bar click primary (works without MCU / MIDI Learn),
        // MCU / CoreMIDI / CGEvent / AppleScript as fallbacks.
        "transport.play":             [.accessibility, .mcu, .coreMIDI, .cgEvent],
        "transport.stop":             [.accessibility, .mcu, .coreMIDI, .cgEvent, .appleScript],
        "transport.record":           [.accessibility, .mcu, .coreMIDI, .cgEvent, .appleScript],
        "transport.pause":            [.coreMIDI, .cgEvent],
        "transport.rewind":           [.mcu, .coreMIDI, .cgEvent],
        "transport.fast_forward":     [.mcu, .coreMIDI, .cgEvent],
        "transport.toggle_cycle":     [.accessibility, .midiKeyCommands, .cgEvent, .mcu],
        "transport.toggle_metronome": [.accessibility, .midiKeyCommands, .cgEvent],
        // AX only — MIDIKeyCommands / CGEvent can't convey the tempo value
        // (MCU set_tempo CC fires blindly, no shortcut actually sets value).
        // Router fallback just obscures the real AX error message.
        "transport.set_tempo":        [.accessibility],
        "transport.get_state":        [.accessibility],
        "transport.goto_position":    [.accessibility, .mcu, .coreMIDI, .cgEvent],
        "transport.set_cycle_range":  [.accessibility],
        "transport.toggle_count_in":  [.accessibility, .midiKeyCommands, .cgEvent],
        "transport.capture_recording":[.midiKeyCommands, .cgEvent],

        // Track state reading
        "track.get_tracks":           [.accessibility],
        "track.get_selected":         [.accessibility],

        // Track mutation — MCU for mute/solo/arm/select, KeyCmd for creation
        "track.select":               [.accessibility, .mcu],
        "track.create_audio":         [.accessibility, .midiKeyCommands, .cgEvent],
        "track.create_instrument":    [.accessibility, .midiKeyCommands, .cgEvent],
        "track.create_drummer":       [.accessibility, .midiKeyCommands, .cgEvent],
        "track.create_external_midi": [.accessibility, .midiKeyCommands, .cgEvent],
        // AX first: clicks "Track > 트랙 삭제" menu item directly. CGEvent
        // fallback uses Cmd+Delete which actually deletes regions (not tracks)
        // in Logic 12 — leaving it as last-resort only for environments where
        // the menu path AX query fails.
        "track.delete":               [.accessibility, .midiKeyCommands, .cgEvent],
        "track.rename":               [.accessibility],
        // AX first: reads current checkbox state and only presses when it
        // differs from desired — idempotent. MCU fallback is last-resort because
        // its buttons are press-only (release is ignored by Logic), so
        // `enabled:false` on MCU becomes a silent no-op, and repeated `enabled:true`
        // toggles instead of setting. (Same bug class as track.select.)
        "track.set_mute":             [.accessibility, .mcu, .cgEvent],
        "track.set_solo":             [.accessibility, .mcu, .cgEvent],
        "track.set_arm":              [.accessibility, .mcu, .cgEvent],
        "track.duplicate":            [.midiKeyCommands, .cgEvent],
        "track.set_color":            [.accessibility],
        "track.set_automation":       [.mcu],  // §4.3.1 new command
        "track.create_stack":         [.midiKeyCommands, .cgEvent],
        "track.set_instrument":       [.accessibility],  // Library panel via AX + CGEvent
        "library.list":               [.accessibility],
        "library.scan_all":           [.accessibility],
        "library.resolve_path":       [.accessibility],

        // Mixer — MCU primary, NO fallback (PRD §4.3)
        "mixer.get_state":            [.mcu, .accessibility],
        "mixer.set_volume":           [.mcu],
        "mixer.set_pan":              [.mcu],
        "mixer.set_send":             [.mcu],
        "mixer.set_output":           [.accessibility],
        "mixer.set_input":            [.accessibility],
        "mixer.get_channel_strip":    [.mcu, .accessibility],
        "mixer.set_master_volume":    [.mcu],
        "mixer.set_output_volume":    [.mcu],
        "mixer.get_bus_routing":      [.accessibility],
        "mixer.toggle_eq":            [.mcu, .accessibility],
        "mixer.reset_strip":          [.mcu, .accessibility],
        "mixer.set_plugin_param":     [.scripter],  // public path narrowed to deterministic Scripter flow
        "plugin.insert":              [.accessibility],

        // MIDI — CoreMIDI only
        "midi.send_note":             [.coreMIDI],
        "midi.send_chord":            [.coreMIDI],
        "midi.play_sequence":         [.coreMIDI],
        "midi.send_cc":               [.coreMIDI],
        "midi.send_program_change":   [.coreMIDI],
        "midi.send_pitch_bend":       [.coreMIDI],
        "midi.send_aftertouch":       [.coreMIDI],
        "midi.send_sysex":            [.coreMIDI],
        "midi.list_ports":            [.coreMIDI],
        "midi.get_input_state":       [.coreMIDI],
        "midi.create_virtual_port":   [.coreMIDI],
        "midi.step_input":            [.coreMIDI],  // §4.3.1 new command

        // MIDI keycmd routing (T5 — PRD Issue#1 §4.3 AC-1.4). Each of the 7
        // send-style ops gets a sibling `*.keycmd` entry that pins the route
        // to MIDIKeyCommands. There is intentionally NO fallback chain: the
        // KeyCmd virtual port is the only surface that can deliver these
        // bytes once Logic's KeyCmd preset has been MIDI-Learned. A missing
        // KeyCmd channel surfaces as State C `port_unavailable` (T1) rather
        // than silently falling back to CoreMIDI, which would mask the
        // operator's setup gap. Membership of the keycmd suffix set is
        // mirrored in `bypassReadinessOps` below; the bidirectional
        // invariant is locked by `testRoutingTableInvariantBypassMatchesKeycmdSuffix`.
        "midi.send_cc.keycmd":             [.midiKeyCommands],
        "midi.send_note.keycmd":           [.midiKeyCommands],
        "midi.send_chord.keycmd":          [.midiKeyCommands],
        "midi.send_program_change.keycmd": [.midiKeyCommands],
        "midi.send_pitch_bend.keycmd":     [.midiKeyCommands],
        "midi.send_aftertouch.keycmd":     [.midiKeyCommands],
        "midi.play_sequence.keycmd":       [.midiKeyCommands],

        // MIDI file import — AX menu path only (AppleScript path abandoned:
        // NSWorkspace.open on .mid creates new project instead of importing)
        "midi.import_file":           [.accessibility],

        // MMC
        "mmc.play":                   [.coreMIDI],
        "mmc.stop":                   [.coreMIDI],
        "mmc.record_strobe":          [.coreMIDI],
        "mmc.record_exit":            [.coreMIDI],
        "mmc.locate":                 [.coreMIDI],
        "mmc.pause":                  [.coreMIDI],

        // Navigation — goto_bar is handled by NavigateDispatcher via
        // transport.goto_position (AX bar-slider); no nav.goto_bar route needed.
        //
        // v3.4.0 (H-2 enterprise review): `NavigateDispatcher.goto_marker`
        // no longer routes to `nav.goto_marker` for any caller path —
        // warm-cache hits go via `transport.goto_position` and cold-cache
        // hits return State C `element_not_found`. The legacy CC 38 keycmd
        // (which advances to "next marker" regardless of index) was
        // confusing target-faithful semantics. The routing table entry is
        // preserved so direct callers (live-e2e harness, future
        // dispatchers, or operators sending the operation key manually
        // via the router) still resolve to the keycmd path; from the
        // primary `logic_navigate` tool surface this entry is now dead
        // weight by design.
        "nav.goto_marker":            [.midiKeyCommands, .cgEvent],
        "nav.create_marker":          [.midiKeyCommands, .cgEvent],
        "nav.delete_marker":          [.midiKeyCommands, .cgEvent],
        "nav.rename_marker":          [.accessibility],
        "nav.get_markers":            [.accessibility],
        "nav.zoom_to_fit":            [.midiKeyCommands, .cgEvent],
        "nav.set_zoom_level":         [.midiKeyCommands, .cgEvent],

        // Editing — MIDIKeyCommands primary, CGEvent fallback
        "edit.undo":                  [.midiKeyCommands, .cgEvent],
        "edit.redo":                  [.midiKeyCommands, .cgEvent],
        "edit.cut":                   [.midiKeyCommands, .cgEvent],
        "edit.copy":                  [.midiKeyCommands, .cgEvent],
        "edit.paste":                 [.midiKeyCommands, .cgEvent],
        "edit.delete":                [.midiKeyCommands, .cgEvent],
        "edit.select_all":            [.midiKeyCommands, .cgEvent],
        "edit.split":                 [.midiKeyCommands, .cgEvent],
        "edit.join":                  [.midiKeyCommands, .cgEvent],
        "edit.quantize":              [.midiKeyCommands, .cgEvent],
        "edit.bounce_in_place":       [.midiKeyCommands, .cgEvent],
        "edit.normalize":             [.midiKeyCommands, .cgEvent],
        "edit.toggle_step_input":     [.midiKeyCommands, .cgEvent],  // §4.3.1 new command
        "edit.duplicate":             [.midiKeyCommands, .cgEvent],

        // Project — AppleScript primary for new/open/close lifecycle, KeyCmd for save/bounce
        "project.new":                [.appleScript, .cgEvent],
        "project.open":               [.appleScript],
        "project.save":               [.midiKeyCommands, .cgEvent, .appleScript],
        "project.save_as":            [.accessibility, .appleScript],
        "project.close":              [.appleScript, .cgEvent],
        "project.get_info":           [.accessibility],
        "project.bounce":             [.midiKeyCommands, .cgEvent],
        "project.is_running":         [],
        "project.launch":             [.appleScript],
        "project.quit":               [.appleScript],

        // Views — MIDIKeyCommands primary
        "view.toggle_mixer":          [.midiKeyCommands, .cgEvent],
        "view.toggle_piano_roll":     [.midiKeyCommands, .cgEvent],
        "view.toggle_score_editor":   [.midiKeyCommands, .cgEvent],
        "view.toggle_step_editor":    [.midiKeyCommands, .cgEvent],
        "view.toggle_library":        [.midiKeyCommands, .cgEvent],
        "view.toggle_inspector":      [.midiKeyCommands, .cgEvent],
        "view.toggle_smart_controls": [.midiKeyCommands, .cgEvent],
        "view.toggle_automation":     [.midiKeyCommands, .cgEvent],
        "view.toggle_plugin_windows": [.midiKeyCommands, .cgEvent],

        // Regions
        "region.get_regions":         [.accessibility],
        "region.select":              [.accessibility],
        // Reserved for a future region-editor tool that picks up the freshly
        // imported region and aligns it to the playhead. Currently unused by
        // any dispatcher (record_sequence handles positioning via SMFWriter
        // + transport.goto_position bar=1 before import).
        "region.select_last":         [.accessibility],
        "region.move_to_playhead":    [.accessibility],
        "region.loop":                [.accessibility, .cgEvent],
        "region.set_name":            [.accessibility],
        "region.move":                [.accessibility],
        "region.resize":              [.accessibility],

        // Plugins — bypass/remove intentionally omitted from the routing
        // table: no channel has a deterministic implementation. insert is
        // reintroduced only through an allowlisted AX mixer-slot path.
        "plugin.list":                [.accessibility],
        "plugin.set_param":           [.scripter],  // deterministic plugin parameter path
        "plugin.scan_presets":        [.accessibility],  // F2 — empirical T0 verdict MIXED (CGEvent popup + AXPress menu)

        // Automation
        "automation.get_mode":        [.accessibility],
        "automation.set_mode":        [.mcu, .midiKeyCommands, .cgEvent],
        "automation.toggle_view":     [.midiKeyCommands, .cgEvent],
        "automation.get_parameter":   [.accessibility],

        // Note manipulation
        "note.up_semitone":           [.midiKeyCommands, .cgEvent],
        "note.down_semitone":         [.midiKeyCommands, .cgEvent],
        "note.up_octave":             [.midiKeyCommands, .cgEvent],
        "note.down_octave":           [.midiKeyCommands, .cgEvent],

        // System — no channel needed
        "system.health":              [],
        "system.cache_state":         [],
        "system.refresh":             [],
        "system.permissions":         [],
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

    func stopAll() async {
        for (_, channel) in channels {
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
