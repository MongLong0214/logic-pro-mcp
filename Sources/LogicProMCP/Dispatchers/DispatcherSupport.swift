import MCP

func intParam(_ params: [String: Value], _ keys: String..., default defaultValue: Int = 0) -> Int {
    for key in keys {
        if let value = params[key]?.intValue {
            return value
        }
        // Accept string-form integers too (client convenience).
        if let s = params[key]?.stringValue, let value = Int(s) {
            return value
        }
    }
    return defaultValue
}

func doubleParam(_ params: [String: Value], _ keys: String..., default defaultValue: Double = 0) -> Double {
    for key in keys {
        // JSON integers decode as Value.int — Value.doubleValue returns nil for those.
        // Accept int, double, or numeric string so callers can send `{"tempo": 120}` or `120.5` or `"120"`.
        if let value = params[key]?.doubleValue {
            return value
        }
        if let value = params[key]?.intValue {
            return Double(value)
        }
        if let s = params[key]?.stringValue, let value = Double(s) {
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
        // Coerce adjacent primitive shapes — callers may send numeric or boolean
        // values for string-typed params (e.g. `{"name": 42}`) and silently
        // losing them to the default mask bugs in production.
        if let value = params[key]?.intValue {
            return String(value)
        }
        if let value = params[key]?.doubleValue {
            return String(value)
        }
        if let value = params[key]?.boolValue {
            return value ? "true" : "false"
        }
    }
    return defaultValue
}

func boolParam(_ params: [String: Value], _ keys: String..., default defaultValue: Bool = false) -> Bool {
    for key in keys {
        if let value = params[key]?.boolValue {
            return value
        }
        // Accept canonical string ("true"/"false") and 0/1 ints — common client
        // conveniences. Silent default on mistyped input used to bury real bugs.
        if let s = params[key]?.stringValue?.lowercased() {
            if s == "true" || s == "1" || s == "yes" { return true }
            if s == "false" || s == "0" || s == "no" { return false }
        }
        if let value = params[key]?.intValue {
            return value != 0
        }
    }
    return defaultValue
}

func csvIntListOrStringParam(_ params: [String: Value], key: String) -> String {
    if let array = params[key]?.arrayValue {
        // Coerce each element through int/double/string the same way doubleParam
        // does — silently dropping doubles/strings was a bug in the prior
        // implementation that turned `[60, 64.0, "67"]` into just "60".
        return array.compactMap { v -> Int? in
            if let i = v.intValue { return i }
            if let d = v.doubleValue { return Int(d) }
            if let s = v.stringValue, let i = Int(s) { return i }
            return nil
        }.map(String.init).joined(separator: ",")
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
