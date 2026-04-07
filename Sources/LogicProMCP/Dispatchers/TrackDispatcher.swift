import Foundation
import MCP

struct TrackDispatcher {
    static let tool = Tool(
        name: "logic_tracks",
        description: "Track actions in Logic Pro. Commands: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, set_automation. Params: select -> { index: Int } or { name: String }; rename -> { index: Int, name: String }; mute/solo/arm -> { index: Int, enabled: Bool }; create_* -> {}; delete/duplicate -> { index: Int }; set_automation -> { index: Int, mode: String }.",
        inputSchema: commandParamsToolSchema(commandDescription: "Track command to execute")
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "select":
            if let index = params["index"]?.intValue {
                let result = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                return toolTextResult(result)
            }
            if let name = params["name"]?.stringValue {
                // Find track by name in cache
                let tracks = await cache.getTracks()
                if let track = tracks.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    let result = await router.route(
                        operation: "track.select",
                        params: ["index": String(track.id)]
                    )
                    return toolTextResult(result)
                }
                return toolTextResult("No track found matching '\(name)'", isError: true)
            }
            return toolTextResult("select requires 'index' or 'name' param", isError: true)

        case "create_audio":
            let result = await router.route(operation: "track.create_audio")
            return toolTextResult(result)

        case "create_instrument":
            let result = await router.route(operation: "track.create_instrument")
            return toolTextResult(result)

        case "create_drummer":
            let result = await router.route(operation: "track.create_drummer")
            return toolTextResult(result)

        case "create_external_midi":
            let result = await router.route(operation: "track.create_external_midi")
            return toolTextResult(result)

        case "delete":
            if let index = params["index"]?.intValue {
                let result = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                guard result.isSuccess else {
                    return toolTextResult(result.message, isError: true)
                }
            }
            let result = await router.route(operation: "track.delete")
            return toolTextResult(result)

        case "duplicate":
            if let index = params["index"]?.intValue {
                let selectResult = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                guard selectResult.isSuccess else {
                    return toolTextResult(selectResult.message, isError: true)
                }
            }
            let result = await router.route(operation: "track.duplicate")
            return toolTextResult(result)

        case "rename":
            let index = params["index"]?.intValue ?? 0
            let name = params["name"]?.stringValue ?? ""
            let result = await router.route(
                operation: "track.rename",
                params: ["index": String(index), "name": name]
            )
            return toolTextResult(result)

        case "mute":
            let index = params["index"]?.intValue ?? 0
            let enabled = params["enabled"]?.boolValue ?? true
            let result = await router.route(
                operation: "track.set_mute",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "solo":
            let index = params["index"]?.intValue ?? 0
            let enabled = params["enabled"]?.boolValue ?? true
            let result = await router.route(
                operation: "track.set_solo",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "arm":
            let index = params["index"]?.intValue ?? 0
            let enabled = params["enabled"]?.boolValue ?? true
            let result = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return toolTextResult(result)

        case "set_color":
            return toolTextResult("set_color is not exposed in the production MCP contract", isError: true)

        case "set_automation":
            let index = params["index"]?.intValue ?? 0
            let mode = params["mode"]?.stringValue ?? "read"
            let result = await router.route(
                operation: "track.set_automation",
                params: ["index": String(index), "mode": mode]
            )
            return toolTextResult(result)

        default:
            return toolTextResult(
                "Unknown track command: \(command). Available: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, set_automation",
                isError: true
            )
        }
    }
}
