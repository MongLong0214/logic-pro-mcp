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
    info: AXLogicProElements.BlockingDialogInfo? = AXLogicProElements.blockingDialogInfo(),
    // #608: the decision the caller REFUSED on, passed in rather than re-read here.
    //
    // Re-reading asks the same question a second time, and between the two the screen can change —
    // so a call that was refused could be annotated `no_blocking_window`, a reason that contradicts
    // the refusal it explains. That is the same defect as the process-global this file already
    // removed, arriving by a different route: state carried across a gap instead of handed across it.
    //
    // Defaulting to a fresh read keeps every existing call site compiling and behaving as before;
    // callers that have the decision should pass it.
    decision: (reason: AXLogicProElements.DialogPresenceReason, windowsReadError: Int32?)? = nil
) -> CallTool.Result {
    // #608: the guard has four ways to answer "blocked" and only one of them is a dialog. Measured,
    // the first call in a fresh process was refused because the windows read answered
    // kAXErrorCannotComplete — not because anything was on screen. That is now re-read once so it no
    // longer refuses, and when a refusal DOES happen the reason travels with it.
    //
    // `blocking_dialog_present` and `failure_stage` keep their existing meanings. Repurposing them
    // would change what every existing caller reads off the wire, and two dispatcher tests assert
    // those exact values — that question deserves its own decision, not a side effect of a bug fix.
    // The distinction is carried by new fields and by the hint.
    let resolved = decision ?? AXLogicProElements.dialogPresenceDecision()
    let reason = resolved.reason
    let sawADialog = info != nil || reason.namesAnActualDialog
    var extras: [String: Any] = [
        "operation": operation,
        "failure_stage": "preflight_blocking_dialog",
        "blocking_dialog_present": true,
        "dialog_presence_reason": reason.rawValue,
        "refusal_names_an_actual_dialog": sawADialog,
        // #608: WHICH AX status, not just which category. -25204 (cannotComplete) is the transient
        // this issue is about; anything else is a different problem wearing the same label.
        "windows_read_ax_error": resolved.windowsReadError.map { Int($0) } ?? NSNull(),
        // Whether the reason was handed over by the caller that refused, or re-read here. A caller
        // that does not pass it gets an honest "this was measured later", not a silent substitution.
        "dialog_presence_reason_source": decision == nil ? "re_read_at_refusal" : "decision_at_refusal_time",
        "write_attempted": false,
        "safe_to_retry": true,
    ]
    var hint = sawADialog
        ? "Refusing \(operation) while a blocking Logic dialog/sheet is present. Dismiss crash, save, bounce, import, or other modal dialogs, then retry."
        : "Refusing \(operation): the blocking-dialog preflight could not establish whether a dialog "
            + "is present (\(reason.rawValue)), so it fails closed. Nothing was touched. No modal was "
            + "identified — do not go looking for one to dismiss; retry in a moment, and if it "
            + "persists check that Logic is running and that this process has Accessibility access."
    // #190: identify the dialog so the demo/product workflow can recover
    // deterministically instead of guessing at a generic blocking-dialog refusal.
    if info == nil {
        // #606: refusing without an identity is refusing on something nobody can name. Say what the
        // guard saw so the caller is not sent hunting for a dialog that is not there.
        extras["dialog_presence_census"] = AXLogicProElements.dialogPresenceCensus()
    }
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
    /// Typed fallthrough for a REGISTERED command that reached this
    /// dispatcher without a matching switch case. Unregistered commands never
    /// get here (the server rejects them before dispatch), so this envelope
    /// firing means registry↔dispatch drift; the executable dispatch census
    /// asserts it never fires for any registered operation. The hint keeps
    /// the human-readable phrasing (and the registry-derived command list);
    /// the error code is the machine contract.
    static func unhandledCommandResult(_ command: String, label: String) -> CallTool.Result {
        let available = OperationRegistry.specs
            .filter { $0.tool.rawValue == tool.name }
            .map(\.command)
            .joined(separator: ", ")
        return toolTextResult(
            HonestContract.encodeStateC(
                error: .unhandledRegisteredCommand,
                hint: "Unknown \(label) command: \(command). Available: \(available)",
                extras: ["tool": tool.name, "command": command]
            ),
            isError: true
        )
    }
}

extension OperationTraceDispatching {
    static func startTraceIfEnabled(command: String) async -> TraceID? {
        guard FeatureFlags.adr005OperationTrace,
              let spec = OperationRegistry.spec(tool: tool.name, command: command),
              spec.mutability == Mutability.`mutating` else {
            return nil
        }
        let id = await OperationTraceStore.shared.start(operationID: spec.id.rawValue)
        var requestAttributes = [
            "operation_id": spec.id.rawValue,
            "command": command,
        ]
        let context = OperationTraceContext.current
        if let parent = context?.parentTraceID {
            requestAttributes["parent_trace_id"] = parent.rawValue
        }
        await OperationTraceStore.shared.record(
            id, phase: .requestReceived, attributes: requestAttributes
        )
        // Reaching dispatch means server-side strict parameter validation
        // already accepted the call (rejections never start a trace).
        await OperationTraceStore.shared.record(id, phase: .inputValidated)
        // The server's mutation gate is try-acquire: there is no queueing
        // wait, so both gate phases record at registration with honest
        // zero-wait semantics.
        if context?.mutationGateAcquired == true {
            await OperationTraceStore.shared.record(
                id, phase: .mutationGateWaitStarted,
                attributes: ["gate_mode": "try_acquire"]
            )
            await OperationTraceStore.shared.record(
                id, phase: .mutationGateAcquired,
                attributes: ["gate_mode": "try_acquire"]
            )
        }
        context?.register(id)
        return id
    }

    /// #389: arm `write_boundary.crossed` for EXACTLY the routed write in
    /// `route`, then let `ChannelRouter` commit it at the first channel it
    /// actually dispatches. The arm clears on exit whether or not it committed,
    /// so a dead route (no channel) records no boundary and a later read route
    /// can never inherit this write's arm.
    ///
    /// Wrap the WRITE route only — never widen the scope back over pre-reads
    /// (`liveTransportState` and friends), which is exactly the false boundary
    /// this replaces.
    static func withWriteBoundaryArmed<T>(
        _ traceID: TraceID?,
        _ route: () async -> T
    ) async -> T {
        await OperationTraceWriteBoundaryArm.armed(traceID, route)
    }

    /// Immediate, unconditional boundary for genuine first writes that do NOT
    /// go through `ChannelRouter` (support-bundle/export materialization, the
    /// project lifecycle AppleScript, the cleanup_apply parent). Router-backed
    /// writes must use `withWriteBoundaryArmed` instead — this call cannot know
    /// whether a channel was ever dispatched.
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
        guard case .text(let raw, let annotations, let meta) = result.content.first else {
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
        // Injecting trace_id must not silently rewrite the rest of the result the
        // dispatcher already built: rebuilding via `toolTextResult` dropped block 0's
        // annotations/_meta, every later content block, the result-level _meta, and
        // coerced a nil `isError` into `false`. Reconstruct in place instead —
        // only block 0's text changes. Mirrors `TargetRefResolution.addEvidence`.
        var content = result.content
        content[0] = .text(text: merged, annotations: annotations, _meta: meta)
        return CallTool.Result(
            content: content,
            structuredContent: structuredContentValue(fromToolText: merged),
            isError: result.isError,
            _meta: result._meta
        )
    }
}
