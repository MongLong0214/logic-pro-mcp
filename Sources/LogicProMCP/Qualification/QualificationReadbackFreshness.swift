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
        /// Where this resource family publishes its ROWS. `logic://tracks` uses `data`;
        /// `logic://mixer` uses `strips`. Asking the wrong key cannot distinguish "no rows" from
        /// "rows under another name", and a gate that cannot tell those apart either refuses every
        /// resource it does not know or admits every empty one. Measured 2026-09-20 when a fix
        /// that assumed `data` everywhere refused three mixer cases that were correct.
        let rowsKey: String

        init(key: String, liveToken: String, rowsKey: String = "data") {
            self.key = key
            self.liveToken = liveToken
            self.rowsKey = rowsKey
        }
    }

    static let defaultDialect = ProvenanceDialect(key: "source", liveToken: liveSourceToken)

    /// Keyed by URI PREFIX, because `logic://mixer` and `logic://mixer/{strip}` are one resource
    /// family emitted by one writer and share its vocabulary.
    static let provenanceDialects: [(prefix: String, dialect: ProvenanceDialect)] = [
        ("logic://mixer", ProvenanceDialect(key: "data_source", liveToken: "ax_poll",
                                            rowsKey: "strips")),
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
        // PROVENANCE BEFORE EMPTINESS, and the order is load-bearing. Emptiness is asked at this
        // dialect's `rowsKey`, so a body read under the WRONG dialect has no rows there whatever
        // it carries -- and answering `emptyUnverified` would report a consequence of the key
        // mismatch while hiding its cause. A body with no live provenance token cannot be admitted
        // on any reading of its rows, so that is the refusal worth naming. Both are refusals;
        // only the reason changes, and the truer reason is the one a person can act on.
        guard envelope.source == liveToken else {
            return .notLive(source: envelope.source)
        }
        if envelope.dataIsEmpty && envelope.verifiedEmpty != true { return .emptyUnverified }

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
            dataIsEmpty: isEmpty(object[dialect.rowsKey]),
            cacheAgeSeconds: object["cache_age_sec"] as? Double
        )
    }

    /// Whether a readback's `data` holds nothing, with a case per SHAPE and no silent default.
    ///
    /// This is the one predicate; `QualificationTransport` calls it too. Until 2026-09-20 there
    /// were two, in the same subsystem, and they disagreed on the case that matters most: an
    /// ABSENT `data` key. This one answered `false` (not empty, carry on) through its `default`
    /// arm; the transport's answered `true` and refused. Whether a rowless readback was admissible
    /// depended on which gate asked, and nothing said so.
    ///
    /// `absent` is now its own answer and it means EMPTY, because a body that publishes no rows
    /// has not shown a reading. The `default` arm stays narrow on purpose -- a `data` that is a
    /// string or a number is a shape nothing here understands, and calling that non-empty leaves
    /// the refusal to the next check rather than inventing one here.
    /// Whether a body shows NO rows under any key this product's resources publish them at.
    ///
    /// For a caller that knows its URI, `isEmpty(object[dialect.rowsKey])` is the precise
    /// question. A mutation-restore record carries no URI -- its three readings come from
    /// whichever resource the recipe used -- so it asks the wider one: a body carrying rows under
    /// ANY known key has shown a reading. The key set is derived from the dialect table, so a
    /// resource that starts publishing under a new name is one edit away from being understood
    /// here too rather than silently reading as empty.
    static func showsNoRows(_ object: [String: Any]) -> Bool {
        var keys = [defaultDialect.rowsKey]
        keys.append(contentsOf: provenanceDialects.map(\.dialect.rowsKey))
        for key in Set(keys) where !isEmpty(object[key]) {
            return false
        }
        return true
    }

    static func isEmpty(_ value: Any?) -> Bool {
        switch value {
        case nil:
            // No `data` key at all. Not "rows we did not look at" -- nothing was published.
            true
        case is NSNull:
            true
        case let values as [Any]:
            values.isEmpty
        case let values as [String: Any]:
            // A dictionary payload is a live shape here -- `SemanticOracleTable` reads
            // `readback["data"] as? [String: Any]` -- and an empty one is as empty as `[]`.
            values.isEmpty
        default:
            false
        }
    }
}
