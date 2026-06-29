import Foundation
import MCP

/// Returns `nil` when none of the keys are present or when any provided value
/// is malformed. Use for required parameters where a silent default is dangerous — e.g.
/// `index` on mutating track commands where falling through to track 0
/// would edit the wrong track on a malformed caller request.
func intParamOrNil(_ params: [String: Value], _ keys: String...) -> Int? {
    var selected: Int?
    for key in keys {
        guard let raw = params[key] else { continue }
        let parsed: Int? = {
            if let value = raw.intValue { return value }
            if let value = raw.doubleValue, value.isFinite { return Int(exactly: value) }
            if let s = raw.stringValue {
                return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }()
        guard let parsed else {
            return nil
        }
        if let selected {
            guard selected == parsed else { return nil }
        } else {
            selected = parsed
        }
    }
    return selected
}

func doubleParamOrNil(_ params: [String: Value], _ keys: String...) -> Double? {
    var selected: Double?
    for key in keys {
        guard let raw = params[key] else { continue }
        let parsed: Double? = {
            if let value = raw.doubleValue { return value }
            if let value = raw.intValue { return Double(value) }
            if let s = raw.stringValue { return Double(s) }
            return nil
        }()
        guard let parsed, parsed.isFinite else { return nil }
        if let selected {
            guard selected == parsed else { return nil }
        } else {
            selected = parsed
        }
    }
    return selected
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

func boolParamOrNil(_ params: [String: Value], _ keys: String...) -> Bool? {
    for key in keys {
        guard let raw = params[key] else { continue }
        if let value = raw.boolValue {
            return value
        }
        if let s = raw.stringValue?.lowercased() {
            if s == "true" || s == "1" || s == "yes" { return true }
            if s == "false" || s == "0" || s == "no" { return false }
            return nil
        }
        if let value = raw.intValue {
            guard value == 0 || value == 1 else { return nil }
            return value == 1
        }
        return nil
    }
    return nil
}

enum StrictBoolParam {
    case missing
    case value(Bool)
    case invalid(String)
}

func strictBoolParam(_ params: [String: Value], _ key: String) -> StrictBoolParam {
    guard let raw = params[key] else { return .missing }
    guard let value = raw.boolValue else {
        return .invalid("'\(key)' must be a literal boolean true or false")
    }
    return .value(value)
}

func routedTextResult(
    _ router: ChannelRouter,
    operation: String,
    params: [String: String] = [:]
) async -> CallTool.Result {
    toolTextResult(await router.route(operation: operation, params: params))
}

private let dispatcherJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

func decodedJSONObject(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func decodeJSONValue<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? dispatcherJSONDecoder.decode(type, from: data)
}

func honestContractExtras(from raw: String) -> [String: Any] {
    guard var object = decodedJSONObject(raw) else { return [:] }
    for key in ["success", "verified", "reason", "error", "state", "hc_schema"] {
        object.removeValue(forKey: key)
    }
    return object
}

func channelResultIsVerified(_ result: ChannelResult) -> Bool {
    guard result.isSuccess else { return false }
    return decodedJSONObject(result.message)?["verified"] as? Bool == true
}

func channelResultIsUnverified(_ result: ChannelResult) -> Bool {
    guard result.isSuccess else { return false }
    return decodedJSONObject(result.message)?["verified"] as? Bool == false
}

func toolTextResultTreatingUnverifiedAsError(_ result: ChannelResult) -> CallTool.Result {
    if channelResultIsUnverified(result) {
        return toolTextResult(result.message, isError: true)
    }
    return toolTextResult(result)
}

func blockingLogicDialogResult(
    operation: String,
    info: AXLogicProElements.BlockingDialogInfo? = AXLogicProElements.blockingDialogInfo()
) -> CallTool.Result {
    var extras: [String: Any] = [
        "operation": operation,
        "failure_stage": "preflight_blocking_dialog",
        "blocking_dialog_present": true,
        "write_attempted": false,
        "safe_to_retry": true,
    ]
    var hint = "Refusing \(operation) while a blocking Logic dialog/sheet is present. Dismiss crash, save, bounce, import, or other modal dialogs, then retry."
    // #190: identify the dialog so the demo/product workflow can recover
    // deterministically instead of guessing at a generic blocking-dialog refusal.
    if let info {
        extras["dialog_title"] = info.title
        extras["dialog_role"] = info.role
        extras["owning_window"] = info.owningWindow
        extras["dialog_buttons"] = info.buttonTitles
        extras["recovery_action"] = info.recoveryAction
        let label = info.title.isEmpty ? info.role : info.title
        hint = "Refusing \(operation): a blocking Logic dialog/sheet is present (\(label)). \(info.recoveryAction)"
    }
    return toolTextResult(
        HonestContract.encodeStateC(error: .unsupportedState, hint: hint, extras: extras),
        isError: true
    )
}
