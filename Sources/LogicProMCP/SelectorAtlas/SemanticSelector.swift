import Foundation

enum SelectorID: String, CaseIterable, Sendable {
    case transportPlayButton
    case trackHeaderNameField
    case mixerStripVolumeFader
    case mixerStripSendSlot
    case pluginWindowTitle
    case pluginParameterControl
    case projectSaveFilenameField
}

struct AncestorConstraint: Equatable, Sendable {
    let role: String
}

enum AttributePredicate: Equatable, Sendable {
    case axIdentifier(String)

    /// Any of `attributes` matching any of `labels` under `mode`.
    ///
    /// One predicate with a mode, rather than one case per matching style. Four had accumulated —
    /// equality, containment, containment-against-a-set, and containment across a set of attributes
    /// — each added when a call site needed it, and the toggle locators would have needed a fifth
    /// for exact-or-prefix. That is the atlas becoming a union of the ad-hoc rules it exists to
    /// replace.
    ///
    /// The mode is `AXLocalePolicy.MatchMode`, which the product has always had and which already
    /// enumerates exactly these: `.exact` trims and compares, `.exactStrict` compares verbatim,
    /// `.prefix` tolerates the trailing state suffixes some Logic builds append to a checkbox
    /// description, `.contains` is a substring. Reusing it means a selector and the accessor it
    /// replaces can express the same rule, which is the whole point of adopting one over the other.
    ///
    /// Multiple attributes are ORed and multiple labels are ORed — a name may live in `AXHelp` on
    /// one control and `AXDescription` on another, which is measured, not assumed.
    case attributes([String], anyOf: [String], mode: AXLocalePolicy.MatchMode)

    case valueSignature(String)
}

struct GeometryHint: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum AmbiguityPolicy: Equatable, Sendable {
    case failClosed
    case highestConfidenceWins
}

struct SemanticSelector: Sendable {
    let id: SelectorID
    let requiredRole: String
    let allowedSubroles: Set<String>
    let titleAliases: [String: [String]]
    let ancestorConstraints: [AncestorConstraint]
    let attributePredicates: [AttributePredicate]
    let geometryHint: GeometryHint?
    let minimumConfidence: Double
    let ambiguityPolicy: AmbiguityPolicy
}

/// How much of the evidence this selector ASKED FOR the candidate actually carries.
///
/// The weights keep ADR-007's evidence priority — identifier, then ancestor chain and attributes,
/// then title, then value signature, with geometry last — but they are a ratio now, not a budget.
///
/// The budget was the defect. It awarded 0.55 of a possible 1.0 for an exact `AXIdentifier`, so an
/// element without one could never exceed 0.45 however much else it matched. Measured on Logic
/// 12.x, the track-header sliders expose no `AXIdentifier` at all: a pan slider satisfying every
/// predicate its selector named scored 0.40 and `minimumConfidence: 0.6` refused it. A model that
/// cannot resolve the elements the product addresses is not a strict model, it is an unusable one —
/// and lowering every threshold to 0.4 instead would leave the tiers decorative and publish a
/// confidence nothing measures.
///
/// Normalising over what was requested fixes that without weakening anything: a selector that asks
/// for an identifier and does not get one still scores low, because the identifier is in its
/// denominator. A selector that asks for role, ancestors and an `AXHelp` substring, and gets all
/// three, scores 1.0 — which is the truth about that selector and that element.
///
/// Two floors survive from the old model and one is new:
///
///   - a candidate whose role or subrole is wrong scores 0, before anything else is considered
///   - geometry alone cannot exceed 0.49, which is ADR-007's acceptance criterion
///   - role alone cannot exceed 0.49 either. Under a ratio a selector naming ONLY a role would
///     otherwise score 1.0 for matching a role, and "it is a slider" is not an identification.
func confidence(of candidate: ResolvableCandidate, against selector: SemanticSelector) -> Double {
    guard candidate.role == selector.requiredRole else { return 0 }
    guard selector.allowedSubroles.isEmpty
        || candidate.subrole.map(selector.allowedSubroles.contains) == true else { return 0 }

    /// (weight, requested, satisfied, isGeometry) in ADR-007's priority order.
    var evidence: [(weight: Double, requested: Bool, satisfied: Bool, isGeometry: Bool)] = []

    let identifiers = selector.attributePredicates.compactMap { predicate -> String? in
        guard case let .axIdentifier(value) = predicate else { return nil }
        return value
    }
    evidence.append((0.40, !identifiers.isEmpty,
                     candidate.axIdentifier.map(identifiers.contains) == true, false))

    evidence.append((0.20, !selector.ancestorConstraints.isEmpty,
                     matchesAncestorChain(candidate.ancestors, selector.ancestorConstraints), false))

    let attributeRules = selector.attributePredicates.compactMap {
        predicate -> ([String], [String], AXLocalePolicy.MatchMode)? in
        guard case let .attributes(names, anyOf: labels, mode: mode) = predicate else { return nil }
        return (names, labels, mode)
    }
    evidence.append((0.20, !attributeRules.isEmpty,
                     attributeRules.allSatisfy { names, labels, mode in
                         let set = AXLocalePolicy.LabelSet(
                             canonical: labels.first ?? "",
                             variants: Array(labels.dropFirst()),
                             rationale: "selector predicate")
                         return names.contains { name in
                             guard let value = candidate.attributes[name] else { return false }
                             return mode == .contains
                                 ? set.containsAny(in: value)
                                 : set.matches(value, mode: mode)
                         }
                     }, false))

    let aliases = selector.titleAliases.values.flatMap { $0 }
    evidence.append((0.10, !aliases.isEmpty,
                     candidate.title.map { title in
                         aliases.contains { title.caseInsensitiveCompare($0) == .orderedSame }
                     } ?? false, false))

    let signatures = selector.attributePredicates.compactMap { predicate -> String? in
        guard case let .valueSignature(value) = predicate else { return nil }
        return value
    }
    evidence.append((0.08, !signatures.isEmpty,
                     candidate.valueSignature.map(signatures.contains) == true, false))

    evidence.append((0.02, selector.geometryHint != nil,
                     selector.geometryHint != nil && selector.geometryHint == candidate.geometry, true))

    let requested = evidence.filter(\.requested)
    // A selector that named nothing but a role has identified nothing.
    guard !requested.isEmpty else { return 0.25 }

    let denominator = requested.reduce(0) { $0 + $1.weight }
    let numerator = requested.filter(\.satisfied).reduce(0) { $0 + $1.weight }
    let score = denominator > 0 ? numerator / denominator : 0

    // Identified by its flag, not by position. `requested` is filtered, so geometry may not be its
    // last element — or present at all — and the first draft's `dropLast()` silently capped a
    // selector that asked only for an identifier and got it. Its own test caught that.
    let satisfiedBeyondGeometry = requested.contains { $0.satisfied && !$0.isGeometry }
    if !satisfiedBeyondGeometry { return min(score, 0.49) }
    return min(max(score, 0), 1)
}

private func matchesAncestorChain(
    _ ancestors: [String],
    _ constraints: [AncestorConstraint]
) -> Bool {
    var nextIndex = ancestors.startIndex
    for constraint in constraints {
        guard let match = ancestors[nextIndex...].firstIndex(of: constraint.role) else { return false }
        nextIndex = ancestors.index(after: match)
    }
    return true
}
