import Foundation
import Testing
@testable import LogicProMCP

/// #984, decided yes: a mutating operation whose qualification passed write → independent
/// readback → restore → restore read back and MATCHED is credited as live-verified, and a restore
/// record that is merely present is not enough.
///
/// Every case here starts from the real producer (`QualificationOperationResult`) and changes ONE
/// thing, and every test that asserts a refusal carries the credited case beside it in the same
/// run. A refusal alone would stay green on the rule this issue replaced, which credited no write
/// cycle at all.
///
/// NO `#expect(<Bool> == <Bool>)` HERE (#393, `Scripts/ci-forbid-dead-expect.sh`): on this
/// toolchain such a comparison records no issue. A first draft of this file had one, and a mutant
/// that made every restore "verified" survived it. Booleans are asserted bare or negated, and
/// optionals are unwrapped with `#require` first.
@Suite("#984 verified write cycle credit")
struct Issue984VerifiedWriteCycleCreditTests {
    private static let binarySHA256 = String(repeating: "a", count: 64)

    /// The three readings are whole resource envelopes, because `readingThatDidNotHappen` parses
    /// each one; `mutation` and `restore` are the values written.
    private static func record(
        restoreReadback: String = #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"before"}]}"#
    ) -> QualificationMutationRestoreRecord {
        QualificationMutationRestoreRecord(
            operationID: OperationID.tracksRename.rawValue,
            preState: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"before"}]}"#,
            mutation: #"{"state":"A","success":true}"#,
            readback: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"after"}]}"#,
            restore: #"{"state":"A","success":true}"#,
            restoreReadback: restoreReadback
        )
    }

    /// A mutating probe refused fail-closed, an admissible independent readback, and the given
    /// record -- the shape `aPassingWriteCycleIsFiledAsOneAndCarriesItsRecord` pins as `.passed`.
    private static func result(
        record: QualificationMutationRestoreRecord?
    ) throws -> QualificationOperationResult {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .tracksRename })
        return QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "cycle-response",
            responseData: Data(#"{"success":false,"state":"C","error":"consent_required"}"#.utf8),
            isError: true,
            state: "C",
            error: "consent_required",
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://tracks",
            readbackRequestID: "cycle-readback",
            readbackData: Data(
                #"{"source":"ax_live","cache_age_sec":1,"data":[{"name":"after"}]}"#.utf8),
            verification: spec.verification,
            deadline: spec.deadline,
            failureReason: nil,
            mutationRestore: record
        )
    }

    /// The case the runner files for a result, field for field as `QualificationRunner` builds it.
    private static func qualificationCase(
        _ result: QualificationOperationResult,
        status: QualificationStatus? = nil,
        restore: QualificationRestoreEvidence?? = nil
    ) -> QualificationCase {
        let status = status ?? result.status
        return QualificationCase(
            id: "in-process/\(result.operationID)",
            status: status,
            tool: result.tool,
            command: result.command,
            traceID: "",
            verified: status == .passed,
            evidenceFiles: ["evidence/operation-\(result.operationID).json"],
            binarySHA256: binarySHA256,
            operationID: result.operationID,
            operationRequestID: result.requestID,
            verificationKind: result.verificationKind,
            deferral: result.deferral,
            readback: result.readback,
            restore: restore ?? result.restore
        )
    }

    private static func attestation(_ cases: [QualificationCase]) -> ReleaseQualificationAttestation {
        ReleaseQualificationAttestation(
            schema: "release-qualification-attestation/v2",
            serverVersion: "1.2.3",
            commitSHA: String(repeating: "c", count: 40),
            binarySHA256: binarySHA256,
            logicVariant: .desktop,
            logicVersion: "11.2.0",
            locale: .enUS,
            profile: .core,
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_060),
            total: cases.count,
            passed: cases.filter { $0.status == .passed }.count,
            failed: 0,
            waived: 0,
            cases: cases,
            waivers: [],
            evidenceManifestSHA256: String(repeating: "e", count: 64)
        )
    }

    /// The two readers of the credit rule, asked about one case each. Returned together so a
    /// test cannot assert one and let the other drift.
    private struct Readers: Equatable {
        let releaseGateSatisfied: Bool
        let debtBoardCredited: Bool
    }

    private static func readers(_ operationCase: QualificationCase) -> Readers {
        let operationID = operationCase.operationID
        let decision = PromotionGate().evaluate(
            attestation: attestation([operationCase]),
            releaseVersion: "1.2.3",
            expectedBinarySHA256: binarySHA256,
            presentArtifacts: [],
            requiredArtifacts: [],
            requiredOperationIDs: [operationID]
        )
        let credited = PromotionGate.liveCreditedOperationIDs(in: attestation([operationCase]))
        let report = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: "",
            registeredOperationIDs: [operationID],
            semanticValidatorOperationIDs: [],
            requiredMatrixAxisCount: 0,
            debtBoardMarkdown: nil,
            expectedAuthorityBaseSHA: nil,
            publishedReleaseEvidencePresent: false,
            mutationRestoreCompensationEvidencePresent: false,
            independentProvenanceEnforced: false,
            liveCreditedOperationIDs: credited
        )
        let rSEMOpen = report.findings.contains {
            $0.id == .semanticCoverageIncomplete && $0.detail.contains("semantic coverage missing")
        }
        return Readers(
            releaseGateSatisfied: !decision.rejections.contains(
                .requiredOperationNotSatisfied(operationID: operationID)),
            debtBoardCredited: credited == [operationID] && !rSEMOpen
        )
    }

    private static let credited = Readers(releaseGateSatisfied: true, debtBoardCredited: true)
    private static let notCredited = Readers(releaseGateSatisfied: false, debtBoardCredited: false)

    @Test func aWriteCyclePassWhoseRestoreVerifiedIsCreditedByBothReaders() throws {
        let cycle = try Self.result(record: Self.record())
        // What the producer files, so the credit below is earned by a real result's shape.
        #expect(cycle.status == .passed)
        #expect(cycle.verificationKind == .verifiedWriteCycle)
        let digest = try QualificationRunner.recordDigest(Self.record())
        #expect(cycle.restore == QualificationRestoreEvidence(recordSHA256: digest, verified: true))

        let operationCase = Self.qualificationCase(cycle)
        #expect(PromotionGate.operationIsLiveCredited(operationCase))
        #expect(Self.readers(operationCase) == Self.credited)
    }

    /// Present-but-unverified, failed, and missing, each one field away from the credited case.
    @Test func aWriteCycleWhoseRestoreDidNotVerifyCreditsNothing() throws {
        let cycle = try Self.result(record: Self.record())
        let digest = try QualificationRunner.recordDigest(Self.record())

        // Positive control, same run.
        #expect(Self.readers(Self.qualificationCase(cycle)) == Self.credited)

        let presentButUnverified = Self.qualificationCase(
            cycle, restore: .some(QualificationRestoreEvidence(recordSHA256: digest, verified: false)))
        #expect(!PromotionGate.operationIsLiveCredited(presentButUnverified))
        #expect(Self.readers(presentButUnverified) == Self.notCredited)

        let missing = Self.qualificationCase(cycle, restore: .some(nil))
        #expect(!PromotionGate.operationIsLiveCredited(missing))
        #expect(Self.readers(missing) == Self.notCredited)

        // A cycle whose restore verified but whose case did not pass. The restore is necessary,
        // not sufficient.
        let failed = Self.qualificationCase(cycle, status: .notQualified)
        let failedRestore = try #require(failed.restore)
        #expect(failedRestore.verified)
        #expect(!PromotionGate.operationIsLiveCredited(failed))
        #expect(Self.readers(failed) == Self.notCredited)
    }

    /// The producer's side of "verified": a record exists AND every reading in it happened.
    @Test func theProducerCallsARestoreVerifiedOnlyWhenItsReadingsHappened() throws {
        let good = try Self.result(record: Self.record())
        let goodRestore = try #require(good.restore)
        #expect(goodRestore.verified)

        // The restore readback did not happen. The record is still PRESENT -- which is the case
        // the decision says must not credit.
        let unread = try Self.result(record: Self.record(
            restoreReadback: #"{"source":"ax_live","readable":false,"data":[]}"#))
        let unreadRestore = try #require(unread.restore)
        #expect(!unreadRestore.verified)
        #expect(unread.status == .notQualified)

        let none = try Self.result(record: nil)
        if let restore = none.restore {
            Issue.record("a result with no record stated a restore: \(restore)")
        }
    }

    @Test func readableWrongRestoreNeverEarnsWriteCycleCredit() throws {
        let cycle = try Self.result(record: Self.record(
            restoreReadback: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"after"}]}"#))
        let restore = try #require(cycle.restore)
        #expect(!restore.verified)
        #expect(cycle.status == .notQualified)
        let operationCase = Self.qualificationCase(cycle)
        #expect(!PromotionGate.operationIsLiveCredited(operationCase))
        #expect(Self.readers(operationCase) == Self.notCredited)
    }

    @Test func valueCycleComparesTheTrackValueAndIdentity() {
        func record(_ restored: String) -> QualificationMutationRestoreRecord {
            QualificationMutationRestoreRecord(
                operationID: OperationID.mixerSetVolume.rawValue,
                preState: #"{"source":"ax_live","data":[{"track_ref":"track-1","volume":0.4}]}"#,
                mutation: #"{"state":"B","success":true}"#,
                readback: #"{"source":"ax_live","data":[{"track_ref":"track-1","volume":0.5}]}"#,
                restore: #"{"state":"A","success":true}"#,
                restoreReadback: restored
            )
        }
        #expect(record(#"{"source":"ax_live","cache_age_sec":0,"data":[{"track_ref":"track-1","volume":0.4}]}"#)
            .verifiedCycleShape)
        #expect(!record(#"{"source":"ax_live","data":[{"track_ref":"track-1","volume":0.5}]}"#)
            .verifiedCycleShape)
        #expect(!record(#"{"source":"ax_live","data":[{"track_ref":"track-2","volume":0.4}]}"#)
            .verifiedCycleShape)
    }

    /// Read credit is what it was: `.semanticReadback` does not consult `restore`.
    @Test func semanticReadbackCreditIsUnchanged() {
        func readCase(
            readbackVerified: Bool,
            restore: QualificationRestoreEvidence? = nil
        ) -> QualificationCase {
            QualificationCase(
                id: "in-process/system.health",
                status: .passed,
                tool: "logic_system",
                command: "health",
                traceID: "",
                verified: true,
                evidenceFiles: ["evidence/operation-system.health.json"],
                binarySHA256: Self.binarySHA256,
                operationID: "system.health",
                verificationKind: .semanticReadback,
                readback: QualificationReadbackEvidence(
                    source: "logic://system/health",
                    requestID: "rb",
                    verified: readbackVerified,
                    sha256: String(repeating: "b", count: 64)
                ),
                restore: restore
            )
        }
        #expect(Self.readers(readCase(readbackVerified: true)) == Self.credited)
        #expect(Self.readers(readCase(
            readbackVerified: true,
            restore: QualificationRestoreEvidence(recordSHA256: "x", verified: false)
        )) == Self.credited)
        #expect(Self.readers(readCase(readbackVerified: false)) == Self.notCredited)
    }

    /// The attestation's `restore` is what the credit rule reads, so it must name the record the
    /// case's evidence file binds -- or a bundle could say "verified" about a record it does not
    /// carry.
    @Test func aCaseMustNameTheRecordItsEvidenceBinds() throws {
        let cycle = try Self.result(record: Self.record())
        let operationCase = Self.qualificationCase(cycle)
        let evidence = CaseEvidence(
            schema: "qualification-case-evidence/v3",
            caseID: operationCase.id,
            operationID: operationCase.operationID,
            tool: operationCase.tool,
            command: operationCase.command,
            registrySpecFound: true,
            handlerBound: true,
            traceStarted: false,
            traceCompleted: false,
            binarySHA256: operationCase.binarySHA256,
            axis: operationCase.axis,
            status: operationCase.status,
            verified: operationCase.verified,
            verificationKind: operationCase.verificationKind,
            deferral: operationCase.deferral,
            readback: operationCase.readback,
            operationRequestID: operationCase.operationRequestID,
            mutationRestoreRecordSHA256: cycle.restore?.recordSHA256
        )
        #expect(QualificationRunner.evidence(evidence, binds: operationCase))

        let otherRecord = Self.qualificationCase(cycle, restore: .some(QualificationRestoreEvidence(
            recordSHA256: String(repeating: "f", count: 64), verified: true)))
        #expect(!QualificationRunner.evidence(evidence, binds: otherRecord))

        let noRecord = Self.qualificationCase(cycle, restore: .some(nil))
        #expect(!QualificationRunner.evidence(evidence, binds: noRecord))
    }
}
