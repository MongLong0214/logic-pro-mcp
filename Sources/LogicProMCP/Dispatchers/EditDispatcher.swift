import Foundation
import MCP

struct EditDispatcher {
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
        case "undo":
            let result = await router.route(operation: "edit.undo")
            return toolTextResult(result)

        case "redo":
            let result = await router.route(operation: "edit.redo")
            return toolTextResult(result)

        case "cut":
            let result = await router.route(operation: "edit.cut")
            return toolTextResult(result)

        case "copy":
            let result = await router.route(operation: "edit.copy")
            return toolTextResult(result)

        case "paste":
            let result = await router.route(operation: "edit.paste")
            return toolTextResult(result)

        case "delete":
            let result = await router.route(operation: "edit.delete")
            return toolTextResult(result)

        case "select_all":
            let result = await router.route(operation: "edit.select_all")
            return toolTextResult(result)

        case "split":
            let result = await router.route(operation: "edit.split")
            return toolTextResult(result)

        case "join":
            let result = await router.route(operation: "edit.join")
            return toolTextResult(result)

        case "quantize":
            let value = params["value"]?.stringValue ?? "1/16"
            let result = await router.route(
                operation: "edit.quantize",
                params: ["value": value]
            )
            return toolTextResult(result)

        case "bounce_in_place":
            let result = await router.route(operation: "edit.bounce_in_place")
            return toolTextResult(result)

        case "normalize":
            let result = await router.route(operation: "edit.normalize")
            return toolTextResult(result)

        case "duplicate":
            let result = await router.route(operation: "edit.duplicate")
            return toolTextResult(result)

        case "toggle_step_input":
            let result = await router.route(operation: "edit.toggle_step_input")
            return toolTextResult(result)

        default:
            return toolTextResult(
                "Unknown edit command: \(command). Available: undo, redo, cut, copy, paste, delete, select_all, split, join, quantize, bounce_in_place, normalize, duplicate, toggle_step_input",
                isError: true
            )
        }
    }
}
