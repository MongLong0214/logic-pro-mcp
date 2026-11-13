import Foundation
import Testing
@testable import LogicProMCP

/// #984: a mutating operation passes qualification only when write → independent readback →
/// restore → restore readback all happened and matched. A restore record that is merely present
/// is not enough.
///
/// Every case here starts from the real producer (`QualificationOperationResult`) and changes ONE
/// thing, so the tests exercise the product's cycle-shape decision rather than a duplicate gate.
///
/// NO `#expect(<Bool> == <Bool>)` HERE (#393, `Scripts/ci-forbid-dead-expect.sh`): on this
/// toolchain such a comparison records no issue. A first draft of this file had one, and a mutant
/// that made every restore "verified" survived it. Booleans are asserted bare or negated, and
/// optionals are unwrapped with `#require` first.
@Suite("#984 verified write cycles")
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
            responseData: Data(#"{"success":false,"state":"C","error":"invalid_params"}"#.utf8),
            isError: true,
            state: "C",
            error: "invalid_params",
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


    @Test func aWriteCyclePassCarriesItsVerifiedRestore() throws {
        let cycle = try Self.result(record: Self.record())
        // What the producer files, so the credit below is earned by a real result's shape.
        #expect(cycle.status == .passed)
        #expect(cycle.verificationKind == .verifiedWriteCycle)
        let digest = try QualificationRunner.recordDigest(Self.record())
        #expect(cycle.restore == QualificationRestoreEvidence(recordSHA256: digest, verified: true))
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

    @Test func readableWrongRestoreCannotPass() throws {
        let cycle = try Self.result(record: Self.record(
            restoreReadback: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"after"}]}"#))
        let restore = try #require(cycle.restore)
        #expect(!restore.verified)
        #expect(cycle.status == .notQualified)
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

    private static func trackRecord(
        operation: OperationID, field: String, before: String, changed: String,
        changedRef: String = "track-1", restoredRef: String = "track-2"
    ) -> QualificationMutationRestoreRecord {
        func reading(_ ref: String, _ value: String) -> String {
            #"{"source":"ax_live","data":[{"track_ref":"\#(ref)","\#(field)":\#(value)}]}"#
        }
        return QualificationMutationRestoreRecord(
            operationID: operation.rawValue,
            preState: reading("track-1", before),
            mutation: #"{"state":"A","success":true}"#,
            readback: reading(changedRef, changed),
            restore: #"{"state":"A","success":true}"#,
            restoreReadback: reading(restoredRef, before)
        )
    }

    @Test func renameRestoreMustReadBackTheSameTrack() {
        #expect(Self.trackRecord(
            operation: .tracksRename, field: "name", before: #""before""#,
            changed: #""after""#, restoredRef: "track-1"
        ).verifiedCycleShape)
        #expect(!Self.trackRecord(
            operation: .tracksRename, field: "name", before: #""before""#,
            changed: #""after""#
        ).verifiedCycleShape)
    }

    @Test func flagRestoreMustReadBackTheSameTrack() {
        #expect(Self.trackRecord(
            operation: .tracksMute, field: "isMuted", before: "false", changed: "true",
            restoredRef: "track-1"
        ).verifiedCycleShape)
        #expect(!Self.trackRecord(
            operation: .tracksMute, field: "isMuted", before: "false", changed: "true"
        ).verifiedCycleShape)
    }

    @Test func historyRestoreMustReadBackTheSameTrack() {
        #expect(Self.trackRecord(
            operation: .editUndo, field: "name", before: #""before""#,
            changed: #""after""#, restoredRef: "track-1"
        ).verifiedCycleShape)
        #expect(!Self.trackRecord(
            operation: .editUndo, field: "name", before: #""before""#,
            changed: #""after""#
        ).verifiedCycleShape)
    }

    @Test func selectionRestoreMustReadBackTheSameTracks() {
        func record(_ restoredFirstRef: String) -> QualificationMutationRestoreRecord {
            QualificationMutationRestoreRecord(
                operationID: OperationID.tracksSelect.rawValue,
                preState: #"{"source":"ax_live","data":[{"track_ref":"track-1","isSelected":true},{"track_ref":"track-2","isSelected":false}]}"#,
                mutation: #"{"state":"A","success":true}"#,
                readback: #"{"source":"ax_live","data":[{"track_ref":"track-1","isSelected":false},{"track_ref":"track-2","isSelected":true}]}"#,
                restore: #"{"state":"A","success":true}"#,
                restoreReadback: #"{"source":"ax_live","data":[{"track_ref":"\#(restoredFirstRef)","isSelected":true},{"track_ref":"track-2","isSelected":false}]}"#
            )
        }
        #expect(record("track-1").verifiedCycleShape)
        #expect(!record("track-3").verifiedCycleShape)
    }

    @Test func aNoOpReadbackCannotPass() throws {
        let before = Self.record().preState
        let record = QualificationMutationRestoreRecord(
            operationID: OperationID.tracksRename.rawValue,
            preState: before,
            mutation: #"{"state":"A","success":true}"#,
            readback: before,
            restore: #"{"state":"A","success":true}"#,
            restoreReadback: before
        )
        #expect(!record.verifiedCycleShape)
        let cycle = try Self.result(record: record)
        let restore = try #require(cycle.restore)
        #expect(!restore.verified)
        #expect(cycle.status == .notQualified)
        #expect(!Self.trackRecord(
            operation: .tracksRename, field: "name", before: #""before""#,
            changed: #""after""#, changedRef: "track-2", restoredRef: "track-1"
        ).verifiedCycleShape)
    }

    private static func transportRecord(
        _ operation: OperationID,
        pre: QualificationTransport.TransportMotion,
        readback: QualificationTransport.TransportMotion,
        restored: QualificationTransport.TransportMotion
    ) throws -> QualificationMutationRestoreRecord {
        func state(_ motion: QualificationTransport.TransportMotion) throws -> String {
            func sample(_ position: String) -> [String: Any] {
                ["source": "ax_live", "observed_tempo": 120,
                 "data": ["state": ["isPlaying": motion != .stopped,
                    "observedCycleEnabled": false, "position": position,
                    "positionReadback": ["value": position,
                        "observedComponents": ["bar", "beat"]]]]]
            }
            let first = sample("1.1")
            var last = sample(motion == .moving ? "1.2" : "1.1")
            if motion != .stopped {
                last["qualification_motion_samples"] = [first, last]
                last["qualification_motion_gap_ms"] = 1_000
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: last), as: UTF8.self)
        }
        return QualificationMutationRestoreRecord(
            operationID: operation.rawValue,
            preState: try state(pre),
            mutation: #"{"state":"A","success":true}"#,
            readback: try state(readback),
            restore: #"{"state":"A","success":true}"#,
            restoreReadback: try state(restored)
        )
    }

    /// `transportRestoreCycle` records its pre-state before its precondition stage, so a transport
    /// already where the operation puts it gives pre-state == readback on a genuine cycle.
    @Test func aStagedTransportCycleVerifiesAndAMisplacedReadbackDoesNot() throws {
        #expect(QualificationTransport.transportExpectedPlaying.count == 3)
        let modes: [QualificationTransport.TransportMotion] = [.stopped, .paused, .moving]
        for (operation, expectedPlaying) in QualificationTransport.transportExpectedPlaying {
            let expected: QualificationTransport.TransportMotion = operation == .transportPause
                ? .paused : (expectedPlaying ? .moving : .stopped)
            for original in modes {
                #expect(try Self.transportRecord(
                    operation, pre: original, readback: expected, restored: original
                ).verifiedCycleShape, "\(operation.rawValue) from \(original)")
            }
            for misplaced in modes where misplaced != expected {
                #expect(try !Self.transportRecord(
                    operation, pre: expected, readback: misplaced, restored: expected
                ).verifiedCycleShape, "misplaced \(operation.rawValue): \(misplaced)")
            }
            let playBitOnly = #"{"source":"ax_live","data":{"state":{"isPlaying":true}}}"#
            #expect(!QualificationMutationRestoreRecord(operationID: operation.rawValue,
                preState: playBitOnly, mutation: #"{"state":"A","success":true}"#,
                readback: playBitOnly, restore: #"{"state":"A","success":true}"#,
                restoreReadback: playBitOnly).verifiedCycleShape)
        }
    }


    /// The attestation's `restore` must name the record the case's evidence file binds -- or a
    /// bundle could say "verified" about a record it does not carry.
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
