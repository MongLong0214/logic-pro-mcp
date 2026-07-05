import Foundation
import MCP

/// Global serialization gate for verified mutating ops (R14): AX UI state is a
/// shared resource, so at most one verified write/insert may be in flight
/// server-wide. A second concurrent request is refused with State C
/// `verified_op_in_progress` (`safe_to_retry:true`) rather than interleaving.
/// `get_inventory` is non-mutating and is NOT gated.
final class VerifiedOpGate: @unchecked Sendable {
    static let shared = VerifiedOpGate()
    private let lock = NSLock()
    private var inProgress = false

    /// Try to acquire the gate. Returns false if a verified op is already
    /// running. The caller MUST call `release()` when done (use defer).
    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inProgress { return false }
        inProgress = true
        return true
    }

    func release() {
        lock.lock()
        inProgress = false
        lock.unlock()
    }
}

/// `logic_plugins` — verified plugin apply-back surface (R16 Plane 1).
///
/// Commands: get_inventory, set_param_verified, insert_verified. The dispatcher
/// validates/normalizes input then routes through `ChannelRouter` to the
/// AX-only verified operations (`plugin.*`). Verified ops never fall back
/// (router chain is `[.accessibility]` alone) so a State C is always the honest
/// AX result.
struct PluginsDispatcher {
    static let tool = commandTool(
        name: "logic_plugins",
        description: "Verified plugin apply-back for Logic Pro (logic_plugins.*). Commands: get_inventory, set_param_verified, insert_verified. Unlike legacy logic_mixer.set_plugin_param (Scripter, unverified State B), this surface identifies the target track/insert/plugin/param via AX, writes, and reads back — State A only when the observed value matches within tolerance. get_inventory -> { track: Int (required, >= 0) } returns a drift-safe insert chain (physical slot index, read_status ok|empty|unreadable, complete). set_param_verified -> { track: Int, insert: Int, plugin: canonical logic.stock.* id or alias, param: key (e.g. gain_db), value: Float, unit: String, mode: \"duplicate_applyback\", project_expected_path: String (required) }. insert_verified -> { track: Int, insert: Int, plugin: Gain|Channel EQ|Compressor, mode: \"duplicate_applyback\", project_expected_path: String (required) }. mode confirmed_live is not supported in Release 1 (State C unsupported_mode).",
        commandDescription: "Verified plugin command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "get_inventory":
            // Non-mutating read — not gated by the verified-op serializer. The
            // channel owns validation and emits the HC v2 envelope (the verified
            // surface speaks HC v2 only), so the dispatcher just coerces the
            // track param if present and routes; a missing/invalid track is
            // reported by the channel as HC v2 invalid_params.
            var inventoryParams: [String: String] = [:]
            if let track = intParamOrNil(params, "track", "track_index", "index") {
                inventoryParams["track"] = String(track)
            }
            return await routedTextResult(router, operation: "plugin.get_inventory", params: inventoryParams)

        case "set_param_verified":
            return await runVerified(operation: "plugin.set_param_verified") {
                await routedTextResult(router, operation: "plugin.set_param_verified",
                                       params: verifiedWriteParams(params))
            }

        case "insert_verified":
            return await runVerified(operation: "plugin.insert_verified") {
                await routedTextResult(router, operation: "plugin.insert_verified",
                                       params: insertVerifiedParams(params))
            }

        default:
            return toolTextResult(
                "Unknown plugins command: \(command). Available: get_inventory, set_param_verified, insert_verified",
                isError: true
            )
        }
    }

    // MARK: - Verified-op serialization (R14)

    /// Acquire the global verified-op gate, run `body`, and release. If the gate
    /// is held, refuse with State C `verified_op_in_progress` before touching AX.
    private static func runVerified(
        operation: String,
        _ body: () async -> CallTool.Result
    ) async -> CallTool.Result {
        guard VerifiedOpGate.shared.tryAcquire() else {
            return toolTextResult(HonestContract.encodeV2StateC(
                error: .verifiedOpInProgress,
                extras: [
                    "operation": "logic_plugins.\(operation.replacingOccurrences(of: "plugin.", with: ""))",
                    "what_was_attempted": "begin a verified op",
                    "what_was_observed": "another verified op is already in progress (serialized server-wide)",
                    "safe_to_retry": true,
                    "write_attempted": false,
                ]
            ), isError: true)
        }
        defer { VerifiedOpGate.shared.release() }
        return await body()
    }

    // MARK: - Param coercion

    /// Coerce the MCP `set_param_verified` arguments to the string params the
    /// channel layer parses. Missing keys are omitted so the channel's R6 step-1
    /// schema validation reports them precisely.
    private static func verifiedWriteParams(_ params: [String: Value]) -> [String: String] {
        var out: [String: String] = [:]
        if let track = intParamOrNil(params, "track") { out["track"] = String(track) }
        if let insert = intParamOrNil(params, "insert") { out["insert"] = String(insert) }
        if let plugin = nonEmptyString(params, "plugin", "plugin_id", "plugin_name") { out["plugin"] = plugin }
        if let param = nonEmptyString(params, "param") { out["param"] = param }
        if let value = doubleParamOrNil(params, "value") { out["value"] = String(value) }
        if let unit = nonEmptyString(params, "unit") { out["unit"] = unit }
        if let mode = nonEmptyString(params, "mode") { out["mode"] = mode }
        if let path = nonEmptyString(params, "project_expected_path") { out["project_expected_path"] = path }
        return out
    }

    private static func insertVerifiedParams(_ params: [String: Value]) -> [String: String] {
        var out: [String: String] = [:]
        if let track = intParamOrNil(params, "track") { out["track"] = String(track) }
        if let insert = intParamOrNil(params, "insert", "slot") { out["insert"] = String(insert) }
        if let plugin = nonEmptyString(params, "plugin", "plugin_id", "plugin_name") { out["plugin"] = plugin }
        if let mode = nonEmptyString(params, "mode") { out["mode"] = mode }
        if let path = nonEmptyString(params, "project_expected_path") { out["project_expected_path"] = path }
        return out
    }

    /// First non-empty string among `keys`, or nil. Trims whitespace so a blank
    /// value is treated as absent (the channel reports it as a schema error).
    private static func nonEmptyString(_ params: [String: Value], _ keys: String...) -> String? {
        for key in keys {
            guard let raw = params[key]?.stringValue else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // audit P2 #20: return the TRIMMED value, not the padded `raw` — the
            // doc promises a trimmed token and forwarding padding drifts the wire.
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
