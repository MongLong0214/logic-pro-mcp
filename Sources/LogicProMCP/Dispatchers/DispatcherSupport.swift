import MCP

func intParam(_ params: [String: Value], _ keys: String..., default defaultValue: Int = 0) -> Int {
    for key in keys {
        if let value = params[key]?.intValue {
            return value
        }
    }
    return defaultValue
}

func doubleParam(_ params: [String: Value], _ keys: String..., default defaultValue: Double = 0) -> Double {
    for key in keys {
        if let value = params[key]?.doubleValue {
            return value
        }
    }
    return defaultValue
}

func stringParam(_ params: [String: Value], _ keys: String..., default defaultValue: String = "") -> String {
    for key in keys {
        if let value = params[key]?.stringValue {
            return value
        }
    }
    return defaultValue
}

func boolParam(_ params: [String: Value], _ keys: String..., default defaultValue: Bool = false) -> Bool {
    for key in keys {
        if let value = params[key]?.boolValue {
            return value
        }
    }
    return defaultValue
}

func csvIntListOrStringParam(_ params: [String: Value], key: String) -> String {
    if let array = params[key]?.arrayValue {
        return array.compactMap(\.intValue).map(String.init).joined(separator: ",")
    }
    return params[key]?.stringValue ?? ""
}

func routedTextResult(
    _ router: ChannelRouter,
    operation: String,
    params: [String: String] = [:]
) async -> CallTool.Result {
    toolTextResult(await router.route(operation: operation, params: params))
}
