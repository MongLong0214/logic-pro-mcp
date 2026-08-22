import Foundation

enum StateSource: String, Sendable, Codable {
    case axLive
    case appleScript
    case mcuEcho
    case coreMIDI
    case cache
    case unknown
}

enum Completeness: String, Sendable, Codable {
    case complete
    case partial
    case unknown
}

struct VersionedSnapshot<Value: Sendable>: Sendable {
    let projectEpoch: UInt64
    let sectionRevision: UInt64
    let observedAt: ContinuousClock.Instant
    let source: StateSource
    let completeness: Completeness
    let fingerprint: String
    let value: Value

    var etag: String { fingerprint }

    func cacheAgeMillis(now: ContinuousClock.Instant) -> Int64 {
        let duration = observedAt.duration(to: now)
        guard duration > .zero else { return 0 }
        let components = duration.components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }
}

/// Who produced a cache write, ranked. ADR-006's commit rule needs this because a bare
/// compare-and-swap is first-writer-wins: two refreshes that capture the same section revision
/// race, and the loser's value is discarded no matter which one is authoritative. When the winner
/// is a slow background poll and the loser is a mutation verification, the cache keeps the older,
/// less trustworthy read — the inversion the ADR names in "slow background polls must not
/// overwrite mutation verification".
///
/// `rank` is the comparison; the case order is not load-bearing.
enum RefreshSource: String, Sendable, CaseIterable {
    case mutationVerification
    case explicitRead
    case subscription
    case backgroundPoll

    /// Higher outranks lower. Only a STRICTLY higher rank may displace an already-committed write.
    var rank: Int {
        switch self {
        case .mutationVerification: return 3
        case .explicitRead: return 2
        case .subscription: return 1
        case .backgroundPoll: return 0
        }
    }
}

enum CacheSectionID: String, Sendable, CaseIterable {
    case transport
    case tracks
    case mixer
    case project
    case pluginInventory
    case libraryInventory
}
