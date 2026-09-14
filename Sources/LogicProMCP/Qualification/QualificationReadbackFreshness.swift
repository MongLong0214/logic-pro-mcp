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

    /// WHERE a resource publishes its provenance and WHICH token there means "read live off the AX
    /// surface". These are not interchangeable across resources, and the gate used to assume they
    /// were.
    ///
    /// Measured 2026-09-14: `logic://mixer` publishes `data_source`, whose live value is `ax_poll`
    /// (with `cache_stale` and `mixer_not_visible` beside it), while `logic://tracks` publishes
    /// `source` with `ax_live`. Asking the mixer envelope for `source` gets nil, so a reading taken
    /// off a visible Mixer was refused as not-live — the gate was asking the wrong question of that
    /// resource rather than getting a wrong answer.
    ///
    /// A dialect is a FACT about a resource, not a relaxation: an entry here still has to produce
    /// its live token, and every other admissibility check runs unchanged. Adding one for a
    /// resource whose provenance vocabulary is not actually different would be the widening this
    /// avoids.
    struct ProvenanceDialect: Equatable, Sendable {
        let key: String
        let liveToken: String
    }

    static let defaultDialect = ProvenanceDialect(key: "source", liveToken: liveSourceToken)

    /// Keyed by URI PREFIX, because `logic://mixer` and `logic://mixer/{strip}` are one resource
    /// family emitted by one writer and share its vocabulary.
    static let provenanceDialects: [(prefix: String, dialect: ProvenanceDialect)] = [
        ("logic://mixer", ProvenanceDialect(key: "data_source", liveToken: "ax_poll")),
    ]

    static func dialect(for uri: String?) -> ProvenanceDialect {
        guard let uri else { return defaultDialect }
        return provenanceDialects.first { uri.hasPrefix($0.prefix) }?.dialect ?? defaultDialect
    }

    static func verdict(
        for readbackData: Data,
        uri: String? = nil,
        verification: VerificationPolicy,
        deadline: DeadlineClass
    ) -> Verdict {
        let dialect = dialect(for: uri)
        return verdict(
            for: envelope(from: readbackData, dialect: dialect),
            verification: verification,
            deadline: deadline,
            liveToken: dialect.liveToken
        )
    }

    static func verdict(
        for envelope: Envelope,
        verification: VerificationPolicy,
        deadline: DeadlineClass,
        liveToken: String = liveSourceToken
    ) -> Verdict {
        // `readbackRequired` is the registry's live-verification contract. Read-only and
        // best-effort operations may retain their existing independent-readback semantics without
        // acquiring a new AX freshness precondition.
        guard verification == .readbackRequired else { return .admissible }

        if envelope.readable == false { return .unreadable }
        if envelope.axOccluded == true { return .axOccluded }
        if envelope.dataIsEmpty && envelope.verifiedEmpty != true { return .emptyUnverified }
        guard envelope.source == liveToken else {
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

    static func envelope(
        from readbackData: Data,
        dialect: ProvenanceDialect = defaultDialect
    ) -> Envelope {
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
            source: object[dialect.key] as? String,
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
