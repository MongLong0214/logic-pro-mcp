import ApplicationServices
import Foundation

/// A sanitized AX snapshot — the atlas's baseline fixture format.
///
/// ADR-007 asks for `LogicProMCP ax-snapshot --scope … --redact --output …` and a criterion that
/// fixtures contain no user project, track or plugin names. Those two pull in opposite directions
/// unless the redaction is decided by construction, so it is:
///
/// **This is an allowlist, not a scrubber.** A snapshot carries the fields a selector can match on
/// and nothing else, and every free-text value is emitted only when it appears in
/// `AXLocalePolicy` — a label the product already recognises. A track called `Absolute Zero`, a
/// plugin called `Vintage EQ`, a project filename: none of them are in any policy set, so none of
/// them can reach the file. Scrubbing would have had to enumerate what to remove, and the thing a
/// scrubber has never heard of is exactly the thing a user named.
///
/// What survives redaction of an unrecognised string is its SHAPE — length and character classes —
/// which is enough to see a tree change and not enough to read a name back out.
enum AXSnapshot {

    struct Node: Codable, Equatable, Sendable {
        let role: String
        let subrole: String?
        /// A recognised label, or a shape like `len:13 latin+space` for anything else.
        let description: String?
        let help: String?
        let identifier: String?
        let valueRange: String?
        let children: [Node]
    }

    struct Document: Codable, Equatable, Sendable {
        let logicVersion: String
        let locale: String
        let scope: String
        let capturedFrom: String
        let root: Node
    }

    /// Every label the product recognises, flattened once.
    ///
    /// Membership in this set is the ONLY way a free-text value survives verbatim. It is built from
    /// `AXLocalePolicy` itself rather than a list kept beside it, so a label the product learns is a
    /// label a snapshot may show, and one it forgets stops appearing — without anyone remembering
    /// to update two places.
    static let recognisedLabels: Set<String> = {
        var out = Set<String>()
        for set in AXLocalePolicy.allLabelSets {
            for label in set.labels where !label.isEmpty {
                out.insert(label.lowercased())
            }
        }
        return out
    }()

    /// A recognised label verbatim, or a description of its shape.
    ///
    /// Case is preserved for a recognised label because a selector may match `.exactStrict`, and a
    /// snapshot that lower-cased everything would show a tree no selector could be tested against.
    /// Roles where Logic appends state to a description, so a recognised PREFIX is still a label.
    ///
    /// Scoped deliberately. The prefix allowance existed for `음소거, 켬` — a checkbox whose
    /// description carries its state — and applying it everywhere let a user's track name leak its
    /// first token: measured on a real capture, five `AXTextField` descriptions came out as
    /// `오디오…` because `오디오` is a variant in two policy sets and the tracks were named
    /// `오디오 1`, `오디오 2`. A track name's leading token is part of a track name.
    ///
    /// A text field's contents are user content by nature. Exact matches are always safe — the
    /// value IS a label the product knows — but a prefix is a concession, and it belongs only where
    /// the phenomenon it concedes to actually happens.
    /// Roles whose text is Logic's own chrome and cannot be something a user typed.
    ///
    /// The line that matters is not prefix-versus-contains, it is WHICH FIELDS CAN CARRY USER
    /// CONTENT. A track name lives in an `AXTextField`; a plugin name lives in an `AXGroup`
    /// description — both measured on this machine. A slider's `AXHelp` ("패닝 노브 및 밸런스
    /// 노브. …") and a checkbox's description are Logic's strings in every tree seen so far.
    ///
    /// Inside these roles a value keeps the recognised labels it CONTAINS, beside its shape. Outside
    /// them only an exact match survives, because a container or a text field is where a name would
    /// be — and `오디오 1` leaking `오디오` from a text field is what the first capture did.
    static let rolesCarryingOnlyChrome: Set<String> = [
        kAXSliderRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXSplitterRole as String,
        kAXDisclosureTriangleRole as String,
    ]

    static func redact(_ value: String?, role: String? = nil) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if recognisedLabels.contains(value.lowercased()) { return value }
        guard let role, rolesCarryingOnlyChrome.contains(role) else { return shape(of: value) }

        // Only allowlist members are emitted, never the text around them — so a chrome string keeps
        // enough for a `.contains` selector to be scored against this fixture, which is what a
        // baseline is FOR. Over-redacting here is safe and useless: the pan selector scored 0.583
        // against a fixture that had shaped its help sentence away, below its own threshold.
        let haystack = value.lowercased()
        let found = recognisedLabels
            .filter { !$0.isEmpty && haystack.contains($0) }
            .sorted { $0.count > $1.count }
        guard !found.isEmpty else { return shape(of: value) }
        return "\(found.prefix(4).joined(separator: " ")) | \(shape(of: value))"
    }

    /// `len:13 latin+space` — enough to notice a tree changed, not enough to read a name.
    static func shape(of value: String) -> String {
        var classes = Set<String>()
        for scalar in value.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) { classes.insert("digit") }
            else if CharacterSet.whitespaces.contains(scalar) { classes.insert("space") }
            else if scalar.value < 128, CharacterSet.letters.contains(scalar) { classes.insert("latin") }
            else if CharacterSet.letters.contains(scalar) { classes.insert("non-latin") }
            else { classes.insert("punct") }
        }
        return "len:\(value.count) \(classes.sorted().joined(separator: "+"))"
    }

    static func capture(
        _ element: AXUIElement,
        depth: Int = 0,
        maxDepth: Int = 6,
        runtime: AXHelpers.Runtime = .production
    ) -> Node {
        let minValue: Double? = AXHelpers.getAttribute(
            element, kAXMinValueAttribute as String, runtime: runtime)
        let maxValue: Double? = AXHelpers.getAttribute(
            element, kAXMaxValueAttribute as String, runtime: runtime)
        var range: String?
        if let low = minValue, let high = maxValue {
            range = "\(Int(low))...\(Int(high))"
        }

        let children: [Node] = depth >= maxDepth ? [] : AXHelpers
            .getChildren(element, runtime: runtime)
            .map { capture($0, depth: depth + 1, maxDepth: maxDepth, runtime: runtime) }

        let role = AXHelpers.getRole(element, runtime: runtime) ?? ""
        return Node(
            role: role,
            subrole: AXHelpers.getAttribute(element, kAXSubroleAttribute as String, runtime: runtime),
            description: redact(AXHelpers.getDescription(element, runtime: runtime), role: role),
            help: redact(AXHelpers.getHelp(element, runtime: runtime), role: role),
            // Identifiers are Logic's own, never a user string — but they are redacted through the
            // same path anyway, so nothing reaches the file by a route the allowlist does not see.
            identifier: redact(AXHelpers.getIdentifier(element, runtime: runtime), role: role),
            valueRange: range,
            children: children
        )
    }
}
