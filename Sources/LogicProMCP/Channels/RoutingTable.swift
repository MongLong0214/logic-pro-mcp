import Foundation

// WS2 (enterprise refactor): the V2 routing-table literal, relocated verbatim
// out of ChannelRouter.swift. Same name / type / (internal) visibility — a pure
// move so the wire-facing route map is unchanged (golden-snapshot pinned;
// RoutingAuditInvariantTests + ChannelRouterTests read ChannelRouter.v2RoutingTable).
extension ChannelRouter {
    /// V2 routing table: MCU primary for mixer/transport/track state, MIDIKeyCommands for editing.
    /// PRD §4.3 + §4.3.1 contract changes.
    static let v2RoutingTable: [String: [ChannelID]] = [
        // Transport — AX control-bar click primary (works without MCU / MIDI Learn),
        // MCU / CoreMIDI / CGEvent / AppleScript as fallbacks.
        "transport.play":             [.accessibility, .mcu, .coreMIDI, .cgEvent, .appleScript],
        // Stop differs from Play/Record: in live 12.2 sessions the AX Play
        // checkbox can refuse to clear while playback is active, and MMC /
        // AppleScript "stop" can still leave transport running. The
        // spacebar-equivalent CGEvent path proved to be the first reliable
        // non-AX fallback, so prefer it before MIDI/AppleScript fallbacks and
        // let the dispatcher's live readback gate decide success.
        "transport.stop":             [.cgEvent, .accessibility, .mcu, .coreMIDI, .appleScript],
        "transport.record":           [.accessibility, .mcu, .coreMIDI, .cgEvent, .appleScript],
        // Logic 12.x has no distinct "pause" — the playhead stops in place via
        // the Stop button / spacebar. MMC "pause" (the old primary) is silently
        // ignored by Logic, so a verified pause always failed closed. Mirror the
        // proven transport.stop order: spacebar-equivalent CGEvent first (the
        // first reliable non-AX path, posted to Logic's PID so it is
        // frontmost-independent), the AX Stop button next, MMC last as a
        // best-effort fallback.
        "transport.pause":            [.cgEvent, .accessibility, .coreMIDI],
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

        // Mixer — public volume/pan writes are AX-only so the wire can carry
        // visible-strip identity plus same-surface readback. MCU echo remains
        // useful internally, but it cannot prove the targeted strip when the
        // visible mixer path is unavailable.
        "mixer.get_state":            [.mcu, .accessibility],
        "mixer.set_volume":           [.accessibility],
        "mixer.set_pan":              [.accessibility],
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

        // Verified plugin surface (logic_plugins.*) — T3 / R16. AX-only, NO
        // fallback: a verified op that fell back to Scripter/MCU would fabricate
        // a false verified result and bury the real AX error (same rationale as
        // transport.set_tempo). Every verified-path State C is terminal
        // (HonestContract.terminalErrorCodes), so the router never continues
        // past them.
        "plugin.get_inventory":       [.accessibility],
        "plugin.set_param_verified":  [.accessibility],
        "plugin.insert_verified":     [.accessibility],

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
        // #109: AX-first — the arrange Horizontal-Zoom AXSlider honours AXValue
        // writes (unlike faders/playhead), so set_zoom now lands a verified
        // zoom level instead of an unmappable, unverifiable key command. Keeps
        // the key-command + CGEvent fallbacks for when the slider isn't found.
        "nav.set_zoom_level":         [.accessibility, .midiKeyCommands, .cgEvent],

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
        // #110: AppleScript-first — the direct `save front document` is the
        // reliable writer and lets the channel verify the .logicx package was
        // (re)written on disk (export/bounce prerequisite). KeyCmd/CGEvent
        // remain as fallbacks (e.g. AppleScript automation denied).
        "project.save":               [.appleScript, .midiKeyCommands, .cgEvent],
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
}
