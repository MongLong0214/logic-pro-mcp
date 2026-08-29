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
        // The role gate comes FIRST, and an exact match does not get past it.
        //
        // It used to: `recognisedLabels.contains(value.lowercased())` returned the value verbatim
        // before the role was considered, on the reasoning that "the value IS a label the product
        // knows". That is a statement about the string, not about where it came from — and a track
        // named `Solo`, `Audio` or `Region` is a user's name that happens to spell a label. `audio`
        // is declared in two policy sets, so `Audio` in a text field would have reached the file
        // intact. Naming the roles that can carry user text and shaping everything in them costs
        // nothing: no adopted selector matches a text field, a group or a layout item.
        guard let role, rolesCarryingOnlyChrome.contains(role) else { return shape(of: value) }
        if recognisedLabels.contains(value.lowercased()) { return value }

        // Only allowlist members are emitted, never the text around them — so a chrome string keeps
        // enough for a `.contains` selector to be scored against this fixture, which is what a
        // baseline is FOR. Over-redacting here is safe and useless: the pan selector scored 0.583
        // against a fixture that had shaped its help sentence away, below its own threshold.
        //
        // EVERY match, and a total order over them.
        //
        // This used to keep the four longest. Two things went wrong with that, and the first English
        // capture showed the symptom: three checkboxes carrying nearly the same 193-character help
        // sentence rendered as `mixer track play mute` and `mixer track mute play`. Whichever
        // labels tie at four characters, only some of them fit in four slots — so which ones
        // survive depends on the rest of the matched set, and `Set` iteration is seeded per process,
        // so it can also depend on which process wrote the file.
        //
        // I did not reproduce a cross-process difference; three captures of the same tree hash
        // identically. The claim here is narrower and enough on its own: truncation makes the output
        // a function of more than its input, and a selector scored against a fixture can be looking
        // for a label that the cut dropped. Keeping all of them is bounded by the allowlist, and
        // sorting by length THEN by the label itself is a total order where length alone was not.
        let haystack = value.lowercased()
        let found = recognisedLabels
            .filter { !$0.isEmpty && haystack.contains($0) }
            .sorted { ($0.count, $1) > ($1.count, $0) }
        guard !found.isEmpty else { return shape(of: value) }
        return "\(found.joined(separator: " ")) | \(shape(of: value))"
    }

    /// An identifier is always a shape. No role earns it a concession, and neither does its content.
    ///
    /// The containment concession reports the labels found INSIDE a value, which is right for a help
    /// sentence Logic wrote and wrong for an identifier. The exact-match concession is wrong here
    /// too, for the same reason it was wrong on a text field: `Solo` is a label the product knows
    /// AND a plausible name, and an identifier equal to it would have walked out verbatim on a
    /// slider. Measured on Logic 12.3, the track-header elements expose no identifier at all — so
    /// the concession would only ever apply to a value this code has never seen, which is the worst
    /// place to be generous. Nothing is lost: an identifier the atlas could match on would be
    /// Logic's own, and a selector that needs one is a selector this capture cannot serve anyway.
    static func redactIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return shape(of: value)
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

    /// The root of a scoped capture, keeping the identity the scope already records.
    ///
    /// A container's own description is shaped like any other group's, and for the control bar that
    /// is the whole identity — `컨트롤 막대` is what `controlBarSelector` matches, so no committed
    /// baseline could score `.controlBar` at all.
    ///
    /// Restoring it on the ROOT of a scoped capture costs nothing, and the reason is arithmetic
    /// rather than judgement: `Document.scope` already carries that exact string, written by the
    /// caller who asked for it. A file that says `"scope": "컨트롤 막대"` and a root described
    /// `len:6 non-latin+space` reveals precisely as much as one that describes the root by name.
    ///
    /// And only when the scope is a label the product recognises. An operator can aim a capture at
    /// any container by description, including one Logic named after a plugin — that string is the
    /// operator's to type, but it is not one this code will copy into a second field.
    /// It also has to have BEEN the description, and the caller has to be able to say so.
    ///
    /// `scope` here is not the argument someone typed — it is a value READ BACK from the element's
    /// own description. Only the named `control-bar` capture can supply that, because only it
    /// resolves through `getControlBar` and then asks the resulting element what it is called. A
    /// generic scope matches title OR description, and `--ax-snapshot-scope window` matches
    /// neither; writing the scope in on those paths would put a string into a field the element
    /// never held, which is manufacturing evidence for a selector to score against.
    ///
    /// The shape check stays as the second lock, not the first. It is lossy on its own — a title
    /// `Mixer` beside an unrelated description `Serum` both render `len:5 latin` — so it can
    /// confirm a value the caller already read, and cannot establish one it did not.
    /// Scopes whose root element is resolved by a product predicate, not by matching a description.
    ///
    /// Only these may have their root's description restored, and the reason is which question the
    /// capture can answer. `control-bar` resolves through `getControlBar` and then asks the element
    /// what it is called, so the label is a READ-BACK. Every other scope matches a string against
    /// title or description without recording which one hit, and `window` matches nothing at all.
    static let scopesResolvedByPredicate: Set<String> = ["control-bar"]

    /// The description a capture may restore on its root, or nil.
    ///
    /// Extracted so the rule can be tested where it is decided. Left inside the capture command it
    /// was a call-site convention: widening it to every scope compiles, passes, and only shows up in
    /// the next fixture someone captures — which is the shape of a rule with no test.
    static func restorableRootDescription(
        scope: String, resolvedDescription: String?
    ) -> String? {
        scopesResolvedByPredicate.contains(scope) ? resolvedDescription : nil
    }

    static func scopedRoot(_ node: Node, readBackDescription scope: String) -> Node {
        guard recognisedLabels.contains(scope.lowercased()),
              node.description == shape(of: scope)
        else { return node }
        return Node(
            role: node.role, subrole: node.subrole, description: scope, help: node.help,
            identifier: node.identifier, valueRange: node.valueRange, children: node.children)
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
            identifier: redactIdentifier(AXHelpers.getIdentifier(element, runtime: runtime)),
            valueRange: range,
            children: children
        )
    }
}
