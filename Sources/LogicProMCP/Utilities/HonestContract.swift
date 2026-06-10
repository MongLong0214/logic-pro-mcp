import Foundation

/// Honest Contract (v3.1.0+): every mutating operation returns one of three
/// states so that a client (LLM agent) can distinguish confirmed success,
/// uncertain success, and hard failure without heuristically parsing free-form
/// text. See `docs/HONEST-CONTRACT.md`.
///
/// This module is the single place responsible for producing the JSON that is
/// wrapped in `ChannelResult.success` / `.error`. Every new mutating op should
/// build its response through `encodeStateA` / `encodeStateB` / `encodeStateC`
/// to keep the wire format invariant.
enum HonestContract {

    /// Why a write is uncertain. Stable string enum so downstream tooling can
    /// switch on it.
    enum UncertainReason {
        /// MCU fader / V-Pot echo did not arrive inside the polling window.
        case echoTimeout(ms: Int)
        /// The AX read-back attribute is not exposed on this element (Logic
        /// build / state dependent).
        case readbackUnavailable
        /// Read-back succeeded but returned a different value than requested.
        case readbackMismatch
        /// Retry budget exhausted without either a confirmed read-back or a
        /// hard error.
        case retryExhausted

        var rawValue: String {
            switch self {
            case .echoTimeout(let ms): return "echo_timeout_\(ms)ms"
            case .readbackUnavailable: return "readback_unavailable"
            case .readbackMismatch: return "readback_mismatch"
            case .retryExhausted: return "retry_exhausted"
            }
        }
    }

    /// Hard-failure category. Stable string enum.
    enum FailureError {
        case axWriteFailed
        case elementNotFound
        case permissionDenied
        case logicNotRunning
        case invalidParams
        case readbackUnavailable
        case readbackMismatch
        /// Operation explicitly not implemented via this channel / build of
        /// Logic. Distinct from `.elementNotFound` (target absent) and
        /// `.axWriteFailed` (write attempt rejected): the surface itself does
        /// not exist. Terminal — no other channel can do better. v3.1.2 P2-1.
        case notImplemented
        /// The requested transport/port for a channel is not configured or
        /// available (e.g. CoreMIDI virtual port absent, KeyCmd not yet
        /// published). Terminal — falling back to another channel cannot
        /// recover the missing port. v3.1.6 T1 (PRD Issue#1 R7).
        case portUnavailable
        /// The router walked the full channel chain for this operation and
        /// every channel reported `healthCheck.unavailable` (or its readiness
        /// gate failed). Terminal — the chain itself produced no usable
        /// candidate. Distinct from `.portUnavailable` (a specific channel's
        /// port is missing) and `.logicNotRunning` (a single channel's
        /// process gone): exhaustion is the chain-level aggregate signal.
        /// v3.4.5-rc5 (Boomer BOOMER-6 / U — fixes semantic overload where
        /// every router fallthrough was being mis-classified as
        /// `port_unavailable` regardless of root cause).
        case channelsExhausted

        var rawValue: String {
            switch self {
            case .axWriteFailed: return "ax_write_failed"
            case .elementNotFound: return "element_not_found"
            case .permissionDenied: return "permission_denied"
            case .logicNotRunning: return "logic_not_running"
            case .invalidParams: return "invalid_params"
            case .readbackUnavailable: return "readback_unavailable"
            case .readbackMismatch: return "readback_mismatch"
            case .notImplemented: return "not_implemented"
            case .portUnavailable: return "port_unavailable"
            case .channelsExhausted: return "channels_exhausted"
            }
        }
    }

    // MARK: - Encoding primitives

