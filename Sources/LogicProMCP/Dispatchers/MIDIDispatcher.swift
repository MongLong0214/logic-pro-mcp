import Foundation
import MCP

struct MIDIDispatcher {
    static let tool = Tool(
        name: "logic_midi",
        description: """
            MIDI operations in Logic Pro. \
            Commands: send_note, send_chord, send_cc, send_program_change, \
            send_pitch_bend, send_aftertouch, send_sysex, \
            create_virtual_port, mmc_play, mmc_stop, mmc_record, mmc_locate. \
            Params by command: \
            send_note -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }; \
            send_chord -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }; \
            send_cc -> { controller: Int, value: Int, channel: Int }; \
            send_program_change -> { program: Int, channel: Int }; \
            send_pitch_bend -> { value: Int, channel: Int } (-8192 to 8191); \
            send_aftertouch -> { value: Int, channel: Int }; \
            send_sysex -> { bytes: [Int] } or { data: String } (hex); \
            mmc_locate -> { bar: Int } or { time: "HH:MM:SS:FF" }; \
            create_virtual_port -> { name: String }
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("MIDI command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "send_note":
            let note = params["note"]?.intValue ?? 60
            let velocity = params["velocity"]?.intValue ?? 100
            let channel = params["channel"]?.intValue ?? 1
            let durationMs = params["duration_ms"]?.intValue ?? 500
            let result = await router.route(
                operation: "midi.send_note",
                params: [
                    "note": String(note),
                    "velocity": String(velocity),
                    "channel": String(channel),
                    "duration_ms": String(durationMs),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_chord":
            // Accept either array of ints or comma-separated string
            let notesStr: String
            if let arr = params["notes"]?.arrayValue {
                notesStr = arr.compactMap { $0.intValue }.map(String.init).joined(separator: ",")
            } else {
                notesStr = params["notes"]?.stringValue ?? ""
            }
            let velocity = params["velocity"]?.intValue ?? 100
            let channel = params["channel"]?.intValue ?? 1
            let durationMs = params["duration_ms"]?.intValue ?? 500
            let result = await router.route(
                operation: "midi.send_chord",
                params: [
                    "notes": notesStr,
                    "velocity": String(velocity),
                    "channel": String(channel),
                    "duration_ms": String(durationMs),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_cc":
            let controller = params["controller"]?.intValue ?? 0
            let value = params["value"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
            let result = await router.route(
                operation: "midi.send_cc",
                params: [
                    "controller": String(controller),
                    "value": String(value),
                    "channel": String(channel),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_program_change":
            let program = params["program"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
            let result = await router.route(
                operation: "midi.send_program_change",
                params: ["program": String(program), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_pitch_bend":
            let value = params["value"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
            let result = await router.route(
                operation: "midi.send_pitch_bend",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_aftertouch":
            let value = params["value"]?.intValue ?? 0
            let channel = params["channel"]?.intValue ?? 1
            let result = await router.route(
                operation: "midi.send_aftertouch",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_sysex":
            let data: String
            if let bytes = params["bytes"]?.arrayValue {
                data = bytes.compactMap { $0.intValue }
                    .map { String(format: "%02X", $0) }
                    .joined(separator: " ")
            } else {
                data = params["data"]?.stringValue ?? ""
            }
            let result = await router.route(
                operation: "midi.send_sysex",
                params: ["data": data]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_virtual_port":
            let name = params["name"]?.stringValue ?? "Virtual Port"
            let result = await router.route(
                operation: "midi.create_virtual_port",
                params: ["name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_play":
            let result = await router.route(operation: "mmc.play")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_stop":
            let result = await router.route(operation: "mmc.stop")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_record":
            let result = await router.route(operation: "mmc.record_strobe")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_locate":
            if let bar = params["bar"]?.intValue {
                let result = await router.route(
                    operation: "mmc.locate",
                    params: ["bar": String(bar)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let time = params["time"]?.stringValue ?? "00:00:00:00"
            let result = await router.route(
                operation: "mmc.locate",
                params: ["time": time]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "step_input":
            let note = params["note"]?.intValue ?? 60
            let duration = params["duration"]?.stringValue ?? "1/4"
            let result = await router.route(
                operation: "midi.step_input",
                params: ["note": String(note), "duration": duration]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown MIDI command: \(command). Available: send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, create_virtual_port, step_input, mmc_play, mmc_stop, mmc_record, mmc_locate")],
                isError: true
            )
        }
    }
}
