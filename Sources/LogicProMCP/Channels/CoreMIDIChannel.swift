import CoreMIDI
import Foundation

/// Channel that routes operations through CoreMIDI / MMC.
actor CoreMIDIChannel: Channel {
    let id: ChannelID = .coreMIDI
    private let engine: any CoreMIDIEngineProtocol
    private let portManager: (any VirtualPortManaging)?

    init(engine: any CoreMIDIEngineProtocol, portManager: (any VirtualPortManaging)? = nil) {
        self.engine = engine
        self.portManager = portManager
    }

    func start() async throws {
        try await engine.start()
        Log.info("CoreMIDIChannel started", subsystem: "midi")
    }

    func stop() async {
        await engine.stop()
        Log.info("CoreMIDIChannel stopped", subsystem: "midi")
    }

    /// Parse a MIDI-spec-bounded UInt8 from a param string (0-127 inclusive).
    /// Rejects UInt8 128-255 which are valid Swift values but outside MIDI data
    /// byte range; also rejects non-numeric / out-of-range ints.
    private static func midiData7(_ s: String?) -> UInt8? {
        guard let s, let v = Int(s), (0...127).contains(v) else { return nil }
        return UInt8(v)
    }

    /// Parse a MIDI channel.  Accepts 0-15 (wire / zero-indexed) or 1-16
    /// (music convention); the engine masks with 0x0F on send so channel 16
    /// wraps to 0. Anything outside 0-16 is rejected as clearly out of range.
    private static func midiChannel(_ s: String?) -> UInt8? {
        guard let s, let v = Int(s), (0...16).contains(v) else { return nil }
        return UInt8(v)
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        // Guard: refuse work when CoreMIDI client / virtual source not active.
        // Without this, every send returns .success even though no MIDI is
        // actually transmitted (silent failure — see prod-hardening review #5).
        if !(await engine.isActive) {
            return .error("CoreMIDI engine not active (virtual source not published)")
        }
        switch operation {
        // MARK: - Transport (MMC)

        case "transport.play":
            await engine.sendSysEx(MMCCommands.play())
            return .success("MMC play sent")

        case "transport.stop":
            await engine.sendSysEx(MMCCommands.stop())
            return .success("MMC stop sent")

        case "transport.pause":
            await engine.sendSysEx(MMCCommands.pause())
            return .success("MMC pause sent")

        case "transport.record_strobe":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .success("MMC record strobe sent")

        case "transport.record_exit":
            await engine.sendSysEx(MMCCommands.recordExit())
            return .success("MMC record exit sent")

        case "transport.fast_forward":
            await engine.sendSysEx(MMCCommands.fastForward())
            return .success("MMC fast forward sent")

        case "transport.rewind":
            await engine.sendSysEx(MMCCommands.rewind())
            return .success("MMC rewind sent")

        case "transport.locate":
            guard let h = params["hours"].flatMap(UInt8.init),
                  let m = params["minutes"].flatMap(UInt8.init),
                  let s = params["seconds"].flatMap(UInt8.init),
                  let f = params["frames"].flatMap(UInt8.init) else {
                return .error("locate requires hours, minutes, seconds, frames")
            }
            let sf = params["subframes"].flatMap(UInt8.init) ?? 0
            await engine.sendSysEx(MMCCommands.locate(hours: h, minutes: m, seconds: s, frames: f, subframes: sf))
            return .success("MMC locate sent to \(h):\(m):\(s):\(f).\(sf)")

        // MARK: - Note Send

        case "midi.send_note":
            guard let note = Self.midiData7(params["note"]) else {
                return .error("send_note requires 'note' in 0-127")
            }
            let velocity: UInt8
            if let v = params["velocity"] {
                guard let parsed = Self.midiData7(v) else {
                    return .error("send_note 'velocity' must be in 0-127")
                }
                velocity = parsed
            } else { velocity = 100 }
            let channel: UInt8
            if let c = params["channel"] {
                guard let parsed = Self.midiChannel(c) else {
                    return .error("send_note 'channel' must be in 0-16")
                }
                channel = parsed
            } else { channel = 0 }
            let durationMs = min(params["duration_ms"].flatMap(UInt64.init) ?? 250, 30_000)
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
            await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
            return .success("Note \(note) on ch \(channel) vel \(velocity) dur \(durationMs)ms")

        case "midi.note_on":
            guard let note = Self.midiData7(params["note"]) else {
                return .error("note_on requires 'note' in 0-127")
            }
            let velocity: UInt8
            if let v = params["velocity"] {
                guard let parsed = Self.midiData7(v) else {
                    return .error("note_on 'velocity' must be in 0-127")
                }
                velocity = parsed
            } else { velocity = 100 }
            let channel: UInt8
            if let c = params["channel"] {
                guard let parsed = Self.midiChannel(c) else {
                    return .error("note_on 'channel' must be in 0-16")
                }
                channel = parsed
            } else { channel = 0 }
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            return .success("Note on \(note) ch \(channel) vel \(velocity)")

        case "midi.note_off":
            guard let note = Self.midiData7(params["note"]) else {
                return .error("note_off requires 'note' in 0-127")
            }
            let channel: UInt8
            if let c = params["channel"] {
                guard let parsed = Self.midiChannel(c) else {
                    return .error("note_off 'channel' must be in 0-16")
                }
                channel = parsed
            } else { channel = 0 }
            await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
            return .success("Note off \(note) ch \(channel)")

        // MARK: - CC

        case "midi.send_cc":
            guard let controller = Self.midiData7(params["controller"]) else {
                return .error("send_cc requires 'controller' and 'value' — 'controller' must be in 0-127")
            }
            guard let value = Self.midiData7(params["value"]) else {
                return .error("send_cc requires 'controller' and 'value' — 'value' must be in 0-127")
            }
            let channel: UInt8
            if let c = params["channel"] {
                guard let parsed = Self.midiChannel(c) else {
                    return .error("send_cc 'channel' must be in 0-16")
                }
                channel = parsed
            } else { channel = 0 }
            await engine.sendCC(channel: channel, controller: controller, value: value)
            return .success("CC \(controller)=\(value) on ch \(channel)")

        // MARK: - Program Change

        case "midi.program_change", "midi.send_program_change":
            guard let program = Self.midiData7(params["program"]) else {
                return .error("program_change requires 'program' in 0-127")
            }
            let channel: UInt8
            if let c = params["channel"] {
                guard let parsed = Self.midiChannel(c) else {
                    return .error("program_change 'channel' must be in 0-16")
                }
                channel = parsed
            } else { channel = 0 }
            await engine.sendProgramChange(channel: channel, program: program)
            return .success("Program change \(program) on ch \(channel)")

        // MARK: - Pitch Bend

        case "midi.pitch_bend", "midi.send_pitch_bend":
            let value: UInt16?
            if let signed = params["value"].flatMap(Int.init) {
                let normalized = min(max(signed, -8192), 8191) + 8192
                value = UInt16(normalized)
            } else if let raw = params["value"].flatMap(UInt16.init) {
                value = min(raw, 16383)
            } else {
                value = nil
            }
            guard let value else {
                return .error("pitch_bend requires 'value' (0-16383, center=8192)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendPitchBend(channel: channel, value: value)
            return .success("Pitch bend \(value) on ch \(channel)")

        // MARK: - Aftertouch

        case "midi.aftertouch", "midi.send_aftertouch":
            guard let pressure = params["pressure"].flatMap(UInt8.init)
                ?? params["value"].flatMap(UInt8.init) else {
                return .error("aftertouch requires 'pressure' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendAftertouch(channel: channel, pressure: pressure)
            return .success("Aftertouch \(pressure) on ch \(channel)")

        // MARK: - Raw SysEx

        case "midi.send_sysex":
            guard let hexString = params["bytes"] ?? params["data"] else {
                return .error("send_sysex requires 'bytes' (hex string, e.g. 'F0 7F 7F 06 02 F7')")
            }
            // Support space-separated or contiguous hex, with optional 0x prefix / comma separators.
            let normalized = hexString
                .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ",", with: " ")
            let bytes = normalized
                .split(whereSeparator: { $0.isWhitespace })
                .compactMap { UInt8(String($0), radix: 16) }
            // Valid SysEx: F0 <at least 1 data byte> F7, no internal F0/F7.
            // 0xF7 only legal at final position; 0xF0 only legal at start.
            guard bytes.count >= 3, bytes.first == 0xF0, bytes.last == 0xF7 else {
                return .error("SysEx must start with F0 and end with F7 and have at least one data byte (parsed \(bytes.count) bytes from '\(hexString.prefix(60))')")
            }
            let interior = bytes.dropFirst().dropLast()
            if interior.contains(0xF0) || interior.contains(0xF7) {
                return .error("SysEx contains illegal internal 0xF0/0xF7 byte")
            }
            await engine.sendSysEx(bytes)
            return .success("SysEx sent (\(bytes.count) bytes)")

        // Aliases for router operation keys
        case "midi.send_chord":
            // Chord = multiple note-ons. Parse and validate.
            let notesStr = params["notes"] ?? ""
            let parsed = notesStr
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            // MIDI spec: notes 0-127. Reject anything outside.
            guard parsed.allSatisfy({ (0...127).contains($0) }) else {
                return .error("send_chord 'notes' must all be in 0-127")
            }
            // Practical cap: a chord beyond 24 simultaneous notes is almost
            // certainly a bug / flood attempt. 24 fits a 2-hand piano cluster
            // plus tuplet headroom.
            guard parsed.count > 0 && parsed.count <= 24 else {
                return .error("send_chord 'notes' count must be 1..24 (got \(parsed.count))")
            }
            let notes = parsed.map { UInt8($0) }
            let vel: UInt8
            if let v = params["velocity"] {
                guard let parsed = Self.midiData7(v) else {
                    return .error("send_chord 'velocity' must be in 0-127")
                }
                vel = parsed
            } else { vel = 80 }
            let ch: UInt8
            if let c = params["channel"] {
                guard let parsed = Self.midiChannel(c) else {
                    return .error("send_chord 'channel' must be in 0-16")
                }
                ch = parsed
            } else { ch = 0 }
            let durMs = min(params["duration_ms"].flatMap(Int.init) ?? 500, 30_000)
            for n in notes { await engine.sendNoteOn(channel: ch, note: n, velocity: vel) }
            try? await Task.sleep(for: .milliseconds(durMs))
            for n in notes { await engine.sendNoteOff(channel: ch, note: n, velocity: 0) }
            return .success("Chord sent: \(notes.count) notes")

        case "midi.play_sequence":
            // Tight-rhythm sequencer: parse `notes` as semicolon-separated
            // events "note,offsetMs,durationMs[,velocity[,channel]]".  Each
            // event scheduled relative to the first — server-side timing is
            // jittery at ±5 ms but far tighter than round-tripping 20+ MCP
            // send_note calls per bar from a client.
            // Example: "60,0,400;64,500,400;67,1000,400" = C-E-G arpeggio.
            let events = NoteSequenceParser.parse(params["notes"] ?? "")
            guard !events.isEmpty else {
                return .error("play_sequence 'notes' must be 'note,offset,dur[,vel[,ch]];...'")
            }
            guard events.count <= 256 else {
                return .error("play_sequence 'notes' count must be ≤ 256 (got \(events.count))")
            }
            let startNs = DispatchTime.now().uptimeNanoseconds
            for event in events {
                let targetNs = startNs + UInt64(event.offsetMs) * 1_000_000
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if targetNs > nowNs {
                    try? await Task.sleep(nanoseconds: targetNs - nowNs)
                }
                await engine.sendNoteOn(channel: event.channel, note: event.pitch, velocity: event.velocity)
                let pitch = event.pitch
                let ch = event.channel
                let durNs = UInt64(event.durationMs) * 1_000_000
                Task.detached { [engine] in
                    try? await Task.sleep(nanoseconds: durNs)
                    await engine.sendNoteOff(channel: ch, note: pitch, velocity: 0)
                }
            }
            if let lastEnd = events.map({ $0.offsetMs + $0.durationMs }).max() {
                let endTargetNs = startNs + UInt64(lastEnd) * 1_000_000
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if endTargetNs > nowNs {
                    try? await Task.sleep(nanoseconds: endTargetNs - nowNs)
                }
            }
            return .success("Sequence sent: \(events.count) events")

        case "midi.step_input":
            let note = params["note"].flatMap(UInt8.init) ?? 60
            let durationMs = stepInputDurationMs(from: params["duration"] ?? params["duration_ms"])
            let vel: UInt8 = 80
            await engine.sendNoteOn(channel: 0, note: note, velocity: vel)
            try? await Task.sleep(for: .milliseconds(durationMs))
            await engine.sendNoteOff(channel: 0, note: note, velocity: 0)
            return .success("Step input: note \(note), duration \(durationMs)ms")

        case "midi.list_ports":
            return .success(listMIDIPortsJSON())

        case "midi.create_virtual_port":
            guard let portManager else {
                return .error("Dynamic virtual port creation unavailable in this context")
            }
            let name = String((params["name"] ?? "LogicProMCP-Virtual")
                .filter { !$0.isNewline && $0 != "\0" }
                .prefix(63))
            do {
                _ = try await portManager.createSendOnlyPort(name: name)
                return .success("Virtual port '\(name)' ready")
            } catch {
                return .error("Failed to create virtual port '\(name)': \(error)")
            }

        case "midi.get_input_state":
            return .success("{\"active\":true}")

        case "transport.record":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .success("MMC record strobe")

        case "transport.goto_position":
            return .error("CoreMIDI cannot position the playhead directly; use MCU or CGEvent fallback")

        case "mmc.play":
            await engine.sendSysEx(MMCCommands.play())
            return .success("MMC play")

        case "mmc.stop":
            await engine.sendSysEx(MMCCommands.stop())
            return .success("MMC stop")

        case "mmc.record_strobe":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .success("MMC record strobe")

        case "mmc.record_exit":
            await engine.sendSysEx(MMCCommands.recordExit())
            return .success("MMC record exit")

        case "mmc.locate":
            guard
                let time = params["time"],
                let components = parseMMCLocateTime(time)
            else {
                return .error("MMC locate requires time in HH:MM:SS:FF")
            }
            await engine.sendSysEx(
                MMCCommands.locate(
                    hours: components.hours,
                    minutes: components.minutes,
                    seconds: components.seconds,
                    frames: components.frames
                )
            )
            return .success("MMC locate sent to \(time)")

        case "mmc.pause":
            await engine.sendSysEx(MMCCommands.pause())
            return .success("MMC pause")

        default:
            return .error("Unknown CoreMIDI operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        let active = await engine.isActive
        if active {
            return .healthy(detail: "CoreMIDI client active, virtual ports created")
        } else {
            return .unavailable("CoreMIDI client not initialized")
        }
    }

    private func parseMMCLocateTime(_ time: String) -> (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8)? {
        let parts = time.split(separator: ":")
        guard parts.count == 4 else { return nil }
        guard
            let hours = UInt8(parts[0]),
            let minutes = UInt8(parts[1]),
            let seconds = UInt8(parts[2]),
            let frames = UInt8(parts[3])
        else {
            return nil
        }
        return (hours, minutes, seconds, frames)
    }

    private func stepInputDurationMs(from rawDuration: String?) -> Int {
        guard let rawDuration, !rawDuration.isEmpty else { return 250 }
        if let durationMs = Int(rawDuration) {
            return min(max(1, durationMs), 30_000)
        }
        switch rawDuration {
        case "1/1": return 1000
        case "1/2": return 500
        case "1/4": return 250
        case "1/8": return 125
        case "1/16": return 63
        case "1/32": return 32
        default: return 250
        }
    }

    private func listMIDIPortsJSON() -> String {
        struct PortListing: Encodable {
            let sources: [String]
            let destinations: [String]
        }

        let listing = PortListing(
            sources: listEndpointNames(count: MIDIGetNumberOfSources(), getter: MIDIGetSource),
            destinations: listEndpointNames(count: MIDIGetNumberOfDestinations(), getter: MIDIGetDestination)
        )
        return encodeJSON(listing)
    }

    private func listEndpointNames(
        count: Int,
        getter: (Int) -> MIDIEndpointRef
    ) -> [String] {
        (0..<count).map { index in
            endpointName(getter(index))
        }
    }

    private func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var cfName: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cfName) == noErr,
           let name = cfName?.takeRetainedValue() as String? {
            return name
        }
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cfName) == noErr,
           let name = cfName?.takeRetainedValue() as String? {
            return name
        }
        return "Unnamed MIDI Endpoint"
    }
}
