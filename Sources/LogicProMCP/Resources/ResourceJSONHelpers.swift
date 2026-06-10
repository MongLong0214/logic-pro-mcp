import Foundation

/// Shared JSON plumbing for static catalog resources (stock plugins, workflow
/// skills). Kept in one file so independent feature branches can add their own
/// resource handlers without colliding on duplicated private helpers.
extension ResourceHandlers {
    /// Decoded value of a single query item. `URLComponents` already
    /// percent-decodes `value`; no second decode is applied.
    static func queryItemValue(from uri: String, name: String) -> String? {
        URLComponents(string: uri)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    static func jsonObject<T: Encodable>(_ value: T) -> Any {
        let text = encodeJSON(value, compact: true)
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [:]
    }

    static func encodeJSONObject(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":"resource JSON encoding failed"}"#
        }
        return text
    }
}
