import ApplicationServices
import Foundation

/// Builds a `ResolvableCandidate` from a live AX element.
///
/// This is what the atlas was missing. `SemanticSelector`, `resolve` and `UIDriftReport` were all
/// written and none of them could be called from the product, because nothing turned an
/// `AXUIElement` into the value type they operate on — so every accessor kept its own hand-rolled
/// predicate and the atlas sat unused beside them.
///
/// What it reads, and why each one:
///
///   - `AXIdentifier` — the model's strongest evidence. Measured absent on Logic's track-header
///     elements, which is why the scoring had to stop assuming it.
///   - role and subrole — the gate; a wrong role scores zero before anything else is considered.
///   - title, and `AXHelp`/`AXDescription` as attributes. Logic puts a control's NAME in `AXHelp`
///     on at least the header pan slider, so an adapter that read only title and description would
///     hand the resolver a candidate with nothing to match.
///   - `valueSignature` as `min...max`. It is what separates a pan slider (`0...127`) from a volume
///     fader (`0...233`) on the same header, and unlike the help text it does not depend on locale.
///   - geometry, last and worth 0.02, because ADR-007 says geometry alone cannot identify anything.
enum AXResolvableCandidate {

    /// Attributes the adapter publishes into `ResolvableCandidate.attributes`.
    ///
    /// A fixed list rather than "every attribute the element has": the selector names what it wants
    /// by key, and an open-ended dictionary would make a selector's meaning depend on which
    /// attributes a particular Logic build happens to expose.
    static let publishedAttributes = [
        kAXHelpAttribute as String,
        kAXDescriptionAttribute as String,
        kAXRoleDescriptionAttribute as String,
    ]

    static func make(
        from element: AXUIElement,
        ancestors: [String] = [],
        runtime: AXHelpers.Runtime = .production
    ) -> ResolvableCandidate {
        var attributes: [String: String] = [:]
        for name in publishedAttributes {
            if let value: String = AXHelpers.getAttribute(element, name, runtime: runtime),
               !value.isEmpty {
                attributes[name] = value
            }
        }

        let minValue: Double? = AXHelpers.getAttribute(
            element, kAXMinValueAttribute as String, runtime: runtime)
        let maxValue: Double? = AXHelpers.getAttribute(
            element, kAXMaxValueAttribute as String, runtime: runtime)
        // Only when BOTH bounds read. A half-known range is not a signature, and formatting one
        // would let a selector match on a number the element never reported.
        var signature: String?
        if let low = minValue, let high = maxValue {
            signature = "\(Self.trim(low))...\(Self.trim(high))"
        }

        return ResolvableCandidate(
            axIdentifier: AXHelpers.getIdentifier(element, runtime: runtime),
            role: AXHelpers.getRole(element, runtime: runtime) ?? "",
            subrole: AXHelpers.getAttribute(element, kAXSubroleAttribute as String, runtime: runtime),
            title: AXHelpers.getTitle(element, runtime: runtime),
            ancestors: ancestors,
            attributes: attributes,
            valueSignature: signature,
            geometry: nil
        )
    }

    /// `0...127`, not `0.0...127.0`. The signature is compared as a string, so its formatting is
    /// part of the contract a selector writes against.
    private static func trim(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }
}
