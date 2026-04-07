import Foundation

struct KeyCmdTransportReadiness: Sendable {
    let available: Bool
    let detail: String
}

/// Protocol for Key Commands MIDI transport — send-only.
protocol KeyCmdTransportProtocol: Actor {
    func prepare() async throws
    func send(_ bytes: [UInt8]) async throws
    func readiness() async -> KeyCmdTransportReadiness
}

/// MIDI Key Commands channel: triggers Logic Pro key commands via MIDI CC on Channel 16.
/// Each operation maps to a specific CC# (§4.11 mapping table).
actor MIDIKeyCommandsChannel: Channel {
    nonisolated let id = ChannelID.midiKeyCommands

    private let transport: any KeyCmdTransportProtocol
    private let approvalStore: any ManualValidationStoring
    private static let midiChannel: UInt8 = 15 // 0-indexed, = channel 16

    init(
        transport: any KeyCmdTransportProtocol,
        approvalStore: any ManualValidationStoring = ManualValidationStore()
    ) {
        self.transport = transport
        self.approvalStore = approvalStore
    }

    /// Operation → CC# mapping table (PRD §4.11).
    /// MIDI Channel 16, CC 20-99.
    static let mappingTable: [String: UInt8] = [
        // Track creation (CC 20-25)
        "track.create_audio":           20,
        "track.create_instrument":      21,
        "track.create_external_midi":   22,
        "track.duplicate":              23,
        "track.delete":                 24,
        "track.create_stack":           25,

        // Editing (CC 30-37)
        "edit.undo":                    30,
        "edit.redo":                    31,
        "edit.cut":                     32,
        "edit.copy":                    33,
        "edit.paste":                   34,
        "edit.select_all":              35,
        "edit.trim_at_playhead":        36,
        "edit.bounce_in_place":         37,

        // Piano roll / MIDI editing (CC 40-44)
        "edit.quantize":                40,
        "edit.force_legato":            41,
        "edit.remove_overlaps":         42,
        "edit.join":                    43,
        "edit.toggle_step_input":       44,

        // View toggles (CC 50-58)
        "view.toggle_mixer":            50,
        "view.toggle_piano_roll":       51,
        "view.toggle_score":            52,
        "view.toggle_list_editors":     53,
        "view.toggle_smart_controls":   54,
        "view.toggle_library":          55,
        "view.toggle_inspector":        56,
        "view.toggle_automation":       57,
        "view.toggle_plugin_windows":   58,

        // Project (CC 60-63)
        "project.save":                 60,
        "project.save_as":              61,
        "project.bounce":               62,
        "project.export_midi":          63,

        // Transport extras (CC 70-73)
        "transport.set_tempo":          70,
        "transport.toggle_click":       71,
        "transport.toggle_cycle":       72,
        "transport.capture_recording":  73,

        // Automation (CC 80-83)
        "automation.off":               80,
        "automation.read":              81,
        "automation.touch":             82,
        "automation.latch":             83,

        // Note manipulation (CC 90-93)
        "note.up_semitone":             90,
        "note.down_semitone":           91,
        "note.up_octave":              92,
        "note.down_octave":            93,

        // Additional mappings (CC 94-99) — router-keycmd gap fill
        "edit.delete":                  94,
        "edit.split":                   95,
        "edit.normalize":               96,
        "edit.duplicate":               97,
        "transport.toggle_metronome":   98,
        "transport.toggle_count_in":    99,

        // Navigation (reusing CC range with CH16 — no conflict)
        "nav.goto_marker":              38,
        "nav.create_marker":            39,
        "nav.delete_marker":            45,
        "nav.zoom_to_fit":              46,
        "nav.set_zoom_level":           47,

        // Track/View/Automation extras
        "track.create_drummer":         26,
        "view.toggle_score_editor":     59,
        "view.toggle_step_editor":      48,
        "automation.set_mode":          84,
        "automation.toggle_view":       85,
    ]

    func start() async throws {
        try await transport.prepare()
        let readiness = await transport.readiness()
        Log.info(
            "MIDIKeyCommands channel started (\(Self.mappingTable.count) commands mapped) — \(readiness.detail)",
            subsystem: "keycmd"
        )
    }

    func stop() async {
        Log.info("MIDIKeyCommands channel stopped", subsystem: "keycmd")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard let cc = Self.mappingTable[operation] else {
            return .error("No MIDI Key Command mapping for: \(operation)")
        }

        // CC message on channel 16: 0xBF = CC status on ch15 (zero-indexed)
        let bytes: [UInt8] = [0xB0 | Self.midiChannel, cc, 0x7F]
        let releaseBytes: [UInt8] = [0xB0 | Self.midiChannel, cc, 0x00]

        do {
            try await transport.send(bytes)
            // Send CC value 0 to "release" (some Logic Pro commands need note-off style)
            try await transport.send(releaseBytes)
        } catch {
            return .error("Failed to send key command for \(operation): \(error)")
        }

        return .success("Key command triggered: \(operation) (CC \(cc) CH 16)")
    }

    func healthCheck() async -> ChannelHealth {
        let readiness = await transport.readiness()
        guard readiness.available else {
            return .unavailable(readiness.detail)
        }
        if await approvalStore.isApproved(.midiKeyCommands) {
            return .healthy(
                detail: "\(readiness.detail). Logic Key Commands preset approved by operator",
                verificationStatus: .runtimeReady
            )
        }
        return .healthy(
            detail: "\(readiness.detail). Logic Key Commands preset installation is not verifiable programmatically. Run `LogicProMCP --approve-channel MIDIKeyCommands` after manual validation",
            verificationStatus: .manualValidationRequired
        )
    }
}
