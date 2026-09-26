import Foundation

enum ProjectIssuance: Sendable {
    case issued(TargetReference)
    case unobserved(reason: String)
    case stale
}

/// The one place a `prj_` reference is issued (#291 R0).
///
/// `logic://project/info` and `logic://mixer` both issue through here. `TargetRegistry.bind`
/// replaces the current project descriptor and drops every other project binding whenever a
/// different descriptor is bound, so two issuers deriving the descriptor differently would evict
/// each other's references on alternate reads. Keeping the derivation in `descriptor` alone is
/// what makes the reference independent of which resource was read first.
///
/// The input is the poller's cached record, not a record one reader completed. `project/info`
/// fills an empty `filePath` from its own project-file read, which the mixer may not make (it runs
/// after every poll, outside the #199 deadline). Issuing from that filled path gave `project/info` a
/// reference the mixer could not carry until the poller filled the same path.
enum ProjectReferenceIssuance {
    static let unobservedReason = "project identity not yet observed: the cache carries no project name and bundle path"

    /// Nil unless both the name and the bundle path are non-empty after trimming: a name alone is a
    /// display label, and two open documents can share one.
    static func descriptor(name: String, filePath: String?, epoch: UInt64) -> TargetDescriptor? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = (filePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPath.isEmpty else { return nil }
        return TargetDescriptor.project(name: trimmedName, filePath: trimmedPath, epoch: epoch)
    }

    static func issue(
        cached project: ProjectInfo,
        registry: TargetRegistry,
        snapshot: TargetRegistrySnapshot
    ) async -> ProjectIssuance {
        guard let descriptor = descriptor(name: project.name, filePath: project.filePath, epoch: snapshot.projectEpoch) else {
            return .unobserved(reason: unobservedReason)
        }
        // One line, so a line search for `bind(kind: .project` finds this sole issuer.
        let bound = await registry.bind(kind: .project, descriptor: descriptor, fingerprint: descriptor.fingerprint, snapshot: snapshot)
        guard let reference = bound else { return .stale }
        return .issued(reference)
    }
}
