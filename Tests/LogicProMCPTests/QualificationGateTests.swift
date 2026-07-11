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

    @Test func missingRequiredCombinationRejects() {
        let missingKey = QualificationAxis.requiredCombinations[0].key
        let decision = evaluate(cases: Array(passedRequiredCases().dropFirst()))

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.requiredCombinationNotQualified(key: missingKey)))
    }

    @Test func failedRequiredCaseRejects() {
        let failedKey = "\(QualificationAxis.requiredCombinations[0].key)/empty"
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
        #expect(decision.rejections == [
            .binarySHAMismatch(expected: "not-a-sha", actual: "not-a-sha"),
        ])
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

    @Test func waivedRequiredCombinationDoesNotCountAsPassed() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        let waivedKey = "\(requiredKey)/empty"
        var cases = passedRequiredCases()
        cases[0] = qualificationCase(id: waivedKey, status: .waived)

        let decision = evaluate(
            cases: cases,
            waivers: [waiver(caseID: waivedKey, expiryVersion: "1.3.0")]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections.contains(.requiredCombinationNotQualified(key: requiredKey)))
    }

    @Test func unverifiedPassedRequiredCombinationDoesNotCountAsPassed() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        var cases = passedRequiredCases()
        cases[0] = qualificationCase(
            id: "\(requiredKey)/empty",
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
            id: "\(requiredKey)/empty",
            status: .passed,
            evidenceFiles: []
        )

        let decision = evaluate(cases: cases)

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .requiredCombinationNotQualified(key: requiredKey),
        ])
    }

    @Test func failedFixtureBlocksPassedSiblingFixture() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        let failedID = "\(requiredKey)/medium"
        let decision = evaluate(
            cases: passedRequiredCases() + [qualificationCase(id: failedID, status: .failed)]
        )

        #expect(!decision.promotable)
        #expect(decision.rejections == [.requiredCaseFailed(caseID: failedID)])
    }

    @Test func multipleFailedFixturesReportLexicallyFirstID() {
        let requiredKey = QualificationAxis.requiredCombinations[0].key
        let largeID = "\(requiredKey)/large"
        let mediumID = "\(requiredKey)/medium"
        let decision = evaluate(
            cases: passedRequiredCases()
                + [qualificationCase(id: mediumID, status: .failed)]
                + [qualificationCase(id: largeID, status: .failed)]
        )

        #expect(decision.rejections == [.requiredCaseFailed(caseID: largeID)])
    }

    @Test func duplicatePassedCaseIDDoesNotQualify() {
        let duplicate = passedRequiredCases()[0]
        let decision = evaluate(cases: passedRequiredCases() + [duplicate])

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .requiredCombinationNotQualified(key: QualificationAxis.requiredCombinations[0].key),
        ])
    }

    @Test func duplicateMixedCaseIDDoesNotQualify() {
        let duplicate = passedRequiredCases()[0]
        let notQualified = qualificationCase(id: duplicate.id, status: .notQualified)
        let decision = evaluate(cases: passedRequiredCases() + [notQualified])

        #expect(!decision.promotable)
        #expect(decision.rejections == [
            .requiredCombinationNotQualified(key: QualificationAxis.requiredCombinations[0].key),
        ])
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
            "desktop/en-US/core/cold",
            "desktop/ko-KR/core/cold",
            "creator/en-US/core/cold",
            "creator/ko-KR/core/cold",
        ])
    }

    private func evaluate(
        cases: [QualificationCase],
        waivers: [QualificationWaiver] = [],
        attestationVersion: String = "1.2.3",
        releaseVersion: String = "1.2.3",
        expectedBinarySHA256: String? = nil,
        presentArtifacts: Set<String>? = nil,
        attestationSHA256: String? = nil
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
            requiredArtifacts: requiredArtifacts
        )
    }

    private func attestation(
        serverVersion: String = "1.2.3",
        binarySHA256: String? = nil,
        cases: [QualificationCase],
        waivers: [QualificationWaiver]
    ) -> ReleaseQualificationAttestation {
        ReleaseQualificationAttestation(
            schema: "release-qualification-attestation/v1",
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
            qualificationCase(id: "\($0.key)/empty", status: .passed)
        }
    }

    private func qualificationCase(
        id: String,
        status: QualificationStatus,
        verified: Bool? = nil,
        evidenceFiles: [String]? = nil
    ) -> QualificationCase {
        let isVerified = verified ?? (status == QualificationStatus.passed)
        return QualificationCase(
            id: id,
            status: status,
            tool: "logic_system",
            command: "doctor",
            traceID: "lpmcp_00000000-0000-0000-0000-000000000000",
            verified: isVerified,
            evidenceFiles: evidenceFiles ?? ["evidence/\(id).json"]
        )
    }

    private func waiver(caseID: String, expiryVersion: String) -> QualificationWaiver {
        QualificationWaiver(
            caseID: caseID,
            reasonCode: "known-limitation",
            owningIssue: "#284",
            userImpact: "Optional capability unavailable",
            affectedCapability: "optional-capability",
            affectsDefaultProfile: false,
            expiryVersion: expiryVersion,
            releaseNoteVisible: true
        )
    }
}
