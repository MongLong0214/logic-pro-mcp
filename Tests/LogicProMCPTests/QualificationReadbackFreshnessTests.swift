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
