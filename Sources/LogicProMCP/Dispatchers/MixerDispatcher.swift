import Foundation
import MCP

struct MixerDispatcher {
    static let tool = Tool(
        name: "logic_mixer",
        description: """
            Mixer actions in Logic Pro. \
            Commands: set_volume, set_pan, set_send, set_output, set_input, \
            set_master_volume, toggle_eq, reset_strip, bypass_plugin, insert_plugin. \
            Params by command: \
            set_volume -> { track: Int, value: Float } (normalized 0.0-1.0); \
            set_pan -> { track: Int, value: Float } (-1.0 left to +1.0 right); \
            set_send -> { track: Int, bus: Int, value: Float }; \
            set_output -> { track: Int, output: String }; \
            set_input -> { track: Int, input: String }; \
            set_master_volume -> { value: Float }; \
            toggle_eq -> { track: Int }; \
            reset_strip -> { track: Int }; \
            insert_plugin -> { track: Int, slot: Int, name: String }; \
            bypass_plugin -> { track: Int, slot: Int, bypassed: Bool }
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Mixer command to execute"),
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
        case "set_volume":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let value = params["value"]?.doubleValue ?? params["volume"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_volume",
                params: ["index": String(track), "volume": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_pan":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let value = params["value"]?.doubleValue ?? params["pan"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_pan",
                params: ["index": String(track), "pan": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_send":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let bus = params["bus"]?.intValue ?? params["send_index"]?.intValue ?? 0
            let value = params["value"]?.doubleValue ?? params["level"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_send",
                params: ["index": String(track), "send_index": String(bus), "level": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_output":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let output = params["output"]?.stringValue ?? ""
            let result = await router.route(
                operation: "mixer.set_output",
                params: ["index": String(track), "output": output]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_input":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let input = params["input"]?.stringValue ?? ""
            let result = await router.route(
                operation: "mixer.set_input",
                params: ["index": String(track), "input": input]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_master_volume":
            let value = params["value"]?.doubleValue ?? params["volume"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_master_volume",
                params: ["volume": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_eq":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let result = await router.route(
                operation: "mixer.toggle_eq",
                params: ["index": String(track)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "reset_strip":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let result = await router.route(
                operation: "mixer.reset_strip",
                params: ["index": String(track)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "insert_plugin":
            let track = params["track"]?.intValue ?? params["track_index"]?.intValue ?? 0
            let slot = params["slot"]?.intValue ?? 0
            let name = params["name"]?.stringValue ?? params["plugin_name"]?.stringValue ?? ""
            let result = await router.route(
                operation: "plugin.insert",
                params: ["track_index": String(track), "plugin_name": name, "slot": String(slot)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "bypass_plugin":
            let track = params["track"]?.intValue ?? params["track_index"]?.intValue ?? 0
            let slot = params["slot"]?.intValue ?? 0
            let bypassed = params["bypassed"]?.boolValue ?? true
            let result = await router.route(
                operation: "plugin.bypass",
                params: ["track_index": String(track), "slot": String(slot), "bypassed": String(bypassed)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_plugin_param":
            let track = params["track"]?.intValue ?? 0
            let insert = params["insert"]?.intValue ?? 0
            let param = params["param"]?.intValue ?? 0
            let value = params["value"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_plugin_param",
                params: ["track": String(track), "insert": String(insert), "param": String(param), "value": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown mixer command: \(command). Available: set_volume, set_pan, set_send, set_output, set_input, set_master_volume, toggle_eq, reset_strip, insert_plugin, bypass_plugin")],
                isError: true
            )
        }
    }
}