    /// State A — confirmed success (write + read-back matched). Extra fields
    /// (e.g. the original requested/observed payload) are merged in.
    static func encodeStateA(extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = ["success": true, "verified": true]
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    /// State B — uncertain: the write landed but read-back couldn't confirm.
    /// `reason` is mandatory per the contract.
    static func encodeStateB(reason: UncertainReason, extras: [String: Any] = [:]) -> String {
        var dict: [String: Any] = [
            "success": true, "verified": false, "reason": reason.rawValue
        ]
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    /// State C — hard failure: the write itself didn't succeed. `error` is
    /// mandatory per the contract. `axCode` / `hint` are optional diagnostics.
    static func encodeStateC(
        error: FailureError,
        axCode: Int? = nil,
        hint: String? = nil,
        extras: [String: Any] = [:]
    ) -> String {
        var dict: [String: Any] = [
            "success": false, "error": error.rawValue
        ]
        if let axCode { dict["axCode"] = axCode }
        if let hint { dict["hint"] = hint }
        for (k, v) in extras { dict[k] = v }
        return jsonString(dict)
    }

    /// 이미 직렬화된 HC envelope (raw JSON) 의 top-level 에 caller-side extras
    /// 를 merge 한다. State C(`success == false`) 응답은 보존 — error payload
    /// 에 caller-side context 가 섞이면 진단성이 떨어지므로. 비-JSON / parse
    /// 실패 입력도 원본 그대로 반환 (defensive).
    static func addExtras(_ extras: [String: Any], into rawJSON: String) -> String {
        guard let data = rawJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return rawJSON
        }
        if (object["success"] as? Bool) == false {
            return rawJSON
        }
        for (k, v) in extras { object[k] = v }
        guard let encoded = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys]
              ),
              let str = String(data: encoded, encoding: .utf8) else {
            return rawJSON
        }
        return str
    }

    // MARK: - Terminal-state inspection (router fallback gate)

    /// Errors that mean "no other channel will do better either" — invalid
    /// caller input, missing element, explicit not-implemented. The router
    /// uses this to short-circuit the fallback chain so an AX honest State C
    /// does not silently regress into a vacuous MCU success on the next
    /// channel down (v3.1.2 P1-1).
    ///
    /// `ax_write_failed` and `permission_denied` are intentionally NOT
    /// terminal: a different channel (CGEvent, AppleScript, MCU) may still
    /// be able to deliver the operation.
    static let terminalErrorCodes: Set<String> = [
        FailureError.elementNotFound.rawValue,
        FailureError.invalidParams.rawValue,
        FailureError.notImplemented.rawValue,
        FailureError.portUnavailable.rawValue,
        FailureError.readbackUnavailable.rawValue,
        FailureError.channelsExhausted.rawValue,
    ]

    /// Returns true if the given message is a State-C envelope whose `error`
    /// is in `terminalErrorCodes`. Free-form (non-JSON) messages and State A
    /// / State B envelopes always return false. Used by `ChannelRouter` to
    /// suppress fallback when the primary channel has already reported an
    /// error the next channel cannot improve on.
    static func isTerminalStateC(_ message: String) -> Bool {
        guard let errorCode = stateCErrorCode(message) else { return false }
        return terminalErrorCodes.contains(errorCode)
    }

    /// Returns the stable State C error code for a valid Honest Contract
    /// failure envelope, or nil for free-form text / State A / State B.
    static func stateCErrorCode(_ message: String) -> String? {
        guard message.hasPrefix("{") else { return nil }
        guard let data = message.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let obj = raw as? [String: Any] else {
            return nil
        }
        // State A / B both carry `success:true`; only State C is `false`.
        guard let success = obj["success"] as? Bool, success == false else {
            return nil
        }
        return obj["error"] as? String
    }

    // MARK: - JSON serialization

    /// Serialize a dictionary deterministically (sorted keys) so snapshots
    /// and tests stay stable across runs. Values that JSONSerialization can't
    /// encode fall back to `String(describing:)`.
    static func jsonString(_ dict: [String: Any]) -> String {
        let sanitized = sanitize(dict)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                withJSONObject: sanitized, options: [.sortedKeys]
              ),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"success\":false,\"error\":\"honest_contract_encode_failed\"}"
        }
        return s
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = sanitize(v) }
            return out
        case let arr as [Any]:
            return arr.map { sanitize($0) }
        case let n as NSNumber:
            return n
        case let s as String:
            return s
        case let b as Bool:
            return b
        case let i as Int:
            return i
        case let d as Double:
            return d
        case is NSNull:
            return NSNull()
        case Optional<Any>.none:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}
