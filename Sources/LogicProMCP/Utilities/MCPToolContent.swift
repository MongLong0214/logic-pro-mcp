import MCP

func toolTextContent(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

func toolTextResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    CallTool.Result(content: [toolTextContent(text)], isError: isError)
}

func toolTextResult(_ result: ChannelResult) -> CallTool.Result {
    CallTool.Result(content: [toolTextContent(result.message)], isError: !result.isSuccess)
}

func toolStateCResult(
    _ error: HonestContract.FailureError,
    hint: String? = nil,
    extras: [String: Any] = [:]
) -> CallTool.Result {
    toolTextResult(
        HonestContract.encodeStateC(error: error, hint: hint, extras: extras),
        isError: true
    )
}

func toolInvalidParamsResult(_ hint: String, extras: [String: Any] = [:]) -> CallTool.Result {
    toolStateCResult(.invalidParams, hint: hint, extras: extras)
}

/// #202: a command token the dispatcher recognises but that is deliberately not
/// part of the production MCP contract. Returns a single, machine-classifiable
/// shape — `error:"command_not_exposed"` + `not_exposed:true` + `supported:false`
/// — so a complete-surface harness can mark it expected rather than a
/// malfunction. The hint keeps the canonical "not exposed in the production MCP
/// contract" phrase (the workflow census uses it to detect stubs); `reason`
/// carries any operation-specific detail.
func notExposedCommandResult(operation: String, reason: String? = nil) -> CallTool.Result {
    let detail = reason.map { " — \($0)" } ?? ""
    return toolStateCResult(
        .commandNotExposed,
        hint: "\(operation) is not exposed in the production MCP contract\(detail)",
        extras: [
            "operation": operation,
            "not_exposed": true,
            "supported": false,
        ]
    )
}

func commandParamsToolSchema(commandDescription: String) -> Value {
    .object([
        "type": .string("object"),
        "properties": .object([
            "command": .object(["type": .string("string"), "description": .string(commandDescription)]),
            "params": .object(["type": .string("object"), "description": .string("Command-specific parameters")]),
        ]),
        "required": .array([.string("command")]),
    ])
}

func commandTool(name: String, description: String, commandDescription: String) -> Tool {
    Tool(
        name: name,
        description: description,
        inputSchema: commandParamsToolSchema(commandDescription: commandDescription)
    )
}
