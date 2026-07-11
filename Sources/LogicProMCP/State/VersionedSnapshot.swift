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

enum CacheSectionID: String, Sendable, CaseIterable {
    case transport
    case tracks
    case mixer
    case project
    case pluginInventory
    case libraryInventory
}
