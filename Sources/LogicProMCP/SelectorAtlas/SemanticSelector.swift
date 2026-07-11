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

func confidence(of candidate: ResolvableCandidate, against selector: SemanticSelector) -> Double {
    guard candidate.role == selector.requiredRole else { return 0 }
    guard selector.allowedSubroles.isEmpty
        || candidate.subrole.map(selector.allowedSubroles.contains) == true else { return 0 }

    var score = 0.25
    let identifierMatch = selector.attributePredicates.contains { predicate in
        guard case let .axIdentifier(expected) = predicate else { return false }
        return candidate.axIdentifier == expected
    }
    if identifierMatch { score += 0.55 }

    let ancestorMatch = !selector.ancestorConstraints.isEmpty
        && matchesAncestorChain(candidate.ancestors, selector.ancestorConstraints)
    if ancestorMatch { score += 0.08 }

    let attributePredicates = selector.attributePredicates.compactMap { predicate -> (String, String)? in
        guard case let .attribute(name, expected) = predicate else { return nil }
        return (name, expected)
    }
    let attributeMatch = !attributePredicates.isEmpty
        && attributePredicates.allSatisfy { candidate.attributes[$0.0] == $0.1 }
    if attributeMatch { score += 0.05 }

    let titleMatch = candidate.title.map { title in
        selector.titleAliases.values.flatMap { $0 }.contains {
            title.caseInsensitiveCompare($0) == .orderedSame
        }
    } ?? false
    if titleMatch { score += 0.04 }

    let signatures = selector.attributePredicates.compactMap { predicate -> String? in
        guard case let .valueSignature(expected) = predicate else { return nil }
        return expected
    }
    let valueMatch = candidate.valueSignature.map(signatures.contains) == true
    if valueMatch { score += 0.02 }

    let geometryMatch = selector.geometryHint == candidate.geometry && selector.geometryHint != nil
    if geometryMatch { score += 0.01 }

    let hasSpecificNonGeometryEvidence = identifierMatch
        || ancestorMatch
        || attributeMatch
        || titleMatch
        || valueMatch
    if geometryMatch, !hasSpecificNonGeometryEvidence {
        return min(score, 0.49)
    }
    return min(score, 1)
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
