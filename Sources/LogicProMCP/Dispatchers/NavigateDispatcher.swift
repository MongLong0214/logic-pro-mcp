import Foundation
import MCP

struct NavigateDispatcher {
    static let tool = Tool(
        name: "logic_navigate",
        description: "Navigation and markers in Logic Pro. Commands: goto_bar, goto_marker, create_marker, delete_marker, rename_marker, zoom_to_fit, set_zoom, toggle_view. Params: goto_bar -> { bar: Int }; goto_marker -> { index: Int } or { name: String }; create_marker -> { name: String }; rename_marker -> { index: Int, name: String }; delete_marker -> { index: Int }; set_zoom -> { level: String } (in|out|fit); toggle_view -> { view: String } (mixer|piano_roll|score|step_editor|library|inspector|automation).",
        inputSchema: commandParamsToolSchema(commandDescription: "Navigation command to execute")
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "goto_bar":
            let bar = intParam(params, "bar", default: 1)
            guard (1...9999).contains(bar) else {
                return toolTextResult("goto_bar 'bar' must be in 1..9999 (got \(bar))", isError: true)
            }
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": "\(bar).1.1.1"]
            )
            return toolTextResult(result)

        case "goto_marker":
            if params["index"] != nil {
                let index = intParam(params, "index", default: 0)
                let result = await router.route(
                    operation: "nav.goto_marker",
                    params: ["index": String(index)]
                )
                return toolTextResult(result)
            }
            let name = stringParam(params, "name")
            if !name.isEmpty {
                let markers = await cache.getMarkers()
                if let marker = markers.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    let result = await router.route(
                        operation: "nav.goto_marker",
                        params: ["index": String(marker.id)]
                    )
                    return toolTextResult(result)
                }
                return toolTextResult("No marker found matching '\(name)'", isError: true)
            }
            return toolTextResult("goto_marker requires 'index' or 'name' param", isError: true)

        case "create_marker":
            let name = stringParam(params, "name", default: "Marker")
            let result = await router.route(
                operation: "nav.create_marker",
                params: ["name": name]
            )
            return toolTextResult(result)

        case "delete_marker":
            let index = intParam(params, "index", default: 0)
            let result = await router.route(
                operation: "nav.delete_marker",
                params: ["index": String(index)]
            )
            return toolTextResult(result)

        case "rename_marker":
            let index = intParam(params, "index", default: 0)
            let name = stringParam(params, "name")
            let result = await router.route(
                operation: "nav.rename_marker",
                params: ["index": String(index), "name": name]
            )
            return toolTextResult(result)

        case "zoom_to_fit":
            let result = await router.route(operation: "nav.zoom_to_fit")
            return toolTextResult(result)

        case "set_zoom":
            // Accept both `level` (docs) and `direction` (common caller term) —
            // matrix tests and real callers drift across both. Silently ignoring
            // a misnamed param was the class of bug that hid 100% false-positive
            // test coverage earlier in the hardening loop.
            let level = stringParam(params, "level", "direction", default: "fit")
            switch level {
            case "in":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "8"]
                )
                return toolTextResult(result)
            case "out":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "2"]
                )
                return toolTextResult(result)
            case "fit":
                let result = await router.route(operation: "nav.zoom_to_fit")
                return toolTextResult(result)
            default:
                // Treat as numeric zoom level
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": level]
                )
                return toolTextResult(result)
            }

        case "toggle_view":
            let view = stringParam(params, "view", default: "mixer")
            let operation: String
            switch view {
            case "mixer": operation = "view.toggle_mixer"
            case "piano_roll": operation = "view.toggle_piano_roll"
            case "score": operation = "view.toggle_score_editor"
            case "step_editor": operation = "view.toggle_step_editor"
            case "library": operation = "view.toggle_library"
            case "inspector": operation = "view.toggle_inspector"
            case "automation": operation = "automation.toggle_view"
            default:
                return toolTextResult(
                    "Unknown view: \(view). Available: mixer, piano_roll, score, step_editor, library, inspector, automation",
                    isError: true
                )
            }
            let result = await router.route(operation: operation)
            return toolTextResult(result)

        default:
            return toolTextResult(
                "Unknown navigate command: \(command). Available: goto_bar, goto_marker, create_marker, delete_marker, rename_marker, zoom_to_fit, set_zoom, toggle_view",
                isError: true
            )
        }
    }
}
