import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-001 qualification gate")
struct QualificationGateTests {
    private let requiredArtifacts: Set<String> = ["LogicProMCP", "evidence-manifest.json"]
    private let binarySHA256 = String(repeating: "a", count: 64)

    @Test func allRequiredCombinationsPassedPromotes() {
        let decision = evaluate(cases: passedRequiredCases())

        #expect(decision.promotable)
        #expect(decision.rejections.isEmpty)
    }

    @Test func promotionGateDistinguishesGovernedAndUngovernedUnavailableAxes() {
        let liveAxis = QualificationAxis.requiredCombinations[0]
        let governedCases = QualificationAxis.requiredCombinations.map { axis in
            qualificationCase(
                id: axis.key,
                status: axis.variant == liveAxis.variant ? .passed : .notQualified,
                reason: axis.variant == liveAxis.variant
                    ? nil
                    : "required axis unavailable: different observed Logic variant or UI locale",
                axis: axis,
                availabilityReason: axis.variant == liveAxis.variant ? nil : availabilityReason(
                    for: axis,
                    observedAxis: liveAxis
                )
            )
        }

        let governed = evaluate(cases: governedCases)
        #expect(governed.promotable)
        #expect(governed.rejections.isEmpty)

        let creatorInstalled = qualificationAvailabilityObservation(
            for: liveAxis,
            creatorInstalled: true
        )
        let unjustifiedVariantSkips = QualificationAxis.requiredCombinations.map { axis in
            qualificationCase(
                id: axis.key,
                status: axis == liveAxis ? .passed : .notQualified,
                reason: axis == liveAxis
                    ? nil
                    : "required axis unavailable: different observed Logic variant or UI locale",
                axis: axis,
                availabilityReason: axis == liveAxis ? nil : availabilityReason(
                    for: axis,
                    observedAxis: liveAxis
                ),
                availabilityObservation: creatorInstalled
            )
        }
        #expect(!evaluate(cases: unjustifiedVariantSkips).promotable)

        var arbitraryCases = governedCases
        arbitraryCases[1] = qualificationCase(
            id: arbitraryCases[1].id,
            status: .notQualified,
            reason: "operator excluded this axis",
            axis: arbitraryCases[1].axis,
            availabilityReason: arbitraryCases[1].availabilityReason
        )
        #expect(!evaluate(cases: arbitraryCases).promotable)

        let noLiveCases = QualificationAxis.requiredCombinations.map { axis in
            qualificationCase(
                id: axis.key,
                status: .notQualified,
                reason: "required axis unavailable: different observed Logic variant or UI locale",
                axis: axis,
                availabilityReason: availabilityReason(for: axis, observedAxis: liveAxis)
            )
        }
        #expect(!evaluate(cases: noLiveCases).promotable)
    }

