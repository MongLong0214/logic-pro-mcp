import Foundation
import MCP

/// Cache-envelope helpers: wrap encoded resource bodies in the T7
/// `{cache_age_sec, fetched_at, ax_occluded[, extras], data}` shape.
/// `wrapWithCacheEnvelope` manual JSON splicing is INTENTIONAL (byte-identical).
extension ResourceHandlers {
    /// v3.1.0 (T7) — produce ISO8601 + cache_age_sec fields that every state
    /// resource wraps its payload in. `fetchedAt` is the cache's own clock;
    /// `cache_age_sec` is recomputed at read time so clients see the true
    /// age at the moment the resource is requested. Passing nil / distantPast
    /// collapses to `cache_age_sec: null` so clients can distinguish "never
    /// populated" from "populated X seconds ago".
    static func cacheEnvelope(fetchedAt: Date?) -> (ageSec: Any, fetchedAtISO: Any) {
        guard let fetchedAt, fetchedAt > .distantPast else {
            return (NSNull(), NSNull())
        }
        let age = Date().timeIntervalSince(fetchedAt)
        let iso = ISO8601DateFormatter.cacheFormatter.string(from: fetchedAt)
        return (age, iso)
    }

    /// Wrap an already-encoded JSON body (e.g. `[{...}]` or `{...}`) in the
    /// T7 cache envelope. Returns
    /// `{"cache_age_sec":…,"fetched_at":…,"ax_occluded":…[,extras…],"data":<body>}`.
    ///
    /// `ax_occluded` (v3.1.4): true when the StatePoller most recently observed
    /// a modal dialog or plugin floating window stealing AX focus from the
    /// arrange window. While occluded, cache values are deliberately preserved
    /// (no zero-out flap) — clients should treat the cache as "frozen at last
    /// non-occluded read" and decide whether to act on potentially-stale data.
    /// Defaults to false when `axOccluded` is omitted (caller didn't have
    /// access to the cache flag, e.g. when wrapping a synthesized body).
    ///
    /// `extras` (v3.1.8 — Issue #7): optional map of additional fields injected
    /// between `ax_occluded` and `data`. Used by tier-merging readers
    /// (`readProjectInfo`, `readTracks`, `readMixer`) to expose `source` (data
    /// provenance) and `last_saved_age_sec` (file mtime delta). When nil or
    /// empty, the envelope shape is byte-identical to v3.1.7. Keys are
    /// serialised in deterministic (sorted) order; unsupported value types
    /// (NSDate, custom classes, etc.) are skipped silently.
    static func wrapWithCacheEnvelope(
        bodyJSON: String,
        fetchedAt: Date?,
        axOccluded: Bool = false,
        extras: [String: Any]? = nil
    ) -> String {
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart: String = {
            if let a = age as? Double { return "\(a)" }
            return "null"
        }()
        let isoPart: String = {
            if let s = iso as? String { return "\"\(s)\"" }
            return "null"
        }()
        let extrasPart = encodeExtrasFragment(extras)
        return "{\"cache_age_sec\":\(agePart),\"fetched_at\":\(isoPart),\"ax_occluded\":\(axOccluded)\(extrasPart),\"data\":\(bodyJSON)}"
    }

    /// Serialise the optional extras map into a fragment that splices between
    /// `ax_occluded` and `data`. Returns an empty string when nil/empty so the
    /// envelope shape is byte-identical to v3.1.7 for callers passing nil.
    static func encodeExtrasFragment(_ extras: [String: Any]?) -> String {
        guard let extras, !extras.isEmpty else { return "" }
        // Filter unsupported types defensively; sortedKeys for determinism.
        let safe = extras.filter { _, value in JSONSerialization.isValidJSONObject(["v": value]) }
        guard !safe.isEmpty else { return "" }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
              var s = String(data: data, encoding: .utf8) else {
            return ""
        }
        // Strip outer braces, prefix with ","
        guard s.hasPrefix("{"), s.hasSuffix("}") else { return "" }
        s.removeFirst()
        s.removeLast()
        return s.isEmpty ? "" : ",\(s)"
    }
}
