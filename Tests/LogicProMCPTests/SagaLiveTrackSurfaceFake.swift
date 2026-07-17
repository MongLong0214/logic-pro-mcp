import Foundation
@testable import LogicProMCP

/// Models the LIVE Logic surface that the saga's AX read seams observe —
/// deliberately SEPARATE from `StateCache`.
///
/// LPMCP-PRD-004: the cache is a poller-refreshed mirror and can disagree with
/// what Logic actually holds. Keeping the two distinct in tests is what makes
/// "the saga never sources a decision from the cache" assertable: a test can
/// desync them and watch which one the saga believes.
final class SagaLiveTrackSurface: @unchecked Sendable {
    private let lock = NSLock()
    private var tracks: [Int: TrackState]
    private var reads = 0

    init(_ tracks: [TrackState]) {
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func snapshot(_ index: Int) -> TrackState? {
        lock.lock()
        defer { lock.unlock() }
        return tracks[index]
    }

    func update(_ index: Int, _ mutate: (inout TrackState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var track = tracks[index] else { return }
        mutate(&track)
        tracks[index] = track
    }

    func readCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    private func noteRead() {
        lock.lock()
        reads += 1
        lock.unlock()
    }

    /// The live-read seam the executor consumes. An absent track reads as nil
    /// on every field — the fail-closed case, never a fabricated default.
    var readback: SagaLiveReadback {
        SagaLiveReadback(
            readTrackName: { [self] index in
                noteRead()
                return snapshot(index)?.name
            },
            readTrackVolume: { [self] index in
                noteRead()
                return snapshot(index)?.volume
            },
            readTrackPan: { [self] index in
                noteRead()
                return snapshot(index)?.pan
            },
            readTrackToggle: { [self] index, field in
                noteRead()
                guard let track = snapshot(index) else { return nil }
                return switch field {
                case .mute: track.isMuted
                case .solo: track.isSoloed
                case .arm: track.isArmed
                }
            }
        )
    }
}
