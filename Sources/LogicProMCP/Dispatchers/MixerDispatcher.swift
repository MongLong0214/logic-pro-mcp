import Foundation
import MCP

struct MixerDispatcher {
    static let tool = commandTool(
        name: "logic_mixer",
        description: "Mixer actions in Logic Pro. Commands: set_volume, set_pan, set_master_volume, insert_plugin, bypass_plugin, set_plugin_param. Params: set_volume -> { track: Int, value: Float }; set_pan -> { track: Int, value: Float }; set_master_volume -> { value: Float }; insert_plugin -> { track: Int, slot: Int, name: String }; bypass_plugin -> { track: Int, slot: Int, bypassed: Bool }; set_plugin_param -> { track: Int, insert: 0, param: Int, value: Float } on the selected track via Scripter.",
        commandDescription: "Mixer command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "set_volume":
            return await routedTextResult(router, operation: "mixer.set_volume", params: [
                "index": String(intParam(params, "track", "index")),
                "volume": String(doubleParam(params, "value", "volume")),
            ])

        case "set_pan":
            return await routedTextResult(router, operation: "mixer.set_pan", params: [
                "index": String(intParam(params, "track", "index")),
                "pan": String(doubleParam(params, "value", "pan")),
            ])

        case "set_send":
            return toolTextResult(
                "set_send is not exposed in the production MCP contract because targeted send/bus control is not yet deterministic",
                isError: true
            )

        case "set_output":
            return toolTextResult("set_output is not exposed in the production MCP contract", isError: true)

        case "set_input":
            return toolTextResult("set_input is not exposed in the production MCP contract", isError: true)

        case "set_master_volume":
            return await routedTextResult(router, operation: "mixer.set_master_volume", params: [
                "volume": String(doubleParam(params, "value", "volume")),
            ])

        case "toggle_eq":
            return toolTextResult("toggle_eq is not exposed in the production MCP contract", isError: true)

        case "reset_strip":
            return toolTextResult("reset_strip is not exposed in the production MCP contract", isError: true)

        case "insert_plugin":
            return await routedTextResult(router, operation: "plugin.insert", params: [
                "track_index": String(intParam(params, "track", "track_index")),
                "plugin_name": stringParam(params, "name", "plugin_name"),
                "slot": String(intParam(params, "slot")),
            ])

        case "bypass_plugin":
            return await routedTextResult(router, operation: "plugin.bypass", params: [
                "track_index": String(intParam(params, "track", "track_index")),
                "slot": String(intParam(params, "slot")),
                "bypassed": String(boolParam(params, "bypassed", default: true)),
            ])

        case "set_plugin_param":
            let track = intParam(params, "track")
            let insert = intParam(params, "insert")
            guard insert == 0 else {
                return toolTextResult(
                    "set_plugin_param currently supports only insert: 0 on the selected track via Scripter",
                    isError: true
                )
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(track)]
            )
            guard selectResult.isSuccess else {
                return toolTextResult(selectResult.message, isError: true)
            }
            return await routedTextResult(router, operation: "plugin.set_param", params: [
                "track": String(track),
                "insert": String(insert),
                "param": String(intParam(params, "param")),
                "value": String(doubleParam(params, "value")),
            ])

        default:
            return toolTextResult(
                "Unknown mixer command: \(command). Available: set_volume, set_pan, set_master_volume, insert_plugin, bypass_plugin, set_plugin_param",
                isError: true
            )
        }
    }
}
