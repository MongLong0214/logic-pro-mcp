import Foundation
import Testing
@testable import LogicProMCP

@Suite("QualificationReadbackFreshness")
struct QualificationReadbackFreshnessTests {
    private static func readback(
        source: String = "ax_live",
        readable: Bool = true,
        axOccluded: Bool = false,
        verifiedEmpty: Bool = false,
        data: Any = [["id": 1, "name": "Track 1"]],
        cacheAge: Double? = 0.28,
        includesCacheAge: Bool = true
    ) throws -> Data {
        var object: [String: Any] = [
            "source": source,
            "readable": readable,
            "ax_occluded": axOccluded,
            "verified_empty": verifiedEmpty,
            "data": data,
        ]
        if includesCacheAge {
            object["cache_age_sec"] = cacheAge ?? NSNull()
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A `logic://mixer` body, which publishes its provenance under a different key with a
    /// different live token than `logic://tracks` does.
    private static func mixerReadback(
        dataSource: String = "ax_poll",
        cacheAge: Double = 0.02
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "cache_age_sec": cacheAge,
                "data_source": dataSource,
                "ax_occluded": false,
                "strips": [["index": 0, "volume": 0.8]],
            ] as [String: Any],
            options: [.sortedKeys]
        )
    }

    @Test("a live Mixer poll is admissible when the reader names the mixer resource")
    func mixerProvenanceIsReadUnderItsOwnKey() throws {
        #expect(
            QualificationReadbackFreshness.verdict(
                for: try Self.mixerReadback(),
                uri: "logic://mixer",
                verification: .readbackRequired,
                deadline: .short
            ) == .admissible
        )
        #expect(
            QualificationReadbackFreshness.verdict(
                for: try Self.mixerReadback(),
                uri: "logic://mixer/0",
                verification: .readbackRequired,
                deadline: .short
            ) == .admissible
        )
    }

    @Test("a Mixer that is stale or not visible is still refused")
    func mixerNonLiveProvenanceIsRefused() throws {
        for token in ["cache_stale", "mixer_not_visible"] {
            #expect(
                QualificationReadbackFreshness.verdict(
                    for: try Self.mixerReadback(dataSource: token),
                    uri: "logic://mixer",
                    verification: .readbackRequired,
                    deadline: .short
                ) == .notLive(source: token)
            )
        }
    }

    /// The dialect is a fact about ONE resource family. If it leaked to every reader, a tracks body
    /// carrying `data_source` would start passing, and the gate would have been widened rather than
    /// corrected.
    @Test("the mixer dialect does not travel to other resources")
    func mixerDialectIsScopedToTheMixerResource() throws {
        let trackShapedMixerBody = try JSONSerialization.data(
            withJSONObject: [
                "cache_age_sec": 0.02,
                "data_source": "ax_poll",
                "readable": true,
                "ax_occluded": false,
                "verified_empty": false,
                "data": [["id": 1]],
            ] as [String: Any],
            options: [.sortedKeys]
        )
        #expect(
            QualificationReadbackFreshness.verdict(
                for: trackShapedMixerBody,
                uri: "logic://tracks",
                verification: .readbackRequired,
                deadline: .short
            ) == .notLive(source: nil)
        )
        #expect(
            QualificationReadbackFreshness.verdict(
                for: try Self.mixerReadback(),
                uri: nil,
                verification: .readbackRequired,
                deadline: .short
            ) == .notLive(source: nil)
        )
    }

    /// `ax_live` is not the mixer's word for live, and reading the mixer with the default dialect
    /// must not accidentally accept it either.
    @Test("the tracks live token is not accepted on the mixer resource")
    func tracksLiveTokenIsNotAMixerLiveToken() throws {
        #expect(
            QualificationReadbackFreshness.verdict(
                for: try Self.mixerReadback(dataSource: "ax_live"),
                uri: "logic://mixer",
                verification: .readbackRequired,
                deadline: .short
            ) == .notLive(source: "ax_live")
        )
    }

    private static func verdict(
        _ readback: Data,
        verification: VerificationPolicy = .readbackRequired,
        deadline: DeadlineClass = .short
    ) -> QualificationReadbackFreshness.Verdict {
        QualificationReadbackFreshness.verdict(
            for: readback,
            verification: verification,
            deadline: deadline
        )
    }

    @Test("readable false refuses while a readable observation is admissible")
    func unreadableReadbackIsRefused() throws {
        let clean = Self.verdict(try Self.readback(readable: true))
        #expect(clean.isAdmissible)

        let refusal = Self.verdict(try Self.readback(readable: false))
        let hasUnreadableReason = refusal.refusalReason == "readback_unreadable"
        #expect(hasUnreadableReason)
    }

    @Test("an AX-occluded surface refuses while an unobstructed readback is admissible")
    func occludedReadbackIsRefused() throws {
        let clean = Self.verdict(try Self.readback(axOccluded: false))
        #expect(clean.isAdmissible)

        let refusal = Self.verdict(try Self.readback(axOccluded: true))
        let hasOcclusionReason = refusal.refusalReason == "readback_ax_occluded"
        #expect(hasOcclusionReason)
    }

    @Test("an unverified empty list refuses while a verified empty list is admissible")
    func unverifiedEmptyReadbackIsRefused() throws {
        let clean = Self.verdict(try Self.readback(verifiedEmpty: true, data: [Any]()))
        #expect(clean.isAdmissible)

        let refusal = Self.verdict(try Self.readback(verifiedEmpty: false, data: [Any]()))
        let hasEmptyReason = refusal.refusalReason == "readback_empty_unverified"
        #expect(hasEmptyReason)
    }

    @Test("a cache source refuses while ax_live is admissible for live verification")
    func cachedReadbackIsRefused() throws {
        let clean = Self.verdict(try Self.readback(source: "ax_live"))
        #expect(clean.isAdmissible)

        let refusal = Self.verdict(try Self.readback(source: "cache"))
        let hasNotLiveReason = refusal.refusalReason == "readback_not_ax_live"
        #expect(hasNotLiveReason)
    }

    @Test("each deadline class accepts its bound and refuses an older observation")
    func expiredReadbackIsRefusedAtItsOwnDeadline() throws {
        for deadline in [DeadlineClass.short, .medium, .long] {
            let clean = Self.verdict(try Self.readback(cacheAge: deadline.seconds), deadline: deadline)
            #expect(clean.isAdmissible)

            let refusal = Self.verdict(
                try Self.readback(cacheAge: deadline.seconds + 0.01),
                deadline: deadline
            )
            let hasExpiredAgeReason = refusal.refusalReason == "readback_cache_age_exceeded"
            #expect(hasExpiredAgeReason)
        }
    }

    @Test("a stale equal readback is refused before equality could confirm it")
    func staleButEqualReadbackIsRefused() throws {
        let expected = [["id": 1, "name": "Track 1"]]
        let fresh = try Self.readback(data: expected, cacheAge: DeadlineClass.medium.seconds)
        let stale = try Self.readback(data: expected, cacheAge: DeadlineClass.medium.seconds + 0.01)
        let valuesMatch = try Self.payload(of: fresh) == Self.payload(of: stale)
        #expect(valuesMatch)

        let refusal = Self.verdict(stale, deadline: .medium)
        let hasExpiredAgeReason = refusal.refusalReason == "readback_cache_age_exceeded"
        #expect(hasExpiredAgeReason)
    }

    @Test("the qualification result refuses a stale equal live readback before semantic equality")
    func staleEqualReadbackCannotPassQualification() throws {
        let freshReadback = try Self.healthReadback(cacheAge: 0.28)
        let freshResult = Self.liveVerificationResult(readback: freshReadback)
        let freshPasses = freshResult.status == .passed
        #expect(freshPasses)

        let staleReadback = try Self.healthReadback(cacheAge: DeadlineClass.short.seconds + 0.01)
        let staleResult = Self.liveVerificationResult(readback: staleReadback)
        let valuesMatch = staleResult.responseData == staleResult.readbackData
        #expect(valuesMatch)
        let staleIsRefused = staleResult.status == .notQualified
        #expect(staleIsRefused)
        let hasExpiredAgeReason = staleResult.deferral?.detail == "readback_cache_age_exceeded"
        #expect(hasExpiredAgeReason)
    }

    @Test("a missing cache age is unknown and cannot satisfy a live-verification bound")
    func missingCacheAgeIsRefused() throws {
        let clean = Self.verdict(try Self.readback(cacheAge: 0.28))
        #expect(clean.isAdmissible)

        let refusal = Self.verdict(try Self.readback(includesCacheAge: false))
        let hasUnknownAgeReason = refusal.refusalReason == "readback_cache_age_unknown"
        #expect(hasUnknownAgeReason)
    }

    @Test("operations without a live-verification contract keep their existing readback semantics")
    func nonLiveVerificationIsUnaffected() throws {
        let inadmissibleForLiveVerification = try Self.readback(
            source: "cache",
            readable: false,
            axOccluded: true,
            data: [Any](),
            cacheAge: DeadlineClass.long.seconds + 1
        )
        let result = Self.verdict(inadmissibleForLiveVerification, verification: .none)
        #expect(result.isAdmissible)

        let nonLiveResult = Self.liveVerificationResult(
            readback: try Self.healthReadback(
                cacheAge: DeadlineClass.long.seconds + 1,
                source: "cache",
                readable: false,
                axOccluded: true
            ),
            verification: .none
        )
        let preservesExistingPass = nonLiveResult.status == .passed
        #expect(preservesExistingPass)
    }

    private static func payload(of readback: Data) throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: readback) as? [String: Any])
        let data = try #require(object["data"])
        return try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    }

    private static func healthReadback(
        cacheAge: Double,
        source: String = "ax_live",
        readable: Bool = true,
        axOccluded: Bool = false
    ) throws -> Data {
        let variants: [[String: Any]] = [
            ["variant": "desktop", "bundle_id": "com.apple.logic10", "installed": true, "running": true],
            ["variant": "creator_studio", "bundle_id": "com.apple.logicpro", "installed": false, "running": false],
        ]
        let object: [String: Any] = [
            "source": source,
            "readable": readable,
            "ax_occluded": axOccluded,
            "verified_empty": false,
            "cache_age_sec": cacheAge,
            "data": [["id": 1, "name": "Track 1"]],
            "logic_pro_running": true,
            "logic_pro_version": "11.2",
            "logic_pro_bundle_id": "com.apple.logic10",
            "logic_pro_variant": "desktop",
            "logic_pro_ui_locale": "en-US",
            "process_metadata_resolved": true,
            "logic_pro_variants": variants,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func liveVerificationResult(
        readback: Data,
        verification: VerificationPolicy = .readbackRequired
    ) -> QualificationOperationResult {
        QualificationOperationResult(
            operationID: OperationID.systemHealth.rawValue,
            tool: ToolID.logicSystem.rawValue,
            command: "health",
            mutability: .readOnly,
            requestID: "freshness-response",
            responseData: readback,
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://tracks",
            readbackRequestID: "freshness-readback",
            readbackData: readback,
            verification: verification,
            deadline: .short,
            failureReason: nil
        )
    }
}

/// #882 review BLOCKER 1 — the recipe's OWN readings decide whether a reading happened.
///
/// `readbackFreshness` cannot answer this. It is computed from the operation's later readback and
/// returns `.admissible` for every verification policy that is not `.readbackRequired` —
/// `transport.toggle_cycle` and `transport.set_tempo` among them.
///
/// The first version of this paragraph said the two mixer operations were `.none`. They are not:
/// `OperationRegistry` hardcodes `verification: .readbackRequired` for the whole mixer block, and
/// the `.none` beside those rows is the ConfirmationPolicy. Corrected after a blind review named
/// the line.
@Suite("Phase-B record readings")
struct QualificationRecipeReadingTests {
    private static func envelope(
        readable: Bool? = nil, axOccluded: Bool? = nil,
        rows: String = #"[{"index":0,"volume":0.4}]"#, verifiedEmpty: Bool? = nil
    ) -> String {
        var fields = [#""data_source":"ax_live""#, "\"data\":\(rows)"]
        if let readable { fields.append("\"readable\":\(readable)") }
        if let axOccluded { fields.append("\"ax_occluded\":\(axOccluded)") }
        if let verifiedEmpty { fields.append("\"verified_empty\":\(verifiedEmpty)") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func record(
        preState: String? = nil, readback: String? = nil, restoreReadback: String? = nil
    ) -> QualificationMutationRestoreRecord {
        QualificationMutationRestoreRecord(
            operationID: "mixer.set_volume",
            preState: preState ?? envelope(),
            mutation: "{\"state\":\"A\"}",
            readback: readback ?? envelope(),
            restore: "{\"state\":\"A\"}",
            restoreReadback: restoreReadback ?? envelope()
        )
    }

    @Test("three real readings are not flagged")
    func allThreeReadingsHappened() {
        #expect(Self.record().readingThatDidNotHappen == nil)
    }

    @Test("an unreadable reading is named, whichever of the three it is")
    func unreadableIsNamed() throws {
        let pre = try #require(Self.record(preState: Self.envelope(readable: false))
            .readingThatDidNotHappen)
        #expect(pre.contains("pre_state"))
        // `hasPrefix`, not `contains`: "restore_readback" CONTAINS "readback", so a `contains`
        // test passes when the loop misattributes the middle reading to the last one. Blind review
        // 2026-09-15 pointed out that only the pre_state case discriminated.
        let mid = try #require(Self.record(readback: Self.envelope(readable: false))
            .readingThatDidNotHappen)
        #expect(mid.hasPrefix("readback:"))
        let post = try #require(Self.record(restoreReadback: Self.envelope(readable: false))
            .readingThatDidNotHappen)
        #expect(post.hasPrefix("restore_readback:"))
    }

    @Test("an occluded reading is named")
    func occludedIsNamed() throws {
        let why = try #require(Self.record(readback: Self.envelope(axOccluded: true))
            .readingThatDidNotHappen)
        #expect(why.hasPrefix("readback:"))
        #expect(why.contains("ax_occluded"))
    }

    @Test("empty is a reading only when the emptiness was verified")
    func emptyNeedsVerification() throws {
        let unverified = try #require(Self.record(readback: Self.envelope(rows: "[]"))
            .readingThatDidNotHappen)
        #expect(unverified.contains("verified_empty"))
        #expect(Self.record(readback: Self.envelope(rows: "[]", verifiedEmpty: true))
            .readingThatDidNotHappen == nil)
    }

    /// The transport family's envelope carries neither `readable` nor `verified_empty` — it says
    /// the same thing with `unverified: true` beside `source: "cache"`. Without this case the check
    /// was inert for exactly the operations whose verification policy is `.none`, which is the only
    /// family where it is the sole defence.
    @Test("a self-declared unverified reading is named")
    func unverifiedIsNamed() throws {
        let cached = #"{"source":"cache","unverified":true,"stale":true,"data":{"state":"playing"}}"#
        let why = try #require(Self.record(readback: cached).readingThatDidNotHappen)
        #expect(why.hasPrefix("readback:"))
        #expect(why.contains("unverified"))
        let live = #"{"source":"ax_live","data":{"state":"playing"}}"#
        #expect(Self.record(readback: live).readingThatDidNotHappen == nil)
    }

    @Test("a body that is not an envelope is not a reading")
    func nonEnvelopeIsNotAReading() throws {
        let why = try #require(Self.record(readback: "not json").readingThatDidNotHappen)
        #expect(why.hasPrefix("readback:"))
    }
}

