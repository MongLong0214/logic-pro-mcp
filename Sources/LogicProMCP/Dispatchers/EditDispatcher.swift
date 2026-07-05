import Foundation
import MCP

struct EditDispatcher {
    private enum EditRoute {
        case regular(String)
        case unverifiedIsError(String)
    }

    private static let routedCommands: [String: EditRoute] = [
        "undo": .regular("edit.undo"),
        "redo": .regular("edit.redo"),
        "cut": .regular("edit.cut"),
        "copy": .regular("edit.copy"),
        "paste": .regular("edit.paste"),
        "delete": .regular("edit.delete"),
        "select_all": .unverifiedIsError("edit.select_all"),
        "split": .regular("edit.split"),
        "join": .regular("edit.join"),
        "bounce_in_place": .regular("edit.bounce_in_place"),
        "normalize": .regular("edit.normalize"),
        "duplicate": .regular("edit.duplicate"),
        "toggle_step_input": .regular("edit.toggle_step_input"),
    ]

    private static let validQuantizeGrids = [
        "1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64", "1/4T", "1/8T", "1/16T",
    ]

    static let tool = Tool(
        name: "logic_edit",
        description: """
            Editing actions in Logic Pro. \
            Commands: undo, redo, cut, copy, paste, delete, select_all, \
            split, join, quantize, bounce_in_place, normalize, duplicate, toggle_step_input. \
            Params by command: \
            quantize -> { value: String } ("1/4", "1/8", "1/16", etc.); \
            Most others -> {} (operate on current selection)
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Edit command to execute"),
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
        case "undo", "redo", "cut", "copy", "paste", "delete", "select_all", "split", "join",
             "bounce_in_place", "normalize", "duplicate", "toggle_step_input":
            guard let route = routedCommands[command] else {
                return toolTextResult("Internal edit route missing for \(command)", isError: true)
            }
            return await routeEditCommand(route, router: router)

        case "quantize":
            guard params["value"] != nil || params["grid"] != nil else {
                return toolInvalidParamsResult(
                    "quantize requires explicit 'value' or 'grid'"
                )
            }
            let value = stringParam(params, "value", "grid", default: "1/16")
            guard validQuantizeGrids.contains(value) else {
                return toolTextResult(
                    "quantize 'value' must be one of \(validQuantizeGrids.joined(separator: ", ")) (got '\(value)')",
                    isError: true
                )
            }
            let result = await router.route(
                operation: "edit.quantize",
                params: ["value": value]
            )
            return toolTextResultTreatingUnverifiedAsError(result)

        default:
            return toolTextResult(
                "Unknown edit command: \(command). Available: undo, redo, cut, copy, paste, delete, select_all, split, join, quantize, bounce_in_place, normalize, duplicate, toggle_step_input",
                isError: true
            )
        }
    }

    private static func routeEditCommand(
        _ route: EditRoute,
        router: ChannelRouter
    ) async -> CallTool.Result {
        switch route {
        case .regular(let operation):
            return await routedTextResult(router, operation: operation)
        case .unverifiedIsError(let operation):
            let result = await router.route(operation: operation)
            return toolTextResultTreatingUnverifiedAsError(result)
        }
    }
}