    @Test func localeDifferentAxisWithoutWaiverRejectsPromotion() {
        let liveAxis = QualificationAxis.requiredCombinations[0]
        let cases = QualificationAxis.requiredCombinations.map { axis in
            qualificationCase(
                id: axis.key,
                status: axis == liveAxis ? .passed : .notQualified,
                reason: axis == liveAxis
                    ? nil
                    : "required axis unavailable: different observed Logic variant or UI locale",
                axis: axis,
                availabilityReason: axis == liveAxis ? nil : availabilityReason(
                    for: axis,
                    observedAxis: liveAxis
                )
            )
        }
        let localeAxis = QualificationAxis.requiredCombinations[1]

        let decision = evaluate(cases: cases)

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .requiredCombinationNotQualified(key: localeAxis.key)
        ))
    }

    @Test func localeDifferentAxisWithPerAxisWaiverPromotes() {
        let liveAxis = QualificationAxis.requiredCombinations[0]
        let localeAxis = QualificationAxis.requiredCombinations[1]
        let cases = QualificationAxis.requiredCombinations.map { axis in
            qualificationCase(
                id: axis.key,
                status: axis == liveAxis ? .passed : axis == localeAxis ? .waived : .notQualified,
                reason: axis == liveAxis
                    ? nil
                    : "required axis unavailable: different observed Logic variant or UI locale",
                axis: axis,
                availabilityReason: axis == liveAxis ? nil : availabilityReason(
                    for: axis,
                    observedAxis: liveAxis
                )
            )
        }
        let waiver = waiver(
            caseID: localeAxis.key,
            expiryVersion: "1.3.0",
            affectedCapability: QualificationWaiver.hostAxisAvailabilityCapability
        )

        let decision = evaluate(cases: cases, waivers: [waiver])

        #expect(decision.promotable)
        #expect(decision.rejections.isEmpty)
    }

    @Test func localeDifferentAxisWithLiveCasePromotes() {
        let decision = evaluate(cases: passedRequiredCases())

        #expect(decision.promotable)
        #expect(decision.rejections.isEmpty)
    }

    @Test func trulyUninstalledVariantRemainsGovernedUnavailable() {
        let liveAxis = QualificationAxis.requiredCombinations[0]
        let secondLiveLocale = QualificationAxis.requiredCombinations[1]
        let cases = QualificationAxis.requiredCombinations.map { axis in
            qualificationCase(
                id: axis.key,
                status: axis.variant == .desktop ? .passed : .notQualified,
                reason: axis.variant == .desktop
                    ? nil
                    : "required axis unavailable: different observed Logic variant or UI locale",
                axis: axis,
                availabilityReason: axis.variant == .desktop ? nil : availabilityReason(
                    for: axis,
                    observedAxis: liveAxis
                ),
                availabilityObservation: axis == secondLiveLocale
                    ? qualificationAvailabilityObservation(for: secondLiveLocale)
                    : qualificationAvailabilityObservation(for: liveAxis)
            )
        }

        let decision = evaluate(cases: cases)

        #expect(decision.promotable)
        #expect(decision.rejections.isEmpty)
    }

    @Test func promotionDoesNotCountProtocolSmokeAsQualified() throws {
        let smokeStatus = try JSONDecoder().decode(
            QualificationStatus.self,
            from: Data(#""protocol_smoke""#.utf8)
        )
        let smokeKind = try JSONDecoder().decode(
            QualificationVerificationKind.self,
            from: Data(#""protocol_smoke""#.utf8)
        )
        let smokeCase = QualificationCase(
            id: "in-process/\(OperationID.systemPermissions.rawValue)",
            status: smokeStatus,
            tool: ToolID.logicSystem.rawValue,
            command: "permissions",
            traceID: "",
            verified: false,
            evidenceFiles: ["evidence/operation-system.permissions.json"],
            reason: "protocol transport succeeded without an operation-specific semantic validator",
            binarySHA256: binarySHA256,
            axis: .defaultAxis,
            operationID: OperationID.systemPermissions.rawValue,
            operationRequestID: "smoke-response",
            verificationKind: smokeKind,
            readback: QualificationReadbackEvidence(
                source: "logic://system/health",
                requestID: "smoke-readback",
                verified: false,
                sha256: String(repeating: "b", count: 64)
            )
        )

        let decision = evaluate(cases: passedRequiredCases() + [smokeCase])

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .requiredOperationNotSatisfied(operationID: OperationID.systemPermissions.rawValue)
        ))
    }

    @Test func missingRequiredOperationCaseRejectsPromotion() {
        let operationID = OperationID.systemHealth.rawValue

        let decision = evaluate(
            cases: passedRequiredCases(),
            requiredOperationIDs: [operationID]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .requiredOperationNotSatisfied(operationID: operationID)
        ))
    }

    @Test func missingRequiredCombinationRejects() {
        let missingKey = QualificationAxis.requiredCombinations[0].key
        let decision = evaluate(cases: Array(passedRequiredCases().dropFirst()))

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.requiredCombinationNotQualified(key: missingKey)))
    }

    @Test func failedRequiredCaseRejects() {
        let failedKey = QualificationAxis.requiredCombinations[0].key
        var cases = passedRequiredCases()
        cases[0] = qualificationCase(id: failedKey, status: .failed)

        let decision = evaluate(cases: cases)

        #expect(!decision.promotable)
        #expect(decision.rejections == [.requiredCaseFailed(caseID: failedKey)])
    }

    @Test func binarySHAMismatchRejects() {
        let expected = String(repeating: "b", count: 64)
        let decision = evaluate(cases: passedRequiredCases(), expectedBinarySHA256: expected)

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .binarySHAMismatch(expected: expected, actual: binarySHA256),
        ])
    }

    @Test func missingRequiredArtifactRejects() {
        let decision = evaluate(
            cases: passedRequiredCases(),
            presentArtifacts: ["LogicProMCP"]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.missingArtifact(name: "evidence-manifest.json")))
    }

    @Test func invalidEqualBinarySHAsReject() {
        let decision = evaluate(
            cases: passedRequiredCases(),
            expectedBinarySHA256: "not-a-sha",
            attestationSHA256: "not-a-sha"
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .binarySHAMismatch(expected: "not-a-sha", actual: "not-a-sha")
        ))
        #expect(QualificationAxis.requiredCombinations.allSatisfy { axis in
            decision.rejections.contains(.requiredCombinationNotQualified(key: axis.key))
        })
    }

    @Test func expiredWaiverAtReleaseVersionRejects() {
        let decision = evaluate(
            cases: passedRequiredCases(),
            waivers: [waiver(caseID: "optional-case", expiryVersion: "v1.2.3")]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.expiredWaiver(caseID: "optional-case")))
    }

    @Test func validNonRequiredWaiverDoesNotReject() {
        let decision = evaluate(
            cases: passedRequiredCases() + [qualificationCase(id: "optional-case", status: .waived)],
            waivers: [waiver(caseID: "optional-case", expiryVersion: "1.3.0")]
        )

        #expect(decision.promotable)
        #expect(decision.rejections.isEmpty)
    }

    @Test func waiverForUnknownCaseRejectsPromotion() {
        let decision = evaluate(
            cases: passedRequiredCases(),
            waivers: [waiver(caseID: "missing-case", expiryVersion: "1.3.0")]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.waiverForUnknownCase(caseID: "missing-case")))
    }

    @Test func waiverForPassingCaseRejectsPromotion() {
        let passedCase = qualificationCase(id: "optional-case", status: .passed)
        let decision = evaluate(
            cases: passedRequiredCases() + [passedCase],
            waivers: [waiver(caseID: passedCase.id, expiryVersion: "1.3.0")]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.waiverForPassingCase(caseID: passedCase.id)))
    }

    @Test func waiverForFailedCaseRejectsPromotion() {
        let failedCase = qualificationCase(id: "optional-case", status: .failed)
        let decision = evaluate(
            cases: passedRequiredCases() + [failedCase],
            waivers: [waiver(caseID: failedCase.id, expiryVersion: "1.3.0")]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .waiverForNonWaivedCase(caseID: failedCase.id, status: .failed)
        ))
    }

    @Test func waiverForNotQualifiedCaseRejectsPromotion() {
        let skippedCase = qualificationCase(id: "optional-case", status: .notQualified)
        let decision = evaluate(
            cases: passedRequiredCases() + [skippedCase],
            waivers: [waiver(caseID: skippedCase.id, expiryVersion: "1.3.0")]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .waiverForNonWaivedCase(caseID: skippedCase.id, status: .notQualified)
        ))
    }

    @Test func waivedCaseWithoutWaiverRejectsPromotion() {
        let waivedCase = qualificationCase(id: "optional-case", status: .waived)
        let decision = evaluate(cases: passedRequiredCases() + [waivedCase])

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.waivedCaseMissingWaiver(caseID: waivedCase.id)))
    }

    @Test func malformedAndDuplicateWaiversRejectPromotion() {
        let waivedCase = qualificationCase(id: "optional-case", status: .waived)
        let malformed = waiver(
            caseID: waivedCase.id,
            expiryVersion: "1.3.0",
            reasonCode: "unsupported-reason",
            owningIssue: ""
        )
        let decision = evaluate(
            cases: passedRequiredCases() + [waivedCase],
            waivers: [malformed, malformed]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .invalidWaiver(caseID: waivedCase.id, field: "reasonCode")
        ))
        #expect(decision.rejections.contains(
            .invalidWaiver(caseID: waivedCase.id, field: "owningIssue")
        ))
        #expect(decision.rejections.contains(.duplicateWaiver(caseID: waivedCase.id)))
    }

    @Test func waivedRequiredCombinationDoesNotCountAsPassed() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        let waivedKey = requiredKey
        var cases = passedRequiredCases()
        cases[0] = qualificationCase(id: waivedKey, status: .waived)

        let decision = evaluate(
            cases: cases,
            waivers: [waiver(caseID: waivedKey, expiryVersion: "1.3.0")]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.requiredCombinationNotQualified(key: requiredKey)))
    }

    @Test func adr001aWaivedRequiredCombinationCountsAsQualified() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        let waivedKey = requiredKey
        var cases = passedRequiredCases()
        cases[0] = qualificationCase(id: waivedKey, status: .waived)

        let decision = evaluate(
            cases: cases,
            waivers: [waiver(
                caseID: waivedKey,
                expiryVersion: "1.3.0",
                affectedCapability: QualificationWaiver.hostAxisAvailabilityCapability
            )]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.requiredCombinationNotQualified(key: requiredKey)))
    }

    @Test func adr001aWaiversCannotReplaceEveryLiveAxis() {
        let cases = QualificationAxis.requiredCombinations.map {
            qualificationCase(id: $0.key, status: .waived, axis: $0)
        }
        let waivers = cases.map {
            waiver(
                caseID: $0.id,
                expiryVersion: "1.3.0",
                affectedCapability: QualificationWaiver.hostAxisAvailabilityCapability
            )
        }

        let decision = evaluate(cases: cases, waivers: waivers)

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(
            .requiredCombinationNotQualified(key: QualificationAxis.requiredCombinations[0].key)
        ))
    }

    @Test func unverifiedPassedRequiredCombinationDoesNotCountAsPassed() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        var cases = passedRequiredCases()
        cases[0] = qualificationCase(
            id: requiredKey,
            status: .passed,
            verified: false
        )

        let decision = evaluate(cases: cases)

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.requiredCombinationNotQualified(key: requiredKey)))
    }

    @Test func passedRequiredCombinationWithoutEvidenceDoesNotCountAsPassed() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        var cases = passedRequiredCases()
        cases[0] = qualificationCase(
            id: requiredKey,
            status: .passed,
            evidenceFiles: []
        )

        let decision = evaluate(cases: cases)

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .requiredCombinationNotQualified(key: requiredKey),
        ])
    }

    @Test func failedNonRequiredFixtureDoesNotReplaceRequiredAxis() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        let failedID = "\(requiredKey)/medium"
        let decision = evaluate(
            cases: passedRequiredCases() + [qualificationCase(id: failedID, status: .failed)]
        )

        #expect(decision.promotable)
        #expect(decision.rejections.isEmpty)
    }

    @Test func multipleNonRequiredFixtureFailuresDoNotAffectRequiredAxis() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        let largeID = "\(requiredKey)/large"
        let mediumID = "\(requiredKey)/medium"
        let decision = evaluate(
            cases: passedRequiredCases()
                + [qualificationCase(id: mediumID, status: .failed)]
                + [qualificationCase(id: largeID, status: .failed)]
        )

        #expect(decision.promotable)
        #expect(decision.rejections.isEmpty)
    }

    @Test func duplicatePassedCaseIDDoesNotQualify() {
        let duplicate = passedRequiredCases()[0]
        let decision = evaluate(cases: passedRequiredCases() + [duplicate])

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .duplicateCaseID(caseID: duplicate.id),
        ])
    }

    @Test func duplicateMixedCaseIDDoesNotQualify() {
        let duplicate = passedRequiredCases()[0]
        let notQualified = qualificationCase(id: duplicate.id, status: .notQualified)
        let decision = evaluate(cases: passedRequiredCases() + [notQualified])

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .duplicateCaseID(caseID: duplicate.id),
        ])
    }

    @Test func duplicateOptionalCaseIDRejectsPromotion() {
        let duplicate = qualificationCase(id: "optional-case", status: .passed)
        let decision = evaluate(cases: passedRequiredCases() + [duplicate, duplicate])

        #expect(!decision.promotable)
        #expect(decision.rejections == [.duplicateCaseID(caseID: duplicate.id)])
    }

    @Test func releaseVersionMismatchRejects() {
        let decision = evaluate(cases: passedRequiredCases(), attestationVersion: "1.2.2")

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.releaseVersionMismatch(expected: "1.2.3", actual: "1.2.2")))
    }

    @Test func equalInvalidReleaseVersionsReject() {
        let decision = evaluate(
            cases: passedRequiredCases(),
            attestationVersion: "banana",
            releaseVersion: "banana"
        )

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .releaseVersionMismatch(expected: "banana", actual: "banana"),
        ])
    }

    @Test func attestationCodableRoundTripPreservesDates() throws {
        let original = attestation(
            cases: passedRequiredCases(),
            waivers: [waiver(caseID: "optional-case", expiryVersion: "1.3.0")]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReleaseQualificationAttestation.self, from: data)

        #expect(decoded == original)
        #expect(decoded.startedAt == Date(timeIntervalSince1970: 1_000))
        #expect(decoded.completedAt == Date(timeIntervalSince1970: 1_060))
    }

    @Test func requiredCombinationKeysAreExact() {
        #expect(QualificationAxis.requiredCombinations.count == 4)
        #expect(QualificationAxis.requiredCombinations.map(\.key) == [
            "desktop/en-US/core/cold/empty",
            "desktop/ko-KR/core/cold/empty",
            "creator/en-US/core/cold/empty",
            "creator/ko-KR/core/cold/empty",
        ])
    }

    private func evaluate(
        cases: [QualificationCase],
        waivers: [QualificationWaiver] = [],
        attestationVersion: String = "1.2.3",
        releaseVersion: String = "1.2.3",
        expectedBinarySHA256: String? = nil,
        presentArtifacts: Set<String>? = nil,
        attestationSHA256: String? = nil,
        requiredOperationIDs: Set<String>? = nil
    ) -> PromotionDecision {
        PromotionGate().evaluate(
            attestation: attestation(
                serverVersion: attestationVersion,
                binarySHA256: attestationSHA256,
                cases: cases,
                waivers: waivers
            ),
            releaseVersion: releaseVersion,
            expectedBinarySHA256: expectedBinarySHA256 ?? binarySHA256,
            presentArtifacts: presentArtifacts ?? requiredArtifacts,
            requiredArtifacts: requiredArtifacts,
            requiredOperationIDs: requiredOperationIDs ?? Set(
                cases.filter { $0.id.hasPrefix("in-process/") }.map(\.operationID)
            )
        )
    }

    private func attestation(
        serverVersion: String = "1.2.3",
        binarySHA256: String? = nil,
        cases: [QualificationCase],
        waivers: [QualificationWaiver]
    ) -> ReleaseQualificationAttestation {
        ReleaseQualificationAttestation(
            schema: "release-qualification-attestation/v2",
            serverVersion: serverVersion,
            commitSHA: String(repeating: "c", count: 40),
            binarySHA256: binarySHA256 ?? self.binarySHA256,
            logicVariant: .desktop,
            logicVersion: "11.2.0",
            locale: .enUS,
            profile: .core,
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_060),
            total: cases.count,
            passed: cases.filter { $0.status == .passed }.count,
            failed: cases.filter { $0.status == .failed }.count,
            waived: cases.filter { $0.status == .waived }.count,
            cases: cases,
            waivers: waivers,
            evidenceManifestSHA256: String(repeating: "d", count: 64)
        )
    }

    private func passedRequiredCases() -> [QualificationCase] {
        QualificationAxis.requiredCombinations.map {
            qualificationCase(id: $0.key, status: .passed, axis: $0)
        }
    }

    private func qualificationCase(
        id: String,
        status: QualificationStatus,
        verified: Bool? = nil,
        evidenceFiles: [String]? = nil,
        reason: String? = nil,
        axis: QualificationAxis? = nil,
        availabilityReason: QualificationAvailabilityReason? = nil,
        availabilityObservation: QualificationAvailabilityObservation? = nil
    ) -> QualificationCase {
        let isVerified = verified ?? (status == QualificationStatus.passed)
        let boundAxis = axis ?? QualificationAxis.requiredCombinations.first {
            id == $0.key || id.hasPrefix($0.key + "/")
        } ?? .defaultAxis
        let readback = QualificationReadbackEvidence(
            source: "logic://system/health",
            requestID: "gate-test-\(id)",
            verified: status == .passed,
            sha256: String(repeating: "b", count: 64)
        )
        let deferral = status == .notQualified || status == .waived
            ? QualificationDeferral(
                code: .operationUnavailable,
                detail: reason ?? "required axis unavailable: unspecified"
            )
            : nil
        return QualificationCase(
            id: id,
            status: status,
            tool: "logic_system",
            command: "doctor",
            traceID: "lpmcp_00000000-0000-0000-0000-000000000000",
            verified: isVerified,
            evidenceFiles: evidenceFiles ?? ["evidence/\(id).json"],
            reason: reason,
            binarySHA256: binarySHA256,
            axis: boundAxis,
            operationID: "qualification.\(boundAxis.key)",
            verificationKind: status == .passed ? .independentReadback : .typedDeferral,
            deferral: deferral,
            readback: readback,
            availabilityReason: availabilityReason,
            availabilityObservation: availabilityObservation
                ?? qualificationAvailabilityObservation(
                    for: status == .passed ? boundAxis : .defaultAxis
                )
        )
    }

    private func qualificationAvailabilityObservation(
        for axis: QualificationAxis,
        creatorInstalled: Bool = false
    ) -> QualificationAvailabilityObservation {
        QualificationAvailabilityObservation(
            activeBundleID: axis.variant == .creatorStudio
                ? LogicProVariant.creatorStudio.bundleID
                : LogicProVariant.desktop.bundleID,
            activeVariant: axis.variant,
            logicUILocale: axis.locale,
            variants: LogicVariant.allCases.map { variant in
                let active = variant == axis.variant
                return QualificationVariantAvailability(
                    variant: variant,
                    bundleID: variant == .creatorStudio
                        ? LogicProVariant.creatorStudio.bundleID
                        : LogicProVariant.desktop.bundleID,
                    installed: active || (variant == .creatorStudio && creatorInstalled),
                    running: active
                )
            }
        )
    }

    private func availabilityReason(
        for axis: QualificationAxis,
        observedAxis: QualificationAxis
    ) -> QualificationAvailabilityReason? {
        switch (axis.variant != observedAxis.variant, axis.locale != observedAxis.locale) {
        case (true, true): .differentLogicVariantAndUILocale
        case (true, false): .differentLogicVariant
        case (false, true): .differentLogicUILocale
        case (false, false): nil
        }
    }

    private func waiver(
        caseID: String,
        expiryVersion: String,
        reasonCode: String = "known-limitation",
        owningIssue: String = "#284",
        affectedCapability: String = "optional-capability"
    ) -> QualificationWaiver {
        QualificationWaiver(
            caseID: caseID,
            reasonCode: reasonCode,
            owningIssue: owningIssue,
            userImpact: "Optional capability unavailable",
            affectedCapability: affectedCapability,
            affectsDefaultProfile: false,
            expiryVersion: expiryVersion,
            releaseNoteVisible: true
        )
    }
}
