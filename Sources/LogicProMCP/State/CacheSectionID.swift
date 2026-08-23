import Foundation

/// The cache sections a poll cycle writes and an operation can dirty.
///
/// This file used to also carry ADR-006's `VersionedSnapshot` capsule — `StateSource`,
/// `Completeness`, `etag` and `cacheAgeMillis`. That capsule was scaffolding for a
/// `RefreshCoordinator` increment that never arrived, and #675 shipped the behaviour it existed to
/// support — single-flight, cancellation, latest-value-wins — without any of it. `docs/adr/README.md`
/// had already recorded it as unadopted, with only `CacheSectionID` live; a census confirmed that
/// exactly, so the unused half is retired rather than left to read as implemented in the next one.
///
/// The live envelope path derives its own etag and cache age in `ResourceHandlers`; nothing was
/// migrated off this type because nothing had been migrated onto it.
enum CacheSectionID: String, Sendable, CaseIterable {
    case transport
    case tracks
    case mixer
    case project
    case pluginInventory
    case libraryInventory
}
