import Foundation

struct ResolvableCandidate: Equatable, Sendable {
    let axIdentifier: String?
    let role: String
    let subrole: String?
    let title: String?
    let ancestors: [String]
    let attributes: [String: String]
    let valueSignature: String?
    let geometry: GeometryHint?
}

enum SelectorResolution: Equatable, Sendable {
    case exact(index: Int)
    case ambiguous(indices: [Int])
    case notFound
    case unsupportedSignature
}

func resolve(
    _ selector: SemanticSelector,
    in candidates: [ResolvableCandidate],
    locale: String
) -> SelectorResolution {
    guard supportsSchema(selector, candidates: candidates) else { return .unsupportedSignature }

    let matches = candidates.enumerated().compactMap { index, candidate -> (Int, Double)? in
        let score = confidence(of: candidate, against: selector, locale: locale)
        return score > 0 && score >= selector.minimumConfidence ? (index, score) : nil
    }
    guard !matches.isEmpty else { return .notFound }
    guard matches.count > 1 else { return .exact(index: matches[0].0) }
    return .ambiguous(indices: matches.map(\.0))
}

func canMutate(_ resolution: SelectorResolution) -> Bool {
    if case .exact = resolution { return true }
    return false
}

private func confidence(
    of candidate: ResolvableCandidate,
    against selector: SemanticSelector,
    locale: String
) -> Double {
    let localizedSelector = SemanticSelector(
        id: selector.id,
        requiredRole: selector.requiredRole,
        allowedSubroles: selector.allowedSubroles,
        titleAliases: selector.titleAliases[locale].map { [locale: $0] } ?? [:],
        ancestorConstraints: selector.ancestorConstraints,
        attributePredicates: selector.attributePredicates,
        geometryHint: selector.geometryHint,
        minimumConfidence: selector.minimumConfidence,
        ambiguityPolicy: selector.ambiguityPolicy
    )
    return confidence(of: candidate, against: localizedSelector)
}

private func supportsSchema(
    _ selector: SemanticSelector,
    candidates: [ResolvableCandidate]
) -> Bool {
    guard !selector.requiredRole.isEmpty,
          selector.minimumConfidence.isFinite,
          (0...1).contains(selector.minimumConfidence),
          candidates.allSatisfy({ !$0.role.isEmpty }) else { return false }
    return selector.attributePredicates.allSatisfy { predicate in
        switch predicate {
        case let .axIdentifier(value), let .valueSignature(value):
            !value.isEmpty
        case let .attribute(name, equals: value), let .attributeContains(name, value):
            !name.isEmpty && !value.isEmpty
        }
    }
}
