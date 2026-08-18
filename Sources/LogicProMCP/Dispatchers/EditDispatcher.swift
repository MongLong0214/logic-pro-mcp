import Foundation
import MCP

struct EditDispatcher: OperationTraceDispatching {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicEdit)

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
        // #575: the only region verb this tool carries. It is a SELECTION-relative edit, exactly
        // like cut/split/join above — the caller does not name a region, Logic's selection does —
        // and it routes to the region channel rather than to an `edit.*` operation. Unverified is
        // an error to the caller: the channel returns State A only when the same region it started
        // with landed on the playhead, and anything short of that is not a move to build on.
        "move_to_playhead": .unverifiedIsError("region.move_to_playhead"),
    ]

    private static let validQuantizeGrids = [
        "1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64", "1/4T", "1/8T", "1/16T",
    ]

    static let tool = Tool(
        name: "logic_edit",
        description: """
            Editing actions in Logic Pro. \
            Commands: undo, redo, cut, copy, paste, delete, select_all, \
            split, join, quantize, bounce_in_place, normalize, duplicate, toggle_step_input, \
            move_to_playhead. \
            Params by command: \
            quantize -> { value: String } ("1/4", "1/8", "1/16", etc.); \
            move_to_playhead -> {} moves the SELECTED region to the playhead and verifies it: \
            State A only when the same region (same name, same track) is selected after the move \
            and its start bar landed on the playhead within one bar; State B when the readback is \
            unavailable, when the region did not move, or when the selection changed underneath \
            the operation; \
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
             "bounce_in_place", "normalize", "duplicate", "toggle_step_input", "move_to_playhead":
            guard let route = routedCommands[command] else {
                return toolTextResult("Internal edit route missing for \(command)", isError: true)
            }
            let traceID = await startTraceIfEnabled(command: command)
            let result = await routeEditCommand(route, router: router, traceID: traceID)
            return await finalizeTrace(result, traceID: traceID)

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
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "edit.quantize",
                    params: ["value": value]
                )
            }
            return await finalizeTrace(
                toolTextResultTreatingUnverifiedAsError(result),
                traceID: traceID
            )

        default:
            return Self.unhandledCommandResult(command, label: "edit")
        }
    }

    private static func routeEditCommand(
        _ route: EditRoute,
        router: ChannelRouter,
        traceID: TraceID?
    ) async -> CallTool.Result {
        switch route {
        case .regular(let operation):
            return await withWriteBoundaryArmed(traceID) {
                await routedTextResult(router, operation: operation)
            }
        case .unverifiedIsError(let operation):
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: operation)
            }
            return toolTextResultTreatingUnverifiedAsError(result)
        }
    }
}
