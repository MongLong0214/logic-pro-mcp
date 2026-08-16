import Foundation
import MCP

func toolTextContent(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

func toolTextResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    // Every tool here is registered with an `outputSchema`, and MCP requires a response that declares
    // one to carry matching `structuredContent`. A handler that hands back prose — a permission
    // summary, "State refresh completed", a failure sentence — produced `nil` here and so violated the
    // tool's own contract; a schema-enforcing client rejects the call outright (#544, reported against
    // v3.13.0 with `logic_system.permissions` and `refresh_cache`).
    //
    // Prose is therefore carried as an object rather than dropped. The text in `content` stays
    // byte-identical, and the structured half says what it actually is instead of claiming a shape it
    // does not have. This is the floor, not the goal: a command whose answer has real fields should
    // encode those fields, and the two commands in the report now do.
    let prose: [String: Value] = ["message": .string(text)]
    let structured: Value? = structuredContentValue(fromToolText: text) ?? .object(prose)
    return CallTool.Result(
        content: [toolTextContent(text)],
        structuredContent: structured,
        isError: isError
    )
}

func toolTextResult(_ result: ChannelResult) -> CallTool.Result {
    toolTextResult(result.message, isError: !result.isSuccess)
}

/// A receipt whose two halves are deliberately different: the text a caller has always read, and the
/// structured object the declared `outputSchema` requires.
///
/// Reaching for this instead of encoding the object as the text matters more than it looks. Several
/// operations are graded by `SemanticOracleTable` against the exact prose they emit — permissions is
/// checked line by line, refresh_cache whole-body — so replacing the text with JSON turns a correct
/// answer RED in qualification while every unit test stays green, because the oracles run against
/// fixtures rather than the live handler. Keep the text; add the structure beside it.
func toolTextResult(
    text: String,
    structured: Value,
    isError: Bool = false
) -> CallTool.Result {
    let payload: Value? = structured
    return CallTool.Result(
        content: [toolTextContent(text)],
        structuredContent: payload,
        isError: isError
    )
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

func structuredContentValue(fromToolText text: String) -> Value? {
    let data = Data(text.utf8)
    guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
        return nil
    }
    return try? JSONDecoder().decode(Value.self, from: data)
}

func genericObjectOutputSchema() -> Value {
    .object([
        "type": .string("object"),
        "additionalProperties": .bool(true),
    ])
}

func honestContractOutputSchema() -> Value {
    .object([
        "type": .string("object"),
        "description": .string("Mutating commands return the Honest Contract envelope (success/verified/state, additional operation-specific keys); read-only commands return command-specific JSON objects."),
        "properties": .object([
            "success": .object(["type": .string("boolean")]),
            "verified": .object(["type": .string("boolean")]),
            "state": .object(["type": .string("string")]),
        ]),
        "additionalProperties": .bool(true),
    ])
}

func toolWithOutputSchema(_ tool: Tool, outputSchema: Value) -> Tool {
    Tool(
        name: tool.name,
        title: tool.title,
        description: tool.description,
        inputSchema: tool.inputSchema,
        annotations: tool.annotations,
        outputSchema: outputSchema,
        icons: tool.icons,
        _meta: tool._meta
    )
}
