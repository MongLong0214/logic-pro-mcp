import Foundation

enum ProjectIssuance: Sendable {
    case issued(TargetReference)
    case unobserved(reason: String)
    case stale
}

/// The one place a `prj_` reference is issued (#291 R0).
///
/// `logic://project/info`, `logic://mixer`, and native plug-in inventory all issue through here. `TargetRegistry.bind`
/// replaces the current project descriptor and drops every other project binding whenever a
/// different descriptor is bound, so two issuers deriving the descriptor differently would evict
/// each other's references on alternate reads. All issuers share `descriptor`; request-owned AX
/// observations additionally normalize their path at the inventory boundary before calling it.
///
/// Inputs may be the poller's cached record or one request-owned native observation. The native
/// inventory boundary canonicalizes its AXDocument path to the poller's real-path form before it
/// reaches this issuer, without changing the descriptor semantics used by other exact-path gates.
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

    static func canonicalObservedProjectPath(_ filePath: String?) -> String? {
        guard let trimmed = filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func issue(
        cached project: ProjectInfo,
        registry: TargetRegistry,
        snapshot: TargetRegistrySnapshot,
        stoppingWhen stop: @Sendable () -> Bool = { false }
    ) async -> ProjectIssuance {
        guard !Task.isCancelled, !stop() else { return .stale }
        guard let descriptor = descriptor(name: project.name, filePath: project.filePath, epoch: snapshot.projectEpoch) else {
            return .unobserved(reason: unobservedReason)
        }
        // One line, so a line search for `bind(kind: .project` finds this sole issuer.
        let bound = await registry.bind(kind: .project, descriptor: descriptor, fingerprint: descriptor.fingerprint, snapshot: snapshot, stoppingWhen: stop)
        guard let reference = bound else { return .stale }
        return .issued(reference)
    }
}
