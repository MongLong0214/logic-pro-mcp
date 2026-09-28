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
    /// The report names at most this many dropped keys and counts the rest.
    static let reportedKeyLimit = 3
    /// A named key shows at most this many of its Characters, cut on a Character boundary.
    static let reportedKeyCharacterLimit = 64
    /// A named key takes at most this many bytes once escaped: room for 64 Characters of up to four
    /// UTF-8 bytes each. The Character limit alone does not bound the line, because one Character can be
    /// any number of bytes: a letter followed by any number of combining marks.
    static let reportedKeyByteLimit = 256
    /// The most bytes the report takes. The transport logs it on its read thread before it hands the
    /// request to the SDK, and the logger writes to stderr synchronously, so a report as long as the
    /// client's keys could fill a stderr pipe the client does not drain and hold back the reply.
    /// By construction the report is at most 948 bytes: 121 of text, 3 keys of 256 bytes each with
    /// their quotes and a 6-byte cut marker, 2 separators and brackets, and a count of up to 19 digits.
    static let reportByteLimit = 1024

    struct Outcome {
        let frame: Data
        /// Sorted. Empty when the frame was returned unchanged.
        let droppedKeys: [String]

        /// One line for stderr naming the dropped keys, never their values, in at most
        /// `reportByteLimit` bytes; nil when nothing was dropped.
        var report: String? {
            guard !droppedKeys.isEmpty else { return nil }
            let named = droppedKeys.prefix(InitializeExperimentalFilter.reportedKeyLimit)
                .map(InitializeExperimentalFilter.reportedKey)
            let unnamed = droppedKeys.count - named.count
            return "initialize: dropped the client's experimental capabilities whose value is not a "
                + "string, which the MCP SDK cannot decode: [\(named.joined(separator: ", "))]"
                + (unnamed > 0 ? " and \(unnamed) more" : "")
        }
    }

    /// `key` as a quoted, escaped string cut to the limits above, followed by ` (cut)` when it was cut.
    static func reportedKey(_ key: String) -> String {
        var body = ""
        var keptBytes = 0
        for character in key.prefix(reportedKeyCharacterLimit) {
            let piece = escaped(String(character))
            guard body.utf8.count + piece.utf8.count <= reportedKeyByteLimit else { break }
            body += piece
            keptBytes += character.utf8.count
        }
        return "\"\(body)\"" + (keptBytes < key.utf8.count ? " (cut)" : "")
    }

    /// `text` escaped as the inside of a JSON string, so nothing in a key can end the log line or
    /// start a forged one. JSONSerialization escapes only the quote, the backslash and U+0000-U+001F;
    /// this also escapes U+007F-U+009F (NEL, U+0085, among them) and the separators U+2028 and U+2029.
    static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                switch scalar.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator:
                    out += String(format: "\\u%04x", scalar.value)
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
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
