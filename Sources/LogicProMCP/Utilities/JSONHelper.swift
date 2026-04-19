import Foundation

// MARK: - ISO8601 with fractional seconds
//
// Swift's `JSONEncoder.DateEncodingStrategy.iso8601` uses
// `ISO8601DateFormatter` configured with `[.withInternetDateTime]` only
// — it drops fractional seconds. Logger's timestamp formatter uses
// `[.withInternetDateTime, .withFractionalSeconds]` and several resources
// (e.g. `logic://mcu/state.connection.lastFeedbackAt`) carry sub-second
// precision that matters for staleness detection. Use one formatter in both
// encoders + decoder so the wire format stays consistent across the server.

private nonisolated(unsafe) let iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let iso8601FormatterLock = NSLock()

private func encodeDate(_ date: Date, to encoder: Encoder) throws {
    iso8601FormatterLock.lock()
    let str = iso8601WithFractional.string(from: date)
    iso8601FormatterLock.unlock()
    var container = encoder.singleValueContainer()
    try container.encode(str)
}

private func decodeDate(from decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let str = try container.decode(String.self)
    iso8601FormatterLock.lock()
    let date = iso8601WithFractional.date(from: str)
    iso8601FormatterLock.unlock()
    guard let date else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected ISO8601 with fractional seconds, got \(str)"
        )
    }
    return date
}

// MARK: - Shared encoder/decoder singletons
//
// JSONEncoder/JSONDecoder allocation is non-trivial (dateFormatter setup,
// options propagation). Reusing a single instance per format avoids ~70
// per-call allocations across MCP tool responses.
//
// `JSONEncoder.encode(_:)` is NOT documented as thread-safe; concurrent calls
// on the same instance race on internal state. MCP tool handlers run on
// separate async tasks and can overlap, so we gate each encode under a lock.
// The critical section is microseconds long and bounded by encode cost, which
// is still cheaper than per-call encoder allocation under realistic loads.
// `JSONDecoder.decode(_:from:)` has the same contract and is gated likewise.

private nonisolated(unsafe) let sharedPrettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .custom(encodeDate)
    return encoder
}()

private nonisolated(unsafe) let sharedCompactEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .custom(encodeDate)
    return encoder
}()

private nonisolated(unsafe) let sharedDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeDate)
    return decoder
}()

private let sharedCodecLock = NSLock()

private func lockedEncode<T: Encodable>(_ value: T, compact: Bool) throws -> Data {
    sharedCodecLock.lock(); defer { sharedCodecLock.unlock() }
    return try (compact ? sharedCompactEncoder : sharedPrettyEncoder).encode(value)
}

private func lockedDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    sharedCodecLock.lock(); defer { sharedCodecLock.unlock() }
    return try sharedDecoder.decode(type, from: data)
}

// MARK: - Public API

/// Encode any `Encodable` value to a JSON string for MCP tool responses.
/// Never throws — on failure, returns a structured `{"error": ...}` payload
/// naming the failing type and the underlying cause. Use for hot paths where
/// a failure string is an acceptable fallback.
///
/// - Parameters:
///   - value: The value to encode.
///   - compact: When `true`, omits pretty-printing (useful for large payloads
///     like MIDI port enumerations). Default `false` keeps human-readable output.
func encodeJSON<T: Encodable>(_ value: T, compact: Bool = false) -> String {
    do {
        let data = try lockedEncode(value, compact: compact)
        return String(data: data, encoding: .utf8)
            ?? #"{"error":"UTF-8 decode failed for \#(T.self)"}"#
    } catch {
        let typeName = jsonStringEscape(String(describing: T.self))
        let reason = jsonStringEscape(error.localizedDescription)
        return "{\"error\":\"Failed to encode \(typeName): \(reason)\"}"
    }
}

/// RFC 8259-safe JSON string escape. Handles `"`, `\`, and U+0000-U+001F
/// control characters. Exported for callers that hand-build JSON payloads
/// (e.g. fallback paths where `JSONEncoder` itself has failed).
func jsonStringEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case let c where c.value < 0x20:
            out += String(format: "\\u%04x", c.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Strict variant that surfaces encoding failures via `throws`.
/// Use when the caller needs to branch on success/failure rather than
/// embedding a fallback error string in the output.
func encodeJSONStrict<T: Encodable>(_ value: T, compact: Bool = false) throws -> String {
    let data = try lockedEncode(value, compact: compact)
    guard let string = String(data: data, encoding: .utf8) else {
        throw JSONHelperError.utf8DecodingFailed(typeName: String(describing: T.self))
    }
    return string
}

/// Decode a JSON string into any `Decodable` type. Throws on malformed
/// input, schema mismatch, or invalid UTF-8.
func decodeJSON<T: Decodable>(_ string: String) throws -> T {
    guard let data = string.data(using: .utf8) else {
        throw JSONHelperError.invalidUTF8
    }
    return try lockedDecode(T.self, from: data)
}

/// Error cases surfaced by the strict JSON API.
enum JSONHelperError: Error, CustomStringConvertible {
    case utf8DecodingFailed(typeName: String)
    case invalidUTF8

    var description: String {
        switch self {
        case .utf8DecodingFailed(let typeName):
            return "UTF-8 decode failed for \(typeName)"
        case .invalidUTF8:
            return "Input string is not valid UTF-8"
        }
    }
}
