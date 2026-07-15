import Foundation
import MCP

/// Returns `nil` when none of the keys are present or when any provided value
/// is malformed. Use for required parameters where a silent default is dangerous — e.g.
/// `index` on mutating track commands where falling through to track 0
/// would edit the wrong track on a malformed caller request.
func intParamOrNil(_ params: [String: Value], _ keys: String...) -> Int? {
    intParamOrNil(params, keys: keys)
}

/// Array-keyed companion to the variadic `intParamOrNil`, so callers that build
/// their alias list dynamically (e.g. the ADR-002 `target_ref` resolver) share
/// the exact same coercion + alias-conflict semantics.
func intParamOrNil(_ params: [String: Value], keys: [String]) -> Int? {
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
    var selected: String?
    for key in keys {
        // Coerce adjacent primitive shapes — callers may send numeric or boolean
        // values for string-typed params (e.g. `{"name": 42}`) and silently
        // losing them to the default mask bugs in production. Order preserved:
        // string > int > double > bool.
        let resolved: String?
        if let value = params[key]?.stringValue {
            resolved = value
        } else if let value = params[key]?.intValue {
            resolved = String(value)
        } else if let value = params[key]?.doubleValue {
            resolved = String(value)
        } else if let value = params[key]?.boolValue {
            resolved = value ? "true" : "false"
        } else {
            resolved = nil
        }
        guard let resolved else { continue }
        if let selected {
            // audit P2 #21: alias-conflict fail-closed, matching
            // intParamOrNil/doubleParamOrNil. Two provided aliases that disagree
            // are ambiguous → return the default so the caller's empty/default
            // guard rejects the request instead of silently binding whichever
            // alias iterated first.
            guard selected == resolved else { return defaultValue }
        } else {
            selected = resolved
        }
    }
    return selected ?? defaultValue
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

func toolResultIsVerified(_ result: CallTool.Result) -> Bool {
    guard result.isError != true else { return false }
    return result.structuredContent?.objectValue?["verified"]?.boolValue == true
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

protocol OperationTraceDispatching {
    static var tool: Tool { get }
}

extension OperationTraceDispatching {
    static func startTraceIfEnabled(command: String) async -> TraceID? {
        guard FeatureFlags.adr005OperationTrace,
              let spec = OperationRegistry.spec(tool: tool.name, command: command),
              spec.mutability == Mutability.`mutating` else {
            return nil
        }
        let id = await OperationTraceStore.shared.start(operationID: spec.id.rawValue)
        await OperationTraceStore.shared.record(id, phase: .requestReceived, attributes: [
            "operation_id": spec.id.rawValue,
            "command": command,
        ])
        return id
    }

    static func recordWriteBoundary(_ traceID: TraceID?) async {
        if let onWriteBoundary = OperationTraceParentBoundary.onWriteBoundary {
            await onWriteBoundary()
        }
        guard let traceID else { return }
        await OperationTraceStore.shared.record(traceID, phase: .writeBoundaryCrossed)
    }

    static func finalizeTrace(
        _ result: CallTool.Result,
        traceID: TraceID?
    ) async -> CallTool.Result {
        guard let traceID else { return result }
        guard case .text(let raw, _, _) = result.content.first else {
            await OperationTraceStore.shared.record(
                traceID,
                phase: .verificationCompleted,
                attributes: ["readback_state": result.isError == true ? "C" : "A"]
            )
            await OperationTraceStore.shared.record(traceID, phase: .resultEmitted)
            await OperationTraceStore.shared.complete(traceID)
            return result
        }

        let object = decodedJSONObject(raw)
        var attributes = [
            "readback_state": object?["state"] as? String
                ?? (result.isError == true ? "C" : "A"),
        ]
        if let errorCode = object?["error"] as? String {
            attributes["error_code"] = errorCode
        }
        await OperationTraceStore.shared.record(
            traceID,
            phase: .verificationCompleted,
            attributes: attributes
        )
        await OperationTraceStore.shared.record(traceID, phase: .resultEmitted)
        await OperationTraceStore.shared.complete(traceID)

        let merged = HonestContract.addExtras(["trace_id": traceID.rawValue], into: raw)
        guard merged != raw else { return result }
        return toolTextResult(merged, isError: result.isError == true)
    }
}
