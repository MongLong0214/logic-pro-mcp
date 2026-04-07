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

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
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
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("send_note requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            let durationMs = params["duration_ms"].flatMap(UInt64.init) ?? 250
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
            await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
            return .success("Note \(note) on ch \(channel) vel \(velocity) dur \(durationMs)ms")

        case "midi.note_on":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_on requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            return .success("Note on \(note) ch \(channel) vel \(velocity)")

        case "midi.note_off":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_off requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendNoteOff(channel: channel, note: note, velocity: 0)
            return .success("Note off \(note) ch \(channel)")

        // MARK: - CC

        case "midi.send_cc":
            guard let controller = params["controller"].flatMap(UInt8.init),
                  let value = params["value"].flatMap(UInt8.init) else {
                return .error("send_cc requires 'controller' and 'value' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendCC(channel: channel, controller: controller, value: value)
            return .success("CC \(controller)=\(value) on ch \(channel)")

        // MARK: - Program Change

        case "midi.program_change", "midi.send_program_change":
            guard let program = params["program"].flatMap(UInt8.init) else {
                return .error("program_change requires 'program' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
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
            let bytes = hexString.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            guard bytes.first == 0xF0, bytes.last == 0xF7 else {
                return .error("SysEx must start with F0 and end with F7")
            }
            await engine.sendSysEx(bytes)
            return .success("SysEx sent (\(bytes.count) bytes)")

        // Aliases for router operation keys
        case "midi.send_chord":
            // Chord = multiple note-ons. Parse notes array.
            let notesStr = params["notes"] ?? ""
            let notes = notesStr.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            let vel = params["velocity"].flatMap(UInt8.init) ?? 80
            let ch = params["channel"].flatMap(UInt8.init) ?? 0
            let durMs = params["duration_ms"].flatMap(Int.init) ?? 500
            for n in notes { await engine.sendNoteOn(channel: ch, note: n, velocity: vel) }
            try? await Task.sleep(for: .milliseconds(durMs))
            for n in notes { await engine.sendNoteOff(channel: ch, note: n, velocity: 0) }
            return .success("Chord sent: \(notes.count) notes")

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
            let name = params["name"] ?? "LogicProMCP-Virtual"
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
            return max(1, durationMs)
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
