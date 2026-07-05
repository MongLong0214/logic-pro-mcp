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
actor MIDIKeyCommandsChannel: KeyCmdCCChannel {
    nonisolated let id = ChannelID.midiKeyCommands

    let transport: any KeyCmdTransportProtocol
    let approvalStore: any ManualValidationStoring

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
        "edit.bounce_in_place":         37,

        // Piano roll / MIDI editing (CC 40-44)
        "edit.quantize":                40,
        "edit.join":                    43,
        "edit.toggle_step_input":       44,

        // View toggles (CC 50-58)
        "view.toggle_mixer":            50,
        "view.toggle_piano_roll":       51,
        "view.toggle_smart_controls":   54,
        "view.toggle_library":          55,
        "view.toggle_inspector":        56,
        "view.toggle_automation":       57,
        "view.toggle_plugin_windows":   58,

        // Project (CC 60-63)
        "project.save":                 60,
        "project.save_as":              61,
        "project.bounce":               62,

        // Transport extras (CC 70-73)
        //
        // NOTE: "transport.set_tempo" is intentionally NOT mapped here. Logic's
        // CC-based key-command fallback cannot convey the tempo value, so firing
        // CC 70 would silently do nothing useful (Logic just triggers whatever
        // the user bound to CC 70, ignoring the BPM parameter). set_tempo must
        // go through the Accessibility channel which writes the actual value.
        "transport.toggle_cycle":       72,
        "transport.capture_recording":  73,

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
        let readiness = try await prepareTransportForStart()
        Log.info(
            "MIDIKeyCommands channel started (\(Self.mappingTable.count) commands mapped) — \(readiness.detail)",
            subsystem: "keycmd"
        )
    }

    func stop() async {
        Log.info("MIDIKeyCommands channel stopped", subsystem: "keycmd")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        // T6 (PRD Issue#1 §4.3 / AC-1.1) — direct MIDI send path for the
        // 7 "midi.*.keycmd" ops. These bypass the CC mapping table and
        // push raw MIDI bytes through the KeyCmd virtual transport. The
        // KeyCmd port is send-only with no echo, so every success is
        // encoded as Honest Contract State B `readback_unavailable`.
        if operation.hasSuffix(".keycmd"), operation.hasPrefix("midi.") {
            return await executeDirectSend(operation: operation, params: params)
        }

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

        // v3.1.1 (P2-3) — wrap success in a Honest Contract State B envelope
        // so the wire format matches AX / MCU / AppleScript channels. MIDI
        // Key Commands fire CCs blindly into Logic; we can't read back what
        // (if anything) Logic actually did with them, so all successes are
        // `verified:false / readback_unavailable`. Free-text legacy form is
        // preserved inside the `raw` field for diagnostic continuity.
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: [
                "operation": operation,
                "method": "midi_key_command",
                "cc": Int(cc),
                "channel": 16,
                "raw": "Key command triggered: \(operation) (CC \(cc) CH 16)"
            ]
        ))
    }

    // MARK: - T6 direct-send path

    /// Routes the 7 `midi.*.keycmd` ops to wire-byte construction + raw
    /// transport.send. Channel param arriving here is already a wire byte
    /// (0..15); the dispatcher (T5) handles the 1-based → 0-based shift.
    /// All successes return Honest Contract State B `readback_unavailable`
    /// because the KeyCmd port gives no echo back from Logic.
    private func executeDirectSend(
        operation: String,
        params: [String: String]
    ) async -> ChannelResult {
        switch operation {
        case "midi.send_cc.keycmd":
            return await sendCCDirect(params: params)
        case "midi.send_note.keycmd":
            return await sendNoteDirect(params: params)
        case "midi.send_chord.keycmd":
            return await sendChordDirect(params: params)
        case "midi.send_program_change.keycmd":
            return await sendProgramChangeDirect(params: params)
        case "midi.send_pitch_bend.keycmd":
            return await sendPitchBendDirect(params: params)
        case "midi.send_aftertouch.keycmd":
            return await sendAftertouchDirect(params: params)
        case "midi.play_sequence.keycmd":
            return await playSequenceDirect(params: params)
        default:
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "Unknown midi.*.keycmd operation: \(operation)",
                extras: ["operation": operation]
            ))
        }
    }

    // MARK: Wire-byte builders

    /// Build a 3-byte CC message: status (0xB0|ch), controller, value.
    private func buildCCBytes(channel: UInt8, controller: UInt8, value: UInt8) -> [UInt8] {
        [0xB0 | (channel & 0x0F), controller, value]
    }

    /// Build a 3-byte Note On: status (0x90|ch), note, velocity.
    private func buildNoteOnBytes(channel: UInt8, note: UInt8, velocity: UInt8) -> [UInt8] {
        [0x90 | (channel & 0x0F), note, velocity]
    }

    /// Build a 3-byte Note Off: status (0x80|ch), note, vel=0.
    private func buildNoteOffBytes(channel: UInt8, note: UInt8) -> [UInt8] {
        [0x80 | (channel & 0x0F), note, 0]
    }

    // MARK: Send helpers

    /// Shared State C envelope for a KeyCmd transport send failure. Every
    /// direct-send op emits the byte-identical `ax_write_failed` code + hint,
    /// so the pinned string lives here once.
    private func failSend(operation: String, error: any Error) -> ChannelResult {
        .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "KeyCmd transport send failed: \(error)",
            extras: ["operation": operation]
        ))
    }

    /// Run a transport send, returning `nil` on success or a `failSend`
    /// envelope on throw. Collapses the repeated do/catch around a single send
    /// into a `guard`.
    private func runValidated(
        operation: String,
        _ body: () async throws -> Void
    ) async -> ChannelResult? {
        do {
            try await body()
            return nil
        } catch {
            return failSend(operation: operation, error: error)
        }
    }

    // MARK: Per-op handlers

    private func sendCCDirect(params: [String: String]) async -> ChannelResult {
        guard let controller = params["controller"].flatMap(UInt8.init), controller <= 127,
              let value = params["value"].flatMap(UInt8.init), value <= 127,
              let channel = params["channel"].flatMap(UInt8.init), channel <= 15 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "send_cc.keycmd requires controller (0-127), value (0-127), channel (0-15 wire byte)",
                extras: ["operation": "midi.send_cc.keycmd"]
            ))
        }
        let bytes = buildCCBytes(channel: channel, controller: controller, value: value)
        if let failure = await runValidated(operation: "midi.send_cc.keycmd", { try await transport.send(bytes) }) {
            return failure
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
            "operation": "midi.send_cc.keycmd",
            "via": "midi-keycmd-direct-send",
            "controller": Int(controller),
            "value": Int(value),
            "channel_wire": Int(channel),
        ]))
    }

    private func sendNoteDirect(params: [String: String]) async -> ChannelResult {
        guard let note = params["note"].flatMap(UInt8.init), note <= 127,
              let velocity = params["velocity"].flatMap(UInt8.init), velocity <= 127,
              let channel = params["channel"].flatMap(UInt8.init), channel <= 15 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "send_note.keycmd requires note (0-127), velocity (0-127), channel (0-15 wire byte)",
                extras: ["operation": "midi.send_note.keycmd"]
            ))
        }
        // duration_ms is capped at 30s to match CoreMIDIChannel send_note.
        let durationMs = min(params["duration_ms"].flatMap(UInt64.init) ?? 250, 30_000)
        if let failure = await runValidated(operation: "midi.send_note.keycmd", {
            try await transport.send(buildNoteOnBytes(channel: channel, note: note, velocity: velocity))
        }) {
            return failure
        }
        try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
        do {
            try await transport.send(buildNoteOffBytes(channel: channel, note: note))
        } catch {
            // The note-on already sounded; best-effort a second note-off before
            // surfacing the failure so a transient KeyCmd transport error still
            // attempts to silence the note (mirrors the CoreMIDI send_note path).
            // State C stays truthful — the reliable note-off could not be confirmed.
            try? await transport.send(buildNoteOffBytes(channel: channel, note: note))
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "KeyCmd transport note-off send failed after note-on: \(error)",
                extras: [
                    "operation": "midi.send_note.keycmd",
                    "note_off_failed": true,
                    "note_on_sent": true,
                ]
            ))
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
            "operation": "midi.send_note.keycmd",
            "via": "midi-keycmd-direct-send",
            "note": Int(note),
            "velocity": Int(velocity),
            "channel_wire": Int(channel),
            "duration_ms": Int(durationMs),
        ]))
    }

    private func sendChordDirect(params: [String: String]) async -> ChannelResult {
        let notesStr = params["notes"] ?? ""
        let parsed = notesStr
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parsed.isEmpty, parsed.count <= 24, parsed.allSatisfy({ (0...127).contains($0) }) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "send_chord.keycmd 'notes' must be 1..24 ints in 0..127 (CSV)",
                extras: ["operation": "midi.send_chord.keycmd"]
            ))
        }
        guard let velocity = params["velocity"].flatMap(UInt8.init), velocity <= 127,
              let channel = params["channel"].flatMap(UInt8.init), channel <= 15 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "send_chord.keycmd requires velocity (0-127) and channel (0-15 wire byte)",
                extras: ["operation": "midi.send_chord.keycmd"]
            ))
        }
        let durationMs = min(params["duration_ms"].flatMap(UInt64.init) ?? 500, 30_000)
        let notes = parsed.map { UInt8($0) }
        if let failure = await runValidated(operation: "midi.send_chord.keycmd", {
            for n in notes {
                try await transport.send(buildNoteOnBytes(channel: channel, note: n, velocity: velocity))
            }
        }) {
            return failure
        }
        try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
        if let failure = await sendKeyCmdNoteOffs(notes, channel: channel) {
            // Best-effort re-send of every note-off before surfacing the failure
            // so a transient transport error still attempts to silence the chord
            // (mirrors the CoreMIDI send_chord path). State C stays truthful.
            for n in notes {
                try? await transport.send(buildNoteOffBytes(channel: channel, note: n))
            }
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "KeyCmd transport note-off send failed after chord note-ons: \(failure.firstError)",
                extras: [
                    "operation": "midi.send_chord.keycmd",
                    "note_off_failed": true,
                    "failed_note_off_count": failure.count,
                    "note_on_count": notes.count,
                ]
            ))
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
            "operation": "midi.send_chord.keycmd",
            "via": "midi-keycmd-direct-send",
            "note_count": notes.count,
            "channel_wire": Int(channel),
            "duration_ms": Int(durationMs),
        ]))
    }

    private func sendProgramChangeDirect(params: [String: String]) async -> ChannelResult {
        guard let program = params["program"].flatMap(UInt8.init), program <= 127,
              let channel = params["channel"].flatMap(UInt8.init), channel <= 15 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "send_program_change.keycmd requires program (0-127) and channel (0-15 wire byte)",
                extras: ["operation": "midi.send_program_change.keycmd"]
            ))
        }
        // Program Change is 2 bytes: status (0xC0|ch), program.
        let bytes: [UInt8] = [0xC0 | (channel & 0x0F), program]
        if let failure = await runValidated(operation: "midi.send_program_change.keycmd", { try await transport.send(bytes) }) {
            return failure
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
            "operation": "midi.send_program_change.keycmd",
            "via": "midi-keycmd-direct-send",
            "program": Int(program),
            "channel_wire": Int(channel),
        ]))
    }

    private func sendPitchBendDirect(params: [String: String]) async -> ChannelResult {
        // PRD §4.3: value is 0..16383 absolute (center=8192), wire-encoded as
        // LSB(value & 0x7F) + MSB(value >> 7).
        guard let raw = params["value"].flatMap(Int.init), (0...16383).contains(raw),
              let channel = params["channel"].flatMap(UInt8.init), channel <= 15 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "send_pitch_bend.keycmd requires value (0..16383, center=8192) and channel (0-15 wire byte)",
                extras: ["operation": "midi.send_pitch_bend.keycmd"]
            ))
        }
        let lsb = UInt8(raw & 0x7F)
        let msb = UInt8((raw >> 7) & 0x7F)
        let bytes: [UInt8] = [0xE0 | (channel & 0x0F), lsb, msb]
        if let failure = await runValidated(operation: "midi.send_pitch_bend.keycmd", { try await transport.send(bytes) }) {
            return failure
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
            "operation": "midi.send_pitch_bend.keycmd",
            "via": "midi-keycmd-direct-send",
            "value": raw,
            "channel_wire": Int(channel),
        ]))
    }

    private func sendAftertouchDirect(params: [String: String]) async -> ChannelResult {
        // Channel pressure (not poly aftertouch): 2-byte 0xD0|ch, pressure.
        guard let pressure = (params["value"] ?? params["pressure"]).flatMap(UInt8.init),
              pressure <= 127,
              let channel = params["channel"].flatMap(UInt8.init), channel <= 15 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "send_aftertouch.keycmd requires value (0-127) and channel (0-15 wire byte)",
                extras: ["operation": "midi.send_aftertouch.keycmd"]
            ))
        }
        let bytes: [UInt8] = [0xD0 | (channel & 0x0F), pressure]
        if let failure = await runValidated(operation: "midi.send_aftertouch.keycmd", { try await transport.send(bytes) }) {
            return failure
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
            "operation": "midi.send_aftertouch.keycmd",
            "via": "midi-keycmd-direct-send",
            "value": Int(pressure),
            "channel_wire": Int(channel),
        ]))
    }

    private func playSequenceDirect(params: [String: String]) async -> ChannelResult {
        // T3 Result API — strict whole-parse-fail. Any malformed segment
        // surfaces as State C invalid_params (no notes sent), so the agent
        // gets a precise diagnostic instead of a partial dispatch.
        let notesStr = params["notes"] ?? ""
        guard !notesStr.isEmpty else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "play_sequence.keycmd 'notes' must be 'pitch,offsetMs,durMs[,vel[,ch]];...'",
                extras: ["operation": "midi.play_sequence.keycmd"]
            ))
        }
        let events: [NoteSequenceParser.ParsedNote]
        switch NoteSequenceParser.parse(notesStr) {
        case .success(let parsed):
            events = parsed
        case .failure(let err):
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "play_sequence.keycmd: \(err.hint)",
                extras: ["operation": "midi.play_sequence.keycmd"]
            ))
        }
        guard !events.isEmpty else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "play_sequence.keycmd 'notes' parsed empty",
                extras: ["operation": "midi.play_sequence.keycmd"]
            ))
        }
        guard events.count <= 256 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "play_sequence.keycmd 'notes' count must be ≤ 256 (got \(events.count))",
                extras: ["operation": "midi.play_sequence.keycmd"]
            ))
        }
        if let violation = NoteSequenceParser.realtimeTimingViolation(in: events) {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "play_sequence.keycmd: \(violation)",
                extras: ["operation": "midi.play_sequence.keycmd"]
            ))
        }

        // Tight-rhythm scheduler — same shape as CoreMIDIChannel.play_sequence.
        // Note Off tasks are retained and awaited so send failures are visible
        // to the caller instead of being dropped in detached `try?` work.
        let startNs = DispatchTime.now().uptimeNanoseconds
        let transport = self.transport
        var noteOffTasks: [Task<Void, Error>] = []
        for event in events {
            let targetNs = startNs + UInt64(event.offsetMs) * 1_000_000
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if targetNs > nowNs {
                try? await Task.sleep(nanoseconds: targetNs - nowNs)
            }
            let onBytes = buildNoteOnBytes(channel: event.channel, note: event.pitch, velocity: event.velocity)
            do {
                try await transport.send(onBytes)
            } catch {
                await drainKeyCmdNoteOffTasks(noteOffTasks)
                return failSend(operation: "midi.play_sequence.keycmd", error: error)
            }
            let pitch = event.pitch
            let ch = event.channel
            let durNs = UInt64(event.durationMs) * 1_000_000
            let offBytes = buildNoteOffBytes(channel: ch, note: pitch)
            noteOffTasks.append(Task {
                try await Task.sleep(nanoseconds: durNs)
                try await transport.send(offBytes)
            })
        }
        if let lastEnd = events.map({ $0.offsetMs + $0.durationMs }).max() {
            let endTargetNs = startNs + UInt64(lastEnd) * 1_000_000
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if endTargetNs > nowNs {
                try? await Task.sleep(nanoseconds: endTargetNs - nowNs)
            }
        }
        if let failure = await waitForKeyCmdNoteOffTasks(noteOffTasks) {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "KeyCmd transport note-off send failed after sequence note-ons: \(failure.firstError)",
                extras: [
                    "operation": "midi.play_sequence.keycmd",
                    "note_off_failed": true,
                    "failed_note_off_count": failure.count,
                    "note_on_count": events.count,
                ]
            ))
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
            "operation": "midi.play_sequence.keycmd",
            "via": "midi-keycmd-direct-send",
            "note_count": events.count,
        ]))
    }

    func healthCheck() async -> ChannelHealth {
        // Honest health detail: virtual port status, manual MIDI Learn
        // requirement, audited coverage matrix pointer, effectively keycmd-only
        // ops, and orphan ops in mappingTable. Total length must stay < 1 KB.
        await manualValidationHealth(
            approval: .midiKeyCommands,
            approvedDetail: { "\($0.detail). Logic Key Commands preset approved by operator" },
            unapprovedDetail: { "Port: LogicProMCP-KeyCmd-Internal — \($0.detail). \(Self.manualValidationDetailSuffix)" }
        )
    }

    /// Internal (not private) so `RoutingAuditInvariantTests` can assert it
    /// enumerates the same op set as `expectedKeycmdOnlyOps` — the runtime
    /// health string and the docs SETUP.md §4.1 matrix must agree.
    static let manualValidationDetailSuffix =
        "Manual MIDI Learn required — see docs/SETUP.md §4. " +
        "Effectively keycmd-only (no working non-keycmd fallback on Logic 12.2): " +
        "edit.duplicate, edit.normalize, edit.toggle_step_input, " +
        "nav.goto_marker, nav.delete_marker, " +
        "project.bounce, transport.capture_recording. " +
        "Other preset ops have an AX/MCU/AppleScript/CGEvent fallback and do not require keycmd binding. " +
        "Orphans (in mappingTable + routingTable but no MCP tool exposes a call path): " +
        "automation.set_mode, note.up_semitone, note.up_octave, note.down_semitone, note.down_octave, " +
            "view.toggle_smart_controls, view.toggle_plugin_windows, view.toggle_automation (CC 57; distinct from automation.toggle_view CC 85), " +
            "track.create_stack. Tracked in NG6 follow-up."

    private struct KeyCmdNoteOffFailure {
        let count: Int
        let firstError: any Error
    }

    private func sendKeyCmdNoteOffs(
        _ notes: [UInt8],
        channel: UInt8
    ) async -> KeyCmdNoteOffFailure? {
        var failureCount = 0
        var firstError: (any Error)?
        for note in notes {
            do {
                try await transport.send(buildNoteOffBytes(channel: channel, note: note))
            } catch {
                failureCount += 1
                if firstError == nil {
                    firstError = error
                }
            }
        }
        guard let firstError else { return nil }
        return KeyCmdNoteOffFailure(count: failureCount, firstError: firstError)
    }

    private func waitForKeyCmdNoteOffTasks(
        _ tasks: [Task<Void, Error>]
    ) async -> KeyCmdNoteOffFailure? {
        var failureCount = 0
        var firstError: (any Error)?
        for task in tasks {
            do {
                try await task.value
            } catch {
                failureCount += 1
                if firstError == nil {
                    firstError = error
                }
            }
        }
        guard let firstError else { return nil }
        return KeyCmdNoteOffFailure(count: failureCount, firstError: firstError)
    }

    private func drainKeyCmdNoteOffTasks(_ tasks: [Task<Void, Error>]) async {
        for task in tasks {
            _ = await task.result
        }
    }
}
