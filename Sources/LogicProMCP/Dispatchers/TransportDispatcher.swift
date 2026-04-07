import Foundation
import MCP

struct TransportDispatcher {
    static let tool = Tool(
        name: "logic_transport",
        description: "Control Logic Pro transport. Commands: play, stop, record, pause, rewind, fast_forward, toggle_cycle, toggle_metronome, set_tempo, goto_position, set_cycle_range, toggle_count_in. Params: set_tempo -> { tempo: Float } (20.0-999.0); goto_position -> { bar: Int } or { time: \"HH:MM:SS:FF\" }; set_cycle_range -> { start: Int, end: Int }; others -> {}.",
        inputSchema: commandParamsToolSchema(commandDescription: "Transport command to execute")
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "play":
            let result = await router.route(operation: "transport.play")
            return toolTextResult(result)

        case "stop":
            let result = await router.route(operation: "transport.stop")
            return toolTextResult(result)

        case "record":
            let result = await router.route(operation: "transport.record")
            return toolTextResult(result)

        case "pause":
            let result = await router.route(operation: "transport.pause")
            return toolTextResult(result)

        case "rewind":
            let result = await router.route(operation: "transport.rewind")
            return toolTextResult(result)

        case "fast_forward":
            let result = await router.route(operation: "transport.fast_forward")
            return toolTextResult(result)

        case "toggle_cycle":
            let result = await router.route(operation: "transport.toggle_cycle")
            return toolTextResult(result)

        case "toggle_metronome":
            let result = await router.route(operation: "transport.toggle_metronome")
            return toolTextResult(result)

        case "toggle_count_in":
            let result = await router.route(operation: "transport.toggle_count_in")
            return toolTextResult(result)

        case "set_tempo":
            let tempo = params["tempo"]?.doubleValue
                ?? params["bpm"]?.doubleValue
                ?? 120.0
            let result = await router.route(
                operation: "transport.set_tempo",
                params: ["bpm": String(tempo)]
            )
            return toolTextResult(result)

        case "goto_position":
            if let bar = params["bar"]?.intValue {
                let result = await router.route(
                    operation: "transport.goto_position",
                    params: ["position": "\(bar).1.1.1"]
                )
                return toolTextResult(result)
            }
            let time = params["time"]?.stringValue
                ?? params["position"]?.stringValue
                ?? "1.1.1.1"
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": time]
            )
            return toolTextResult(result)

        case "set_cycle_range":
            let start = params["start"]?.intValue ?? 1
            let end = params["end"]?.intValue ?? 5
            let result = await router.route(
                operation: "transport.set_cycle_range",
                params: ["start": "\(start).1.1.1", "end": "\(end).1.1.1"]
            )
            return toolTextResult(result)

        default:
            return toolTextResult(
                "Unknown transport command: \(command). Available: play, stop, record, pause, rewind, fast_forward, toggle_cycle, toggle_metronome, set_tempo, goto_position, set_cycle_range, toggle_count_in",
                isError: true
            )
        }
    }
}
