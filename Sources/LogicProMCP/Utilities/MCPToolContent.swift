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
