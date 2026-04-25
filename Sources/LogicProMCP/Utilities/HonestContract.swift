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
        case readbackMismatch

        var rawValue: String {
            switch self {
            case .axWriteFailed: return "ax_write_failed"
            case .elementNotFound: return "element_not_found"
            case .permissionDenied: return "permission_denied"
            case .logicNotRunning: return "logic_not_running"
            case .invalidParams: return "invalid_params"
            case .readbackMismatch: return "readback_mismatch"
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
