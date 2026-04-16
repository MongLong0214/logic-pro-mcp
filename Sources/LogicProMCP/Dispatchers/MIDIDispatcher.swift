import Foundation
import MCP

struct MIDIDispatcher {
    static let tool = commandTool(
        name: "logic_midi",
        description: "MIDI operations in Logic Pro. Commands: send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, play_sequence, create_virtual_port, step_input, mmc_play, mmc_stop, mmc_record, mmc_locate. Params: send_note/send_chord -> MIDI note payloads; send_cc/program_change/pitch_bend/aftertouch -> controller payloads; send_sysex -> { bytes: [Int] } or { data: String }; play_sequence -> { notes: \"pitch,offsetMs,durMs[,vel[,ch]];...\" } (≤256 events, tight server-side timing); mmc_locate -> { bar: Int } or { time: \"HH:MM:SS:FF\" }; create_virtual_port -> { name: String }.",
        commandDescription: "MIDI command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "send_note":
            return await routedTextResult(router, operation: "midi.send_note", params: [
                "note": String(intParam(params, "note", default: 60)),
                "velocity": String(intParam(params, "velocity", default: 100)),
                "channel": String(intParam(params, "channel", default: 1)),
                "duration_ms": String(intParam(params, "duration_ms", default: 500)),
            ])

        case "send_chord":
            return await routedTextResult(router, operation: "midi.send_chord", params: [
                "notes": csvIntListOrStringParam(params, key: "notes"),
                "velocity": String(intParam(params, "velocity", default: 100)),
                "channel": String(intParam(params, "channel", default: 1)),
                "duration_ms": String(intParam(params, "duration_ms", default: 500)),
            ])

        case "play_sequence":
            // Tight-rhythm sequencer. `notes` is a raw string of
            // "pitch,offsetMs,durMs[,vel[,ch]]" events separated by ';'.
            return await routedTextResult(router, operation: "midi.play_sequence", params: [
                "notes": stringParam(params, "notes"),
            ])

        case "send_cc":
            return await routedTextResult(router, operation: "midi.send_cc", params: [
                "controller": String(intParam(params, "controller")),
                "value": String(intParam(params, "value")),
                "channel": String(intParam(params, "channel", default: 1)),
            ])

        case "send_program_change":
            return await routedTextResult(router, operation: "midi.send_program_change", params: [
                "program": String(intParam(params, "program")),
                "channel": String(intParam(params, "channel", default: 1)),
            ])

        case "send_pitch_bend":
            return await routedTextResult(router, operation: "midi.send_pitch_bend", params: [
                "value": String(intParam(params, "value")),
                "channel": String(intParam(params, "channel", default: 1)),
            ])

        case "send_aftertouch":
            return await routedTextResult(router, operation: "midi.send_aftertouch", params: [
                "value": String(intParam(params, "value")),
                "channel": String(intParam(params, "channel", default: 1)),
            ])

        case "send_sysex":
            // Accept three input shapes so callers can use whichever is ergonomic:
            //   bytes: [0xF0, 0x7E, ..., 0xF7]           (array of ints)
            //   bytes: "F0 7E 7F 06 01 F7"               (hex string, space-sep)
            //   data:  "F0 7E 7F 06 01 F7"               (hex string alias)
            let data: String
            if let arr = params["bytes"]?.arrayValue {
                data = arr.compactMap(\.intValue).map { String(format: "%02X", $0) }.joined(separator: " ")
            } else if let s = params["bytes"]?.stringValue, !s.isEmpty {
                data = s
            } else {
                data = stringParam(params, "data")
            }
            return await routedTextResult(router, operation: "midi.send_sysex", params: ["data": data])

        case "create_virtual_port":
            return await routedTextResult(router, operation: "midi.create_virtual_port", params: [
                "name": stringParam(params, "name", default: "Virtual Port"),
            ])

        case "mmc_play":
            return await routedTextResult(router, operation: "mmc.play")

        case "mmc_stop":
            return await routedTextResult(router, operation: "mmc.stop")

        case "mmc_record":
            return await routedTextResult(router, operation: "mmc.record_strobe")

        case "mmc_locate":
            // Prefer `bar` (int) → expand to bar.beat.sub.tick, else SMPTE `time`.
            // intParam handles int/double/string coercion, so a stringified bar
            // ("5") is accepted too.
            if params["bar"] != nil {
                let bar = intParam(params, "bar", default: 1)
                guard (1...9999).contains(bar) else {
                    return toolTextResult("mmc_locate 'bar' must be in 1..9999 (got \(bar))", isError: true)
                }
                return await routedTextResult(router, operation: "transport.goto_position", params: [
                    "position": "\(bar).1.1.1",
                ])
            }
            return await routedTextResult(router, operation: "mmc.locate", params: [
                "time": stringParam(params, "time", default: "00:00:00:00"),
            ])

        case "step_input":
            return await routedTextResult(router, operation: "midi.step_input", params: [
                "note": String(intParam(params, "note", default: 60)),
                "duration": stringParam(params, "duration", default: "1/4"),
            ])

        default:
            return toolTextResult(
                "Unknown MIDI command: \(command). Available: send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, create_virtual_port, step_input, mmc_play, mmc_stop, mmc_record, mmc_locate",
                isError: true
            )
        }
    }
}
