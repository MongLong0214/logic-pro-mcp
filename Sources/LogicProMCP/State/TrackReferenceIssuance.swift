import Foundation

/// References issued for one observed track inventory, aligned with that inventory.
///
/// `byRow[i]` is the reference issued for `inventory[i]`, or nil when that row is not eligible.
/// `byTrackIndex` carries only eligible rows whose `id` occurs exactly once: a strip joins a track
/// by id, and an id two rows share cannot say which of them the strip belongs to.
struct IssuedTrackReferences: Sendable {
    let byRow: [TargetReference?]
    let byTrackIndex: [Int: TargetReference]
    let ambiguousTrackIndices: [Int]
}

/// The one place a `trk_` reference is issued (#291 R0).
///
/// `logic://tracks` and `logic://mixer` both issue through here, so whichever is read first binds
/// the same observed row to the same reference: `TargetRegistry.bind` de-duplicates on the
/// descriptor and fingerprint, and both come from the row alone. That de-duplication is the whole
/// mechanism — there is deliberately no memo here, because a memo would outlive a topology or
/// project-epoch bump that the registry has already invalidated.
enum TrackReferenceIssuance {
    static func isEligible(_ track: TrackState) -> Bool {
        track.liveIdentityBacked && track.placeholder != true
    }

    /// Logic 12.x leaks the Inspector subtree through the track-header walk when another panel has
    /// focus: three or more rows whose names all end in `:`. The threshold keeps a single real track
    /// named "MyMix:" from being dropped.
    static func isInspectorContaminated(_ tracks: [TrackState]) -> Bool {
        tracks.count >= 3 && tracks.allSatisfy { $0.name.hasSuffix(":") }
    }

    static func liveInventory(_ cached: [TrackState]) -> [TrackState] {
        isInspectorContaminated(cached) ? [] : cached
    }

    /// Nil when the snapshot went stale during issuance: a reference bound after the registry moved
    /// on would name a topology the caller did not observe.
    static func issue(
        for inventory: [TrackState],
        registry: TargetRegistry,
        snapshot: TargetRegistrySnapshot
    ) async -> IssuedTrackReferences? {
        var byRow: [TargetReference?] = []
        byRow.reserveCapacity(inventory.count)
        for row in inventory {
            guard isEligible(row) else {
                byRow.append(nil)
                continue
            }
            let descriptor = TargetDescriptor(trackIndex: row.id, trackName: row.name)
            // One line, so a line search for `bind(kind: .track` finds this sole issuer.
            let bound = await registry.bind(kind: .track, descriptor: descriptor, fingerprint: descriptor.fingerprint, snapshot: snapshot)
            guard let reference = bound else { return nil }
            byRow.append(reference)
        }

        var occurrences: [Int: Int] = [:]
        for row in inventory {
            occurrences[row.id, default: 0] += 1
        }
        var byTrackIndex: [Int: TargetReference] = [:]
        for (row, reference) in zip(inventory, byRow) {
            guard let reference, occurrences[row.id] == 1 else { continue }
            byTrackIndex[row.id] = reference
        }
        let ambiguousTrackIndices = occurrences
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
        return IssuedTrackReferences(
            byRow: byRow,
            byTrackIndex: byTrackIndex,
            ambiguousTrackIndices: ambiguousTrackIndices
        )
    }
}