// MARK: - one emptiness predicate, a case per shape

/// Two checks in one subsystem used to answer this differently. `QualificationTransport` refused an
/// absent `data` key; this gate waved it through its `default` arm. Whether a rowless readback was
/// admissible depended on which gate asked, and nothing said so. They are one predicate now, and
/// every shape it can be handed has a case here — including the two that used to fall through.
@Suite("readback emptiness, by shape")
struct ReadbackEmptinessByShapeTests {
    @Test("an absent `data` key is EMPTY — nothing was published, not rows nobody looked at")
    func absentIsEmpty() {
        #expect(QualificationReadbackFreshness.isEmpty(nil))
    }

    @Test("an explicit null is empty")
    func nullIsEmpty() {
        #expect(QualificationReadbackFreshness.isEmpty(NSNull()))
    }

    @Test("an array says what it holds")
    func arraysAnswerByCount() {
        #expect(QualificationReadbackFreshness.isEmpty([Any]()))
        #expect(!QualificationReadbackFreshness.isEmpty([["name": "Track 1"]]))
    }

    /// The shape both checks were blind to. `SemanticOracleTable` reads
    /// `readback["data"] as? [String: Any]`, so a dictionary payload is live here — and an empty
    /// one used to read as "not empty" and pass.
    @Test("a dictionary payload answers by count too, and used to be invisible")
    func dictionariesAnswerByCount() {
        #expect(QualificationReadbackFreshness.isEmpty([String: Any]()))
        #expect(!QualificationReadbackFreshness.isEmpty(["tempo": 120]))
    }

    /// The narrow `default`. A string or a number under `data` is a shape nothing here
    /// understands; calling it non-empty leaves the refusal to the next check rather than
    /// inventing one, and the case is written down so the narrowness is a decision and not an
    /// oversight.
    @Test("a shape this predicate does not understand is not claimed empty")
    func unknownShapesAreNotClaimedEmpty() {
        #expect(!QualificationReadbackFreshness.isEmpty("rows"))
        #expect(!QualificationReadbackFreshness.isEmpty(0))
    }

    /// The end the product cares about: a body with no `data` at all must not be admissible, and
    /// before this it was — on the freshness side.
    @Test("a body publishing no rows is refused as empty-unverified, not admitted")
    func aBodyWithNoRowsIsRefused() throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["source": "ax_live", "cache_age_sec": 1] as [String: Any])
        let verdict = QualificationReadbackFreshness.verdict(
            for: body,
            uri: "logic://tracks",
            verification: .readbackRequired,
            deadline: .short
        )
        #expect(verdict == .emptyUnverified, "got \(verdict)")
    }
}
