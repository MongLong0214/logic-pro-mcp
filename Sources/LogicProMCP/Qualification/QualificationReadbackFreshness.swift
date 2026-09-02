import Foundation

/// Whether an independent readback may count as live-verification evidence — #373.
///
/// State resources already publish the observations this gate needs. In particular, a tracks
/// envelope says whether Accessibility was readable, whether an AX-occluding surface was present,
/// whether an empty result was positively established, where the result came from, and how old it
/// is. Comparing only `data` let an unchanged cache masquerade as a post-write observation.
enum QualificationReadbackFreshness {
    /// The observed fields that determine whether a resource body is evidence. `dataIsEmpty` is
    /// derived from the resource payload rather than supplied by the caller, so an empty list and
    /// an unconfirmed empty list cannot be confused.
    struct Envelope: Equatable, Sendable {
        let source: String?
        let readable: Bool?
        let axOccluded: Bool?
        let verifiedEmpty: Bool?
        let dataIsEmpty: Bool
        let cacheAgeSeconds: Double?

        init(
            source: String?,
            readable: Bool?,
            axOccluded: Bool?,
            verifiedEmpty: Bool?,
            dataIsEmpty: Bool,
            cacheAgeSeconds: Double?
        ) {
            self.source = source
            self.readable = readable
            self.axOccluded = axOccluded
            self.verifiedEmpty = verifiedEmpty
            self.dataIsEmpty = dataIsEmpty
            self.cacheAgeSeconds = cacheAgeSeconds
        }
    }

    /// The reason an otherwise well-formed readback cannot confirm a live operation. These are
    /// wire-stable strings because a refusal needs to say whether to retry the AX read, dismiss an
    /// occluding panel, or investigate an outdated cache.
    enum Verdict: Equatable, Sendable {
        case admissible
        case unreadable
        case axOccluded
        case emptyUnverified
        case notLive(source: String?)
        case cacheAgeUnknown
        case cacheAgeExceeded(age: Double, maximum: Double)

        var isAdmissible: Bool { self == .admissible }

        var refusalReason: String? {
            switch self {
            case .admissible:
                nil
            case .unreadable:
                "readback_unreadable"
            case .axOccluded:
                "readback_ax_occluded"
            case .emptyUnverified:
                "readback_empty_unverified"
            case .notLive:
                "readback_not_ax_live"
            case .cacheAgeUnknown:
                "readback_cache_age_unknown"
            case .cacheAgeExceeded:
                "readback_cache_age_exceeded"
            }
        }
    }

    /// The sole resource provenance that means this answer came from the AX surface.
    static let liveSourceToken = "ax_live"

    static func verdict(
        for readbackData: Data,
        verification: VerificationPolicy,
        deadline: DeadlineClass
    ) -> Verdict {
        verdict(for: envelope(from: readbackData), verification: verification, deadline: deadline)
    }

    static func verdict(
        for envelope: Envelope,
        verification: VerificationPolicy,
        deadline: DeadlineClass
    ) -> Verdict {
        // `readbackRequired` is the registry's live-verification contract. Read-only and
        // best-effort operations may retain their existing independent-readback semantics without
        // acquiring a new AX freshness precondition.
        guard verification == .readbackRequired else { return .admissible }

        if envelope.readable == false { return .unreadable }
        if envelope.axOccluded == true { return .axOccluded }
        if envelope.dataIsEmpty && envelope.verifiedEmpty != true { return .emptyUnverified }
        guard envelope.source == liveSourceToken else {
            return .notLive(source: envelope.source)
        }

        // The bound is the operation's own deadline, not a new uniform cache constant:
        // short = 25 s, medium = 90 s, and long = 300 s (`DeadlineClass.seconds`). Those are the
        // maximum in-flight windows the operation contract already grants. An observation older
        // than its own window could predate the write it is meant to confirm; a tighter shared
        // window would invent a constraint for slower classes, while a looser one would defeat the
        // short class's contract. Unknown age (including an absent `cache_age_sec`) is refused:
        // without a measurement, it cannot satisfy any age bound.
        guard let age = envelope.cacheAgeSeconds, age >= 0 else {
            return .cacheAgeUnknown
        }
        let maximum = deadline.seconds
        guard age <= maximum else {
            return .cacheAgeExceeded(age: age, maximum: maximum)
        }
        return .admissible
    }

    private static func envelope(from readbackData: Data) -> Envelope {
        guard let object = try? JSONSerialization.jsonObject(with: readbackData) as? [String: Any]
        else {
            return Envelope(
                source: nil,
                readable: nil,
                axOccluded: nil,
                verifiedEmpty: nil,
                dataIsEmpty: false,
                cacheAgeSeconds: nil
            )
        }
        return Envelope(
            source: object["source"] as? String,
            readable: object["readable"] as? Bool,
            axOccluded: object["ax_occluded"] as? Bool,
            verifiedEmpty: object["verified_empty"] as? Bool,
            dataIsEmpty: isEmpty(object["data"]),
            cacheAgeSeconds: object["cache_age_sec"] as? Double
        )
    }

    private static func isEmpty(_ value: Any?) -> Bool {
        switch value {
        case let values as [Any]:
            values.isEmpty
        case let values as [String: Any]:
            values.isEmpty
        case is NSNull:
            true
        default:
            false
        }
    }
}
