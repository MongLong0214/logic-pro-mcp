import Foundation
import MCP

struct EditDispatcher {
    static let tool = Tool(
        name: "logic_edit",
        description: """
            Editing actions in Logic Pro. \
            Commands: undo, redo, cut, copy, paste, delete, select_all, \
            split, join, quantize, bounce_in_place, normalize, duplicate. \
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
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "redo":
            let result = await router.route(operation: "edit.redo")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "cut":
            let result = await router.route(operation: "edit.cut")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "copy":
            let result = await router.route(operation: "edit.copy")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "paste":
            let result = await router.route(operation: "edit.paste")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "delete":
            let result = await router.route(operation: "edit.delete")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "select_all":
            let result = await router.route(operation: "edit.select_all")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "split":
            let result = await router.route(operation: "edit.split")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "join":
            let result = await router.route(operation: "edit.join")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "quantize":
            let value = params["value"]?.stringValue ?? "1/16"
            let result = await router.route(
                operation: "edit.quantize",
                params: ["value": value]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "bounce_in_place":
            let result = await router.route(operation: "edit.bounce_in_place")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "normalize":
            let result = await router.route(operation: "edit.normalize")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "duplicate":
            let result = await router.route(operation: "edit.duplicate")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_step_input":
            let result = await router.route(operation: "edit.toggle_step_input")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown edit command: \(command). Available: undo, redo, cut, copy, paste, delete, select_all, split, join, quantize, bounce_in_place, normalize, duplicate, toggle_step_input")],
                isError: true
            )
        }
    }
}
