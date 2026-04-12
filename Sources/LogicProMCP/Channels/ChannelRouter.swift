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

    /// V2 routing table: MCU primary for mixer/transport/track state, MIDIKeyCommands for editing.
    /// PRD §4.3 + §4.3.1 contract changes.
    static let v2RoutingTable: [String: [ChannelID]] = [
        // Transport — MCU primary, CoreMIDI + CGEvent fallback
        "transport.play":             [.mcu, .coreMIDI, .cgEvent],
        "transport.stop":             [.mcu, .coreMIDI, .cgEvent, .appleScript],
        "transport.record":           [.mcu, .coreMIDI, .cgEvent, .appleScript],
        "transport.pause":            [.coreMIDI, .cgEvent],
        "transport.rewind":           [.mcu, .coreMIDI, .cgEvent],
        "transport.fast_forward":     [.mcu, .coreMIDI, .cgEvent],
        "transport.toggle_cycle":     [.mcu, .midiKeyCommands, .cgEvent],
        "transport.toggle_metronome": [.midiKeyCommands, .cgEvent],
        "transport.set_tempo":        [.accessibility, .midiKeyCommands, .cgEvent],
        "transport.get_state":        [.accessibility],
        "transport.goto_position":    [.mcu, .coreMIDI, .cgEvent],
        "transport.set_cycle_range":  [.accessibility],
        "transport.toggle_count_in":  [.midiKeyCommands, .cgEvent],
        "transport.capture_recording":[.midiKeyCommands, .cgEvent],

        // Track state reading
        "track.get_tracks":           [.accessibility],
        "track.get_selected":         [.accessibility],

        // Track mutation — MCU for mute/solo/arm/select, KeyCmd for creation
        "track.select":               [.mcu, .accessibility, .cgEvent],
        "track.create_audio":         [.accessibility, .midiKeyCommands, .cgEvent],
        "track.create_instrument":    [.accessibility, .midiKeyCommands, .cgEvent],
        "track.create_drummer":       [.accessibility, .midiKeyCommands, .cgEvent],
        "track.create_external_midi": [.accessibility, .midiKeyCommands, .cgEvent],
        "track.delete":               [.midiKeyCommands, .cgEvent],
        "track.rename":               [.accessibility],
        "track.set_mute":             [.mcu, .accessibility, .cgEvent],
        "track.set_solo":             [.mcu, .accessibility, .cgEvent],
        "track.set_arm":              [.mcu, .accessibility, .cgEvent],
        "track.duplicate":            [.midiKeyCommands, .cgEvent],
        "track.set_color":            [.accessibility],
        "track.set_automation":       [.mcu],  // §4.3.1 new command
        "track.create_stack":         [.midiKeyCommands, .cgEvent],

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

        // MIDI — CoreMIDI only
        "midi.send_note":             [.coreMIDI],
        "midi.send_chord":            [.coreMIDI],
        "midi.send_cc":               [.coreMIDI],
        "midi.send_program_change":   [.coreMIDI],
        "midi.send_pitch_bend":       [.coreMIDI],
        "midi.send_aftertouch":       [.coreMIDI],
        "midi.send_sysex":            [.coreMIDI],
        "midi.list_ports":            [.coreMIDI],
        "midi.get_input_state":       [.coreMIDI],
        "midi.create_virtual_port":   [.coreMIDI],
        "midi.step_input":            [.coreMIDI],  // §4.3.1 new command

        // MMC
        "mmc.play":                   [.coreMIDI],
        "mmc.stop":                   [.coreMIDI],
        "mmc.record_strobe":          [.coreMIDI],
        "mmc.record_exit":            [.coreMIDI],
        "mmc.locate":                 [.coreMIDI],
        "mmc.pause":                  [.coreMIDI],

        // Navigation — MCU jog + KeyCmd views, CGEvent fallback
        "nav.goto_bar":               [.mcu, .cgEvent],
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
        "region.loop":                [.accessibility, .cgEvent],
        "region.set_name":            [.accessibility],
        "region.move":                [.accessibility],
        "region.resize":              [.accessibility],

        // Plugins
        "plugin.list":                [.accessibility],
        "plugin.insert":              [.accessibility],
        "plugin.bypass":              [.mcu, .accessibility],
        "plugin.remove":              [.accessibility],
        "plugin.set_param":           [.scripter],  // deterministic plugin parameter path

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

    /// Active routing table (v2)
    private static let routingTable = v2RoutingTable

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

        for channelID in chain {
            guard let channel = channels[channelID] else {
                Log.debug("Channel \(channelID.rawValue) not registered, skipping", subsystem: "router")
                continue
            }

            let health = await channel.healthCheck()
            guard health.available else {
                Log.debug("Channel \(channelID.rawValue) unhealthy: \(health.detail), trying next", subsystem: "router")
                lastError = "Channel \(channelID.rawValue): \(health.detail)"
                continue
            }
            guard health.ready || ServerConfig.allowManualValidationChannels else {
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
                Log.debug("\(operation) failed via \(channelID.rawValue): \(msg), trying next", subsystem: "router")
                lastError = msg
            }
        }

        return .error("All channels exhausted for \(operation). Last error: \(lastError)")
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
