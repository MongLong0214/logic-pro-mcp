import Foundation

/// Makes an `initialize` request that follows the MCP schema decodable by the swift-sdk (#1048).
///
/// The schema types a client's `capabilities.experimental` as `{ [key: string]: object }`. swift-sdk
/// 0.12.1 — the pinned version, and still the type on its main branch — declares it `[String: String]?`.
/// A client that sends an object there makes `Initialize.Parameters` fail to decode, and the SDK answers
/// the handshake with `-32603 Internal error: The data couldn't be read because it isn't in the correct
/// format.` The client in #1048 sends an object-valued entry on every start, so it could not connect.
///
/// The rewrite keeps the entries whose value is a string and drops every other value. Dropping is safe
/// because nothing in this server reads the client's experimental capabilities: neither
/// `server.start(transport:)` call installs an `initializeHook`, which is the only place the SDK hands
/// them to server code. A string is kept because it is the one shape the SDK can carry.
///
/// Every other frame is returned as the same bytes. That includes a JSON-RPC batch: the MCP lifecycle
/// (2025-03-26) says the initialize request MUST NOT be part of one, and 2025-06-18 removed batching.
enum InitializeExperimentalFilter {
    struct Outcome {
        let frame: Data
        /// Sorted. Empty when the frame was returned unchanged.
        let droppedKeys: [String]
    }

    static func filter(_ frame: Data) -> Outcome {
        let unchanged = Outcome(frame: frame, droppedKeys: [])
        guard var message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any]
        else { return unchanged }
        let dropped = experimental.filter { !($0.value is String) }.map(\.key).sorted()
        guard !dropped.isEmpty else { return unchanged }
        capabilities["experimental"] = experimental.filter { $0.value is String }
        params["capabilities"] = capabilities
        message["params"] = params
        guard let rewritten = try? JSONSerialization.data(withJSONObject: message,
                                                          options: [.withoutEscapingSlashes])
        else { return unchanged }
        return Outcome(frame: rewritten, droppedKeys: dropped)
    }
}
