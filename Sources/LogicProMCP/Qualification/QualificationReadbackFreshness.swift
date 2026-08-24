import Foundation

/// Whether a Phase-B readback may be believed — #373.
///
/// Phase B is "pre-state → mutation → independent readback → restore → restore-readback", and its
/// recorded blocker was that `logic://tracks` is served from the poller cache: a cache that never
/// moved satisfies a value-equality check exactly as well as a fresh read does. The proposed remedy
/// was a second, non-cached read path.
///
/// Measured 2026-08-24 against live Logic, one `tracks.create_audio` with a readback either side:
///
///     PRE   source=ax_live  fetched_at=…T01:19:00.078Z  cache_age_sec=0.80  tracks=1
///     MUT   observed_delta=1  state=A
///     POST  source=ax_live  fetched_at=…T01:19:06.135Z  cache_age_sec=0.28  tracks=2
///
/// The envelope already carries the proof. `fetched_at` advanced past the mutation and `source`
/// distinguishes a live walk from a cache or default answer, so the freshness requirement is an
/// assertion on fields that ship today rather than a new read path.
///
/// The clause that does the work is `fetchedAt > mutationStartedAt`: a stale envelope fails it by
/// construction, whatever its values say. The other two are there because a check that cannot see
/// its subject reports absence as agreement — `source` absent or `default` means the poller never
/// read, and a missing `cache_age_sec` means the envelope is not the one this rule was measured on.
enum QualificationReadbackFreshness {
    /// The three fields `ResourceHandlers+StateReaders` publishes on every state envelope.
    struct Envelope: Equatable, Sendable {
        let source: String?
        let fetchedAt: Date?
        let cacheAgeSeconds: Double?

        init(source: String?, fetchedAt: Date?, cacheAgeSeconds: Double?) {
            self.source = source
            self.fetchedAt = fetchedAt
            self.cacheAgeSeconds = cacheAgeSeconds
        }
    }

    /// Why a readback was refused, named rather than reduced to `false`. A Phase-B recipe that
    /// logs "inadmissible" and nothing else cannot tell a stale cache from an unread poller, and
    /// those two failures call for opposite responses.
    enum Verdict: Equatable, Sendable {
        case admissible
        /// The poller never produced a live walk — `source` is `cache`, `default`, or absent.
        case notLive(source: String?)
        /// The envelope predates the mutation it is supposed to witness.
        case predatesMutation(fetchedAt: Date, mutationStartedAt: Date)
        /// `fetched_at` is absent, so the envelope cannot be placed in time at all.
        case unplaceableInTime
        /// `cache_age_sec` is absent; this is not the envelope shape the rule was measured against.
        case ageAbsent

        var isAdmissible: Bool { self == .admissible }
    }

    /// The one source token that means "the poller walked Accessibility for this answer".
    /// `cache` and `default` are the other two `ResourceHandlers` emits, and both are refusals here.
    static let liveSourceToken = "ax_live"

    static func verdict(for envelope: Envelope, mutationStartedAt: Date) -> Verdict {
        guard envelope.source == liveSourceToken else {
            return .notLive(source: envelope.source)
        }
        guard let fetchedAt = envelope.fetchedAt else {
            return .unplaceableInTime
        }
        // Strictly after: an envelope stamped at the same instant as the mutation started cannot
        // have observed its effect, and equality is exactly the case a coarse clock produces.
        guard fetchedAt > mutationStartedAt else {
            return .predatesMutation(fetchedAt: fetchedAt, mutationStartedAt: mutationStartedAt)
        }
        guard envelope.cacheAgeSeconds != nil else {
            return .ageAbsent
        }
        return .admissible
    }
}
