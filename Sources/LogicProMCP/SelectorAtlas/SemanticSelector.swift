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
    case attribute(String, equals: String)

    /// Substring match on an attribute, case-insensitively.
    ///
    /// Added because equality could not express the evidence Logic actually offers. The
    /// discriminator that identifies a track-header pan slider is the word `밸런스` inside an
    /// `AXHelp` that reads "패닝 노브 및 밸런스 노브. 트랙 신호를 스테레오 필드에 위치하려면 수직으로
    /// 드래그합니다." — an equality predicate there pins a whole localized sentence, so it breaks on
    /// any wording change and cannot be written for a locale nobody has measured.
    case attributeContains(String, String)

    /// Substring match against ANY of several alternatives, case-insensitively.
    ///
    /// Multiple `attributeContains` predicates are ANDed, which cannot express what a locale set
    /// is: the header pan slider is identified by `AXHelp` containing any one of
    /// `pan` / `panning` / `패닝` / `밸런스`, and requiring all four matches nothing in any locale.
    /// This is the atlas gaining the primitive the product already uses everywhere else —
    /// `AXLocalePolicy.LabelSet.containsAny`.
    case attributeContainsAny(String, [String])

    /// Substring match against any of several alternatives, in ANY of several attributes.
    ///
    /// Two `attributeContainsAny` predicates are ANDed, so naming both `AXHelp` and
    /// `AXDescription` demands the label appear in both. Measured: Logic puts a volume fader's name
    /// in `AXDescription` on a track header and its sentence in `AXHelp`, and a synthetic fixture
    /// carries only the description — the conjunction matched neither reliably and the existing
    /// mixer tests caught it.
    ///
    /// What the product has always meant is a search across a group of fields, which is
    /// `AXLogicProElements.elementSearchText` joining identifier, description, title and help
    /// before a single `containsAny`. This is that, expressed as a selector.
    case anyAttributeContainsAny([String], [String])

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

    let equals = selector.attributePredicates.compactMap { predicate -> (String, String)? in
        guard case let .attribute(name, expected) = predicate else { return nil }
        return (name, expected)
    }
    let contains = selector.attributePredicates.compactMap { predicate -> (String, String)? in
        guard case let .attributeContains(name, expected) = predicate else { return nil }
        return (name, expected)
    }
    let containsAny = selector.attributePredicates.compactMap { predicate -> (String, [String])? in
        guard case let .attributeContainsAny(name, needles) = predicate else { return nil }
        return (name, needles)
    }
    let anyOf = selector.attributePredicates.compactMap { predicate -> ([String], [String])? in
        guard case let .anyAttributeContainsAny(names, needles) = predicate else { return nil }
        return (names, needles)
    }
    func hits(_ value: String?, _ needles: [String]) -> Bool {
        guard let value else { return false }
        return needles.contains {
            !$0.isEmpty && value.range(of: $0, options: [.caseInsensitive]) != nil
        }
    }
    evidence.append((0.20,
                     !equals.isEmpty || !contains.isEmpty || !containsAny.isEmpty || !anyOf.isEmpty,
                     equals.allSatisfy { candidate.attributes[$0.0] == $0.1 }
                         && contains.allSatisfy { name, needle in
                             candidate.attributes[name].map {
                                 $0.range(of: needle, options: [.caseInsensitive]) != nil
                             } ?? false
                         }
                         && containsAny.allSatisfy { name, needles in
                             hits(candidate.attributes[name], needles)
                         }
                         && anyOf.allSatisfy { names, needles in
                             names.contains { hits(candidate.attributes[$0], needles) }
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
