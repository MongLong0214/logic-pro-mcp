import Foundation

/// Identity + capability resolution for the verified-plugin surface
/// (`logic_plugins.*`). Kept separate from the large `StockPluginCatalog`
/// discovery layer so the verified path has a single, narrowly-scoped place to
/// answer three questions per requirements §5.2 / R5 / R6:
///
///   1. canonical plugin identity — map a caller alias (display name `"Gain"`,
///      bare catalog suffix `gain`, or a full `logic.stock.effect.*` id) to the
///      canonical catalog id, or refuse (`unknown_plugin_identity`, AC11).
///   2. canonical parameter key — map a parameter alias (`gain` → `gain_db`) to
///      the verified public key (R5: "구현 전에 `gain -> gain_db` alias를 명시").
///   3. write/readback capability — does the resolved plugin/param actually
///      have a write method AND a display-readback parser? (R6 step 5 preflight;
///      Compressor `threshold` is the first verified-writable parameter
///      (`writeMethod`/`readbackMethod` both `ax_slider_axvalue`) → `.writeReadback`,
///      while Gain still has neither — `writeMethod:nil, readbackMethod:nil` — so
///      it stays the honest State C `unsupported_param_readback`.)
///
/// This module is deterministic and contains NO live AX interaction.
enum VerifiedPluginCatalog {

    /// Display-name / alias → canonical `logic.stock.*` id table.
    ///
    /// MVP scope (R5): the four allowlisted stock plugins. Compressor `threshold`
    /// is the first verified parameter-write target (audit #28); the others
    /// (including Gain) are identity/insert only. Display
    /// names are accepted as user-facing aliases but never become the identity
    /// themselves (requirements §5.2 "display name은 identity가 아니라 alias").
    private static let pluginAliases: [String: String] = [
        "gain": "logic.stock.effect.gain",
        "logic.stock.effect.gain": "logic.stock.effect.gain",
        "channel eq": "logic.stock.effect.channel_eq",
        "channeleq": "logic.stock.effect.channel_eq",
        "logic.stock.effect.channel_eq": "logic.stock.effect.channel_eq",
        "compressor": "logic.stock.effect.compressor",
        "logic.stock.effect.compressor": "logic.stock.effect.compressor",
        "noise gate": "logic.stock.effect.noise_gate",
        "noisegate": "logic.stock.effect.noise_gate",
        "logic.stock.effect.noise_gate": "logic.stock.effect.noise_gate",
    ]

    /// Per-plugin parameter-key alias table: caller key → canonical catalog
    /// parameter id. The public verified API uses `gain_db` (unit-explicit)
    /// while the catalog entry's parameter id is still `gain` (R5); both resolve
    /// to the catalog id so the capability lookup can find the parameter.
    private static let paramAliases: [String: [String: String]] = [
        "logic.stock.effect.gain": [
            "gain": "gain",
            "gain_db": "gain",
        ],
        // Compressor `threshold` is the first verified-writable parameter (T5,
        // T0 spike). The public key and the catalog parameter id are both
        // `threshold` (normalized %, NOT dB) — see `StockPluginCatalog`.
        "logic.stock.effect.compressor": [
            "threshold": "threshold",
        ],
    ]

    /// Resolve a caller-supplied plugin alias to its canonical catalog id, or
    /// nil when no explicit alias mapping exists (→ State C
    /// `unknown_plugin_identity`, AC11). Matching is case- and
    /// whitespace-insensitive; a full canonical id is accepted only if it is a
    /// known catalog id (so an unbacked `com.apple.logic.gain` still fails).
    static func canonicalPluginID(from alias: String) -> String? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return pluginAliases[normalized]
    }

    /// Resolve a caller-supplied parameter alias to the catalog parameter id for
    /// a (already-canonical) plugin id, or nil when the plugin declares no such
    /// parameter alias.
    static func canonicalParamKey(pluginID: String, alias: String) -> String? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return paramAliases[pluginID]?[normalized]
    }

    /// Map a slot's observed display name (from AX readback) to a canonical
    /// catalog id for `get_inventory.plugins[].plugin_id`, or nil when the name
    /// does not match an allowlisted stock plugin. Reuses the same alias table
    /// as caller-input resolution so the two stay consistent.
    static func pluginID(forObservedName name: String) -> String? {
        canonicalPluginID(from: name)
    }

    /// Result of the R6 step-5 capability preflight.
    enum ParamCapability: Equatable {
        /// Plugin or parameter is not in the verified allowlist at all.
        case unknownParameter
        /// Parameter exists but lacks a write method and/or a display-readback
        /// parser — writing it could never be confirmed, so it is State C
        /// `unsupported_param_readback` BEFORE any write (R6, AC10).
        case unsupported
        /// Parameter has both a write method and a readback parser. Eligible for
        /// a verified State A write. (Compressor `threshold` is the first MVP
        /// parameter to reach this — see `StockPluginCatalog`; Gain does not.)
        case writeReadback
    }

    /// Look up whether a (canonical) plugin/param can be written AND read back.
    /// Drives R6 step 5: only `.writeReadback` may proceed past preflight; every
    /// other result is a write-blocking State C.
    ///
    /// `unit` is validated against the catalog parameter's declared unit (R2/R8:
    /// "param map이 선언하지 않은 unit은 State C `invalid_params`"); a mismatch is
    /// reported by the caller as `invalid_params`, so this returns the capability
    /// independent of unit and exposes the expected unit separately.
    static func paramCapability(pluginID: String, paramKey: String) -> ParamCapability {
        guard let entry = StockPluginCatalog.entry(id: pluginID),
              let param = entry.parameters.first(where: { $0.id == paramKey }) else {
            return .unknownParameter
        }
        let hasWrite = !(param.writeMethod?.isEmpty ?? true)
        let hasReadback = !(param.readbackMethod?.isEmpty ?? true)
        return (hasWrite && hasReadback) ? .writeReadback : .unsupported
    }

    /// The canonical unit a (canonical) plugin parameter declares, or nil when
    /// the parameter is unknown. Used to enforce unit honesty (R8) before a
    /// write: a caller `unit` that disagrees is `invalid_params`.
    static func paramUnit(pluginID: String, paramKey: String) -> String? {
        StockPluginCatalog.entry(id: pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.unit
    }

    /// The valid display-value range a (canonical) plugin parameter declares, or
    /// nil when unknown. Used for range validation (R6 step 1).
    static func paramRange(pluginID: String, paramKey: String) -> StockPluginValueRange? {
        StockPluginCatalog.entry(id: pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.valueRange
    }

    /// The live `AXDescription` string that identifies a (canonical) plugin
    /// parameter's `AXSlider` inside the plugin window (T0 evidence), or nil when
    /// the parameter has no stable description matcher. The verified write path
    /// (R6 step 9) matches a window slider by this description; a parameter
    /// without one cannot reach a verified write (it stays `.unsupported`).
    static func paramAXDescription(pluginID: String, paramKey: String) -> String? {
        StockPluginCatalog.entry(id: pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.axDescription
    }

    /// The verified write/readback tolerance (in the parameter's own unit) for a
    /// (canonical) plugin parameter, or nil when unknown / not verified-writable.
    /// R6 step 13: |observed - requested| <= tolerance ⇒ State A.
    static func paramTolerance(pluginID: String, paramKey: String) -> Double? {
        StockPluginCatalog.entry(id: pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.tolerance
    }
}
