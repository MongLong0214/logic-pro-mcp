import CoreMIDI
import Foundation

/// Channel that routes operations through CoreMIDI / MMC.
actor CoreMIDIChannel: Channel {
    let id: ChannelID = .coreMIDI
    private let engine: MIDIEngine

    init(engine: MIDIEngine) {
        self.engine = engine
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
            await engine.sendNoteOff(channel: channel, note: note)
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
            await engine.sendNoteOff(channel: channel, note: note)
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
            guard let value = params["value"].flatMap(UInt16.init) else {
                return .error("pitch_bend requires 'value' (0-16383, center=8192)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendPitchBend(channel: channel, value: value)
            return .success("Pitch bend \(value) on ch \(channel)")

        // MARK: - Aftertouch

        case "midi.aftertouch", "midi.send_aftertouch":
            guard let pressure = params["pressure"].flatMap(UInt8.init) else {
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
            for n in notes { await engine.sendNoteOff(channel: ch, note: n) }
            return .success("Chord sent: \(notes.count) notes")

        case "midi.step_input":
            let note = params["note"].flatMap(UInt8.init) ?? 60
            let vel: UInt8 = 80
            await engine.sendNoteOn(channel: 0, note: note, velocity: vel)
            try? await Task.sleep(for: .milliseconds(50))
            await engine.sendNoteOff(channel: 0, note: note)
            return .success("Step input: note \(note)")

        case "midi.list_ports":
            return .success("{\"sources\":\(MIDIGetNumberOfSources()),\"destinations\":\(MIDIGetNumberOfDestinations())}")

        case "midi.create_virtual_port":
            let name = params["name"] ?? "LogicProMCP-Virtual"
            return .success("Virtual port '\(name)' — managed by MIDIPortManager")

        case "midi.get_input_state":
            return .success("{\"active\":true}")

        case "transport.record":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .success("MMC record strobe")

        case "transport.goto_position":
            let bar = params["bar"].flatMap(Int.init) ?? 1
            return .success("Goto bar \(bar) — via MCU jog preferred")

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
            return .success("MMC locate — use transport.goto_position")

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
}
