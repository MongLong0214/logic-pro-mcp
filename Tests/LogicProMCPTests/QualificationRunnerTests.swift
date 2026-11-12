@preconcurrency import ApplicationServices
import Foundation
import Darwin
import CryptoKit
import MCP
import Testing
@testable import LogicProMCP

@Suite("ADR-001 qualification runner", .serialized)
struct QualificationRunnerTests {
    @Test(arguments: [OperationID.transportFastForward, .transportRewind])
    func registeredOffBoundaryStepRetainsActualStagingAndRestoresOriginalPosition(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(playheadStep: operation)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(result.operationResults[operation.rawValue]?.status == .passed)
        let record = try #require(result.mutationRestoreRecords.first)
        #expect(record.verifiedCycleShape)
        let encoded = try #require(sharedJSONObject(String(decoding: try JSONEncoder().encode(record), as: UTF8.self)))
        let stage = try #require(encoded["staging_mutation"] as? String)
        let stageBody = try #require(sharedJSONObject(stage))
        #expect(stageBody["state"] as? String == "A")
        let verified = try #require(stageBody["verified"] as? Bool)
        #expect(verified)
        let stageRead = try #require(encoded["staging_readback"] as? String)
        let expectedAfter = operation == .transportFastForward ? "10.1.1.1" : "8.1.1.1"
        for (raw, expected) in [(record.preState, "9.3.2.120"), (stageRead, "9.1.1.1"),
                                (record.readback, expectedAfter), (record.restoreReadback, "9.3.2.120")] {
            let envelope = try #require(sharedJSONObject(raw))
            let data = try #require(envelope["data"] as? [String: Any])
            let state = try #require(data["state"] as? [String: Any])
            let readback = try #require(state["positionReadback"] as? [String: Any])
            #expect(readback["value"] as? String == expected)
            #expect(readback["observedComponents"] as? [String] == ["bar", "beat", "subdivision", "tick"])
        }
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        #expect(effects.map(\.operationID) == ["phase_b.stage", "phase_b.mutation", "phase_b.restore"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "9.3.2.120")
    }

    @Test func stagedStepTimeoutCannotRenewCleanupFromAnUnchangedPosition() throws {
        let fixture = try SlowHandshakeFixture(playheadStep: .transportFastForward, playheadFault: "stage_lost_step_reply")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportFastForward })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("step-fault-consumed").path))
        #expect(result.operationResults[spec.id.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        #expect(effects.map(\.operationID) == ["phase_b.stage", "phase_b.mutation"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "9.1.1.1")
    }

    @Test func explicitNoWriteStepCannotClaimOrRestoreACoincidentForeignLanding() throws {
        let fixture = try SlowHandshakeFixture(
            playheadStep: .transportFastForward,
            playheadFault: "step_noop_race"
        )
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportFastForward })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("step-fault-consumed").path))
        #expect(result.operationResults[spec.id.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        #expect(effects.map(\.operationID) == ["phase_b.stage", "phase_b.mutation"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "10.1.1.1")
    }

    @Test(arguments: [OperationID.transportFastForward, .transportRewind])
    func explicitNoWriteStepRestoresItsStillOwnedStagedBoundary(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(
            playheadStep: operation,
            playheadFault: "step_noop_boundary"
        )
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("step-fault-consumed").path))
        #expect(result.operationResults[spec.id.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        #expect(effects.map(\.operationID) == ["phase_b.stage", "phase_b.mutation", "phase_b.cleanup"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "9.3.2.120")
    }

    @Test func cgEventGotoProofWithoutWriteAttemptedCanStageAndRestore() throws {
        let fixture = try SlowHandshakeFixture(
            playheadStep: .transportFastForward,
            playheadFault: "cgevent_goto_reply"
        )
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportFastForward })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(result.operationResults[spec.id.rawValue]?.status == .passed)
        #expect(try #require(result.mutationRestoreRecords.first).verifiedCycleShape)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        #expect(effects.map(\.operationID) == ["phase_b.stage", "phase_b.mutation", "phase_b.restore"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "9.3.2.120")
    }

    @Test(arguments: [OperationID.transportFastForward, .transportRewind])
    func playheadStepRefusesAnObservedNonBoundaryPositionBeforeAnyWrite(operation: OperationID) throws {
        // Staging now supports ordinary off-boundary positions, but never invents an adjacent
        // bar outside the existing parser's range (nor clamps a rewind to a special bar).
        let origin = operation == .transportFastForward ? "9999.3.2.120" : "1.3.2.120"
        let fixture = try SlowHandshakeFixture(playheadStep: operation, playheadOrigin: origin)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(result.operationResults[operation.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        #expect(effects.isEmpty)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == origin)
    }

    @Test(arguments: [OperationID.transportFastForward, .transportRewind],
          ["stage_refused", "stage_unverified", "stage_no_effect", "stage_missing_read",
           "stage_cache_read", "stage_stale_read", "stage_project_loss", "refused_forward",
           "stage_unknown_step", "stage_step_no_effect", "stage_foreign_position",
           "stage_cleanup_project_loss", "stage_cleanup_position_loss", "stage_refused_restore",
           "stage_attempted_restore_failure", "stage_noop_race", "unsafe_restore"])
    func stagedStepKeepsCleanupConditionalOnActualOwnedEvidence(operation: OperationID, shape: String) throws {
        let fixture = try SlowHandshakeFixture(playheadStep: operation, playheadFault: shape)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("step-fault-consumed").path))
        #expect(result.operationResults[operation.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        let cleanupOwned = ["refused_forward", "stage_step_no_effect", "stage_refused_restore"].contains(shape)
        let expectedPhases = shape.hasPrefix("stage_") &&
            ["stage_refused", "stage_unverified", "stage_no_effect", "stage_missing_read",
             "stage_cache_read", "stage_stale_read", "stage_project_loss"].contains(shape)
            ? ["phase_b.stage"]
            : shape == "stage_noop_race"
                ? ["phase_b.stage"]
            : shape == "stage_refused_restore"
                ? ["phase_b.stage", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"]
                : shape == "stage_attempted_restore_failure"
                    ? ["phase_b.stage", "phase_b.mutation", "phase_b.restore"]
                : shape == "unsafe_restore"
                    ? ["phase_b.stage", "phase_b.mutation", "phase_b.restore"]
                    : cleanupOwned
                        ? ["phase_b.stage", "phase_b.mutation", "phase_b.cleanup"]
                        : ["phase_b.stage", "phase_b.mutation"]
        #expect(effects.map(\.operationID) == expectedPhases)
        let residual = try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptedRestoreResidual = operation == .transportFastForward ? "10.1.1.1" : "8.1.1.1"
        let expectedResidual = shape == "stage_attempted_restore_failure" ? attemptedRestoreResidual
            : cleanupOwned || ["stage_refused", "stage_no_effect", "unsafe_restore"].contains(shape)
            ? "9.3.2.120"
            : ["stage_foreign_position", "stage_cleanup_position_loss"].contains(shape) ? "7.2.2.99" : "9.1.1.1"
        #expect(residual == expectedResidual)
    }

    @Test func unstagedMutationRecordPreservesItsLegacyWireBytes() throws {
        let raw = #"{"mutation":"m","operation_id":"transport.fast_forward","pre_state":"p","readback":"r","restore":"s","restore_readback":"t"}"#
        let record = try JSONDecoder().decode(QualificationMutationRestoreRecord.self, from: Data(raw.utf8))
        #expect(record.stagingMutation == nil)
        #expect(record.stagingReadback == nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(record), as: UTF8.self) == raw)
    }

    @Test func supportBundleRecordRequiresVerifiedArtifactCreationAndRemoval() throws {
        func observation(exists: Bool, verified: Bool = false) throws -> String {
            let files = verified ? SupportBundleBuilder.fileNames.map {
                ["name": $0, "sha256": String(repeating: "a", count: 64)]
            } : []
            let object: [String: Any] = [
                "source": "host_filesystem",
                "readable": true,
                "data": [
                    "path": "/tmp/qualification-owned-support-bundle",
                    "exists": exists,
                    "manifest_verified": verified,
                    "files": files,
                ] as [String: Any],
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let owned = "/tmp/qualification-owned-support-bundle"
        let files = SupportBundleBuilder.fileNames.map {
            ["name": $0, "sha256": String(repeating: "a", count: 64)]
        }
        let mutation = String(decoding: try JSONSerialization.data(withJSONObject: [
            "state": "A", "bundle_path": owned, "files": files,
        ]), as: UTF8.self)
        let record = QualificationMutationRestoreRecord(
            operationID: OperationID.systemExportSupportBundle.rawValue,
            preState: try observation(exists: false),
            mutation: mutation,
            readback: try observation(exists: true, verified: true),
            restore: #"{"state":"A","verified":true,"write_attempted":true,"operation":"host_filesystem.remove_owned_support_bundle","path":"/tmp/qualification-owned-support-bundle"}"#,
            restoreReadback: try observation(exists: false)
        )
        #expect(record.verifiedCycleShape)
    }

    @Test(arguments: ["wrong_path", "unverified_manifest", "partial_manifest", "still_exists",
                      "mutation_manifest", "restore_receipt"])
    func supportBundleRecordRejectsIncompleteArtifactOrRestore(shape: String) throws {
        func observation(
            path: String,
            exists: Bool,
            verified: Bool = false,
            completeManifest: Bool = true
        ) throws -> String {
            let names = completeManifest ? SupportBundleBuilder.fileNames : ["manifest.json"]
            let files = verified ? names.map {
                ["name": $0, "sha256": String(repeating: "a", count: 64)]
            } : []
            let object: [String: Any] = [
                "source": "host_filesystem",
                "readable": true,
                "data": [
                    "path": path,
                    "exists": exists,
                    "manifest_verified": verified,
                    "files": files,
                ] as [String: Any],
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let owned = "/tmp/qualification-owned-support-bundle"
        let mutationNames = shape == "mutation_manifest"
            ? Array(SupportBundleBuilder.fileNames.dropLast())
            : SupportBundleBuilder.fileNames
        let mutationFiles = mutationNames.map {
            ["name": $0, "sha256": String(repeating: "a", count: 64)]
        }
        let mutation = String(decoding: try JSONSerialization.data(withJSONObject: [
            "state": "A", "bundle_path": owned, "files": mutationFiles,
        ]), as: UTF8.self)
        let restoreOperation = shape == "restore_receipt"
            ? "host_filesystem.remove_foreign_bundle"
            : "host_filesystem.remove_owned_support_bundle"
        let restore = String(decoding: try JSONSerialization.data(withJSONObject: [
            "state": "A", "verified": true, "write_attempted": true,
            "operation": restoreOperation, "path": owned,
        ]), as: UTF8.self)
        let record = QualificationMutationRestoreRecord(
            operationID: OperationID.systemExportSupportBundle.rawValue,
            preState: try observation(path: owned, exists: false),
            mutation: mutation,
            readback: try observation(
                path: shape == "wrong_path" ? owned + "-foreign" : owned,
                exists: true,
                verified: shape != "unverified_manifest",
                completeManifest: shape != "partial_manifest"),
            restore: restore,
            restoreReadback: try observation(path: owned, exists: shape == "still_exists")
        )
        #expect(!record.verifiedCycleShape)
    }

    @Test func registeredSupportBundleRecipeVerifiesAndRemovesItsOwnedDirectory() throws {
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LogicProMCPTests", isDirectory: true)
            .appendingPathComponent("qualification-support-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fixture = try SlowHandshakeFixture(supportBundleCycle: true)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .systemExportSupportBundle
        })
        let result = try QualificationTransport(
            handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2,
            supportBundleRoot: { root }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0", rootKey: root.path],
            expectedOperationCount: 0,
            operations: [spec]
        ))
        let observed = try #require(result.operationResults[spec.id.rawValue])
        #expect(observed.status == .passed, "\(observed)")
        #expect(observed.readbackSource
            == QualificationReadbackFreshness.ownedSupportBundleReadbackSource)
        let record = try #require(result.mutationRestoreRecords.first)
        #expect(record.operationID == spec.id.rawValue)
        #expect(record.verifiedCycleShape)
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(children.isEmpty, "the recipe must remove its UUID bundle, not leave diagnostics behind")
        let effects = result.wireFrames.filter {
            $0.direction == .request && $0.operationID == "phase_b.mutation"
        }
        #expect(effects.count == 1)
    }

    @Test func malformedSupportBundleReplyIsRefusedAndItsOwnedDirectoryIsStillRemoved() throws {
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LogicProMCPTests", isDirectory: true)
            .appendingPathComponent("qualification-support-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fixture = try SlowHandshakeFixture(
            supportBundleCycle: true, supportBundleFault: "missing_manifest")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .systemExportSupportBundle
        })
        let result = try QualificationTransport(
            handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2,
            supportBundleRoot: { root }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0", rootKey: root.path],
            expectedOperationCount: 0,
            operations: [spec]
        ))
        let observed = try #require(result.operationResults[spec.id.rawValue])
        #expect(observed.status != .passed)
        #expect(observed.mutationRestore == nil)
        let refusal = try #require(observed.mutationRestoreRefusal)
        #expect(refusal.contains("no file manifest"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "a malformed reply must not strand its verifier-owned bundle")
    }

    @Test func lostSupportBundleReplyIsRefusedAndItsOwnedDirectoryIsStillRemoved() throws {
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LogicProMCPTests", isDirectory: true)
            .appendingPathComponent("qualification-support-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fixture = try SlowHandshakeFixture(
            supportBundleCycle: true, supportBundleFault: "lost_reply_nonzero")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .systemExportSupportBundle
        })
        do {
            _ = try QualificationTransport(
                handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2,
                supportBundleRoot: { root }
            ).drive(.init(
                executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0", rootKey: root.path],
                expectedOperationCount: 0,
                operations: [spec]
            ))
            Issue.record("a lost support-bundle reply must abort the candidate drive")
        } catch {
            #expect(String(describing: error).contains("support_bundle_outcome_quiesced"))
            #expect(String(describing: error).contains("removed_and_absence_verified"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "a lost reply must not strand the verifier-owned bundle")
    }

    @Test func timedOutSupportBundleThatPublishesLateIsQuiescedAndRemoved() throws {
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LogicProMCPTests", isDirectory: true)
            .appendingPathComponent("qualification-support-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fixture = try SlowHandshakeFixture(
            supportBundleCycle: true, supportBundleFault: "late_timeout")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .systemExportSupportBundle
        })
        do {
            _ = try QualificationTransport(
                handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2,
                supportBundleRoot: { root }
            ).drive(.init(
                executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0", rootKey: root.path],
                expectedOperationCount: 0,
                operations: [spec]
            ))
            Issue.record("a timed-out support-bundle write must abort the candidate drive")
        } catch {
            #expect(String(describing: error).contains("support_bundle_outcome_quiesced"))
            #expect(String(describing: error).contains("removed_and_absence_verified"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "a timed-out late publication must be quiesced before cleanup is credited")
    }

    @Test func failedSupportBundleQuiescenceWithholdsCleanupAndReportsResidual() throws {
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LogicProMCPTests", isDirectory: true)
            .appendingPathComponent("qualification-support-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fixture = try SlowHandshakeFixture(
            supportBundleCycle: true, supportBundleFault: "late_timeout")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .systemExportSupportBundle
        })
        do {
            _ = try QualificationTransport(
                handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2,
                supportBundleRoot: { root },
                supportBundleQuiescer: { _ in
                    let deadline = Date().addingTimeInterval(2)
                    while Date() < deadline,
                          (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) != false {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    throw QualificationTransportError.shutdownTimeout
                },
                supportBundleRemover: { _, _ in
                    Issue.record("cleanup must be withheld while the candidate may still publish")
                    return "unexpected cleanup"
                }
            ).drive(.init(
                executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0", rootKey: root.path],
                expectedOperationCount: 0,
                operations: [spec]
            ))
            Issue.record("failed quiescence must abort the candidate drive")
        } catch {
            #expect(String(describing: error).contains("support_bundle_outcome_uncertain"))
            #expect(String(describing: error).contains("cleanup_withheld(candidate_not_quiesced)"))
            #expect(String(describing: error).contains("residual=present_or_unverified"))
        }
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "unsafe cleanup must leave a diagnosed residual instead of racing a live writer")
    }

    @Test func supportBundleCleanupFailureIsReportedWithResidualState() throws {
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LogicProMCPTests", isDirectory: true)
            .appendingPathComponent("qualification-support-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fixture = try SlowHandshakeFixture(
            supportBundleCycle: true, supportBundleFault: "missing_manifest")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .systemExportSupportBundle
        })
        let result = try QualificationTransport(
            handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2,
            supportBundleRoot: { root },
            supportBundleRemover: { _, _ in
                throw QualificationTransportError.protocolViolation("injected cleanup failure")
            }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0", rootKey: root.path],
            expectedOperationCount: 0,
            operations: [spec]
        ))
        let observed = try #require(result.operationResults[spec.id.rawValue])
        #expect(observed.status != .passed)
        let refusal = try #require(observed.mutationRestoreRefusal)
        #expect(refusal.contains("owned support-bundle cleanup failed"))
        #expect(refusal.contains("residual=present_or_unverified"))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "the injected cleanup failure must leave a residual for the refusal to report")
    }

    @Test(arguments: [#"{"state":"A","verified":false}"#,
                      #"{"state":"A","verified":true,"write_attempted":false}"#,
                      #"{"state":"A","verified":true,"unchanged":true}"#])
    func playheadStepRecordCannotCreditAnUnverifiedOrNoWriteGotoRestore(restore: String) throws {
        func reading(_ position: String) throws -> String {
            let object: [String: Any] = ["source": "ax_live", "cache_age_sec": 0,
                "data": ["state": ["isPlaying": false, "isRecording": false, "observedCycleEnabled": false,
                    "positionReadback": ["value": position,
                        "observedComponents": ["bar", "beat", "subdivision", "tick"]]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let record = QualificationMutationRestoreRecord(operationID: OperationID.transportFastForward.rawValue,
            preState: try reading("9.1.1.1"),
            mutation: #"{"state":"B","success":true,"method":"cgevent","sent":true}"#,
            readback: try reading("10.1.1.1"), restore: restore,
            restoreReadback: try reading("9.1.1.1"))
        #expect(!record.verifiedCycleShape)
    }

    @Test func playheadStepRecordRejectsAnExplicitNoWriteMutation() throws {
        func reading(_ position: String) throws -> String {
            let object: [String: Any] = ["source": "ax_live", "cache_age_sec": 0,
                "data": ["state": ["isPlaying": false, "isRecording": false, "observedCycleEnabled": false,
                    "positionReadback": ["value": position,
                        "observedComponents": ["bar", "beat", "subdivision", "tick"]]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let record = QualificationMutationRestoreRecord(
            operationID: OperationID.transportFastForward.rawValue,
            preState: try reading("9.1.1.1"),
            mutation: #"{"state":"B","success":true,"write_attempted":false,"unchanged":true}"#,
            readback: try reading("10.1.1.1"),
            restore: #"{"state":"A","verified":true,"write_attempted":true}"#,
            restoreReadback: try reading("9.1.1.1")
        )
        #expect(!record.verifiedCycleShape)
    }

    @Test(arguments: ["missing_write", "missing_read", "unverified_stage", "no_write_stage_reply",
                      "unchanged_stage_reply", "cache_stage", "stale_stage", "partial_stage",
                      "wrong_boundary", "unchanged_stage", "unsafe_restore"])
    func stagedRecordCannotCreditMissingOrUnobservedPreconditions(shape: String) throws {
        func reading(_ position: String, components: [String] = ["bar", "beat", "subdivision", "tick"],
                     source: String = "ax_live", age: Int = 0) throws -> String {
            let object: [String: Any] = ["source": source, "cache_age_sec": age,
                "data": ["state": ["isPlaying": false, "isRecording": false, "observedCycleEnabled": false,
                    "positionReadback": ["value": position, "observedComponents": components]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let verified = #"{"state":"A","verified":true,"write_attempted":true}"#
        var record = QualificationMutationRestoreRecord(operationID: OperationID.transportFastForward.rawValue,
            preState: try reading("9.3.2.120"),
            mutation: #"{"state":"B","success":true,"method":"cgevent","sent":true}"#,
            readback: try reading("10.1.1.1"), restore: verified, restoreReadback: try reading("9.3.2.120"),
            stagingMutation: verified, stagingReadback: try reading("9.1.1.1"))
        #expect(record.verifiedCycleShape)
        switch shape {
        case "missing_write": record.stagingMutation = nil
        case "missing_read": record.stagingReadback = nil
        case "unverified_stage": record.stagingMutation = #"{"state":"B","success":true,"verified":false}"#
        case "no_write_stage_reply":
            record.stagingMutation = #"{"state":"A","verified":true,"write_attempted":false}"#
        case "unchanged_stage_reply":
            record.stagingMutation = #"{"state":"A","verified":true,"unchanged":true}"#
        case "cache_stage": record.stagingReadback = try reading("9.1.1.1", source: "cache")
        case "stale_stage": record.stagingReadback = try reading("9.1.1.1", age: 1000)
        case "partial_stage": record.stagingReadback = try reading("9.1", components: ["bar", "beat"])
        case "wrong_boundary": record.stagingReadback = try reading("8.1.1.1")
        case "unchanged_stage": record.stagingReadback = try reading("9.3.2.120")
        default:
            record = .init(operationID: record.operationID, preState: record.preState, mutation: record.mutation,
                readback: record.readback, restore: #"{"state":"B","success":true,"fallback_unsafe":true}"#,
                restoreReadback: record.restoreReadback, stagingMutation: record.stagingMutation,
                stagingReadback: record.stagingReadback)
        }
        #expect(!record.verifiedCycleShape)
    }

    @Test(arguments: ["cache_pre", "stale_pre", "cache_after", "stale_after",
                      "cache_restore", "stale_restore"])
    func playheadStepRecordRequiresFreshEveryPositionReading(shape: String) throws {
        func reading(_ position: String, source: String = "ax_live", age: Int = 0) throws -> String {
            let object: [String: Any] = ["source": source, "cache_age_sec": age,
                "data": ["state": ["isPlaying": false, "isRecording": false,
                    "observedCycleEnabled": false,
                    "positionReadback": ["value": position,
                        "observedComponents": ["bar", "beat", "subdivision", "tick"]]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        var pre = try reading("9.3.2.120")
        var after = try reading("10.1.1.1")
        var restored = try reading("9.3.2.120")
        switch shape {
        case "cache_pre": pre = try reading("9.3.2.120", source: "cache")
        case "stale_pre": pre = try reading("9.3.2.120", age: 1000)
        case "cache_after": after = try reading("10.1.1.1", source: "cache")
        case "stale_after": after = try reading("10.1.1.1", age: 1000)
        case "cache_restore": restored = try reading("9.3.2.120", source: "cache")
        default: restored = try reading("9.3.2.120", age: 1000)
        }
        let verified = #"{"state":"A","verified":true,"write_attempted":true}"#
        let record = QualificationMutationRestoreRecord(
            operationID: OperationID.transportFastForward.rawValue,
            preState: pre,
            mutation: #"{"state":"B","success":true,"method":"cgevent","sent":true}"#,
            readback: after, restore: verified, restoreReadback: restored,
            stagingMutation: verified, stagingReadback: try reading("9.1.1.1"))
        #expect(!record.verifiedCycleShape)
    }

    @Test(arguments: [OperationID.transportFastForward, .transportRewind])
    func registeredPlayheadStepRestoresItsExactObservedPosition(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(playheadStep: operation, playheadAtBoundary: true)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(result.operationResults[operation.rawValue]?.status == .passed)
        let record = try #require(result.mutationRestoreRecords.first)
        #expect(record.verifiedCycleShape)
        #expect(record.operationID == operation.rawValue)
        let expectedAfter = operation == .transportFastForward ? "10.1.1.1" : "8.1.1.1"
        for (raw, expected) in [(record.preState, "9.1.1.1"), (record.readback, expectedAfter),
                                (record.restoreReadback, "9.1.1.1")] {
            let envelope = try #require(sharedJSONObject(raw))
            let data = try #require(envelope["data"] as? [String: Any])
            let state = try #require(data["state"] as? [String: Any])
            let readback = try #require(state["positionReadback"] as? [String: Any])
            #expect(readback["value"] as? String == expected)
            #expect(readback["observedComponents"] as? [String] == ["bar", "beat", "subdivision", "tick"])
        }
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.mutation", "phase_b.restore"].contains($0.operationID) }
        #expect(effects.count == 2)
        let restoreRequest = try #require(effects.last.flatMap { sharedJSONObject($0.payload) })
        let params = try #require(restoreRequest["params"] as? [String: Any])
        let arguments = try #require(params["arguments"] as? [String: Any])
        #expect(arguments["command"] as? String == "goto_position")
        #expect(arguments["params"] as? [String: String] == ["position": "9.1.1.1"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "9.1.1.1")
    }

    @Test(arguments: [OperationID.transportFastForward, .transportRewind],
          ["partial2_pre", "partial3_pre", "missing_pre", "malformed_pre", "playing_pre", "recording_pre",
           "unknown_stop_pre", "missing_cycle_pre", "cycle_pre", "cache_pre", "stale_pre", "unverified_pre",
           "unknown_age_pre", "project_pre", "project_after", "project_during_after", "partial_after",
           "stale_after", "wrong_components_after", "refused_forward", "refused_restore", "missing_restore",
           "mismatch_restore", "unverified_restore", "unsafe_restore"])
    func playheadStepWithholdsWritesAndCreditWhenExactObservationIsLost(operation: OperationID, shape: String) throws {
        let fixture = try SlowHandshakeFixture(playheadStep: operation, playheadFault: shape, playheadAtBoundary: true)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("step-fault-consumed").path))
        #expect(result.operationResults[operation.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        let expectedAttempts = shape.hasSuffix("_pre") ? 0
            : shape == "refused_restore" ? 3
            : (["missing_restore", "mismatch_restore", "unverified_restore", "unsafe_restore"].contains(shape) ? 2 : 1)
        #expect(effects.count == expectedAttempts, "unknown source or position cannot authorize a dependent inverse")
        if shape == "refused_restore" {
            #expect(effects.contains { $0.operationID == "phase_b.cleanup" })
            #expect(try String(contentsOf: fixture.directory.appendingPathComponent("step-position"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "9.1.1.1")
        } else {
            #expect(!effects.contains { $0.operationID == "phase_b.cleanup" })
        }
    }

    @Test func registeredAutopunchToggleRecordsAnObservedWriteAndRestoreCycle() throws {
        let fixture = try SlowHandshakeFixture(autopunchCycle: "healthy")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportToggleAutopunch })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        let observed = try #require(result.operationResults[spec.id.rawValue])
        #expect(observed.status == .passed)
        let record = try #require(result.mutationRestoreRecords.first)
        #expect(record.operationID == spec.id.rawValue)
        #expect(record.verifiedCycleShape)
        for (reading, enabled) in [(record.preState, false), (record.readback, true), (record.restoreReadback, false)] {
            let envelope = try #require(sharedJSONObject(reading))
            let data = try #require(envelope["data"] as? [String: Any])
            let state = try #require(data["state"] as? [String: Any])
            let actual = try #require(state["isAutopunchEnabled"] as? Bool)
            if enabled { #expect(actual) } else { #expect(!actual) }
        }
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.mutation", "phase_b.restore"].contains($0.operationID) }
        #expect(effects.count == 2)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("autopunch"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "false")
    }

    @Test(arguments: ["missing_pre", "malformed_pre", "cache_pre", "stale_pre", "unknown_age_pre",
                      "unverified_pre", "missing_after", "cache_after", "refused_forward",
                      "refused_restore", "mismatch_after", "mismatch_restore"])
    func autopunchRecipeWithholdsDependentWritesAndCreditWhenEvidenceIsLost(shape: String) throws {
        let fixture = try SlowHandshakeFixture(autopunchCycle: shape)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportToggleAutopunch })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("autopunch-fault-consumed").path))
        #expect(result.operationResults[spec.id.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.mutation", "phase_b.restore"].contains($0.operationID) }
        let expectedAttempts = shape.hasSuffix("_pre") ? 0 : (["refused_restore", "mismatch_restore"].contains(shape) ? 2 : 1)
        #expect(effects.count == expectedAttempts, "unobserved state cannot authorize a dependent toggle")
        let residual = try String(contentsOf: fixture.directory.appendingPathComponent("autopunch"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedResidual = ["missing_after", "cache_after", "refused_restore", "mismatch_restore"].contains(shape)
        #expect(residual == (expectedResidual ? "true" : "false"))
    }

    @Test func registeredCountInToggleRecordsAnObservedWriteAndRestoreCycle() throws {
        let fixture = try SlowHandshakeFixture(countInCycle: "healthy")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportToggleCountIn })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        let observed = try #require(result.operationResults[spec.id.rawValue])
        #expect(observed.status == .passed)
        let record = try #require(result.mutationRestoreRecords.first)
        #expect(record.operationID == spec.id.rawValue)
        #expect(record.verifiedCycleShape)
        for (reading, enabled) in [(record.preState, false), (record.readback, true), (record.restoreReadback, false)] {
            let envelope = try #require(sharedJSONObject(reading))
            let data = try #require(envelope["data"] as? [String: Any])
            let state = try #require(data["state"] as? [String: Any])
            let actual = try #require(state["isCountInEnabled"] as? Bool)
            if enabled { #expect(actual) } else { #expect(!actual) }
        }
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.mutation", "phase_b.restore"].contains($0.operationID) }
        #expect(effects.count == 2)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("count_in"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "false")
    }

    @Test(arguments: ["missing_pre", "malformed_pre", "cache_pre", "stale_pre", "unknown_age_pre",
                      "unverified_pre", "missing_after", "cache_after", "refused_forward",
                      "refused_restore", "mismatch_after", "mismatch_restore"])
    func countInRecipeWithholdsDependentWritesAndCreditWhenEvidenceIsLost(shape: String) throws {
        let fixture = try SlowHandshakeFixture(countInCycle: shape)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportToggleCountIn })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("count-in-fault-consumed").path))
        #expect(result.operationResults[spec.id.rawValue]?.status == .notQualified)
        #expect(result.mutationRestoreRecords.isEmpty)
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.mutation", "phase_b.restore"].contains($0.operationID) }
        let expectedAttempts = shape.hasSuffix("_pre") ? 0 : (["refused_restore", "mismatch_restore"].contains(shape) ? 2 : 1)
        #expect(effects.count == expectedAttempts, "unobserved state cannot authorize a dependent toggle")
        let residual = try String(contentsOf: fixture.directory.appendingPathComponent("count_in"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedResidual = ["missing_after", "cache_after", "refused_restore", "mismatch_restore"].contains(shape)
        #expect(residual == (expectedResidual ? "true" : "false"))
    }

    @Test(arguments: [OperationID.tracksRename, .editUndo, .editRedo], ["ref_changed", "reordered"])
    func nameRecipesDoNotRestoreThroughANewlyIndexedRow(operation: OperationID, shape: String) throws {
        let fixture = try SlowHandshakeFixture(nameRecipe: operation, nameIdentityFault: shape)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("identity-fault-consumed").path),
            "the independently read row really changed identity while retaining the expected name")
        let unsafe = fixture.directory.appendingPathComponent("unsafe-writes")
        #expect(!FileManager.default.fileExists(atPath: unsafe.path),
            "no inverse or cleanup may rename a newly indexed row, or run history after target continuity was lost")
        #expect(result.operationResults[operation.rawValue]?.status != .passed)
    }

    @Test(arguments: [OperationID.tracksRename, .editUndo, .editRedo])
    func healthyNameRecipesUseExactReferencesForEveryRename(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(nameRecipe: operation)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .passed)
        let record = try #require(observed.mutationRestore)
        #expect(record.verifiedCycleShape)
        #expect(observed.mutationRestoreRefusal == nil)
        let renames = try result.wireFrames.filter { $0.direction == .request && $0.operationID.hasPrefix("phase_b.") }.compactMap { frame -> [String: Any]? in
            let request = try #require(sharedJSONObject(frame.payload))
            let params = request["params"] as? [String: Any]
            let arguments = params?["arguments"] as? [String: Any]
            return arguments?["command"] as? String == "rename" ? arguments?["params"] as? [String: Any] : nil
        }
        #expect(!renames.isEmpty, "the healthy recipe must actually stage or rename its target")
        for arguments in renames {
            #expect(arguments["target_ref"] as? String == "held-track")
            #expect(arguments["index"] == nil)
        }
        let restored = try #require(sharedJSONObject(record.restoreReadback)?["data"] as? [[String: Any]])
        #expect(restored.first?["track_ref"] as? String == "held-track")
    }

    @Test(
        "history staging gives its rename the registered operation deadline",
        arguments: [OperationID.editUndo, .editRedo]
    )
    func historyStageRenameUsesOperationDeadline(operation: OperationID) throws {
        // Keep the injected delay above the generic request budget, but leave enough budget for
        // fixture startup and precondition reads under coverage instrumentation.
        let fixture = try SlowHandshakeFixture(nameRecipe: operation, nameStageDelay: 1.25)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })

        let result = try QualificationTransport(
            handshakeTimeout: 2,
            requestTimeout: 1,
            shutdownGrace: 2
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]))

        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .passed)
        #expect(try #require(observed.mutationRestore).verifiedCycleShape)
        let residual = try String(
            contentsOf: fixture.directory.appendingPathComponent("track-name"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(residual == "Before")
    }

    @Test(arguments: [OperationID.tracksRename, .editUndo, .editRedo], ["ref_changed", "reordered"])
    func nameRecipeIdentityLossKeepsItsExplicitUncreditedCause(operation: OperationID, shape: String) throws {
        let fixture = try SlowHandshakeFixture(nameRecipe: operation, nameIdentityFault: shape)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .notQualified)
        #expect(observed.mutationRestore == nil)
        let cause = try #require(observed.mutationRestoreRefusal)
        #expect(cause.contains("track identity changed"))
        #expect(cause.contains("inverse and cleanup withheld"))
    }

    private final class CleanupSleepProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var delaysStorage: [TimeInterval] = []

        func record(_ delay: TimeInterval) {
            lock.lock()
            delaysStorage.append(delay)
            lock.unlock()
        }

        var delays: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return delaysStorage
        }
    }

    @Test(
        "history staging restores an exact-reference rename after a timeout response",
        arguments: [OperationID.editUndo, .editRedo]
    )
    func historyStageTimeoutAfterWriteRestoresOriginalName(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(
            nameRecipe: operation,
            nameCleanupDelay: 1.25,
            nameStageFailure: "timeout_after_write")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let probe = CleanupSleepProbe()
        let marker = fixture.directory.appendingPathComponent("gate-reclaimed")

        let result = try QualificationTransport(
            handshakeTimeout: 2,
            requestTimeout: 1,
            shutdownGrace: 2,
            cleanupSleep: { delay in
                probe.record(delay)
                try? Data().write(to: marker)
            }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]))

        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .notQualified)
        #expect(observed.mutationRestore == nil)
        let refusal = try #require(observed.mutationRestoreRefusal)
        #expect(refusal.contains("rename refused"))
        #expect(probe.delays == [0.25])
        #expect(result.wireFrames.contains {
            $0.direction == .response && $0.operationID == "phase_b.cleanup"
        }, "cleanup must complete within the operation deadline, not merely write after a generic timeout")
        #expect(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("cleanup-readback").path),
            "cleanup must return before the transport performs its exact-reference readback")
        let residual = try String(
            contentsOf: fixture.directory.appendingPathComponent("track-name"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(residual == "Before")
    }

    @Test(
        "name cleanup waits for exact abandoned-holder grace and restores the same track",
        arguments: [OperationID.tracksRename, .editUndo, .editRedo]
    )
    func nameCleanupWaitsForExactAbandonedHolderGrace(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(
            nameRecipe: operation,
            nameCleanupContention: "reclaimable")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let probe = CleanupSleepProbe()
        let marker = fixture.directory.appendingPathComponent("gate-reclaimed")

        let result = try QualificationTransport(
            handshakeTimeout: 2,
            requestTimeout: 2,
            shutdownGrace: 2,
            cleanupSleep: { delay in
                probe.record(delay)
                try? Data().write(to: marker)
            }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]))

        if operation == .editUndo {
            #expect(result.operationResults[operation.rawValue]?.status == .passed)
        } else {
            #expect(result.operationResults[operation.rawValue]?.status == .notQualified)
        }
        #expect(probe.delays == [0.25])
        let residual = try String(
            contentsOf: fixture.directory.appendingPathComponent("track-name"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(residual == "Before")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("unsafe-writes").path))
    }

    @Test(
        "name cleanup does not wait for contention without exact reclaim proof",
        arguments: [
            "unproven",
            "boolean_delay",
            "missing_success",
            "successful_error",
            "numeric_boole",
        ]
    )
    func nameCleanupDoesNotWaitWithoutExactReclaimProof(shape: String) throws {
        let fixture = try SlowHandshakeFixture(
            nameRecipe: .tracksRename,
            nameCleanupContention: shape)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .tracksRename })
        let probe = CleanupSleepProbe()

        _ = try QualificationTransport(
            handshakeTimeout: 2,
            requestTimeout: 2,
            shutdownGrace: 2,
            cleanupSleep: { probe.record($0) }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]))

        #expect(probe.delays.isEmpty)
        let residual = try String(
            contentsOf: fixture.directory.appendingPathComponent("track-name"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(residual == "qualification_phase_b_probe")
    }

    @Test(arguments: [OperationID.mixerSetPan, .mixerSetVolume])
    func mixerScalarRecipesUseTheirExactTrackReadback(operation: OperationID) throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        #expect(QualificationTransport.valueRestoreReadbackField[operation] != nil)
        #expect(QualificationTransport.readbackSource(for: spec) == "logic://tracks",
            "the scalar recipe captures and restores this exact track, not a separately hidden Mixer")
    }

    @Test(arguments: [OperationID.mixerSetPan, .mixerSetVolume])
    func mixerScalarCyclesAddressAndRestoreTheHeldTrack(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(valueCycle: operation)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))

        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .passed)
        #expect(try #require(observed.mutationRestore).verifiedCycleShape)
        let writes = try scalarWriteArguments(in: result)
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0["target_ref"] as? String == "held-track" })
        #expect(writes.allSatisfy { $0["index"] == nil })
        let field = try #require(QualificationTransport.valueRestoreReadbackField[operation])
        #expect(writes.last?[field] as? Double == 0.4)
        #expect(try scalarValue(in: fixture) == 0.4)
    }

    @Test(arguments: [OperationID.mixerSetPan, .mixerSetVolume],
          ["wrong_target_after", "malformed_after"])
    func mixerScalarCyclesCompensateEveryIndeterminateWrite(
        operation: OperationID, fault: String
    ) throws {
        let fixture = try SlowHandshakeFixture(valueCycle: operation, valueFault: fault)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 0.2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))

        #expect(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("value-fault-consumed").path))
        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .notQualified)
        #expect(observed.mutationRestore == nil)
        let writes = try scalarWriteArguments(in: result)
        #expect(writes.count == 2, "one attempted mutation requires one owned compensation")
        #expect(writes.allSatisfy { $0["target_ref"] as? String == "held-track" })
        #expect(writes.allSatisfy { $0["index"] == nil })
        let field = try #require(QualificationTransport.valueRestoreReadbackField[operation])
        #expect(writes.last?[field] as? Double == 0.4)
        #expect(result.wireFrames.contains {
            $0.direction == .request && $0.operationID == "phase_b.compensate_readback"
        })
        #expect(try scalarValue(in: fixture) == 0.4)
    }

    @Test func mixerScalarTimeoutStillCompensatesTheHeldTrack() throws {
        let fixture = try SlowHandshakeFixture(
            valueCycle: .mixerSetVolume, valueFault: "lost_mutation_reply")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .mixerSetVolume })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 0.2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))

        let observed = try #require(result.operationResults[spec.id.rawValue])
        #expect(observed.status == .notQualified)
        let writes = try scalarWriteArguments(in: result)
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0["target_ref"] as? String == "held-track" && $0["index"] == nil })
        #expect(writes.last?["volume"] as? Double == 0.4)
        #expect(try scalarValue(in: fixture) == 0.4)
    }

    @Test(arguments: [OperationID.mixerSetPan, .mixerSetVolume])
    func mixerScalarCompensationRequiresObservedLanding(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(
            valueCycle: operation, valueFault: "malformed_after_compensation_noop")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))

        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .notQualified)
        #expect(observed.mutationRestore == nil)
        #expect(try #require(observed.mutationRestoreRefusal).contains("SENT BUT NOT LANDED"))
        #expect(try scalarValue(in: fixture) == 0.5,
            "the fixture must prove that a successful compensation reply is not enough")
    }

    @Test(arguments: [OperationID.mixerSetPan, .mixerSetVolume])
    func mixerScalarZeroWriteRefusalDoesNotApplyAStaleCompensation(operation: OperationID) throws {
        let fixture = try SlowHandshakeFixture(valueCycle: operation, valueFault: "refused_forward")
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))

        let observed = try #require(result.operationResults[operation.rawValue])
        #expect(observed.status == .notQualified)
        #expect(observed.mutationRestore == nil)
        #expect(try scalarWriteArguments(in: result).count == 1)
        #expect(!result.wireFrames.contains {
            $0.direction == .request && $0.operationID == "phase_b.compensate"
        })
        #expect(try scalarValue(in: fixture) == 0.4)
    }

    private func scalarWriteArguments(in result: QualificationDriveResult) throws -> [[String: Any]] {
        try result.wireFrames.compactMap { frame in
            guard frame.direction == .request,
                  ["phase_b.mutation", "phase_b.restore", "phase_b.compensate"].contains(frame.operationID)
            else { return nil }
            let request = try #require(sharedJSONObject(frame.payload))
            let params = try #require(request["params"] as? [String: Any])
            let arguments = try #require(params["arguments"] as? [String: Any])
            return try #require(arguments["params"] as? [String: Any])
        }
    }

    private func scalarValue(in fixture: SlowHandshakeFixture) throws -> Double {
        let text = try String(
            contentsOf: fixture.directory.appendingPathComponent("scalar-value"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Double(text))
    }

    @Test(arguments: [OperationID.mixerGetInputBusVerified, .mixerGetOutputVerified,
                      .mixerGetSendDestinationVerified, .pluginsGetInventory])
    func neighboringMixerAndPluginRecipesKeepTheirMixerReadback(operation: OperationID) throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        #expect(QualificationTransport.readbackSource(for: spec) == "logic://mixer")
    }

    @Test func mixerReadProbeParamsUseFreshTypedReferencesAndOccupiedCensusOrdinals() throws {
        let envelope: [String: Any] = [
            "schema": "logic_pro_mcp_session_population.v1",
            "read_only": true,
            "snapshot_id": "snap_typed_rows",
            "scope": "whole_project",
            "requested_domains": ["tracks", "hierarchy", "strips", "associations"],
            "sources": ["tracks": "ax_request_read", "strips": "ax_request_read"],
            "tracks": [
                "coverage": "partial",
                "rows": [
                    ["track_ref": "trk_output"],
                    ["track_ref": "trk_physical_input"],
                    ["track_ref": "trk_bus_input"],
                    ["track_ref": "trk_send"],
                ],
            ],
            "strips": [
                "coverage": "partial",
                "rows": [
                [
                    "mixer_strip_ref": "mix_output",
                    "output_observation": [
                        "state": "observed_destination", "destination": "출력 3-4",
                    ],
                ],
                [
                    "mixer_strip_ref": "mix_physical_input",
                    "input_observation": ["state": "observed_source", "source": "입력 1"],
                ],
                [
                    "mixer_strip_ref": "mix_bus_input",
                    "input_observation": ["state": "observed_source", "source": "버스 2"],
                ],
                [
                    "mixer_strip_ref": "mix_send",
                    "send_slots": [
                        ["ordinal": 0, "state": "observed_empty"],
                        [
                            "ordinal": 3,
                            "state": "occupied_unknown_destination",
                            "bypassed": false,
                        ],
                    ],
                ],
                [
                    "output_observation": [
                        "state": "observed_destination", "destination": "Stereo Out",
                    ],
                    "send_slots": [[
                        "ordinal": 9, "state": "occupied_unknown_destination", "bypassed": true,
                    ]],
                ],
                ],
            ],
            "associations": [
                "coverage": "partial",
                "rows": [
                    ["track_ref": "trk_output", "mixer_strip_ref": "mix_output",
                     "source": "held_exclusive_selection_focus"],
                    ["track_ref": "trk_physical_input", "mixer_strip_ref": "mix_physical_input",
                     "source": "held_exclusive_selection_focus"],
                    ["track_ref": "trk_bus_input", "mixer_strip_ref": "mix_bus_input",
                     "source": "held_exclusive_selection_selected_child"],
                    ["track_ref": "trk_send", "mixer_strip_ref": "mix_send",
                     "source": "held_exclusive_selection_focus"],
                ],
            ],
            "ui_effects": [
                "navigation_performed": true,
                "restoration": "restored",
                "attempted": ["track_selection"],
                "changed": ["track_selection"],
            ],
        ]
        let params = QualificationTransport.mixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: envelope)
        )

        #expect(params[.mixerGetOutputVerified]?["target_ref"] as? String == "mix_output")
        #expect(params[.mixerGetInputBusVerified]?["target_ref"] as? String == "mix_bus_input")
        #expect(params[.mixerGetSendDestinationVerified]?["target_ref"] as? String == "mix_send")
        #expect(params[.mixerGetSendDestinationVerified]?["ordinal"] as? Int == 3)
        #expect(params[.mixerGetSendBypassVerified]?["target_ref"] as? String == "mix_send")
        #expect(params[.mixerGetSendBypassVerified]?["ordinal"] as? Int == 3)
    }

    @Test func sessionInspectionSeedPurposesKeepPlannerPassiveAndMixerNavigationBound() throws {
        let planner = QualificationTransport.sessionInspectionSeedRequestParams(for: .planner)
        let mixer = QualificationTransport.sessionInspectionSeedRequestParams(for: .mixerRead)

        #expect(planner.isEmpty)
        #expect(mixer["scope"] as? String == "whole_project")
        #expect(mixer["domains"] as? [String]
            == ["tracks", "hierarchy", "strips", "associations"])
        #expect(try #require(mixer["allow_ui_navigation"] as? Bool))
        #expect(QualificationTransport.mixerReadProbeOperationIDs == [
            .mixerGetOutputVerified,
            .mixerGetInputBusVerified,
            .mixerGetSendDestinationVerified,
            .mixerGetSendBypassVerified,
        ])
    }

    @Test func preparedMixerReadProbeParamsReplaceTheEmptyCatalogFallback() throws {
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .mixerGetSendDestinationVerified
        })
        let prepared: [OperationID: [String: Any]] = [
            .mixerGetSendDestinationVerified: ["target_ref": "mix_live", "ordinal": 4],
        ]
        let params = QualificationTransport.probeParams(
            for: spec, traceID: "trace", preparedReadParams: prepared
        )

        #expect(params["target_ref"] as? String == "mix_live")
        #expect(params["ordinal"] as? Int == 4)
    }

    @Test func mixerReadProbeParamsRetainSameSessionTargetsOnlyForMeasuredPopulationMovement() throws {
        func stableInspection(reference: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "schema": "logic_pro_mcp_session_population.v1",
                "read_only": true,
                "snapshot_id": "snap_\(reference)",
                "scope": "whole_project",
                "requested_domains": ["tracks", "hierarchy", "strips", "associations"],
                "sources": ["tracks": "ax_request_read", "strips": "ax_request_read"],
                "tracks": [
                    "coverage": "partial",
                    "rows": [["track_ref": "trk_\(reference)"]],
                ],
                "strips": [
                    "coverage": "partial",
                    "rows": [[
                        "mixer_strip_ref": "mix_\(reference)",
                        "input_observation": [
                            "state": "observed_source", "source": "버스 1",
                        ],
                        "output_observation": [
                            "state": "observed_destination", "destination": "Stereo Output",
                        ],
                    ]],
                ],
                "associations": [
                    "coverage": "partial",
                    "rows": [[
                        "track_ref": "trk_\(reference)",
                        "mixer_strip_ref": "mix_\(reference)",
                        "source": "held_exclusive_selection_selected_child",
                    ]],
                ],
                "ui_effects": [
                    "navigation_performed": true,
                    "restoration": "restored",
                    "attempted": ["track_selection"],
                    "changed": ["track_selection"],
                ],
            ])
        }
        let movedInspection = try JSONSerialization.data(withJSONObject: [
            "schema": "logic_pro_mcp_session_population.v1",
            "read_only": true,
            "snapshot_id": "snap_population_moved",
            "scope": "whole_project",
            "requested_domains": ["tracks", "hierarchy", "strips", "associations"],
            "sources": ["tracks": "ax_request_read", "strips": "ax_request_read"],
            "tracks": [
                "coverage": "unstable", "reasons": ["live_population_moved"], "rows": [],
            ],
            "hierarchy": [
                "coverage": "unstable", "reasons": ["live_population_moved"],
            ],
            "strips": [
                "coverage": "unstable", "reasons": ["live_population_moved"], "rows": [],
            ],
            "associations": [
                "coverage": "unstable", "reasons": ["live_population_moved"],
            ],
            "ui_effects": [
                "navigation_performed": true,
                "restoration": "not_restored",
                "attempted": ["track_selection"],
                "changed": ["track_selection"],
                "reason": "association_restoration_unverified",
            ],
        ])
        let requested: Set<OperationID> = [
            .mixerGetInputBusVerified,
            .mixerGetOutputVerified,
        ]
        var prepared = QualificationTransport.preparedMixerReadProbeParams(
            from: try stableInspection(reference: "before"),
            requested: requested,
            previouslyPrepared: [:]
        )
        #expect(prepared[.mixerGetInputBusVerified]?["target_ref"] as? String
            == "mix_before")
        #expect(prepared[.mixerGetOutputVerified]?["target_ref"] as? String
            == "mix_before")
        #expect(prepared[.mixerGetSendBypassVerified] == nil)

        prepared = QualificationTransport.preparedMixerReadProbeParams(
            from: movedInspection,
            requested: requested,
            previouslyPrepared: prepared
        )
        #expect(prepared[.mixerGetInputBusVerified]?["target_ref"] as? String
            == "mix_before")
        #expect(prepared[.mixerGetOutputVerified]?["target_ref"] as? String
            == "mix_before")

        let malformed = QualificationTransport.preparedMixerReadProbeParams(
            from: Data(#"{}"#.utf8),
            requested: requested,
            previouslyPrepared: prepared
        )
        #expect(malformed.isEmpty)

        prepared = QualificationTransport.preparedMixerReadProbeParams(
            from: try stableInspection(reference: "after"),
            requested: requested,
            previouslyPrepared: prepared
        )
        #expect(prepared[.mixerGetInputBusVerified]?["target_ref"] as? String
            == "mix_after")
        #expect(prepared[.mixerGetOutputVerified]?["target_ref"] as? String
            == "mix_after")
    }

    @Test(arguments: [
        "schema", "read_only", "snapshot", "scope", "domains", "sources",
        "coverage", "reasons", "navigation", "restoration", "effect_reason",
        "attempted", "changed",
    ])
    func mixerReadProbeParamsRejectRetainedTargetsOutsideMeasuredPopulationMovement(
        fault: String
    ) throws {
        var envelope: [String: Any] = [
            "schema": "logic_pro_mcp_session_population.v1",
            "read_only": true,
            "snapshot_id": "snap_population_moved",
            "scope": "whole_project",
            "requested_domains": ["tracks", "hierarchy", "strips", "associations"],
            "sources": ["tracks": "ax_request_read", "strips": "ax_request_read"],
            "tracks": [
                "coverage": "unstable", "reasons": ["live_population_moved"], "rows": [],
            ],
            "hierarchy": [
                "coverage": "unstable", "reasons": ["live_population_moved"],
            ],
            "strips": [
                "coverage": "unstable", "reasons": ["live_population_moved"], "rows": [],
            ],
            "associations": [
                "coverage": "unstable", "reasons": ["live_population_moved"],
            ],
            "ui_effects": [
                "navigation_performed": true,
                "restoration": "not_restored",
                "attempted": ["track_selection"],
                "changed": ["track_selection"],
                "reason": "association_restoration_unverified",
            ],
        ]
        switch fault {
        case "schema": envelope["schema"] = "legacy"
        case "read_only": envelope["read_only"] = false
        case "snapshot": envelope["snapshot_id"] = ""
        case "scope": envelope["scope"] = "selected_tracks"
        case "domains": envelope["requested_domains"] = ["tracks", "strips"]
        case "sources": envelope["sources"] = ["tracks": "cache", "strips": "ax_request_read"]
        case "coverage":
            envelope["tracks"] = [
                "coverage": "partial", "reasons": ["live_population_moved"], "rows": [],
            ]
        case "reasons":
            envelope["hierarchy"] = [
                "coverage": "unstable", "reasons": ["foreign_reason"],
            ]
        case "navigation":
            var effects = try #require(envelope["ui_effects"] as? [String: Any])
            effects["navigation_performed"] = false
            envelope["ui_effects"] = effects
        case "restoration":
            var effects = try #require(envelope["ui_effects"] as? [String: Any])
            effects["restoration"] = "restored"
            envelope["ui_effects"] = effects
        case "effect_reason":
            var effects = try #require(envelope["ui_effects"] as? [String: Any])
            effects["reason"] = "foreign_reason"
            envelope["ui_effects"] = effects
        case "attempted":
            var effects = try #require(envelope["ui_effects"] as? [String: Any])
            effects["attempted"] = []
            envelope["ui_effects"] = effects
        case "changed":
            var effects = try #require(envelope["ui_effects"] as? [String: Any])
            effects["changed"] = ["track_selection", "mixer_visibility"]
            envelope["ui_effects"] = effects
        default: Issue.record("unknown fault \(fault)")
        }

        let prepared = QualificationTransport.preparedMixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: envelope),
            requested: [.mixerGetOutputVerified],
            previouslyPrepared: [
                .mixerGetOutputVerified: ["target_ref": "mix_previous"],
            ]
        )
        #expect(prepared.isEmpty)
    }

    @Test func mixerReadProbeParamsAcceptRequestOwnedFreshInspectionRows() throws {
        let inspection: [String: Any] = [
            "schema": "logic_pro_mcp_session_population.v1",
            "read_only": true,
            "snapshot_id": "snap_fresh",
            "scope": "whole_project",
            "requested_domains": ["tracks", "hierarchy", "strips", "associations"],
            "sources": ["tracks": "ax_request_read", "strips": "ax_request_read"],
            "tracks": [
                "coverage": "partial",
                "rows": [["track_ref": "trk_fresh_output"]],
            ],
            "strips": [
                "coverage": "partial",
                "rows": [[
                    "mixer_strip_ref": "mix_fresh_output",
                    "output_observation": [
                        "state": "observed_destination", "destination": "출력 3-4",
                    ],
                ]],
            ],
            "associations": [
                "coverage": "partial",
                "rows": [[
                    "track_ref": "trk_fresh_output",
                    "mixer_strip_ref": "mix_fresh_output",
                    "source": "held_exclusive_selection_selected_child",
                ]],
            ],
            "ui_effects": [
                "navigation_performed": true,
                "restoration": "restored",
                "attempted": ["track_selection"],
                "changed": ["track_selection"],
            ],
        ]

        let params = QualificationTransport.mixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: inspection)
        )

        #expect(params[.mixerGetOutputVerified]?["target_ref"] as? String
            == "mix_fresh_output")
    }

    @Test func mixerReadProbeParamsRejectUnsafeOrUnboundInspectionRows() throws {
        func inspection(
            stripCoverage: String = "partial",
            associationCoverage: String = "partial",
            trackRefs: [String] = ["trk_fresh_output"],
            stripRefs: [String] = ["mix_fresh_output"],
            associationTrackRef: String = "trk_fresh_output",
            associationRef: String = "mix_fresh_output",
            associationRows: [[String: Any]]? = nil,
            navigationPerformed: Bool = true,
            restoration: String = "restored",
            attempted: [String] = ["track_selection"],
            changed: [String] = ["track_selection"],
            reason: Any = NSNull()
        ) -> [String: Any] {
            [
                "schema": "logic_pro_mcp_session_population.v1",
                "read_only": true,
                "snapshot_id": "snap_fresh",
                "scope": "whole_project",
                "requested_domains": ["tracks", "hierarchy", "strips", "associations"],
                "sources": ["tracks": "ax_request_read", "strips": "ax_request_read"],
                "tracks": [
                    "coverage": "partial",
                    "rows": trackRefs.map { ["track_ref": $0] },
                ],
                "strips": [
                    "coverage": stripCoverage,
                    "rows": stripRefs.map { reference in [
                        "mixer_strip_ref": reference,
                        "output_observation": [
                            "state": "observed_destination", "destination": "출력 3-4",
                        ],
                    ] },
                ],
                "associations": [
                    "coverage": associationCoverage,
                    "rows": associationRows ?? [[
                        "track_ref": associationTrackRef,
                        "mixer_strip_ref": associationRef,
                        "source": "held_exclusive_selection_focus",
                    ]],
                ],
                "ui_effects": [
                    "navigation_performed": navigationPerformed,
                    "restoration": restoration,
                    "attempted": attempted,
                    "changed": changed,
                    "reason": reason,
                ],
            ]
        }
        let unsafe: [[String: Any]] = [
            inspection(stripCoverage: "unstable"),
            inspection(associationCoverage: "unavailable"),
            inspection(associationRef: "mix_other"),
            inspection(associationTrackRef: "trk_ghost"),
            inspection(trackRefs: ["trk_fresh_output", "trk_fresh_output"]),
            inspection(
                trackRefs: ["trk_first", "trk_second"],
                associationRows: [
                    [
                        "track_ref": "trk_first", "mixer_strip_ref": "mix_fresh_output",
                        "source": "held_exclusive_selection_focus",
                    ],
                    [
                        "track_ref": "trk_second", "mixer_strip_ref": "mix_fresh_output",
                        "source": "held_exclusive_selection_focus",
                    ],
                ]
            ),
            inspection(
                stripRefs: ["mix_first", "mix_second"],
                associationRows: [
                    [
                        "track_ref": "trk_fresh_output", "mixer_strip_ref": "mix_first",
                        "source": "held_exclusive_selection_focus",
                    ],
                    [
                        "track_ref": "trk_fresh_output", "mixer_strip_ref": "mix_second",
                        "source": "held_exclusive_selection_focus",
                    ],
                ]
            ),
            inspection(restoration: "not_restored"),
            inspection(changed: ["mixer_visibility"]),
            inspection(reason: "association_population_moved"),
            inspection(
                navigationPerformed: false,
                restoration: "not_applicable",
                attempted: ["track_selection"],
                changed: []
            ),
        ]

        for envelope in unsafe {
            let params = QualificationTransport.mixerReadProbeParams(
                from: try JSONSerialization.data(withJSONObject: envelope)
            )
            #expect(params.isEmpty)
        }

        let legacyBypass: [String: Any] = [
            "snapshot_id": "snap_legacy",
            "strips": [[
                "mixer_strip_ref": "mix_fresh_output",
                "output_observation": [
                    "state": "observed_destination", "destination": "출력 3-4",
                ],
            ]],
        ]
        #expect(QualificationTransport.mixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: legacyBypass)
        ).isEmpty)
    }

    @Test func pluginReadProbeParamsUseOnlyFreshOccupiedRefsAndSupportedCatalogReaders() throws {
        let inventory: [String: Any] = [
            "state": "A",
            "complete": true,
            "plugins": [
                [
                    "insert": 0, "read_status": "ok", "occupied": true,
                    "plugin_id": "logic.stock.effect.sample_delay",
                    "plugin_insert_ref": "stale_sample_delay",
                ],
                [
                    "insert": 1, "read_status": "empty", "occupied": false,
                    "plugin_id": NSNull(), "plugin_insert_ref": "ins_empty",
                ],
                [
                    "insert": 2, "read_status": "ok", "occupied": true,
                    "plugin_id": "logic.stock.effect.gain", "plugin_insert_ref": "ins_gain",
                ],
                [
                    "insert": 3, "read_status": "ok", "occupied": true,
                    "plugin_id": "logic.stock.effect.compressor",
                    "plugin_insert_ref": "ins_compressor",
                ],
                [
                    "insert": 4, "read_status": "ok", "occupied": true,
                    "plugin_id": "logic.stock.effect.channel_eq",
                    "plugin_insert_ref": "ins_channel_eq",
                ],
            ],
        ]
        let params = QualificationTransport.pluginReadProbeParams(from: [
            try JSONSerialization.data(withJSONObject: inventory),
            try JSONSerialization.data(withJSONObject: [
                "state": "B", "complete": false,
                "plugins": [[
                    "read_status": "ok", "occupied": true,
                    "plugin_id": "logic.stock.effect.gain", "plugin_insert_ref": "ins_state_b",
                ]],
            ]),
        ])

        #expect(params[.pluginsGetHostParameterManifest]?["target_ref"] as? String == "ins_gain")
        #expect(params[.pluginsGetHostParameterManifest]?["expected_build_fingerprint"] as? String
            == "logic-pro-mcp-qualification-unverified")
        #expect(params[.pluginsGetParamVerified]?["target_ref"] as? String == "ins_gain")
        #expect(params[.pluginsGetParamVerified]?["param"] as? String == "gain")
        #expect(params[.pluginsGetChannelEQStateVerified]?["target_ref"] as? String
            == "ins_channel_eq")
        #expect(params[.pluginsPlanParameterChanges]?["target_ref"] as? String
            == "ins_compressor")
        let changes = try #require(
            params[.pluginsPlanParameterChanges]?["changes"] as? [[String: Any]]
        )
        #expect(changes.count == 1)
        #expect(changes[0]["param"] as? String == "threshold")
        #expect(changes[0]["unit"] as? String == "normalized")
        #expect(changes[0]["value"] is Double)
    }

    @Test func pluginReadProbePreparationUsesTracksAndInventoryWithoutSessionInspection() throws {
        let tracks = try JSONSerialization.data(withJSONObject: [
            "source": "ax_live",
            "readable": true,
            "data": [
                ["id": 7, "track_ref": "trk_later"],
                ["id": 3, "track_ref": "trk_first"],
            ],
        ])
        var inventoryReads: [Int] = []
        let params = try QualificationTransport.preparePluginReadProbeParams(
            tracksRead: { tracks },
            inventoryRead: { track in
                inventoryReads.append(track)
                let pluginID = track == 3
                    ? "logic.stock.effect.sample_delay"
                    : "logic.stock.effect.compressor"
                return try JSONSerialization.data(withJSONObject: [
                    "state": "A",
                    "complete": true,
                    "plugins": [[
                        "read_status": "ok",
                        "occupied": true,
                        "plugin_id": pluginID,
                        "plugin_insert_ref": "ins_\(track)",
                    ]],
                ])
            }
        )

        #expect(inventoryReads == [3, 7])
        #expect(params[.pluginsGetHostParameterManifest]?["target_ref"] as? String == "ins_3")
    }

    @Test func requestedReadProbePreparationRefreshesBeforePluginAuthorities() throws {
        let tracks = try JSONSerialization.data(withJSONObject: [
            "source": "ax_live",
            "readable": true,
            "data": [["id": 3, "track_ref": "trk_first"]],
        ])
        var events: [String] = []
        var observedRefreshTimeout: TimeInterval?

        let preparation = QualificationTransport.prepareRequestedReadProbeParams(
            requestedMixerReads: [.mixerGetOutputVerified],
            requestedPluginReads: [.pluginsGetHostParameterManifest],
            refresh: { timeout in
                observedRefreshTimeout = timeout
                events.append("refresh")
                return ("{\"refreshed\":true}", false)
            },
            pluginPreparation: {
                try QualificationTransport.preparePluginReadProbeParams(
                    tracksRead: {
                        events.append("tracks")
                        return tracks
                    },
                    inventoryRead: { track in
                        events.append("inventory.\(track)")
                        return try JSONSerialization.data(withJSONObject: [
                            "state": "A",
                            "complete": true,
                            "plugins": [[
                                "read_status": "ok",
                                "occupied": true,
                                "plugin_id": "logic.stock.effect.gain",
                                "plugin_insert_ref": "ins_\(track)",
                            ]],
                        ])
                    }
                )
            }
        )

        #expect(events == ["refresh", "tracks", "inventory.3"])
        let refreshSpec = try #require(OperationRegistry.spec(
            tool: "logic_system", command: "refresh_cache"))
        #expect(observedRefreshTimeout
            == QualificationTransport.operationRequestTimeout(for: refreshSpec))
        #expect(try #require(observedRefreshTimeout) > 10)
        #expect(preparation.failures.isEmpty)
        #expect(preparation.params[.pluginsGetHostParameterManifest]?["target_ref"] as? String
            == "ins_3")
    }

    @Test func mixerOnlyReadProbePreparationRefreshesWithoutPluginPreparation() {
        var refreshCount = 0
        var pluginPreparationCount = 0

        let preparation = QualificationTransport.prepareRequestedReadProbeParams(
            requestedMixerReads: [.mixerGetInputBusVerified],
            requestedPluginReads: [],
            refresh: { _ in
                refreshCount += 1
                return ("{\"refreshed\":false}", false)
            },
            pluginPreparation: {
                pluginPreparationCount += 1
                return [:]
            }
        )

        #expect(refreshCount == 1)
        #expect(pluginPreparationCount == 0)
        #expect(preparation.params.isEmpty)
        #expect(preparation.failures.isEmpty)
    }

    @Test func emptyReadProbePreparationDoesNotRefreshOrPreparePlugins() {
        var refreshCount = 0
        var pluginPreparationCount = 0

        let preparation = QualificationTransport.prepareRequestedReadProbeParams(
            requestedMixerReads: [],
            requestedPluginReads: [],
            refresh: { _ in
                refreshCount += 1
                return ("{}", false)
            },
            pluginPreparation: {
                pluginPreparationCount += 1
                return [:]
            }
        )

        #expect(refreshCount == 0)
        #expect(pluginPreparationCount == 0)
        #expect(preparation.params.isEmpty)
        #expect(preparation.failures.isEmpty)
    }

    @Test func pluginPreparationFailureDoesNotInvalidateRefreshedMixerReads() {
        let requestedPluginReads: Set<OperationID> = [
            .pluginsGetHostParameterManifest,
            .pluginsGetParamVerified,
        ]

        let preparation = QualificationTransport.prepareRequestedReadProbeParams(
            requestedMixerReads: [.mixerGetSendDestinationVerified],
            requestedPluginReads: requestedPluginReads,
            refresh: { _ in ("{\"refreshed\":true}", false) },
            pluginPreparation: {
                throw QualificationTransportError.malformedFrame("inventory")
            }
        )

        #expect(preparation.params.isEmpty)
        #expect(Set(preparation.failures.keys) == requestedPluginReads)
        #expect(preparation.failures.values.allSatisfy {
            $0.contains("plug-in read-probe preparation failed")
                && $0.contains("qualification_transport_malformed_frame:inventory")
        })
    }

    @Test(arguments: [false, true])
    func failedReadProbeRefreshFailsEveryRequestedReadAndSkipsPluginPreparation(
        throwsRefresh: Bool
    ) {
        let requestedMixerReads: Set<OperationID> = [
            .mixerGetOutputVerified,
            .mixerGetSendBypassVerified,
        ]
        let requestedPluginReads: Set<OperationID> = [
            .pluginsGetParamVerified,
            .pluginsPlanParameterChanges,
        ]
        var pluginPreparationCount = 0

        let preparation = QualificationTransport.prepareRequestedReadProbeParams(
            requestedMixerReads: requestedMixerReads,
            requestedPluginReads: requestedPluginReads,
            refresh: { _ in
                if throwsRefresh {
                    throw QualificationTransportError.closedPipe(phase: "refresh")
                }
                return ("{\"error\":\"refused\"}", true)
            },
            pluginPreparation: {
                pluginPreparationCount += 1
                return [:]
            }
        )

        #expect(pluginPreparationCount == 0)
        #expect(Set(preparation.failures.keys) == requestedMixerReads.union(requestedPluginReads))
        let reasons = Set(preparation.failures.values)
        #expect(reasons.count == 1)
        let reason = reasons.first ?? ""
        #expect(reason.contains("read-probe cache refresh failed"))
        if throwsRefresh {
            #expect(reason.contains("qualification_transport_closed_pipe:refresh"))
        } else {
            #expect(reason.contains("read_probe_refresh: tool returned isError"))
        }
    }

    @Test func independentMixerReadbackRefreshesImmediatelyBeforeReading() throws {
        var events: [String] = []
        var nextRequestID = 41
        var observedRefreshTimeout: TimeInterval?
        let expected = Data(#"{"data_source":"ax_live"}"#.utf8)

        let actual = try QualificationTransport.independentResourceReadback(
            source: "logic://mixer",
            nextRequestID: &nextRequestID,
            refresh: { requestID, timeout in
                observedRefreshTimeout = timeout
                events.append("refresh.\(requestID)")
                return (#"{"refreshed":true}"#, false)
            },
            read: { requestID in
                events.append("read.\(requestID)")
                return expected
            }
        )

        #expect(actual == expected)
        #expect(events == ["refresh.41", "read.42"])
        #expect(nextRequestID == 43)
        let refreshSpec = try #require(OperationRegistry.spec(
            tool: "logic_system", command: "refresh_cache"))
        #expect(observedRefreshTimeout
            == QualificationTransport.operationRequestTimeout(for: refreshSpec))
        #expect(try #require(observedRefreshTimeout) > 10)
    }

    @Test func independentNonMixerReadbackDoesNotRefresh() throws {
        var events: [String] = []
        var nextRequestID = 41

        _ = try QualificationTransport.independentResourceReadback(
            source: "logic://tracks",
            nextRequestID: &nextRequestID,
            refresh: { requestID, _ in
                events.append("refresh.\(requestID)")
                return (#"{"refreshed":true}"#, false)
            },
            read: { requestID in
                events.append("read.\(requestID)")
                return Data()
            }
        )

        #expect(events == ["read.41"])
        #expect(nextRequestID == 42)
    }

    @Test(arguments: [false, true])
    func failedIndependentMixerRefreshPreventsRead(throwsRefresh: Bool) {
        var readCount = 0
        var nextRequestID = 41
        var refreshRequestID: Int?

        #expect(throws: QualificationTransportError.self) {
            _ = try QualificationTransport.independentResourceReadback(
                source: "logic://mixer",
                nextRequestID: &nextRequestID,
                refresh: { requestID, _ in
                    refreshRequestID = requestID
                    if throwsRefresh {
                        throw QualificationTransportError.closedPipe(
                            phase: "independent_readback_refresh")
                    }
                    return (#"{"error":"refused"}"#, true)
                },
                read: { _ in
                    readCount += 1
                    return Data()
                }
            )
        }

        #expect(readCount == 0)
        #expect(refreshRequestID == 41)
        #expect(nextRequestID == 42)
    }

    @Test func pluginInventoryTrackIndicesRequireUniqueLiveReferencedArrangeRows() throws {
        let live: [String: Any] = [
            "source": "ax_live", "readable": true,
            "data": [
                ["id": 2, "track_ref": "trk_two"],
                ["id": 0, "track_ref": "trk_zero"],
                ["id": 2, "track_ref": "trk_duplicate"],
                ["id": -1, "track_ref": "trk_negative"],
                ["id": 4, "track_ref": "not_current"],
            ],
        ]
        let placeholder: [String: Any] = [
            "source": "project_file", "readable": false,
            "data": [["id": 0], ["id": 1]],
        ]

        #expect(QualificationTransport.pluginInventoryTrackIndices(
            from: try JSONSerialization.data(withJSONObject: live)
        ) == [0])
        #expect(QualificationTransport.pluginInventoryTrackIndices(
            from: try JSONSerialization.data(withJSONObject: placeholder)
        ).isEmpty)
    }

    @Test func operationRequestsUseTheirRegistryDeadlineInsteadOfTheTransportDefault() throws {
        let inspect = try #require(OperationRegistry.specs.first {
            $0.id == .projectInspectSession
        })
        let health = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let saga = try #require(OperationRegistry.specs.first { $0.id == .systemSagaExecute })

        #expect(QualificationTransport.operationRequestTimeout(for: inspect) == 95)
        #expect(QualificationTransport.operationRequestTimeout(for: health) == 30)
        #expect(QualificationTransport.operationRequestTimeout(for: saga) == 905)
    }

    @Test(arguments: [OperationID.mixerSetPan, .mixerSetVolume],
          ["live", "cache", "stale", "missing_age", "unreadable", "occluded"])
    func scalarTrackReadbackStillRequiresActualFreshEvidence(operation: OperationID, shape: String) throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let field = try #require(QualificationTransport.valueRestoreReadbackField[operation])
        func reading(_ value: Double) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: [
                "source": "ax_live", "cache_age_sec": 0,
                "data": [["track_ref": "held-track", field: value]],
            ] as [String: Any], options: [.sortedKeys]), as: UTF8.self)
        }
        let original = try reading(0.4)
        let record = QualificationMutationRestoreRecord(operationID: operation.rawValue,
            preState: original, mutation: #"{"state":"A","success":true}"#,
            readback: try reading(0.5), restore: #"{"state":"A","success":true}"#,
            restoreReadback: original)
        #expect(record.verifiedCycleShape)
        var finalRead = try #require(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        switch shape {
        case "cache": finalRead["source"] = "cache"
        case "stale": finalRead["cache_age_sec"] = spec.deadline.seconds + 1
        case "missing_age": finalRead.removeValue(forKey: "cache_age_sec")
        case "unreadable": finalRead["readable"] = false
        case "occluded": finalRead["ax_occluded"] = true
        default: break
        }
        let result = QualificationOperationResult(operationID: operation.rawValue,
            tool: spec.tool.rawValue, command: spec.command, mutability: spec.mutability,
            requestID: "scalar-no-write-probe",
            responseData: Data(#"{"state":"C","error":"invalid_params","write_attempted":false}"#.utf8),
            isError: true, state: "C", error: "invalid_params", hint: nil, writeAttempted: false,
            readbackSource: QualificationTransport.readbackSource(for: spec),
            readbackRequestID: "independent-scalar-read",
            readbackData: try JSONSerialization.data(withJSONObject: finalRead),
            verification: spec.verification, deadline: spec.deadline, failureReason: nil,
            mutationRestore: record)
        #expect(result.status == (shape == "live" ? .passed : .notQualified))
    }

    @Test(arguments: [false, true])
    func stoppedTransportMustBeObservedBeforeARecipeAcquiresChanges(cached: Bool) throws {
        let fixture = try SlowHandshakeFixture(transportNativePause: true, cachedTransport: cached)
        defer { fixture.remove() }
        let pause = try #require(OperationRegistry.specs.first { $0.id == .transportPause })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [pause]))
        let effects = result.wireFrames.filter { $0.direction == .request &&
            ["phase_b.precondition", "phase_b.mutation", "phase_b.restore", "phase_b.cleanup"].contains($0.operationID) }
        if cached {
            #expect(effects.isEmpty, "cached/unverified false cannot authorize staging or a compensating write")
            #expect(result.mutationRestoreRecords.isEmpty)
        } else {
            #expect(effects.count == 3)
            #expect(result.operationResults[pause.id.rawValue]?.status == .passed)
        }
    }

    @Test(arguments: ["slow_short_gap", "unreadable", "changed", "slow_full_gap"])
    func motionGapUsesActualTempoRatherThanTheResourceDefault(shape: String) throws {
        let state: [String: Any] = ["isPlaying": true, "tempo": 120,
            "isCycleEnabled": false, "observedCycleEnabled": false, "position": "1.1",
            "positionReadback": ["value": "1.1", "observedComponents": ["bar", "beat"]]]
        var first: [String: Any] = ["source": "ax_live", "cache_age_sec": 0, "data": ["state": state]]
        if shape != "unreadable" { first["observed_tempo"] = 20 }
        var second = first
        if shape == "changed" { second["observed_tempo"] = 25 }
        var reading = second
        reading["qualification_motion_samples"] = [first, second]
        reading["qualification_motion_gap_ms"] = shape == "slow_full_gap" ? 3_750 : 1_000
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: reading), as: UTF8.self)
        #expect(QualificationTransport.recordedTransportMotion(raw) == (shape == "slow_full_gap" ? .paused : nil))
    }

    @Test(arguments: ["on", "missing", "malformed", "off"])
    func equalTransportPositionsNeedObservedCycleOff(cycle: String) throws {
        var state: [String: Any] = ["isPlaying": true, "tempo": 120, "position": "1.1",
            "positionReadback": ["value": "1.1", "observedComponents": ["bar", "beat"]]]
        switch cycle {
        case "on": state["isCycleEnabled"] = true; state["observedCycleEnabled"] = true
        case "off": state["isCycleEnabled"] = false; state["observedCycleEnabled"] = false
        case "malformed": state["isCycleEnabled"] = "unreadable"; state["observedCycleEnabled"] = "unreadable"
        default: break
        }
        let sample: [String: Any] = ["source": "ax_live", "cache_age_sec": 0, "observed_tempo": 120, "data": ["state": state]]
        var recordReading = sample
        // At 120 BPM a two-beat loop can return to the same display position in one second.
        recordReading["qualification_motion_samples"] = [sample, sample]
        recordReading["qualification_motion_gap_ms"] = 1_000
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: recordReading), as: UTF8.self)
        #expect(QualificationTransport.recordedTransportMotion(raw) == (cycle == "off" ? .paused : nil))
    }

    @Test(arguments: ["play", "stop", "pause"], ["stopped", "paused", "moving"])
    func transportCyclesRestoreTheObservedOriginalMotion(command: String, original: String) throws {
        let fixture = try SlowHandshakeFixture(transportNativePause: true, initialTransportMotion: original)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.tool == .logicTransport && $0.command == command })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [spec]))
        let observed = try #require(result.operationResults[spec.id.rawValue])
        #expect(observed.status == .passed)
        let record = try #require(result.mutationRestoreRecords.first)
        let expected: QualificationTransport.TransportMotion = original == "stopped" ? .stopped : (original == "paused" ? .paused : .moving)
        #expect(QualificationTransport.recordedTransportMotion(record.preState) == expected)
        #expect(QualificationTransport.recordedTransportMotion(record.restoreReadback) == expected)
        #expect(record.verifiedCycleShape)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("playing"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == (original == "stopped" ? "false" : "true"))
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("moving"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == (original == "moving" ? "true" : "false"))
    }

    @Test func nativePauseCycleUsesMotionRatherThanClearingPlay() throws {
        let fixture = try SlowHandshakeFixture(transportNativePause: true)
        defer { fixture.remove() }
        let pause = try #require(OperationRegistry.specs.first { $0.id == .transportPause })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [pause]))
        let observed = try #require(result.operationResults[pause.id.rawValue])
        #expect(observed.status == .passed)
        let record = try #require(result.mutationRestoreRecords.first)
        #expect(record.operationID == pause.id.rawValue)
        #expect(record.verifiedCycleShape)
        let readback = try #require(sharedJSONObject(record.readback))
        let payload = try #require(readback["data"] as? [String: Any])
        let state = try #require(payload["state"] as? [String: Any])
        let playOn = try #require(state["isPlaying"] as? Bool)
        #expect(playOn, "native Pause leaves Play on; stationary positions establish its effect")
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("playing"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "false")
    }

    @Test func failedTransportPreconditionDoesNotLeakPlayback() throws {
        let fixture = try SlowHandshakeFixture(transportRefusal: true)
        defer { fixture.remove() }
        let pause = try #require(OperationRegistry.specs.first { $0.id == .transportPause })
        let result = try QualificationTransport(handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2)
            .drive(.init(executableURL: fixture.executableURL,
                environment: ["HANDSHAKE_DELAY": "0"], expectedOperationCount: 0, operations: [pause]))
        let observed = try #require(result.operationResults[pause.id.rawValue])
        #expect(observed.status != .passed, "a refused mutation never acquires write-cycle credit")
        #expect(observed.mutationRestore == nil)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("playing"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "false")
        let requests = try String(contentsOf: fixture.directory.appendingPathComponent("requests"), encoding: .utf8)
        #expect(requests.contains("\"command\":\"play\""), "the real recipe must stage playback")
        #expect(requests.contains("\"command\":\"pause\""), "the refused mutation must actually run")
        #expect(requests.contains("\"command\":\"stop\""), "the acquired precondition must be compensated")
    }

    @Test("Only intentionally withheld mutations get a non-crediting not-run receipt",
          arguments: ["withheld", "opted_in_missing", "missing_readonly", "actual_failure"])
    func missingResultsDistinguishWithheldMutationFromFailedExecution(shape: String) async throws {
        let read = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let mutation = try #require(OperationRegistry.specs.first { $0.id == .mixerSetVolume })
        let specs = [read, mutation]
        let original = Self.driveResult(specs: specs,
            failedOperationID: shape == "actual_failure" ? mutation.id : nil)
        let fixture = try Fixture(specs: specs, drive: { request in
            #expect(request.expectedOperationCount == specs.count)
            if shape == "opted_in_missing" { #expect(request.operations.contains(where: { $0.id == mutation.id })) }
            else { #expect(!request.operations.contains(where: { $0.id == mutation.id })) }
            let included = Set((shape == "actual_failure" ? specs : request.operations).map(\.id.rawValue))
            let results = original.operationResults.filter { entry in
                included.contains(entry.key)
                    && !(shape == "opted_in_missing" && entry.key == mutation.id.rawValue)
                    && !(shape == "missing_readonly" && entry.key == read.id.rawValue)
            }
            return QualificationDriveResult(handshake: original.handshake, health: original.health,
                catalog: original.catalog, expectedOperationCount: original.expectedOperationCount,
                traceList: original.traceList, traceDetail: original.traceDetail, negative: original.negative,
                observedLocale: original.observedLocale, operationResults: results,
                wireFrames: original.wireFrames.filter { included.contains($0.operationID) || $0.operationID == "handshake" },
                mutationRestoreRecords: [], failureReason: original.failureReason)
        })
        defer { fixture.remove() }
        let result = await fixture.runQualification(mutateOpenProject: shape == "opted_in_missing")
        #expect(result.exitCode == 1, "nonwaived missing or withheld operations still prevent full qualification")
        let attestation = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        let mutationCase = try #require(attestation.cases.first { $0.operationID == mutation.id.rawValue })
        if shape == "withheld" || shape == "missing_readonly" {
            #expect(mutationCase.status == .notQualified)
            #expect(mutationCase.verificationKind == .typedDeferral)
            #expect(mutationCase.deferral?.code == .liveMutationNotRun)
            let reason = try #require(mutationCase.reason)
            #expect(reason.contains("--mutate-open-project"))
            #expect(mutationCase.operationRequestID == nil && mutationCase.readback == nil && mutationCase.restore == nil)
            let evidenceURL = fixture.directory.appendingPathComponent(try #require(mutationCase.evidenceFiles.first))
            let evidence = try JSONDecoder().decode(CaseEvidence.self, from: Data(contentsOf: evidenceURL))
            #expect(QualificationRunner.evidence(evidence, binds: mutationCase))
            #expect(!QualificationRunner.evidenceShapeIsValid(evidence), "no readback or trusted-acceptance proof was invented")
        } else { #expect(mutationCase.status == .failed) }
        #expect(!mutationCase.verified)
        #expect(!PromotionGate.operationIsLiveCredited(mutationCase))
        let readCase = try #require(attestation.cases.first { $0.operationID == read.id.rawValue })
        #expect(readCase.status == (shape == "missing_readonly" ? .failed : .passed))
        let decision = PromotionGate().evaluate(attestation: attestation, releaseVersion: "1.2.3",
            expectedBinarySHA256: fixture.binarySHA256, presentArtifacts: [], requiredArtifacts: [],
            requiredOperationIDs: Set(specs.map(\.id.rawValue)))
        #expect(!decision.promotable)
    }

    @Test func qualificationExecutesEachOperationAndBindsIndependentReadback() async throws {
        let specs = [
            try #require(OperationRegistry.specs.first { $0.id == .transportPlay }),
            try #require(OperationRegistry.specs.first { $0.id == .mixerSetVolume }),
        ]
        let fixture = try Fixture(specs: specs)
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let operationCases = attestation.cases.filter { $0.id.hasPrefix("in-process/") }
        #expect(operationCases.count == specs.count)

        var responseDigests: Set<String> = []
        var operationRequestIDs: Set<String> = []
        var readbackRequestIDs: Set<String> = []
        var readbackSources: Set<String> = []
        for operationCase in operationCases {
            let evidence = try fixture.evidence(for: operationCase)
            let responseDigest = try #require(evidence["operation_response_sha256"] as? String)
            let operationRequestID = try #require(evidence["operation_request_id"] as? String)
            let readback = try #require(evidence["readback"] as? [String: Any])
            let readbackDigest = try #require(readback["sha256"] as? String)
            let readbackRequestID = try #require(readback["request_id"] as? String)
            let readbackSource = try #require(readback["source"] as? String)
            #expect(responseDigest.count == 64)
            #expect(readbackDigest.count == 64)
            responseDigests.insert(responseDigest)
            operationRequestIDs.insert(operationRequestID)
            readbackRequestIDs.insert(readbackRequestID)
            readbackSources.insert(readbackSource)
        }

        #expect(responseDigests.count == specs.count)
        #expect(operationRequestIDs.count == specs.count)
        #expect(readbackRequestIDs.count == specs.count)
        #expect(readbackSources == ["logic://transport/state", "logic://mixer"])
    }

    @Test func runnerVerifierRejectsCoherentLegacyMIDIPortSemanticBundle() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .midiListPorts })
        let originalDrive = Self.driveResult(specs: [spec])
        let captured = try #require(originalDrive.operationResults[spec.id.rawValue])
        let ports = QualificationOperationResult(
            operationID: captured.operationID, tool: captured.tool, command: captured.command,
            mutability: captured.mutability, requestID: captured.requestID,
            responseData: captured.responseData, isError: captured.isError,
            state: nil, error: nil, hint: nil, writeAttempted: nil,
            // This fixture is deliberately the legacy circular resource path. Do not derive it
            // from the production source mapping, which now selects a separate host census.
            readbackSource: "logic://midi/ports",
            readbackRequestID: captured.readbackRequestID, readbackData: captured.readbackData,
            verification: spec.verification, deadline: spec.deadline, failureReason: captured.failureReason
        )
        let drive = QualificationDriveResult(
            handshake: originalDrive.handshake, health: originalDrive.health,
            catalog: originalDrive.catalog, expectedOperationCount: originalDrive.expectedOperationCount,
            traceList: originalDrive.traceList, traceDetail: originalDrive.traceDetail,
            negative: originalDrive.negative, observedLocale: originalDrive.observedLocale,
            operationResults: [spec.id.rawValue: ports], wireFrames: originalDrive.wireFrames,
            mutationRestoreRecords: originalDrive.mutationRestoreRecords,
            failureReason: originalDrive.failureReason
        )
        let fixture = try Fixture(specs: [spec], drive: { _ in drive })
        defer { fixture.remove() }
        let axisWaivers = Self.axisWaivers()
        // A legitimate known limitation may be waived for this CONTROL only.
        // Before the repair the producer calls it passed, so no operation waiver is supplied.
        let controlWaivers = axisWaivers + (ports.status == .passed ? [] : [
            Self.waiver(
                caseID: "in-process/midi.list_ports", owningIssue: "#373",
                affectedCapability: "operation:midi.list_ports"
            )
        ])
        try JSONEncoder().encode(controlWaivers).write(to: fixture.waiversURL)
        let baseline = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let control = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        try #require(control.exitCode == 0, "baseline must actually verify: \(control.stdout)")
        let operationCase = try #require(baseline.cases.first { $0.id == "in-process/midi.list_ports" })
        let evidencePath = try #require(operationCase.evidenceFiles.first)
        let evidenceURL = fixture.directory.appendingPathComponent(evidencePath)
        let originals = try [
            evidenceURL, fixture.caseManifestURL, fixture.manifestURL, fixture.attestationURL
        ].map { ($0, try Data(contentsOf: $0)) }

        func claimLegacySemanticPass(_ object: inout [String: Any]) throws {
            object["status"] = "passed"
            object["verified"] = true
            object["verification_kind"] = "semantic_readback"
            object["deferral"] = nil
            object["reason"] = nil
            object["failure_reason"] = nil
            var readback = try #require(object["readback"] as? [String: Any])
            readback["verified"] = true
            object["readback"] = readback
        }
        // Keep the exact port payloads, response/readback request IDs and digests.
        // Only the producer's meaning/credit claim changes, not the observations.
        try Self.mutateJSONObject(at: evidenceURL, claimLegacySemanticPass)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let axisWaiverJSON = try JSONSerialization.jsonObject(with: encoder.encode(axisWaivers))
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            var cases = try #require(object["cases"] as? [[String: Any]])
            let index = try #require(cases.firstIndex { $0["id"] as? String == operationCase.id })
            try claimLegacySemanticPass(&cases[index])
            object["cases"] = cases
            object["waivers"] = axisWaiverJSON // no operation waiver can mask the counterexample
        }
        let forged = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self, from: Data(contentsOf: fixture.attestationURL)
        )
        try Self.mutateJSONObject(at: fixture.caseManifestURL) { object in
            object["cases"] = try JSONSerialization.jsonObject(with: encoder.encode(forged.cases))
        }
        // The existing rewritePassedAxisEvidence helper shows this exact digest chain.
        // This operation witness additionally updates the CASE manifest and waiver binding.
        let evidenceData = try Data(contentsOf: evidenceURL)
        let caseManifestData = try Data(contentsOf: fixture.caseManifestURL)
        try Self.mutateJSONObject(at: fixture.manifestURL) { object in
            var entries = try #require(object["files"] as? [[String: Any]])
            let index = try #require(entries.firstIndex { $0["path"] as? String == evidencePath })
            entries[index]["sha256"] = SupportBundleBuilder.sha256(evidenceData)
            object["files"] = entries
            object["case_manifest_sha256"] = SupportBundleBuilder.sha256(caseManifestData)
            object["waivers_sha256"] = SupportBundleBuilder.sha256(try encoder.encode(axisWaivers))
        }
        let manifestSHA256 = SupportBundleBuilder.sha256(try Data(contentsOf: fixture.manifestURL))
        let counts = QualificationSummaryCounts(cases: forged.cases)
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            object["total"] = counts.total
            object["passed"] = counts.passed
            object["failed"] = counts.failed
            object["waived"] = counts.waived
            object["evidenceManifestSHA256"] = manifestSHA256
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["evidenceManifestSHA256"] = manifestSHA256
            object["provenance"] = provenance
        }
        try fixture.forceSignForDiagnosticFixture()
        let refused = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(refused.exitCode != 0, "\(refused.stdout)")
        let rejections = try #require(try Self.resultObject(refused)["rejections"] as? [[String: Any]])
        #expect(rejections.count == 2, "\(refused.stdout)")
        #expect(Self.rejectionReasons(try Self.resultObject(refused)) == [
            "requiredOperationNotSatisfied", "evidenceBindingMismatch"
        ], "\(refused.stdout)")
        #expect(rejections.contains {
            $0["reason"] as? String == "evidenceBindingMismatch"
                && $0["actual"] as? String == "semantic readback binding"
        }, "\(refused.stdout)")
        #expect(rejections.contains {
            $0["reason"] as? String == "requiredOperationNotSatisfied"
                && $0["key"] as? String == "midi.list_ports"
        }, "\(refused.stdout)")
        // A signed original with the same fixture, axis and verifier still works after restoration.
        for (url, data) in originals { try data.write(to: url, options: .atomic) }
        let restored = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(restored.exitCode == 0, "\(restored.stdout)")
    }

    @Test func runnerVerifierAcceptsBoundHostCoreMIDIPortReadback() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .midiListPorts })
        let drive = Self.driveResult(specs: [spec])
        let ports = try #require(drive.operationResults[spec.id.rawValue])
        #expect(ports.readbackSource
            == QualificationSemanticReadbackValidator.coreMIDIPortReadbackSource)
        #expect(ports.status == .passed)

        let fixture = try Fixture(specs: [spec], drive: { _ in drive })
        defer { fixture.remove() }
        try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)
        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let operationCase = try #require(
            attestation.cases.first { $0.id == "in-process/midi.list_ports" }
        )
        #expect(operationCase.status == .passed)
        #expect(operationCase.readback?.source
            == QualificationSemanticReadbackValidator.coreMIDIPortReadbackSource)
        let accepted = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(accepted.exitCode == 0, "\(accepted.stdout)\(accepted.stderr)")
    }

    @Test func runnerVerifierAcceptsBoundHostLibraryPanelReadback() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .tracksListLibrary })
        let drive = Self.driveResult(specs: [spec])
        let library = try #require(drive.operationResults[spec.id.rawValue])
        #expect(library.readbackSource
            == QualificationSemanticReadbackValidator.libraryPanelReadbackSource)
        #expect(QualificationTransport.readbackSource(for: spec)
            == QualificationSemanticReadbackValidator.libraryPanelReadbackSource)
        #expect(library.status == .passed)

        let fixture = try Fixture(specs: [spec], drive: { _ in drive })
        defer { fixture.remove() }
        try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)
        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let operationCase = try #require(
            attestation.cases.first { $0.id == "in-process/tracks.list_library" }
        )
        #expect(operationCase.status == .passed)
        #expect(operationCase.readback?.source
            == QualificationSemanticReadbackValidator.libraryPanelReadbackSource)
        let accepted = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(accepted.exitCode == 0, "\(accepted.stdout)\(accepted.stderr)")
    }

    private final class LibraryReadbackProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var callsStorage = 0

        func record() {
            lock.lock()
            callsStorage += 1
            lock.unlock()
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callsStorage
        }
    }

    private enum LibraryReadbackFailure: Error {
        case unavailable
    }

    @Test func transportUsesInjectedLibraryPanelReadbackInsteadOfCacheResource() throws {
        let fixture = try SlowHandshakeFixture(libraryReadback: true)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .tracksListLibrary })
        let snapshot = Data(#"{"categories":["Bass"],"presetsByCategory":{}}"#.utf8)
        let probe = LibraryReadbackProbe()

        let drive = try QualificationTransport(
            handshakeTimeout: 2,
            requestTimeout: 2,
            shutdownGrace: 2,
            libraryPanelReadback: {
                probe.record()
                return snapshot
            }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]
        ))

        let result = try #require(drive.operationResults[spec.id.rawValue])
        #expect(probe.calls == 1)
        #expect(result.status == .passed)
        #expect(result.responseData == snapshot)
        #expect(result.readbackData == snapshot)
        #expect(result.readbackSource
            == QualificationSemanticReadbackValidator.libraryPanelReadbackSource)
        let requests = try String(
            contentsOf: fixture.directory.appendingPathComponent("requests"),
            encoding: .utf8
        )
        #expect(!requests.contains("logic://library/inventory"))
    }

    @Test func transportFailsClosedWhenLibraryPanelReadbackThrows() throws {
        let fixture = try SlowHandshakeFixture(libraryReadback: true)
        defer { fixture.remove() }
        let spec = try #require(OperationRegistry.specs.first { $0.id == .tracksListLibrary })
        let probe = LibraryReadbackProbe()

        let drive = try QualificationTransport(
            handshakeTimeout: 2,
            requestTimeout: 2,
            shutdownGrace: 2,
            libraryPanelReadback: {
                probe.record()
                throw LibraryReadbackFailure.unavailable
            }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]
        ))

        let result = try #require(drive.operationResults[spec.id.rawValue])
        #expect(probe.calls == 1)
        #expect(result.status == .failed)
        #expect(result.readbackData == nil)
        let failureReason = try #require(result.failureReason)
        #expect(failureReason.contains("independent readback"))
    }

    @Test func operationQualificationSeparatesSemanticReadSmokeAndTypedDeferrals() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let operationCases = attestation.cases.filter { $0.id.hasPrefix("in-process/") }

        // Oracle presence is not independent readback. Response-only plugin checks and
        // same-host receipt checks are withheld; other semantic checks still pass.
        // DERIVED: one case per registry spec. It was `113` and read 114 the day main added
        // `system.setup_control_surface`.
        #expect(operationCases.count == OperationRegistry.specs.count)
        let readOnlyCount = OperationRegistry.specs.filter { $0.mutability == .readOnly }.count
        let marked = Set(SemanticOracleTable.all
            .filter { $0.independentReadbackDeferral != nil }.map(\.operationID))
        #expect(marked == Set<OperationID>([.midiListPorts, .tracksListLibrary, .midiReadSelectedRegionEvents, .mixerGetOutputVerified, .mixerGetSendDestinationVerified,
            .mixerGetInputBusVerified, .mixerGetSendBypassVerified, .pluginsPlanParameterChanges,
            .pluginsGetHostParameterManifest, .pluginsGetParamVerified, .pluginsGetChannelEQStateVerified]))
        let smokeOnly = marked.subtracting([.midiListPorts, .tracksListLibrary])
        let readOnlyIDs = Set(OperationRegistry.specs.filter { $0.mutability == .readOnly }.map(\.id.rawValue))
        let smokeOnlyIDs = Set(smokeOnly.map(\.rawValue))
        let passed = operationCases.filter { $0.status == .passed }
        #expect(passed.count == readOnlyCount - smokeOnly.count)
        #expect(Set(passed.map(\.operationID)) == readOnlyIDs.subtracting(smokeOnlyIDs))
        let smoke = operationCases.filter { $0.status == .protocolSmoke }
        #expect(smoke.count == smokeOnly.count)
        #expect(Set(smoke.map(\.operationID)) == smokeOnlyIDs)
        for qualificationCase in smoke {
            let declared = try #require(QualificationSemanticReadbackValidator.independentReadbackDeferral(
                for: qualificationCase.operationID))
            #expect(qualificationCase.status == .protocolSmoke)
            #expect(!qualificationCase.verified)
            #expect(qualificationCase.verificationKind == .protocolSmoke)
            #expect(qualificationCase.deferral == declared)
            #expect(declared.code == .semanticValidatorUnavailable)
            let readback = try #require(qualificationCase.readback)
            #expect(!readback.verified)
            #expect(!PromotionGate.operationIsLiveCredited(qualificationCase))
        }
        // DERIVED: everything the registry has, minus the read-only specs this fixture qualifies.
        // It was `90`, and the day main added `system.setup_control_surface` it read 91 -- a number
        // that tracks the registry turns every new operation into a failing test that says
        // nothing about the product.
        #expect(operationCases.filter { $0.status == .notQualified }.count
                    == OperationRegistry.specs.count - readOnlyCount)
        #expect(operationCases.filter { $0.status == .failed }.isEmpty)
        #expect(operationCases.filter { $0.status == .passed }.allSatisfy {
            $0.verificationKind == .semanticReadback
                && $0.deferral == nil
                && $0.readback?.verified == true
        })
        #expect(operationCases.filter { $0.status == .notQualified }.allSatisfy {
            $0.verificationKind == .typedDeferral
                && $0.deferral?.code == .liveMutationNotRun
                && $0.deferral?.detail.contains("ADR-001-c") == true
                && $0.readback != nil
        })
    }

    @Test func qualificationFixtureMetadataMatchesSelectedRegionResponseEnvelope() throws {
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .midiReadSelectedRegionEvents
        })
        let result = try #require(Self.driveResult(specs: [spec])
            .operationResults[spec.id.rawValue])
        let responseData = try #require(result.responseData)
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let resultWriteAttempted = String(describing: result.writeAttempted)
        let responseWriteAttempted = String(describing: response["write_attempted"] as? Bool)

        #expect(result.state == response["state"] as? String)
        #expect(result.error == response["error"] as? String)
        #expect(resultWriteAttempted == responseWriteAttempted)
    }

    @Test func qualificationFixtureResponseArtifactsBindRetainedEvidence() async throws {
        let fixture = try trustedFixture(includeRequiredAtlas: false)
        defer { fixture.remove() }
        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)

        for qualificationCase in attestation.cases where qualificationCase.id.hasPrefix("in-process/") {
            let artifacts = try qualificationCase.evidenceFiles.map {
                try Data(contentsOf: fixture.directory.appendingPathComponent($0))
            }
            let evidence = try #require(artifacts.compactMap {
                try? JSONDecoder().decode(CaseEvidence.self, from: $0)
            }.first, "\(qualificationCase.id)")
            let response = try #require(artifacts.compactMap {
                try? JSONDecoder().decode(QualificationOperationResponseArtifact.self, from: $0)
            }.first, "\(qualificationCase.id)")

            #expect(response.operationID == evidence.operationID, "\(qualificationCase.id)")
            #expect(response.tool == evidence.tool, "\(qualificationCase.id)")
            #expect(response.command == evidence.command, "\(qualificationCase.id)")
            #expect(response.requestID == evidence.operationRequestID, "\(qualificationCase.id)")
            #expect(response.isError == evidence.operationIsError, "\(qualificationCase.id)")
            guard evidence.verificationKind != .semanticReadback else { continue }
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(response.payload.utf8)) as? [String: Any],
                "\(qualificationCase.id)"
            )
            #expect(payload["state"] as? String == evidence.operationState, "\(qualificationCase.id)")
            #expect(payload["error"] as? String == evidence.operationError, "\(qualificationCase.id)")
            let payloadWriteAttempted = String(describing: payload["write_attempted"] as? Bool)
            let evidenceWriteAttempted = String(describing: evidence.operationWriteAttempted)
            #expect(payloadWriteAttempted == evidenceWriteAttempted, "\(qualificationCase.id)")
        }
    }

    /// #882. THE CASE NOBODY HAD WRITTEN, and its absence is why the whole mutating class was
    /// rejected by its own verifier without anyone noticing. A read passes because its response
    /// AGREED with an independent readback, so its probe SUCCEEDED. A mutating operation passes
    /// because a write-and-restore cycle was recorded and its probe was REFUSED fail-closed. Both
    /// used to be filed as `semantic_readback`, whose shape rule requires `operation_is_error ==
    /// false` -- so every mutating pass carried `true` into a rule demanding `false`.
    ///
    /// `grep -c 'mutationRestore:' Tests` was ZERO before this: no test had ever built a passing
    /// mutating result, so the runner reported `.passed` and the verifier refused it and nothing
    /// compared the two.
    @Test func aPassingWriteCycleIsFiledAsOneAndCarriesItsRecord() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .tracksRename })
        // The three READINGS are whole resource bodies, not words. `readingThatDidNotHappen`
        // parses each as a JSON envelope and refuses one it cannot read. Writes are tool response
        // envelopes; the comparison uses the track name and identity in the resource readings.
        let record = Self.recipeShapedRecord()
        // The probe is a typed zero-write REFUSAL. That is the only way a mutating operation
        // reaches `.passed`, and it is what made `operationIsError == false` unsatisfiable.
        let refusal = Data(#"{"success":false,"state":"C","error":"invalid_params"}"#.utf8)
        let result = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "cycle-response",
            responseData: refusal,
            isError: true,
            state: "C",
            error: "invalid_params",
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://tracks",
            readbackRequestID: "cycle-readback",
            // Every field the freshness gate actually asks for, because it asks for four and a
            // fixture that carries one defers for a reason that has nothing to do with the case.
            // `source: ax_live` (the token, not `live`); `cache_age_sec` present and within the
            // operation's own deadline -- absent age is refused outright, since an unmeasured age
            // cannot satisfy any bound; and a non-empty body, because an empty one needs
            // `verified_empty` to say the emptiness was observed rather than unread.
            // Rows under `data`, not `tracks`. The emptiness check reads `data`, so a body keyed
            // `tracks` passes it by having no `data` key at all rather than by carrying rows --
            // passing for a reason unrelated to the thing being tested.
            readbackData: Data(
                #"{"source":"ax_live","cache_age_sec":1,"data":[{"name":"after"}]}"#.utf8),
            // The SPEC's policy, not the default. `verification` is what makes the freshness gate
            // apply at all; constructing the result with `.none` asks a different question than
            // the runner does.
            verification: spec.verification,
            deadline: spec.deadline,
            failureReason: nil,
            mutationRestore: record
        )
        #expect(result.status == .passed)
        // Filed as its own kind. Before this it was `.semanticReadback`, and that single line is
        // the whole defect.
        #expect(result.verificationKind == .verifiedWriteCycle)

        // Straight at the verifier's own rule, with the evidence the runner would write.
        let digest = try QualificationRunner.recordDigest(record)
        let evidence = CaseEvidence(
            schema: "qualification-case-evidence/v3",
            caseID: "in-process/\(spec.id.rawValue)",
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            registrySpecFound: true,
            handlerBound: true,
            traceStarted: false,
            traceCompleted: false,
            healthReadStable: true,
            catalogReadStable: true,
            binarySHA256: String(repeating: "a", count: 64),
            axis: QualificationAxis.defaultAxis,
            status: result.status,
            verified: result.verified,
            verificationKind: result.verificationKind,
            readback: result.readback,
            operationResponseSHA256: result.responseSHA256,
            operationRequestID: result.requestID,
            operationIsError: result.isError,
            operationState: result.state,
            operationError: result.error,
            operationWriteAttempted: result.writeAttempted,
            mutationRestoreRecordSHA256: digest
        )
        #expect(QualificationRunner.evidenceShapeIsValid(evidence),
                "a recorded cycle must satisfy the verifier's own shape rule")

        // And the control on the rule itself: drop the record digest and it must refuse.
        let unbound = CaseEvidence(
            schema: evidence.schema, caseID: evidence.caseID, operationID: evidence.operationID,
            tool: evidence.tool, command: evidence.command, registrySpecFound: true,
            handlerBound: true, traceStarted: false, traceCompleted: false,
            healthReadStable: true, catalogReadStable: true, binarySHA256: evidence.binarySHA256,
            axis: evidence.axis, status: evidence.status, verified: evidence.verified,
            verificationKind: evidence.verificationKind, readback: evidence.readback,
            operationResponseSHA256: evidence.operationResponseSHA256,
            operationRequestID: evidence.operationRequestID,
            operationIsError: evidence.operationIsError,
            operationState: evidence.operationState, operationError: evidence.operationError,
            operationWriteAttempted: evidence.operationWriteAttempted,
            mutationRestoreRecordSHA256: nil
        )
        #expect(!QualificationRunner.evidenceShapeIsValid(unbound),
                "a cycle case that names no record is not evidence")
    }

    /// The control. Strip the record and the same probe must NOT read as a verified write cycle --
    /// otherwise the new kind would be "any mutating refusal", which is not evidence of anything.
    @Test func aRefusalWithoutARecordedCycleIsNotAWriteCycle() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .tracksRename })
        let result = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "no-cycle",
            responseData: Data(#"{"success":false,"state":"C","error":"invalid_params"}"#.utf8),
            isError: true,
            state: "C",
            error: "invalid_params",
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://tracks",
            readbackRequestID: "no-cycle-readback",
            // Every field the freshness gate actually asks for, because it asks for four and a
            // fixture that carries one defers for a reason that has nothing to do with the case.
            // `source: ax_live` (the token, not `live`); `cache_age_sec` present and within the
            // operation's own deadline -- absent age is refused outright, since an unmeasured age
            // cannot satisfy any bound; and a non-empty body, because an empty one needs
            // `verified_empty` to say the emptiness was observed rather than unread.
            // Rows under `data`, not `tracks`. The emptiness check reads `data`, so a body keyed
            // `tracks` passes it by having no `data` key at all rather than by carrying rows --
            // passing for a reason unrelated to the thing being tested.
            readbackData: Data(
                #"{"source":"ax_live","cache_age_sec":1,"data":[{"name":"after"}]}"#.utf8),
            failureReason: nil
        )
        #expect(result.status != .passed)
        #expect(result.verificationKind != .verifiedWriteCycle)
    }

    @Test func semanticMismatchCannotPassReadOperation() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let response = Data(#"{"logic_pro_running":true,"logic_pro_version":"11.2","logic_pro_bundle_id":"com.apple.logic10","logic_pro_variant":"desktop","logic_pro_ui_locale":"en-US","process_metadata_resolved":true,"logic_pro_variants":[{"variant":"desktop","bundle_id":"com.apple.logic10","installed":true,"running":true},{"variant":"creator_studio","bundle_id":"com.apple.logicpro","installed":false,"running":false}]}"#.utf8)
        let mismatchedReadback = Data(#"{"logic_pro_running":false,"logic_pro_version":"11.2","logic_pro_bundle_id":"com.apple.logic10","logic_pro_variant":"desktop","logic_pro_ui_locale":"en-US","process_metadata_resolved":true,"logic_pro_variants":[{"variant":"desktop","bundle_id":"com.apple.logic10","installed":true,"running":true},{"variant":"creator_studio","bundle_id":"com.apple.logicpro","installed":false,"running":false}]}"#.utf8)
        let result = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "semantic-response",
            responseData: response,
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "semantic-readback",
            readbackData: mismatchedReadback,
            failureReason: nil
        )

        #expect(result.status != .passed)
        #expect(!result.verified)
        let v1 = try #require(result.readback?.verified)
        #expect(!v1)
    }

    /// #373 Phase A retired the protocolSmoke bucket for read-only operations.
    /// Before, system.permissions had no validator, so ANY well-formed body was
    /// recorded protocolSmoke — "the transport worked, nobody checked". Now it
    /// has an oracle, and this body (invented JSON, not the prose the handler
    /// actually emits) is a semantic mismatch, not an unchecked smoke pass.
    @Test func readOperationWithAnOracleIsNoLongerProtocolSmoke() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemPermissions })
        let result = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "smoke-response",
            responseData: Data(#"{"state":"A","permissions":[]}"#.utf8),
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "smoke-readback",
            readbackData: Data(#"{"logic_pro_running":true}"#.utf8),
            failureReason: nil
        )

        #expect(result.status == .notQualified)
        #expect(result.status.rawValue != "protocol_smoke")
        #expect(!result.verified)
        #expect(result.deferral?.code == .semanticMismatch)
        let v1 = try #require(result.readback?.verified)
        #expect(!v1)
    }

    /// Every supported read-only operation has an oracle or health's bespoke validator.
    /// That structural census does not establish independence for a same-handler check.
    @Test func readOnlyOperationsHaveAnOracleOrBespokeValidator() {
        let unoracled = OperationRegistry.specs
            .filter { $0.mutability == .readOnly && $0.availability != .unsupported }
            .filter { spec in
                spec.id != .systemHealth && SemanticOracleTable.byOperationID[spec.id] == nil
            }
        #expect(unoracled.isEmpty)
    }

    @Test func readErrorIsNotLabeledSemanticMismatch() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemPermissions })
        let result = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "error-response",
            responseData: Data(#"{"state":"C","error":"unavailable","write_attempted":false}"#.utf8),
            isError: true,
            state: "C",
            error: "unavailable",
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "error-readback",
            readbackData: Data(#"{"logic_pro_running":true}"#.utf8),
            failureReason: nil
        )

        #expect(result.status == .notQualified)
        #expect(result.deferral?.code == .operationUnavailable)
    }

    @Test func matchingHealthSemanticReadbackPasses() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let health = Data(#"{"logic_pro_running":true,"logic_pro_version":"11.2","logic_pro_bundle_id":"com.apple.logic10","logic_pro_variant":"desktop","logic_pro_ui_locale":"en-US","process_metadata_resolved":true,"logic_pro_variants":[{"variant":"desktop","bundle_id":"com.apple.logic10","installed":true,"running":true},{"variant":"creator_studio","bundle_id":"com.apple.logicpro","installed":false,"running":false}]}"#.utf8)
        let result = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "semantic-response",
            responseData: health,
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "semantic-readback",
            readbackData: health,
            failureReason: nil
        )

        #expect(result.status == .passed)
        #expect(result.verified)
        #expect(result.verificationKind == .semanticReadback)
        let v1 = try #require(result.readback?.verified)
        #expect(v1)
    }

    @Test func operationFailurePreventsLiveAxisPromotion() async throws {
        let specs = Array(OperationRegistry.specs.prefix(2))
        let failedID = try #require(specs.last?.id)
        let driveResult = Self.driveResult(specs: specs, failedOperationID: failedID)
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let liveAxis = try #require(attestation.cases.first { $0.id == QualificationAxis.defaultAxis.key })
        #expect(liveAxis.status == .failed)
        #expect(liveAxis.reason == "one or more operation-specific protocol checks failed")

        let decision = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(decision.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(decision)).contains("requiredCaseFailed"))
    }

    /// A consent-gated mutating op whose no-write probe refuses `consent_required`
    /// is a typed zero-write deferral (notQualified), and its nested readback must
    /// NOT be marked verified — only a passed qualification claims verification
    /// (#413).
    @Test func zeroWriteMutatingDeferralDoesNotClaimNestedReadbackVerification() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemSetupArmKey })
        let result = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "consent-refusal",
            responseData: Data(#"{"state":"C","error":"consent_required","write_attempted":false}"#.utf8),
            isError: true,
            state: "C",
            error: "consent_required",
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "consent-readback",
            readbackData: Data(#"{"logic_pro_running":true}"#.utf8),
            failureReason: nil
        )

        #expect(result.status == .notQualified)
        #expect(result.verificationKind == .typedDeferral)
        let readback = try #require(result.readback)
        #expect(spec.mutability == .mutating)
        #expect(!readback.verified)
    }

    @Test func zeroQualifiedOperationsRejectsPromotion() async throws {
        let specs = OperationRegistry.specs
        let driveResult = Self.driveResult(specs: specs, qualifiedReadOperationCount: 0)
        #expect(driveResult.operationResults.values.filter { $0.status == .passed }.isEmpty)
        // DERIVED. It was `113`, and the day main added `system.setup_control_surface` this
        // read 114 -- a number that tracks the registry is not a fact worth writing down.
        #expect(driveResult.operationResults.values.filter { $0.status == .notQualified }.count
                    == specs.count)
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let liveAxis = try #require(attestation.cases.first {
            $0.id == QualificationAxis.defaultAxis.key
        })
        #expect(liveAxis.status == .failed)

        let decision = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(decision.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(decision)).contains(
            "requiredOperationNotSatisfied"
        ))
    }

    // The deferral count is DERIVED, not typed. It was written out twice — in the body and in the
    // test's own name — so adding an operation broke the assertion and, had only the number been
    // updated, would have left the name asserting something false. Registry size is already pinned
    // by `OperationRegistry.specs.count` elsewhere; repeating it here bought no coverage and cost a
    // second place to drift.
    @Test func legacyTransportSuccessesWithEveryOtherOperationDeferredRejectPromotion() async throws {
        let specs = OperationRegistry.specs
        let qualified = 13
        let driveResult = Self.driveResult(specs: specs, qualifiedReadOperationCount: qualified)
        #expect(driveResult.operationResults.values.filter { $0.isError == false }.count == qualified)
        #expect(
            driveResult.operationResults.values.filter { $0.isError == true }.count
                == driveResult.operationResults.count - qualified
        )
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let liveAxis = try #require(attestation.cases.first {
            $0.id == QualificationAxis.defaultAxis.key
        })
        #expect(liveAxis.status == .failed)

        let decision = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(decision.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(decision)).contains(
            "requiredOperationNotSatisfied"
        ))
    }

    @Test func individualGovernedOperationWaiverSatisfiesRequiredOperation() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.mutability == .mutating })
        let fixture = try Fixture(specs: [spec])
        defer { fixture.remove() }
        let waiver = Self.waiver(
            caseID: "in-process/\(spec.id.rawValue)",
            affectedCapability: "operation:\(spec.id.rawValue)"
        )
        try JSONEncoder().encode([waiver] + Self.axisWaivers())
            .write(to: fixture.waiversURL)

        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let operationCase = try #require(attestation.cases.first {
            $0.id == waiver.caseID
        })
        #expect(operationCase.status == .waived)
        #expect(!operationCase.verified)
        let liveAxis = try #require(attestation.cases.first {
            $0.id == QualificationAxis.defaultAxis.key
        })
        #expect(liveAxis.status == .passed)

        let decision = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(decision.exitCode == 0)
        let v1 = try #require(try Self.resultObject(decision)["promotable"] as? Bool)
        #expect(v1)
    }

    /// #373 Phase A inverted this test's premise, and the inversion is the
    /// point. This used to waive system.permissions because it could only reach
    /// protocolSmoke — a validator-shaped hole a waiver had to paper over. The
    /// op now qualifies on its own semantics, so waiving it is no longer
    /// governance, it is noise: the gate must reject a waiver for a passing
    /// case rather than let a stale waiver linger over a healthy operation.
    @Test func waiverForNowQualifyingReadOperationIsRejected() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemPermissions })
        let fixture = try Fixture(specs: [spec])
        defer { fixture.remove() }
        let waiver = Self.waiver(
            caseID: "in-process/\(spec.id.rawValue)",
            affectedCapability: "operation:\(spec.id.rawValue)"
        )
        try JSONEncoder().encode([waiver] + Self.axisWaivers())
            .write(to: fixture.waiversURL)

        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let operationCase = try #require(attestation.cases.first { $0.id == waiver.caseID })
        #expect(operationCase.status == .passed)
        #expect(operationCase.verified)
        #expect(operationCase.verificationKind == .semanticReadback)
        #expect(operationCase.deferral == nil)

        let decision = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(decision.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(decision)).contains(
            "waiverForPassingCase"
        ))
    }

    @Test func forgedCoherentBundleWithoutTrustedSignatureRejectsPromotion() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
        var object = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.attestationURL)
        ) as? [String: Any])
        let forgedCommit = String(repeating: "f", count: 40)
        object["commitSHA"] = forgedCommit
        if var provenance = object["provenance"] as? [String: Any] {
            provenance["commitSHA"] = forgedCommit
            object["provenance"] = provenance
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.attestationURL)

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains(
            "provenanceSignatureInvalid"
        ))
    }

    @Test func foreignSigningKeyCannotSatisfyPinnedVerifier() async throws {
        let foreignKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 9, count: 32)
        )
        let fixture = try promotableFixture(
            trustedPublicKeyData: foreignKey.publicKey.rawRepresentation
        )
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains(
            "provenanceSignatureInvalid"
        ))
    }

    /// Synthetic archived EN scopes, fake transport and existing fixture trust only. No candidate
    /// executable or Logic is launched. A prior baseline version is intentionally still diffable.
    @Test func trustedAtlasRejectsCoherentlyResignedRelabelledWindowRoots() async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        // Existing fixed synthetic key and in-process runner; no candidate process or real trust.
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        func verify() -> QualificationCommandResult {
            QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
                bundleURL: fixture.directory, releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        }
        let control = verify()
        #expect(control.exitCode == 0, "\(control.stdout)\(control.stderr)")
        let controlPromotable = try #require(try Self.resultObject(control)["promotable"] as? Bool)
        #expect(controlPromotable)
        let signedData = try Data(contentsOf: fixture.attestationURL)
        let signed = try JSONDecoder().decode(ReleaseQualificationAttestation.self, from: signedData)
        let atlas = try #require(signed.cases.first { $0.id == "atlas.drift_diff" })
        #expect(atlas.status == .passed)
        #expect(atlas.verified)
        let path = try #require(atlas.evidenceFiles.first)
        let evidenceURL = fixture.directory.appendingPathComponent(path)
        let evidenceData = try Data(contentsOf: evidenceURL)
        let manifestData = try Data(contentsOf: fixture.manifestURL)
        let caseManifestData = try Data(contentsOf: fixture.caseManifestURL)
        let candidateData = try Data(contentsOf: fixture.executableURL)
        let original = try JSONDecoder().decode(CaseEvidence.self, from: evidenceData)
        let comparison = try #require(original.atlasComparison)
        #expect(comparison.pairs.count == 2)
        #expect(comparison.pairs.allSatisfy { $0.baseline.root.role == "AXGroup" && $0.current.root.role == "AXGroup" })
        func windowObject(_ roots: [AXSnapshot.Node]) throws -> [String: Any] {
            let root = AXSnapshot.Node(role: "AXWindow", subrole: nil, description: nil,
                help: nil, identifier: nil, valueRange: nil, children: roots)
            return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(root)) as? [String: Any])
        }
        let baselineWindow = try windowObject(comparison.pairs.map { $0.baseline.root })
        let currentWindow = try windowObject(comparison.pairs.map { $0.current.root })
        try Self.mutateJSONObject(at: evidenceURL) { object in
            var packet = try #require(object["atlas_comparison"] as? [String: Any])
            var pairs = try #require(packet["pairs"] as? [[String: Any]])
            for index in pairs.indices {
                var baseline = try #require(pairs[index]["baseline"] as? [String: Any])
                var current = try #require(pairs[index]["current"] as? [String: Any])
                baseline["root"] = baselineWindow
                current["root"] = currentWindow
                pairs[index]["baseline"] = baseline
                pairs[index]["current"] = current
            }
            packet["pairs"] = pairs
            object["atlas_comparison"] = packet
        }
        let changedData = try Data(contentsOf: evidenceURL)
        let changed = try JSONDecoder().decode(CaseEvidence.self, from: changedData)
        let changedComparison = try #require(changed.atlasComparison)
        #expect(changedComparison.pairs.map(\.scope) == comparison.pairs.map(\.scope))
        #expect(changedComparison.pairs.map { $0.current.logicVersion } == comparison.pairs.map { $0.current.logicVersion })
        #expect(changedComparison.pairs.allSatisfy { $0.baseline.root.role == "AXWindow" && $0.current.root.role == "AXWindow" })
        #expect(QualificationRunner.evidence(changed, binds: atlas))
        #expect(!QualificationRunner.evidenceShapeIsValid(changed))
        // Bind the changed evidence and manifest into the ORIGINAL passing cases/provenance.
        // Signature/digest/axis failures cannot substitute for selected-root rejection.
        try Self.mutateJSONObject(at: fixture.manifestURL) { manifest in
            var entries = try #require(manifest["files"] as? [[String: Any]])
            let indices = entries.indices.filter { entries[$0]["path"] as? String == path }
            try #require(indices.count == 1)
            entries[indices[0]]["sha256"] = SupportBundleBuilder.sha256(changedData)
            manifest["files"] = entries
        }
        let manifestSHA = SupportBundleBuilder.sha256(try Data(contentsOf: fixture.manifestURL))
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            object["evidenceManifestSHA256"] = manifestSHA
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["evidenceManifestSHA256"] = manifestSHA
            object["provenance"] = provenance
        }
        try fixture.forceSignForDiagnosticFixture()
        let resealed = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        #expect(resealed.cases == signed.cases)
        #expect(resealed.evidenceManifestSHA256 == manifestSHA)
        #expect(try Data(contentsOf: fixture.caseManifestURL) == caseManifestData)
        #expect(try Data(contentsOf: fixture.executableURL) == candidateData)
        let signature = try #require(resealed.provenanceSignature)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: fixture.trustedPublicKeyData)
        #expect(publicKey.isValidSignature(try #require(Data(base64Encoded: signature.value)),
            for: try encoder.encode(try #require(resealed.provenance))))
        let refused = verify()
        #expect(refused.exitCode == 1, "\(refused.stdout)")
        let object = try Self.resultObject(refused)
        let promotable = try #require(object["promotable"] as? Bool)
        #expect(!promotable)
        let rejections = try #require(object["rejections"] as? [[String: Any]])
        #expect(rejections.count == 1, "\(refused.stdout)")
        #expect(rejections.contains { $0["reason"] as? String == "evidenceBindingMismatch"
            && $0["actual"] as? String == "case evidence binding" }, "\(refused.stdout)")
        #expect(!rejections.contains { $0["reason"] as? String == "provenanceSignatureInvalid" })
        try evidenceData.write(to: evidenceURL, options: .atomic)
        try manifestData.write(to: fixture.manifestURL, options: .atomic)
        try signedData.write(to: fixture.attestationURL, options: .atomic)
        let restored = verify()
        #expect(restored.exitCode == 0, "\(restored.stdout)")
        let restoredPromotable = try #require(try Self.resultObject(restored)["promotable"] as? Bool)
        #expect(restoredPromotable)
    }

    @Test func desktopDriveCannotPassWithActualCreatorAtlasCapture() async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let specs = OperationRegistry.specs
        let drive = Self.driveResult(specs: specs, mutationRestoreRecords: [Self.recipeShapedRecord()])
        #expect(drive.observedVariant == "desktop")
        let fixture = try Fixture(specs: specs, drive: { _ in drive })
        defer { fixture.remove() }
        let operationWaivers = specs.compactMap { spec in
            drive.operationResults[spec.id.rawValue]?.status == .passed ? nil :
                Self.waiver(caseID: "in-process/\(spec.id.rawValue)",
                    affectedCapability: "operation:\(spec.id.rawValue)")
        }
        try JSONEncoder().encode(operationWaivers + Self.axisWaivers()).write(to: fixture.waiversURL)
        let baselines = fixture.directory.appendingPathComponent("selected-baselines", isDirectory: true)
        try FileManager.default.createDirectory(at: baselines, withIntermediateDirectories: false)
        let documents = try Self.atlasProducerVersionPairs(drive.logicProVersion).map(\.baseline)
        let b = FakeAXRuntimeBuilder()
        let app = b.element(30_000)
        let window = b.element(30_001)
        let menu = b.element(30_002)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(app, kAXWindowsAttribute as String, [window] as NSArray)
        b.setAttribute(app, kAXMenuBarAttribute as String, menu)
        b.setAttribute(menu, kAXRoleAttribute as String, kAXMenuBarRole as String)
        var nextID = 30_010
        // Materialize archived sanitized shapes as synthetic controls, not native observations.
        func materialize(_ node: AXSnapshot.Node) -> AXUIElement {
            nextID += 1
            let element = b.element(nextID)
            b.setAttribute(element, kAXRoleAttribute as String, node.role)
            if let value = node.subrole { b.setAttribute(element, kAXSubroleAttribute as String, value) }
            if let value = node.description { b.setAttribute(element, kAXDescriptionAttribute as String, value) }
            if let value = node.help { b.setAttribute(element, kAXHelpAttribute as String, value) }
            if let value = node.valueRange {
                let bounds = value.components(separatedBy: "...").compactMap(Double.init)
                if bounds.count == 2 {
                    b.setAttribute(element, kAXMinValueAttribute as String, bounds[0])
                    b.setAttribute(element, kAXMaxValueAttribute as String, bounds[1])
                }
            }
            b.setChildren(element, node.children.map(materialize))
            return element
        }
        let roots = documents.map { document -> AXUIElement in
            let root = materialize(document.root)
            b.setAttribute(root, kAXDescriptionAttribute as String, document.scope)
            return root
        }
        b.setChildren(window, roots)
        b.setChildren(menu, ["File", "Edit", "Track"].map { title in
            nextID += 1
            let item = b.element(nextID)
            b.setAttribute(item, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
            b.setAttribute(item, kAXTitleAttribute as String, title)
            return item
        })
        let ax = b.makeAXRuntime(appElement: app, setAttributeHandler: nil,
            performActionHandler: nil, executeAppleScript: { _ in
                Issue.record("Atlas capture must not execute AppleScript")
                return .error("unexpected AppleScript")
            })
        // Both comparison halves are read from the fake controls, so re-redaction cannot
        // manufacture drift. The normal Desktop capture below must prove the full positive.
        for (index, document) in documents.enumerated() {
            let captured = AXSnapshot.capture(roots[index], runtime: ax)
            let root = AXLocalePolicy.controlBarGroupLabel.matches(document.scope, mode: .exactStrict)
                ? AXSnapshot.scopedRoot(captured, readBackDescription: document.scope) : captured
            let baseline = AXSnapshot.Document(logicVersion: drive.logicProVersion,
                locale: "en-US", scope: document.scope, capturedFrom: "ax", root: root)
            try JSONEncoder().encode(baseline).write(to: baselines.appendingPathComponent("scope-\(index).json"))
        }
        #expect(LogicProVariant.from(bundleID: "com.apple.mobilelogic") == .creatorStudio)
        for bundleID in ["com.apple.logic10", "com.apple.mobilelogic", "com.apple.logic10"] {
            let driveCalls = RequiredAtlasCaptureCounter()
            let captures = RequiredAtlasCaptureCounter()
            // All runtime closures and the AX transport are injected; no real executable,
            // application discovery, global Control Bar, permissions or GUI writes run.
            let runner = QualificationRunner(runtime: .init(
                executableURL: { fixture.executableURL }, environment: { ["GIT_COMMIT": fixture.commitSHA] },
                now: { Date(timeIntervalSince1970: 1_000) }, serverVersion: { "1.2.3" }, specs: { specs },
                registryValidationErrors: { [] }, handlerValidationErrors: { [] },
                handlerExists: { OperationHandlerRegistry.handler(tool: $0, command: $1) != nil },
                beforeEvidenceRead: { _ in }, drive: { _ in driveCalls.record(); return drive },
                atlasPairs: {
                    #expect(driveCalls.count == 1)
                    captures.record()
                    return AtlasCapture.pairs(baselinesIn: baselines, window: window, runtime: ax,
                        runningTarget: { .init(pid: 4242, bundleID: bundleID, logicVersion: drive.logicProVersion) })
                }))
            let run = await runner.run(arguments: ["LogicProMCP", "--qualify",
                "--out", fixture.attestationURL.path, "--release-version", "1.2.3",
                "--variant", "desktop", "--locale", "en", "--mutate-open-project",
                "--require-atlas", "--waivers", fixture.waiversURL.path])
            #expect(driveCalls.count == 1)
            #expect(captures.count == 1)
            let attestation = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
                from: Data(contentsOf: fixture.attestationURL))
            #expect(attestation.logicVariant == .desktop)
            #expect(attestation.logicVersion == drive.logicProVersion)
            let atlas = try #require(attestation.cases.first { $0.id == "atlas.drift_diff" })
            let evidence = try JSONDecoder().decode(CaseEvidence.self,
                from: Data(contentsOf: fixture.directory.appendingPathComponent(try #require(atlas.evidenceFiles.first))))
            let comparison = try #require(evidence.atlasComparison)
            if bundleID == "com.apple.mobilelogic" {
                #expect(run.exitCode == 1, "Creator capture must refuse: \(run.stdout)\(run.stderr)")
                #expect(atlas.status == .failed)
                #expect(!atlas.verified)
                #expect(comparison.pairs.isEmpty)
                #expect(comparison.dropped == ["scope-0.json", "scope-1.json"])
            } else {
                #expect(run.exitCode == 0, "\(run.stdout)\(run.stderr)")
                #expect(atlas.status == .passed)
                #expect(atlas.verified)
                #expect(comparison.pairs.count == 2)
                #expect(comparison.dropped.isEmpty)
            }
            #expect(b.setCalls.isEmpty)
            #expect(b.actionCalls.isEmpty)
        }
    }

    @Test func atlasCurrentVersionMustMatchTheIndependentSignedHostVersion() async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let fixture = try trustedFixture()
        defer { fixture.remove() }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        let documents = try ["logic-12.x-desktop-en-track-headers.json",
                             "logic-12.x-desktop-en-control-bar.json"].map {
            try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent($0)))
        }
        #expect(Set(documents.map(\.scope)) == Set(["Tracks header", "Control Bar"]))
        #expect(documents.allSatisfy { $0.logicVersion == "12.x" && $0.locale == "en" && $0.capturedFrom == "ax" })
        let pairs = documents.map { baseline in
            AtlasQualification.Pair(scope: baseline.scope, baseline: baseline,
                current: AXSnapshot.Document(logicVersion: "11.2", locale: "en-US",
                    scope: baseline.scope, capturedFrom: "ax", root: baseline.root))
        }
        let atlas = try #require(AtlasQualification.evidenceCaseFor(armed: true, pairs: pairs,
            axis: .defaultAxis, binarySHA256: fixture.binarySHA256,
            traceID: "controlled-atlas-current-version"))
        #expect(atlas.qualificationCase.status == .passed)
        #expect(atlas.qualificationCase.verified)
        #expect(QualificationRunner.evidence(atlas.evidence, binds: atlas.qualificationCase))
        #expect(QualificationRunner.evidenceShapeIsValid(atlas.evidence))
        let evidencePath = try #require(atlas.qualificationCase.evidenceFiles.first)
        let evidenceURL = fixture.directory.appendingPathComponent(evidencePath)
        try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(atlas.evidence).write(to: evidenceURL)
        try JSONEncoder().encode(QualificationCaseManifest(schema: "qualification-case-manifest/v1",
            binarySHA256: fixture.binarySHA256, cases: [atlas.qualificationCase]))
            .write(to: fixture.externalCasesURL)
        let qualification = await fixture.runner.run(arguments: ["LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path, "--release-version", "1.2.3",
            "--mutate-open-project", "--cases", fixture.externalCasesURL.path,
            "--waivers", fixture.waiversURL.path])
        // Expectations, not requires: a failing positive must not suppress the counterexample.
        #expect(qualification.exitCode == 0, "\(qualification.stdout)\(qualification.stderr)")
        let unsigned = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        #expect(unsigned.logicVersion == "11.2")
        #expect(unsigned.provenance?.schema == "qualification-provenance/v3")
        #expect(unsigned.provenance?.logicVersion == "11.2")
        #expect(unsigned.cases.filter { $0.id == "atlas.drift_diff" } == [atlas.qualificationCase])
        let signing = QualificationRunner.signTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, signingPrivateKeyData: fixture.signingKeyData)
        #expect(signing.exitCode == 0, "\(signing.stdout)\(signing.stderr)")
        let control = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        #expect(control.exitCode == 0, "\(control.stdout)\(control.stderr)")
        let controlPromotable = try #require(try Self.resultObject(control)["promotable"] as? Bool)
        #expect(controlPromotable)
        let originalEvidenceData = try Data(contentsOf: evidenceURL)
        let originalManifestData = try Data(contentsOf: fixture.manifestURL)
        let originalAttestationData = try Data(contentsOf: fixture.attestationURL)
        let originalCaseManifestData = try Data(contentsOf: fixture.caseManifestURL)
        let originalCandidateData = try Data(contentsOf: fixture.executableURL)
        let signed = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: originalAttestationData)
        #expect(signed.provenanceSignature != nil)
        let originalEvidence = try JSONDecoder().decode(CaseEvidence.self, from: originalEvidenceData)
        var expectedEvidence = try #require(JSONSerialization.jsonObject(with: originalEvidenceData) as? [String: Any])
        var comparison = try #require(expectedEvidence["atlas_comparison"] as? [String: Any])
        var changedPairs = try #require(comparison["pairs"] as? [[String: Any]])
        try #require(changedPairs.count == 2)
        var changedCurrent = try #require(changedPairs[0]["current"] as? [String: Any])
        #expect(changedCurrent["logicVersion"] as? String == "11.2")
        changedCurrent["logicVersion"] = "11.3"
        changedPairs[0]["current"] = changedCurrent
        comparison["pairs"] = changedPairs
        expectedEvidence["atlas_comparison"] = comparison
        try Self.mutateJSONObject(at: evidenceURL) { $0 = expectedEvidence }
        let changedEvidenceData = try Data(contentsOf: evidenceURL)
        #expect(try JSONSerialization.data(withJSONObject:
            JSONSerialization.jsonObject(with: changedEvidenceData), options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject: expectedEvidence, options: [.sortedKeys]))
        let changedEvidence = try JSONDecoder().decode(CaseEvidence.self, from: changedEvidenceData)
        let originalComparison = try #require(originalEvidence.atlasComparison)
        let changedComparison = try #require(changedEvidence.atlasComparison)
        #expect(changedComparison.pairs.map(\.baseline) == originalComparison.pairs.map(\.baseline))
        #expect(changedComparison.pairs.map(\.scope) == originalComparison.pairs.map(\.scope))
        #expect(changedComparison.pairs.map { $0.current.root } == originalComparison.pairs.map { $0.current.root })
        #expect(changedComparison.pairs.map { $0.current.logicVersion } == ["11.3", "11.2"])
        // The diff and its local candidate/axis binding remain valid. Only the independent host
        // version binding must reject this otherwise coherent passing comparison.
        #expect(QualificationRunner.evidence(changedEvidence, binds: atlas.qualificationCase))
        #expect(QualificationRunner.evidenceShapeIsValid(changedEvidence))
        try Self.mutateJSONObject(at: fixture.manifestURL) { manifest in
            var entries = try #require(manifest["files"] as? [[String: Any]])
            let matching = entries.indices.filter { entries[$0]["path"] as? String == evidencePath }
            try #require(matching.count == 1)
            entries[matching[0]]["sha256"] = SupportBundleBuilder.sha256(changedEvidenceData)
            manifest["files"] = entries
        }
        let changedManifestSHA = SupportBundleBuilder.sha256(try Data(contentsOf: fixture.manifestURL))
        try Self.mutateJSONObject(at: fixture.attestationURL) { attestation in
            attestation["evidenceManifestSHA256"] = changedManifestSHA
            var provenance = try #require(attestation["provenance"] as? [String: Any])
            provenance["evidenceManifestSHA256"] = changedManifestSHA
            attestation["provenance"] = provenance
        }
        try fixture.forceSignForDiagnosticFixture()
        let resealed = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        #expect(resealed.logicVersion == "11.2")
        #expect(resealed.provenance?.schema == "qualification-provenance/v3")
        #expect(resealed.provenance?.logicVersion == "11.2")
        #expect(resealed.evidenceManifestSHA256 == changedManifestSHA)
        #expect(resealed.provenance?.evidenceManifestSHA256 == changedManifestSHA)
        #expect(resealed.cases == signed.cases)
        #expect(try Data(contentsOf: fixture.caseManifestURL) == originalCaseManifestData)
        #expect(try Data(contentsOf: fixture.executableURL) == originalCandidateData)
        let refused = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        #expect(refused.exitCode == 1, "\(refused.stdout)\(refused.stderr)")
        let refusal = try Self.resultObject(refused)
        let refusedPromotable = try #require(refusal["promotable"] as? Bool)
        #expect(!refusedPromotable)
        let rejections = try #require(refusal["rejections"] as? [[String: Any]])
        #expect(rejections.count == 1, "\(refused.stdout)")
        #expect(rejections.first?["reason"] as? String == "evidenceBindingMismatch", "\(refused.stdout)")
        #expect(rejections.first?["actual"] as? String == "atlas current Logic version binding", "\(refused.stdout)")
        #expect(!rejections.contains { $0["reason"] as? String == "provenanceSignatureInvalid" })
        try originalEvidenceData.write(to: evidenceURL, options: .atomic)
        try originalManifestData.write(to: fixture.manifestURL, options: .atomic)
        try originalAttestationData.write(to: fixture.attestationURL, options: .atomic)
        let restored = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        #expect(restored.exitCode == 0, "\(restored.stdout)\(restored.stderr)")
        let restoredPromotable = try #require(try Self.resultObject(restored)["promotable"] as? Bool)
        #expect(restoredPromotable)
        #expect(try Data(contentsOf: evidenceURL) == originalEvidenceData)
        #expect(try Data(contentsOf: fixture.manifestURL) == originalManifestData)
        #expect(try Data(contentsOf: fixture.attestationURL) == originalAttestationData)
    }

    /// AFTER-only producer controls. Archived roots and fake drive metadata, never live capture.
    private static func atlasProducerVersionPairs(
        _ version: String,
        locale: QualificationLocale = .enUS
    ) throws -> [AtlasQualification.Pair] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        let language = locale == .koKR ? "ko" : "en"
        return try ["logic-12.x-desktop-\(language)-track-headers.json",
                    "logic-12.x-desktop-\(language)-control-bar.json"].map { name in
            let baseline = try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent(name)))
            #expect(baseline.logicVersion == "12.x")
            return AtlasQualification.Pair(scope: baseline.scope, baseline: baseline,
                current: AXSnapshot.Document(logicVersion: version, locale: locale.rawValue,
                    scope: baseline.scope, capturedFrom: "ax", root: baseline.root))
        }
    }

    private static func assertAtlasProducerVersionResult(
        _ result: QualificationCommandResult, fixture: Fixture, version: String
    ) throws {
        if version == "11.2" {
            #expect(result.exitCode == 0, "\(result.stdout)\(result.stderr)")
            #expect(result.stderr.isEmpty)
            let attestation = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
                from: Data(contentsOf: fixture.attestationURL))
            #expect(attestation.logicVersion == "11.2")
            #expect(attestation.provenance?.logicVersion == "11.2")
            let atlas = try #require(attestation.cases.first { $0.id == "atlas.drift_diff" })
            #expect(atlas.status == .passed)
            #expect(atlas.verified)
            let evidencePath = try #require(atlas.evidenceFiles.first)
            let evidence = try JSONDecoder().decode(CaseEvidence.self,
                from: Data(contentsOf: fixture.directory.appendingPathComponent(evidencePath)))
            let comparison = try #require(evidence.atlasComparison)
            #expect(comparison.pairs.count == 2)
            #expect(comparison.pairs.allSatisfy {
                $0.baseline.logicVersion == "12.x" && $0.current.logicVersion == "11.2"
            })
        } else {
            #expect(result.exitCode == 1)
            #expect(result.stderr ==
                "Qualification failed: External evidence binding mismatch: atlas current Logic version binding\n")
            #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
        }
    }

    @Test(arguments: ["11.2", "11.3"])
    func externalAtlasCurrentVersionBindsToFakeDriveHostVersion(version: String) async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        #expect(!FeatureFlags.adr007SelectorAtlas)
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let fixture = try Fixture(specs: [spec])
        defer { fixture.remove() }
        let pairs = try Self.atlasProducerVersionPairs(version)
        let atlas = try #require(AtlasQualification.evidenceCaseFor(armed: true, pairs: pairs,
            axis: .defaultAxis, binarySHA256: fixture.binarySHA256,
            traceID: "after-only-external-version"))
        // The local diff is valid even with the mismatched version; the independent host binds it.
        #expect(atlas.qualificationCase.status == .passed)
        #expect(QualificationRunner.evidenceShapeIsValid(atlas.evidence))
        let path = try #require(atlas.qualificationCase.evidenceFiles.first)
        let evidenceURL = fixture.directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(atlas.evidence).write(to: evidenceURL)
        try JSONEncoder().encode(QualificationCaseManifest(schema: "qualification-case-manifest/v1",
            binarySHA256: fixture.binarySHA256, cases: [atlas.qualificationCase]))
            .write(to: fixture.externalCasesURL)
        let result = await fixture.runner.run(arguments: ["LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path, "--release-version", "1.2.3",
            "--cases", fixture.externalCasesURL.path])
        try Self.assertAtlasProducerVersionResult(result, fixture: fixture, version: version)
    }

    @Test(arguments: ["11.2", "11.3"])
    func armedAtlasCurrentVersionBindsToInjectedFakeDriveHostVersion(version: String) async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        setenv(flag, "1", 1)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        #expect(FeatureFlags.adr007SelectorAtlas)
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let fixture = try Fixture(specs: specs)
        defer { fixture.remove() }
        let drive = Self.driveResult(specs: specs)
        let pairs = try Self.atlasProducerVersionPairs(version)
        // Spell every runtime closure: neither the transport nor AtlasCapture production path runs.
        let runner = QualificationRunner(runtime: .init(
            executableURL: { fixture.executableURL },
            environment: { ["GIT_COMMIT": fixture.commitSHA] },
            now: { Date(timeIntervalSince1970: 1_000) },
            serverVersion: { "1.2.3" }, specs: { specs },
            registryValidationErrors: { [] }, handlerValidationErrors: { [] },
            handlerExists: { OperationHandlerRegistry.handler(tool: $0, command: $1) != nil },
            beforeEvidenceRead: { _ in }, drive: { _ in drive },
            atlasPairs: { (pairs: pairs, dropped: []) }
        ))
        let result = await runner.run(arguments: ["LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path, "--release-version", "1.2.3"])
        try Self.assertAtlasProducerVersionResult(result, fixture: fixture, version: version)
    }

    @Test func requiredTrustedAtlasCannotDisappearWhenTheOptionalFlagIsOff() async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let specs = OperationRegistry.specs
        let drive = Self.driveResult(specs: specs,
            mutationRestoreRecords: [Self.recipeShapedRecord()])
        let fixture = try Fixture(specs: specs, drive: { _ in drive })
        defer { fixture.remove() }
        let operationWaivers = specs.compactMap { spec in
            drive.operationResults[spec.id.rawValue]?.status == .passed ? nil :
                Self.waiver(caseID: "in-process/\(spec.id.rawValue)",
                    affectedCapability: "operation:\(spec.id.rawValue)")
        }
        try JSONEncoder().encode(operationWaivers + Self.axisWaivers()).write(to: fixture.waiversURL)
        let run = await fixture.runQualification(waiversURL: fixture.waiversURL)
        #expect(run.exitCode == 0, "\(run.stdout)\(run.stderr)")
        let unsigned = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        #expect(!unsigned.cases.contains { $0.id == "atlas.drift_diff" })
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("evidence/atlas-drift-diff.json").path))
        let signing = QualificationRunner.signTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, signingPrivateKeyData: fixture.signingKeyData)
        #expect(signing.exitCode == 1, "\(signing.stdout)")
        let signingRejections = try #require(try Self.resultObject(signing)["rejections"] as? [[String: Any]])
        #expect(signingRejections.contains {
            $0["reason"] as? String == "missingArtifact"
                && $0["name"] as? String == "evidence/atlas-drift-diff.json"
        })
        // Existing fixture signing deliberately constructs a coherent diagnostic packet even
        // when the production signer refuses it; signature failure cannot mask this witness.
        try fixture.forceSignForDiagnosticFixture()
        let diagnostic = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(diagnostic.exitCode == 0, "\(diagnostic.stdout)")
        let refused = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        #expect(refused.exitCode == 1, "\(refused.stdout)")
        let rejections = try #require(try Self.resultObject(refused)["rejections"] as? [[String: Any]])
        #expect(rejections.contains {
            $0["reason"] as? String == "missingArtifact"
                && $0["name"] as? String == "evidence/atlas-drift-diff.json"
        })
        #expect(!rejections.contains { $0["reason"] as? String == "provenanceSignatureInvalid" })
    }

    @Test func aNonAtlasCaseCannotSatisfyTheRequiredAtlasArtifactPath() async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let specs = OperationRegistry.specs
        let drive = Self.driveResult(specs: specs,
            mutationRestoreRecords: [Self.recipeShapedRecord()])
        let fixture = try Fixture(specs: specs, drive: { _ in drive })
        defer { fixture.remove() }
        let operationWaivers = specs.compactMap { spec in
            drive.operationResults[spec.id.rawValue]?.status == .passed ? nil :
                Self.waiver(caseID: "in-process/\(spec.id.rawValue)",
                    affectedCapability: "operation:\(spec.id.rawValue)")
        }
        try JSONEncoder().encode(operationWaivers + Self.axisWaivers()).write(to: fixture.waiversURL)
        let path = "evidence/atlas-drift-diff.json"
        let external = QualificationCase(id: "external/not-atlas", status: .failed,
            tool: "external", command: "observe", traceID: "non-atlas-path-control", verified: false,
            evidenceFiles: [path], reason: "controlled external refusal",
            binarySHA256: fixture.binarySHA256, axis: .defaultAxis,
            operationID: "qualification.external-control", verificationKind: .typedDeferral)
        let evidence = CaseEvidence(schema: "qualification-case-evidence/v3",
            caseID: external.id, operationID: external.operationID, tool: external.tool,
            command: external.command, registrySpecFound: false, handlerBound: false,
            traceStarted: false, traceCompleted: false, failureReason: external.reason,
            binarySHA256: fixture.binarySHA256, axis: .defaultAxis,
            status: .failed, verified: false, verificationKind: .typedDeferral)
        #expect(QualificationRunner.evidence(evidence, binds: external))
        #expect(QualificationRunner.evidenceShapeIsValid(evidence))
        let evidenceURL = fixture.directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(evidence).write(to: evidenceURL)
        try JSONEncoder().encode(QualificationCaseManifest(schema: "qualification-case-manifest/v1",
            binarySHA256: fixture.binarySHA256, cases: [external])).write(to: fixture.externalCasesURL)
        let run = await fixture.runner.run(arguments: ["LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path, "--release-version", "1.2.3",
            "--mutate-open-project", "--cases", fixture.externalCasesURL.path,
            "--waivers", fixture.waiversURL.path])
        #expect(run.exitCode == 1, "the optional external case failed: \(run.stdout)\(run.stderr)")
        try fixture.forceSignForDiagnosticFixture()
        let diagnostic = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(diagnostic.exitCode == 0, "\(diagnostic.stdout)")
        let refused = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        #expect(refused.exitCode == 1, "\(refused.stdout)")
        let rejections = try #require(try Self.resultObject(refused)["rejections"] as? [[String: Any]])
        #expect(rejections.contains {
            $0["reason"] as? String == "evidenceBindingMismatch"
                && $0["actual"] as? String == "required atlas case binding"
        })
        #expect(!rejections.contains { $0["reason"] as? String == "provenanceSignatureInvalid" })
    }

    @Test(arguments: [QualificationLocale.enUS, .koKR])
    func trustedRequiredAtlasAcceptsBothDeclaredSelectedScopeControls(locale: QualificationLocale) async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let specs = OperationRegistry.specs
        let drive = Self.driveResult(specs: specs, observedLocale: locale.rawValue,
            mutationRestoreRecords: [Self.recipeShapedRecord()])
        let fixture = try Fixture(specs: specs, drive: { _ in drive })
        defer { fixture.remove() }
        let axis = QualificationAxis(variant: .desktop, locale: locale,
            profile: .core, cache: .cold, fixture: .empty)
        let operationWaivers = specs.compactMap { spec in
            drive.operationResults[spec.id.rawValue]?.status == .passed ? nil :
                Self.waiver(caseID: "in-process/\(spec.id.rawValue)",
                    affectedCapability: "operation:\(spec.id.rawValue)")
        }
        try JSONEncoder().encode(operationWaivers + Self.axisWaivers(observedAxis: axis))
            .write(to: fixture.waiversURL)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        let language = locale == .koKR ? "ko" : "en"
        let documents = try ["track-headers", "control-bar"].map {
            try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent(
                    "logic-12.x-desktop-\(language)-\($0).json")))
        }
        #expect(documents.allSatisfy { $0.logicVersion == "12.x" && $0.locale == language && $0.capturedFrom == "ax" })
        let pairs = documents.map { baseline in AtlasQualification.Pair(scope: baseline.scope,
            baseline: baseline, current: AXSnapshot.Document(logicVersion: "11.2",
                locale: locale.rawValue, scope: baseline.scope, capturedFrom: "ax", root: baseline.root)) }
        let atlas = try #require(AtlasQualification.evidenceCaseFor(armed: true, pairs: pairs,
            axis: axis, binarySHA256: fixture.binarySHA256, traceID: "required-atlas-control"))
        #expect(atlas.qualificationCase.status == .passed)
        #expect(atlas.qualificationCase.verified)
        let evidencePath = try #require(atlas.qualificationCase.evidenceFiles.first)
        let evidenceURL = fixture.directory.appendingPathComponent(evidencePath)
        try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(atlas.evidence).write(to: evidenceURL)
        try JSONEncoder().encode(QualificationCaseManifest(schema: "qualification-case-manifest/v1",
            binarySHA256: fixture.binarySHA256, cases: [atlas.qualificationCase]))
            .write(to: fixture.externalCasesURL)
        let run = await fixture.runner.run(arguments: ["LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path, "--release-version", "1.2.3",
            "--locale", language, "--mutate-open-project", "--cases", fixture.externalCasesURL.path,
            "--waivers", fixture.waiversURL.path])
        #expect(run.exitCode == 0, "\(run.stdout)\(run.stderr)")
        let unsigned = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        #expect(unsigned.locale == locale)
        #expect(unsigned.logicVersion == "11.2")
        #expect(unsigned.cases.filter { $0.id == "atlas.drift_diff" } == [atlas.qualificationCase])
        let signing = QualificationRunner.signTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, signingPrivateKeyData: fixture.signingKeyData)
        #expect(signing.exitCode == 0, "\(signing.stdout)")
        let accepted = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        #expect(accepted.exitCode == 0, "\(accepted.stdout)")
        let promotable = try #require(try Self.resultObject(accepted)["promotable"] as? Bool)
        #expect(promotable)
    }

    /// AFTER-only arming controls: all capture and transport observations below are injected.
    private enum RequiredAtlasCaptureShape: String, Sendable {
        case complete, absent, partial, dropped
    }

    private final class RequiredAtlasCaptureCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func record() { lock.withLock { calls += 1 } }
        var count: Int { lock.withLock { calls } }
    }

    private func assertRequiredAtlasProducer(
        locale: QualificationLocale, shape: RequiredAtlasCaptureShape, viaEntrypoint: Bool = false
    ) async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        #expect(!FeatureFlags.adr007SelectorAtlas)
        let specs = OperationRegistry.specs
        let drive = Self.driveResult(specs: specs, observedLocale: locale.rawValue,
            mutationRestoreRecords: [Self.recipeShapedRecord()])
        let fixture = try Fixture(specs: specs, drive: { _ in drive })
        defer { fixture.remove() }
        let axis = QualificationAxis(variant: .desktop, locale: locale,
            profile: .core, cache: .cold, fixture: .empty)
        let operationWaivers = specs.compactMap { spec in
            drive.operationResults[spec.id.rawValue]?.status == .passed ? nil :
                Self.waiver(caseID: "in-process/\(spec.id.rawValue)",
                    affectedCapability: "operation:\(spec.id.rawValue)")
        }
        try JSONEncoder().encode(operationWaivers + Self.axisWaivers(observedAxis: axis))
            .write(to: fixture.waiversURL)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/AX")
        let language = locale == .koKR ? "ko" : "en"
        let documents = try ["track-headers", "control-bar"].map {
            try JSONDecoder().decode(AXSnapshot.Document.self,
                from: Data(contentsOf: directory.appendingPathComponent(
                    "logic-12.x-desktop-\(language)-\($0).json")))
        }
        let complete = documents.map { baseline in AtlasQualification.Pair(
            scope: baseline.scope, baseline: baseline,
            current: AXSnapshot.Document(logicVersion: drive.logicProVersion,
                locale: locale.rawValue, scope: baseline.scope, capturedFrom: "ax", root: baseline.root)) }
        let pairs: [AtlasQualification.Pair]
        switch shape {
        case .complete, .dropped: pairs = complete
        case .absent: pairs = []
        case .partial: pairs = Array(complete.prefix(1))
        }
        let dropped = shape == .dropped ? ["controlled unread selected baseline"] : []
        let capture = RequiredAtlasCaptureCounter()
        // Spell every closure: neither the production transport nor production AtlasCapture runs.
        let runner = QualificationRunner(runtime: .init(
            executableURL: { fixture.executableURL },
            environment: { ["GIT_COMMIT": fixture.commitSHA] },
            now: { Date(timeIntervalSince1970: 1_000) },
            serverVersion: { "1.2.3" }, specs: { specs },
            registryValidationErrors: { [] }, handlerValidationErrors: { [] },
            handlerExists: { OperationHandlerRegistry.handler(tool: $0, command: $1) != nil },
            beforeEvidenceRead: { _ in }, drive: { _ in drive },
            atlasPairs: {
                capture.record()
                return (pairs: pairs, dropped: dropped)
            }
        ))
        let arguments = ["LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path, "--release-version", "1.2.3",
            "--locale", language, "--mutate-open-project", "--require-atlas",
            "--waivers", fixture.waiversURL.path]
        let run: QualificationCommandResult
        if viaEntrypoint {
            var permissionCalls = 0
            var serverCalls = 0
            var approvalCalls = 0
            var commandCalls = 0
            var forwarded: [String] = []
            var stdout = ""
            var stderr = ""
            var commandResult: QualificationCommandResult?
            let approvalURL = fixture.directory.appendingPathComponent("unused-approvals.json")
            let exit = await MainEntrypoint.run(
                arguments: arguments,
                permissionCheck: {
                    permissionCalls += 1
                    return .init(accessibility: false, automationLogicPro: false)
                },
                serverFactory: {
                    serverCalls += 1
                    return MockQualificationServer()
                },
                approvalStoreFactory: {
                    approvalCalls += 1
                    return ManualValidationStore(fileURL: approvalURL)
                },
                qualificationCommand: { actualArguments in
                    commandCalls += 1
                    forwarded = actualArguments
                    let actual = await runner.run(arguments: actualArguments)
                    commandResult = actual
                    return actual
                },
                writeStdout: { stdout += $0 },
                writeStderr: { stderr += $0 })
            run = try #require(commandResult)
            #expect(commandCalls == 1)
            #expect(forwarded == arguments)
            #expect(exit == run.exitCode)
            #expect(stdout == run.stdout)
            #expect(stderr == run.stderr)
            #expect(permissionCalls == 0)
            #expect(serverCalls == 0)
            #expect(approvalCalls == 0)
            #expect(!FileManager.default.fileExists(atPath: approvalURL.path))
        } else {
            run = await runner.run(arguments: arguments)
        }
        #expect(capture.count == 1)
        #expect(!FeatureFlags.adr007SelectorAtlas)
        let unsigned = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        #expect(unsigned.logicVersion == drive.logicProVersion)
        #expect(unsigned.locale == locale)
        let atlasCases = unsigned.cases.filter { $0.id == "atlas.drift_diff" }
        #expect(atlasCases.count == 1)
        let atlas = try #require(atlasCases.first)
        #expect(atlas.axis == axis)
        #expect(atlas.verificationKind == .atlasComparison)
        let path = try #require(atlas.evidenceFiles.first)
        let evidence = try JSONDecoder().decode(CaseEvidence.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent(path)))
        let comparison = try #require(evidence.atlasComparison)
        #expect(comparison.pairs == pairs)
        #expect(comparison.dropped == dropped)
        #expect(QualificationRunner.evidenceShapeIsValid(evidence))
        let signing = QualificationRunner.signTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, signingPrivateKeyData: fixture.signingKeyData)
        if shape == .complete {
            #expect(run.exitCode == 0, "\(run.stdout)")
            #expect(run.stderr.isEmpty, "\(run.stderr)")
            #expect(atlas.status == .passed)
            #expect(atlas.verified)
            #expect(signing.exitCode == 0, "\(signing.stdout)")
        } else {
            #expect(run.exitCode == 1, "\(run.stdout)")
            #expect(unsigned.failed == 1)
            #expect(run.stderr ==
                "qualification: \(unsigned.failed) of \(unsigned.total) case(s) failed\n")
            #expect(atlas.status == .failed)
            #expect(!atlas.verified)
            if shape == .dropped {
                let reason = try #require(atlas.reason)
                #expect(reason.contains("controlled unread selected baseline"))
            } else {
                #expect(atlas.reason ==
                    "required atlas scopes missing or ambiguous: trackHeaderRail, controlBar")
            }
            #expect(signing.exitCode == 1, "\(signing.stdout)")
            try Self.expectRejection(signing, reason: "atlasDriftRefused")
            // Keep coherent diagnostic signatures so trusted refusal is not merely unsigned.
            try fixture.forceSignForDiagnosticFixture()
        }
        let verification = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL,
            bundleURL: fixture.directory, releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        let object = try Self.resultObject(verification)
        let promotable = try #require(object["promotable"] as? Bool)
        if shape == .complete {
            #expect(verification.exitCode == 0, "\(verification.stdout)")
            #expect(promotable)
        } else {
            #expect(verification.exitCode == 1, "\(verification.stdout)")
            #expect(!promotable)
            try Self.expectRejection(verification, reason: "atlasDriftRefused")
            #expect(!Self.rejectionReasons(object).contains("provenanceSignatureInvalid"))
        }
    }

    @Test(arguments: [QualificationLocale.enUS, .koKR])
    func requireAtlasInvokesSelectedCaptureWithOptionalFlagOff(locale: QualificationLocale) async throws {
        try await assertRequiredAtlasProducer(locale: locale, shape: .complete)
    }

    @Test(arguments: [RequiredAtlasCaptureShape.absent, .partial, .dropped])
    private func requireAtlasRefusesIncompleteCaptureBeforeTrustedPromotion(shape: RequiredAtlasCaptureShape) async throws {
        try await assertRequiredAtlasProducer(locale: .enUS, shape: shape)
    }

    /// AFTER-only MainEntrypoint composition with the real runner and entirely injected data.
    @Test(arguments: [RequiredAtlasCaptureShape.complete, .absent])
    private func mainEntrypointRequiredAtlasComposesWithInjectedRunner(shape: RequiredAtlasCaptureShape) async throws {
        try await assertRequiredAtlasProducer(locale: .enUS, shape: shape, viaEntrypoint: true)
    }

    @Test func trustedSignedProvenancePromotes() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(result.exitCode == 0, "\(result.stdout)")
        let v1 = try #require(try Self.resultObject(result)["promotable"] as? Bool)
        #expect(v1)
    }

    @Test func standaloneSignerAndVerifierUseCandidateBytesWithoutExecutingCandidate() async throws {
        let sentinelURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trusted-verifier-candidate-executed-\(UUID().uuidString)"
        )
        let fixture = try trustedFixture(candidateExecutionSentinelURL: sentinelURL)
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: sentinelURL)
        }

        let qualification = await fixture.runQualification(waiversURL: fixture.waiversURL)
        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        try #require(qualification.exitCode == 0)
        let unsigned = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(unsigned.provenanceSignature == nil)
        if let exportPath = ProcessInfo.processInfo.environment["LPMCP367_QA_DIR"] {
            let exportURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: exportURL)
            try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: fixture.directory,
                to: exportURL.appendingPathComponent("bundle", isDirectory: true)
            )
            try Data(fixture.signingKeyData.base64EncodedString().utf8).write(
                to: exportURL.appendingPathComponent("signing-key.base64")
            )
            try Data(fixture.trustedPublicKeyData.base64EncodedString().utf8).write(
                to: exportURL.appendingPathComponent("public-key.base64")
            )
            try Data(sentinelURL.path.utf8).write(
                to: exportURL.appendingPathComponent("candidate-sentinel-path")
            )
        }

        let signing = QualificationRunner.signTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            signingPrivateKeyData: fixture.signingKeyData
        )
        #expect(signing.exitCode == 0, "\(signing.stdout)")
        let signed = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(signed.provenanceSignature?.algorithm == "ed25519")
        #expect(signed.provenanceSignature?.keyID == SupportBundleBuilder.sha256(
            fixture.trustedPublicKeyData
        ))

        let verification = QualificationRunner.verifyTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            trustedPublicKeyData: fixture.trustedPublicKeyData
        )
        #expect(verification.exitCode == 0, "\(verification.stdout)")
        #expect(!FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    @Test func trustedVerifierAcceptsSignedRecipeShapedCycle() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        let cycleCase = try #require(attestation.cases.first { $0.operationID == "tracks.rename" })
        #expect(cycleCase.status == .passed)
        #expect(cycleCase.verificationKind == .verifiedWriteCycle)
        let restore = try #require(cycleCase.restore)
        #expect(restore.verified)
        #expect(PromotionGate.operationIsLiveCredited(cycleCase))
        let result = QualificationRunner.verifyTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            trustedPublicKeyData: fixture.trustedPublicKeyData
        )
        #expect(result.exitCode == 0, "\(result.stdout)")
    }

    private func publicEvidenceDirectory(_ fixture: Fixture, archiveFault: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("public-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try FileManager.default.copyItem(at: fixture.executableURL, to: directory.appendingPathComponent("LogicProMCP"))
            let program = #"""
import io, pathlib, sys, tarfile
root, fault = pathlib.Path(sys.argv[1]), sys.argv[2]
data = (root / 'LogicProMCP').read_bytes()
for name in ('LogicProMCP-macOS-universal.tar.gz', 'LogicProMCP-macOS-arm64.tar.gz'):
    with tarfile.open(root / name, 'w:gz') as archive:
        member = tarfile.TarInfo('LogicProMCP')
        member.mode = 0o755
        payload = b'wrong candidate' if fault == 'wrong_binary' else data
        member.size = len(payload)
        if fault == 'symlink':
            member.type = tarfile.SYMTYPE
            member.linkname = '/private/unowned'
            member.size = 0
        if fault != 'missing':
            archive.addfile(member, io.BytesIO(payload))
        if fault == 'duplicate':
            archive.addfile(member, io.BytesIO(payload))
        if fault == 'traversal':
            other = tarfile.TarInfo('../escaped')
            other.size = 1
            archive.addfile(other, io.BytesIO(b'x'))
        if fault in ('file_parent', 'file_child'):
            pair = [('Companion', b'x'), ('companion/child', b'y')]
            for path, content in pair if fault == 'file_parent' else reversed(pair):
                other = tarfile.TarInfo(path)
                other.size = len(content)
                archive.addfile(other, io.BytesIO(content))
"""#
            let result = BoundedProcessRunner.run(executable: "/usr/bin/env",
                arguments: ["-i", "PATH=/usr/bin:/bin", "/usr/bin/python3", "-I", "-c", program,
                            directory.path, archiveFault ?? "healthy"], timeout: 10)
            try #require(result.output?.exitCode == 0)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func publicEvidenceCommand(_ command: String, fixture: Fixture, directory: URL,
                                       commit: String? = nil, version: String = "1.2.3",
                                       axis: String = QualificationAxis.defaultAxis.key,
                                       key: Data? = nil, bundleURL: URL? = nil) -> QualificationCommandResult {
        var arguments = ["trusted-verifier", command, "--public-directory", directory.path,
                         "--release-version", version, "--expected-commit", commit ?? fixture.commitSHA]
        if command == "export-public" {
            arguments += ["--candidate", fixture.executableURL.path, "--bundle", (bundleURL ?? fixture.directory).path]
        } else { arguments += ["--expected-axis", axis] }
        return QualificationRunner.runTrusted(arguments: arguments, environment: [
            "LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY": fixture.signingKeyData.base64EncodedString(),
            "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY": (key ?? fixture.trustedPublicKeyData).base64EncodedString(),
        ])
    }

    private func publicMatrixPayload(
        axes: [QualificationAxis] = QualificationAxis.requiredAxes(
            profile: .core,
            cache: .cold,
            fixture: .empty
        )
    ) -> QualificationPublicMatrixEvidence.Payload {
        let digest = String(repeating: "a", count: 64)
        let artifacts = QualificationPublicEvidence.artifactNames.map {
            QualificationPublicEvidence.Artifact(name: $0, sha256: digest)
        }
        let runs = axes.enumerated().map { index, axis in
            let token = String(format: "%064x", index + 1)
            let child = QualificationPublicEvidence.Payload(
                schema: QualificationPublicEvidence.schema,
                commitSHA: String(repeating: "b", count: 40),
                releaseVersion: "1.2.3",
                binarySHA256: digest,
                logicVersion: "12.4",
                axis: axis,
                runIDHash: token,
                startedAt: 1_000,
                completedAt: 1_001,
                privateManifestSHA256: token,
                artifacts: artifacts,
                cases: [.init(
                    caseIDHash: token,
                    operationID: "system.health",
                    status: .passed,
                    verificationKind: .independentReadback,
                    liveCredited: true
                )],
                waivers: [],
                evidence: [.init(
                    pathHash: token,
                    sha256: digest,
                    caseIDHash: token,
                    kind: "semantic_readback"
                )],
                total: 1,
                passed: 1,
                failed: 0,
                waived: 0,
                disclosure: "No private paths."
            )
            return QualificationPublicMatrixEvidence.Run(
                axis: axis,
                childAttestationSHA256: token,
                payload: child
            )
        }
        return QualificationPublicMatrixEvidence.Payload(
            schema: QualificationPublicMatrixEvidence.schema,
            commitSHA: String(repeating: "b", count: 40),
            releaseVersion: "1.2.3",
            binarySHA256: digest,
            logicVersion: "12.4",
            operationCatalogSHA256: digest,
            privateMatrixSHA256: digest,
            artifacts: artifacts,
            runs: runs,
            disclosure: "Authenticated two-axis projection; private paths remain private."
        )
    }

    @Test func publicMatrixEvidenceBindsBothRequiredAxesAndExactPrivateSnapshots() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 19, count: 32))
        let payload = publicMatrixPayload()

        let signed = try QualificationPublicMatrixEvidence.sign(payload, key: key)
        let verified = try QualificationPublicMatrixEvidence.verify(
            signed,
            trustedKey: key.publicKey.rawRepresentation
        )

        #expect(verified == payload)
        let actualAxes = verified.runs.map(\.axis)
        let sortedAxes = actualAxes.sorted { $0.key < $1.key }
        let requiredAxes = QualificationAxis.requiredAxes(
            profile: .core,
            cache: .cold,
            fixture: .empty
        )
        #expect(actualAxes == sortedAxes)
        #expect(Set(actualAxes) == Set(requiredAxes))
    }

    @Test func publicMatrixEvidenceRejectsMissingAxisAndSignedPayloadSubstitution() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 23, count: 32))
        let complete = publicMatrixPayload()
        #expect(throws: QualificationPublicMatrixEvidence.Rejection.self) {
            _ = try QualificationPublicMatrixEvidence.sign(
                publicMatrixPayload(axes: [QualificationAxis.defaultAxis]),
                key: key
            )
        }

        var envelope = try #require(
            JSONSerialization.jsonObject(with: QualificationPublicMatrixEvidence.sign(complete, key: key))
                as? [String: Any]
        )
        let encoded = try #require(envelope["payload"] as? String)
        let encodedPayload = try #require(Data(base64Encoded: encoded))
        var projected = try #require(
            JSONSerialization.jsonObject(with: encodedPayload)
                as? [String: Any]
        )
        projected["privateMatrixSHA256"] = String(repeating: "f", count: 64)
        envelope["payload"] = try JSONSerialization.data(
            withJSONObject: projected,
            options: [.sortedKeys]
        ).base64EncodedString()
        let substituted = try JSONSerialization.data(withJSONObject: envelope)

        #expect(throws: QualificationPublicMatrixEvidence.Rejection.self) {
            _ = try QualificationPublicMatrixEvidence.verify(
                substituted,
                trustedKey: key.publicKey.rawRepresentation
            )
        }
    }

    private func preparedPublicMatrix() async throws -> (
        en: Fixture,
        ko: Fixture,
        matrix: URL,
        publicDirectory: URL
    ) {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let executableData = Data("public-matrix-candidate".utf8)
        let commitSHA = String(repeating: "d", count: 40)
        let en = try Fixture(
            specs: specs,
            executableData: executableData,
            commitSHA: commitSHA,
            drive: { _ in Self.driveResult(specs: specs, observedLocale: "en-US") }
        )
        let ko = try Fixture(
            specs: specs,
            executableData: executableData,
            commitSHA: commitSHA,
            drive: { _ in Self.driveResult(specs: specs, observedLocale: "ko-KR") }
        )
        let matrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("public-matrix-private-\(UUID())", isDirectory: true)
        do {
            try #require((await en.runQualification(mutateOpenProject: false)).exitCode == 0)
            let koResult = await ko.runner.run(arguments: [
                "LogicProMCP", "--qualify",
                "--out", ko.attestationURL.path,
                "--release-version", "1.2.3",
                "--locale", "ko",
            ])
            try #require(koResult.exitCode == 0, "\(koResult.stdout)\(koResult.stderr)")
            try FileManager.default.createDirectory(at: matrix, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: en.directory, to: matrix.appendingPathComponent("en"))
            try FileManager.default.copyItem(at: ko.directory, to: matrix.appendingPathComponent("ko"))
            let input = QualificationMatrixInput(
                schema: QualificationMatrixInput.currentSchema,
                runs: [.init(path: "en"), .init(path: "ko")]
            )
            try QualificationPublicEvidence.encode(input).write(
                to: matrix.appendingPathComponent("qualification-matrix-input.json")
            )
            let signing = QualificationRunner.signTrustedMatrix(
                candidateURL: en.executableURL,
                matrixURL: matrix,
                releaseVersion: "1.2.3",
                expectedCommitSHA: commitSHA,
                signingPrivateKeyData: en.signingKeyData,
                requiredArtifacts: [],
                requiredOperationIDs: en.requiredOperationIDs
            )
            try #require(signing.exitCode == 0, "\(signing.stdout)\(signing.stderr)")
            return (en, ko, matrix, try publicEvidenceDirectory(en))
        } catch {
            en.remove()
            ko.remove()
            try? FileManager.default.removeItem(at: matrix)
            throw error
        }
    }

    @Test func publicMatrixExportValidatesAndProjectsTheCompletePrivateMatrix() async throws {
        let fixture = try await preparedPublicMatrix()
        defer {
            fixture.en.remove()
            fixture.ko.remove()
            try? FileManager.default.removeItem(at: fixture.matrix)
            try? FileManager.default.removeItem(at: fixture.publicDirectory)
        }
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: fixture.en.signingKeyData
        )
        let exported = try QualificationRunner.exportPublicMatrixEvidence(
            candidate: fixture.en.executableURL,
            matrix: fixture.matrix,
            directory: fixture.publicDirectory,
            version: "1.2.3",
            commit: fixture.en.commitSHA,
            key: key,
            requiredArtifacts: [],
            requiredOperationIDs: fixture.en.requiredOperationIDs
        )
        try #require(exported.exitCode == 0, "\(exported.stdout)\(exported.stderr)")

        let verified = QualificationRunner.runTrusted(arguments: [
            "trusted-verifier", "verify-public-matrix",
            "--public-directory", fixture.publicDirectory.path,
            "--release-version", "1.2.3",
            "--expected-commit", fixture.en.commitSHA,
        ], environment: [
            "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY": fixture.en.trustedPublicKeyData
                .base64EncodedString(),
        ])
        #expect(verified.exitCode == 0, "\(verified.stdout)\(verified.stderr)")
        let evidenceData = try Data(contentsOf: fixture.publicDirectory.appendingPathComponent(
            QualificationPublicEvidence.filename
        ))
        let payload = try QualificationPublicMatrixEvidence.verify(
            evidenceData,
            trustedKey: fixture.en.trustedPublicKeyData
        )
        let privateMatrix = try Data(contentsOf: fixture.matrix.appendingPathComponent(
            "release-qualification-matrix.json"
        ))
        let privateRoot = try JSONDecoder().decode(
            ReleaseQualificationMatrixAttestation.self,
            from: privateMatrix
        )
        #expect(payload.privateMatrixSHA256 == SupportBundleBuilder.sha256(privateMatrix))
        #expect(payload.operationCatalogSHA256 == privateRoot.operationCatalogSHA256)
        for projectedRun in payload.runs {
            let privateRun = try #require(privateRoot.runs.first {
                $0.axis == projectedRun.axis
            })
            let childDirectory = fixture.matrix.appendingPathComponent(privateRun.path)
            let childAttestationData = try Data(contentsOf: childDirectory.appendingPathComponent(
                "release-qualification-attestation.json"
            ))
            let childAttestation = try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: childAttestationData
            )
            let childCatalogData = try Data(contentsOf: childDirectory.appendingPathComponent(
                "operation-catalog.json"
            ))
            #expect(projectedRun.childAttestationSHA256 == privateRun.childAttestationSHA256)
            #expect(projectedRun.childAttestationSHA256
                == SupportBundleBuilder.sha256(childAttestationData))
            #expect(childAttestation.operationCatalogSHA256 == privateRoot.operationCatalogSHA256)
            #expect(payload.operationCatalogSHA256 == SupportBundleBuilder.sha256(childCatalogData))
        }
        #expect(Set(payload.runs.map(\.axis)) == Set(QualificationAxis.requiredAxes(
            profile: .core,
            cache: .cold,
            fixture: .empty
        )))
        let encodedPayload = String(
            decoding: try QualificationPublicEvidence.encode(payload),
            as: UTF8.self
        )
        #expect(!encodedPayload.contains(fixture.matrix.path))
        #expect(!encodedPayload.contains("\"path\":\"en\""))
        #expect(!encodedPayload.contains("\"path\":\"ko\""))

        try Data("replacement".utf8).write(
            to: fixture.publicDirectory.appendingPathComponent("LogicProMCP")
        )
        let substituted = QualificationRunner.runTrusted(arguments: [
            "trusted-verifier", "verify-public-matrix",
            "--public-directory", fixture.publicDirectory.path,
            "--release-version", "1.2.3",
            "--expected-commit", fixture.en.commitSHA,
        ], environment: [
            "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY": fixture.en.trustedPublicKeyData
                .base64EncodedString(),
        ])
        #expect(substituted.exitCode != 0)
    }

    @Test func publicMatrixExportRefusesDestinationInsidePrivateMatrix() async throws {
        let fixture = try await preparedPublicMatrix()
        defer {
            fixture.en.remove()
            fixture.ko.remove()
            try? FileManager.default.removeItem(at: fixture.matrix)
            try? FileManager.default.removeItem(at: fixture.publicDirectory)
        }
        let nested = fixture.matrix.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.publicDirectory, to: nested)
        let result = try QualificationRunner.exportPublicMatrixEvidence(
            candidate: fixture.en.executableURL,
            matrix: fixture.matrix,
            directory: nested,
            version: "1.2.3",
            commit: fixture.en.commitSHA,
            key: Curve25519.Signing.PrivateKey(rawRepresentation: fixture.en.signingKeyData),
            requiredArtifacts: [],
            requiredOperationIDs: fixture.en.requiredOperationIDs
        )
        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent(
            QualificationPublicEvidence.filename
        ).path))
    }

    @Test func publicMatrixProjectsTheSameChildManifestSnapshotsItValidated() async throws {
        let fixture = try await preparedPublicMatrix()
        defer {
            fixture.en.remove()
            fixture.ko.remove()
            try? FileManager.default.removeItem(at: fixture.matrix)
            try? FileManager.default.removeItem(at: fixture.publicDirectory)
        }
        let manifest = fixture.matrix.appendingPathComponent("en/evidence-manifest.json")
        let originalManifest = try Data(contentsOf: manifest)
        let originalDigest = SupportBundleBuilder.sha256(originalManifest)
        let replacement = Data("unvalidated replacement".utf8)
        let result = try QualificationRunner.exportPublicMatrixEvidence(
            candidate: fixture.en.executableURL,
            matrix: fixture.matrix,
            directory: fixture.publicDirectory,
            version: "1.2.3",
            commit: fixture.en.commitSHA,
            key: Curve25519.Signing.PrivateKey(rawRepresentation: fixture.en.signingKeyData),
            requiredArtifacts: [],
            requiredOperationIDs: fixture.en.requiredOperationIDs,
            beforeProjection: {
                try? replacement.write(to: manifest, options: .atomic)
            }
        )
        try #require(result.exitCode == 0, "\(result.stdout)\(result.stderr)")
        let publicData = try Data(contentsOf: fixture.publicDirectory.appendingPathComponent(
            QualificationPublicEvidence.filename
        ))
        let payload = try QualificationPublicMatrixEvidence.verify(
            publicData,
            trustedKey: fixture.en.trustedPublicKeyData
        )
        let en = try #require(payload.runs.first { $0.axis.locale == .enUS })
        #expect(en.payload.privateManifestSHA256 == originalDigest)
        #expect(SupportBundleBuilder.sha256(try Data(contentsOf: manifest))
            == SupportBundleBuilder.sha256(replacement))
    }

    @Test func publicMatrixCLIExportsAndVerifiesFullyQualifiedRequiredArtifacts() async throws {
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("public-matrix-candidate-executed-\(UUID())")
        let en = try trustedFixture(
            candidateExecutionSentinelURL: sentinel,
            includeAxisWaivers: false
        )
        let ko = try trustedFixture(
            candidateExecutionSentinelURL: sentinel,
            observedLocale: .koKR,
            includeAxisWaivers: false
        )
        let matrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("public-matrix-cli-\(UUID())", isDirectory: true)
        defer {
            en.remove()
            ko.remove()
            try? FileManager.default.removeItem(at: matrix)
            try? FileManager.default.removeItem(at: sentinel)
        }
        let enResult = await en.runQualification(
            waiversURL: en.waiversURL,
            locale: .enUS
        )
        let koResult = await ko.runQualification(
            waiversURL: ko.waiversURL,
            locale: .koKR
        )
        try #require(enResult.exitCode == 0, "\(enResult.stdout)\(enResult.stderr)")
        try #require(koResult.exitCode == 0, "\(koResult.stdout)\(koResult.stderr)")
        try FileManager.default.createDirectory(at: matrix, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: en.directory, to: matrix.appendingPathComponent("en"))
        try FileManager.default.copyItem(at: ko.directory, to: matrix.appendingPathComponent("ko"))
        try QualificationPublicEvidence.encode(QualificationMatrixInput(
            schema: QualificationMatrixInput.currentSchema,
            runs: [.init(path: "en"), .init(path: "ko")]
        )).write(to: matrix.appendingPathComponent("qualification-matrix-input.json"))
        let signing = QualificationRunner.signTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: matrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: en.commitSHA,
            signingPrivateKeyData: en.signingKeyData
        )
        try #require(signing.exitCode == 0, "\(signing.stdout)\(signing.stderr)")
        let directory = try publicEvidenceDirectory(en)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY": en.signingKeyData.base64EncodedString(),
            "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY": en.trustedPublicKeyData.base64EncodedString(),
        ]
        let exported = QualificationRunner.runTrusted(arguments: [
            "trusted-verifier", "export-public-matrix",
            "--candidate", en.executableURL.path,
            "--matrix-index", matrix.appendingPathComponent("qualification-matrix-input.json").path,
            "--public-directory", directory.path,
            "--release-version", "1.2.3",
            "--expected-commit", en.commitSHA,
        ], environment: environment)
        try #require(exported.exitCode == 0, "\(exported.stdout)\(exported.stderr)")
        let verified = QualificationRunner.runTrusted(arguments: [
            "trusted-verifier", "verify-public-matrix",
            "--public-directory", directory.path,
            "--release-version", "1.2.3",
            "--expected-commit", en.commitSHA,
        ], environment: environment)
        #expect(verified.exitCode == 0, "\(verified.stdout)\(verified.stderr)")
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func publicEvidenceAcceptsBoundArtifactsWithoutDisclosingPrivatePaths() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exported = publicEvidenceCommand("export-public", fixture: fixture, directory: directory)
        try #require(exported.exitCode == 0, "\(exported.stdout)")
        let verified = publicEvidenceCommand("verify-public", fixture: fixture, directory: directory)
        #expect(verified.exitCode == 0, "\(verified.stdout)")
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("qualification-public.json"))) as? [String: Any]
        let encoded = try #require(envelope?["payload"] as? String)
        let data = try #require(Data(base64Encoded: encoded))
        let payload = String(decoding: data, as: UTF8.self)
        #expect(!payload.contains(fixture.directory.path))
        #expect(!payload.contains(fixture.executableURL.path))
        #expect(!payload.contains(fixture.signingKeyData.base64EncodedString()))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("raw-transcript.json").path))
    }

    @Test(arguments: ["candidate", "archive_and_digest", "payload_and_digest", "foreign_key",
                      "source", "version", "axis", "missing_member"])
    func publicEvidenceRejectsSubstitutionAgainstIndependentAnchor(fault: String) async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(publicEvidenceCommand("export-public", fixture: fixture, directory: directory).exitCode == 0)
        let evidence = directory.appendingPathComponent("qualification-public.json")
        if fault == "candidate" {
            try Data("replacement".utf8).write(to: directory.appendingPathComponent("LogicProMCP"))
        } else if fault == "archive_and_digest" {
            let archive = directory.appendingPathComponent("LogicProMCP-macOS-arm64.tar.gz")
            try Data("replacement".utf8).write(to: archive)
            try Data(SupportBundleBuilder.sha256(Data("replacement".utf8)).utf8)
                .write(to: directory.appendingPathComponent("SHA256SUMS.txt"))
        } else if fault == "payload_and_digest" {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any])
            let encoded = try #require(object["payload"] as? String)
            let originalPayload = try #require(Data(base64Encoded: encoded))
            var payload = try #require(JSONSerialization.jsonObject(with: originalPayload) as? [String: Any])
            payload["commitSHA"] = String(repeating: "b", count: 40)
            let replacement = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            object["payload"] = replacement.base64EncodedString()
            try JSONSerialization.data(withJSONObject: object).write(to: evidence)
            try Data(SupportBundleBuilder.sha256(replacement).utf8).write(to:
                directory.appendingPathComponent("qualification-public.sha256"))
        } else if fault == "missing_member" {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("LogicProMCP-macOS-arm64.tar.gz"))
        }
        let result = publicEvidenceCommand("verify-public", fixture: fixture, directory: directory,
            commit: fault == "source" ? String(repeating: "b", count: 40) : nil,
            version: fault == "version" ? "9.9.9" : "1.2.3",
            axis: fault == "axis" ? "desktop/ko-KR/core/cold/empty" : QualificationAxis.defaultAxis.key,
            key: fault == "foreign_key" ? Data(repeating: 77, count: 32) : nil)
        #expect(result.exitCode != 0, "\(fault): \(result.stdout)")
    }

    @Test(arguments: ["wrong_binary", "duplicate", "symlink", "traversal", "missing", "file_parent", "file_child"])
    func publicEvidenceExportRequiresTheActualArchiveCandidate(fault: String) async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let directory = try publicEvidenceDirectory(fixture, archiveFault: fault)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = publicEvidenceCommand("export-public", fixture: fixture, directory: directory)
        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("qualification-public.json").path))
    }

    @Test(arguments: ["same", "public_inside_private", "private_inside_public",
                      "public_inside_private_via_alias", "private_inside_public_via_alias"])
    func publicEvidenceRefusesPrivateBundleDestinationOverlap(shape: String) async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let prepared = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: prepared) }
        var directory = prepared, bundle = fixture.directory
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("public-alias-\(UUID())")
        defer { try? FileManager.default.removeItem(at: alias) }
        if shape == "same" {
            for name in QualificationPublicEvidence.artifactNames.dropFirst() {
                try FileManager.default.copyItem(at: prepared.appendingPathComponent(name),
                    to: fixture.directory.appendingPathComponent(name))
            }
            directory = fixture.directory
        } else if shape == "public_inside_private" {
            directory = fixture.directory.appendingPathComponent("public-projection")
            try FileManager.default.moveItem(at: prepared, to: directory)
        } else if shape == "public_inside_private_via_alias" {
            let nested = fixture.directory.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: prepared, to: nested.appendingPathComponent("public"))
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
            directory = alias.appendingPathComponent("public")
        } else if shape == "private_inside_public_via_alias" {
            let nested = prepared.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: fixture.directory, to: nested.appendingPathComponent("private-bundle"))
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
            bundle = alias.appendingPathComponent("private-bundle")
        } else {
            bundle = prepared.appendingPathComponent("private-bundle")
            try FileManager.default.copyItem(at: fixture.directory, to: bundle)
        }
        let result = publicEvidenceCommand("export-public", fixture: fixture, directory: directory, bundleURL: bundle)
        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("qualification-public.json").path))
    }

    @Test func publicEvidenceValidatesTheSnapshotItActuallyProjects() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Model the actual load boundary: A was loaded, while accepted B is now
        // at the same on-disk location. No timing/environment fault flag is used.
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.attestationURL)) as? [String: Any])
        let anotherCommit = String(repeating: "b", count: 40)
        object["commitSHA"] = anotherCommit
        let loaded = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: JSONSerialization.data(withJSONObject: object))
        try #require(loaded.commitSHA == anotherCommit && loaded.commitSHA != fixture.commitSHA)
        let acceptedB = QualificationRunner.verifyTrusted(candidateURL: fixture.executableURL, bundleURL: fixture.directory,
            releaseVersion: "1.2.3", expectedCommitSHA: fixture.commitSHA, trustedPublicKeyData: fixture.trustedPublicKeyData)
        try #require(acceptedB.exitCode == 0)
        let controlDirectory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: controlDirectory) }
        let original = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        let control = try QualificationRunner.exportPublicEvidenceSnapshot(attestation: original,
            manifestData: Data(contentsOf: fixture.manifestURL), candidate: fixture.executableURL,
            bundle: fixture.directory, directory: controlDirectory, version: "1.2.3", commit: fixture.commitSHA,
            key: Curve25519.Signing.PrivateKey(rawRepresentation: fixture.signingKeyData))
        try #require(control.exitCode == 0, "\(control.stdout)")
        let result = try QualificationRunner.exportPublicEvidenceSnapshot(attestation: loaded,
            manifestData: Data(contentsOf: fixture.manifestURL), candidate: fixture.executableURL,
            bundle: fixture.directory, directory: directory, version: "1.2.3", commit: fixture.commitSHA,
            key: Curve25519.Signing.PrivateKey(rawRepresentation: fixture.signingKeyData))
        #expect(result.exitCode != 0, "Unverified A must not inherit accepted B's authority")
        if result.exitCode == 0 {
            #expect(publicEvidenceCommand("verify-public", fixture: fixture, directory: directory,
                commit: anotherCommit).exitCode != 0, "The public signature must not authenticate A's unverified source")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("qualification-public.json").path))
    }

    @Test func publicEvidenceProjectsTheCatalogSnapshotThatPassedPrivateValidation() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogURL = fixture.directory.appendingPathComponent("operation-catalog.json")
        let original = try JSONDecoder().decode(
            QualificationOperationCatalog.self,
            from: Data(contentsOf: catalogURL)
        )
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        let unregistered = try #require(attestation.cases.first { candidateCase in
            !candidateCase.id.hasPrefix("in-process/") && !original.operations.contains(where: {
                $0.operationID == candidateCase.operationID
            })
        })
        let replacementEntry = QualificationOperationCatalog.Entry(
            operationID: unregistered.operationID,
            caseID: "in-process/\(unregistered.operationID)",
            oracleDisposition: .noSemanticOracle,
            semanticPolicy: QualificationSemanticPolicy(
                kind: .none,
                strength: nil,
                constraints: [],
                independentlyCreditable: false
            ),
            mutationRestorePolicy: nil
        )
        let replacement = QualificationOperationCatalog(
            schema: original.schema,
            binarySHA256: original.binarySHA256,
            semanticPolicySHA256: try QualificationRunner.operationCatalogPolicyDigest([
                replacementEntry
            ]),
            operations: [replacementEntry]
        )
        let swapper = CatalogSecondReadReplacement(
            replacement: try JSONEncoder().encode(replacement)
        )
        let result = try QualificationRunner.exportPublicEvidenceSnapshot(
            attestation: attestation,
            manifestData: Data(contentsOf: fixture.manifestURL),
            candidate: fixture.executableURL,
            bundle: fixture.directory,
            directory: directory,
            version: "1.2.3",
            commit: fixture.commitSHA,
            key: Curve25519.Signing.PrivateKey(rawRepresentation: fixture.signingKeyData),
            beforeEvidenceRead: swapper.replaceOnSecondCatalogRead
        )

        #expect(result.exitCode == 0, "\(result.stdout)\(result.stderr)")
        #expect(swapper.didReplace, "the counterexample must replace the on-disk catalog")
        let publicData = try Data(contentsOf: directory.appendingPathComponent(
            QualificationPublicEvidence.filename
        ))
        let payload = try QualificationPublicEvidence.verify(
            publicData,
            trustedKey: fixture.trustedPublicKeyData
        )
        #expect(Set(payload.cases.compactMap(\.operationID))
                == Set(original.operations.map(\.operationID)))
    }

    @Test func unknownOperationCannotReceiveLiveSemanticCredit() {
        let unknown = "future.operation"
        let qualificationCase = QualificationCase(
            id: "in-process/\(unknown)",
            status: .passed,
            tool: "logic_future",
            command: "operation",
            traceID: "future-trace",
            verified: true,
            evidenceFiles: ["future.json"],
            binarySHA256: String(repeating: "a", count: 64),
            operationID: unknown,
            verificationKind: .semanticReadback,
            readback: QualificationReadbackEvidence(
                source: "logic://future",
                requestID: "future-readback",
                verified: true,
                sha256: String(repeating: "b", count: 64)
            )
        )

        #expect(!PromotionGate.operationIsLiveCredited(qualificationCase))
    }

    @Test func signedDeclarativePolicyReplaysWithoutVerifierRegistryMembership() throws {
        let policy = QualificationSemanticPolicy(
            kind: .declarative,
            strength: .shapeAndDomain,
            constraints: [
                .valueEquals(key: "schema", expected: .string("future/v1")),
                .crossCheck(responseKey: "value", readbackKey: "value"),
            ],
            independentlyCreditable: true
        )
        let encoded = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(QualificationSemanticPolicy.self, from: encoded)
        #expect(decoded == policy)
        #expect(decoded.evaluate(
            operationID: "future.operation",
            responseData: Data(#"{"schema":"future/v1","value":7}"#.utf8),
            readbackData: Data(#"{"value":7}"#.utf8)
        ))
        #expect(!decoded.evaluate(
            operationID: "future.operation",
            responseData: Data(#"{"schema":"future/v1","value":7}"#.utf8),
            readbackData: Data(#"{"value":8}"#.utf8)
        ))
    }

    @Test func signedMutationRestorePolicyReplaysWithoutVerifierRegistryMembership() throws {
        let local = Self.recipeShapedRecord()
        let record = QualificationMutationRestoreRecord(
            operationID: "future.operation",
            preState: local.preState,
            mutation: local.mutation,
            readback: local.readback,
            restore: local.restore,
            restoreReadback: local.restoreReadback
        )
        let policy = QualificationMutationRestorePolicy.trackName

        #expect(!record.verifiedCycleShape)
        #expect(record.verifiedCycleShape(using: policy))
        let encoded = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(
            QualificationMutationRestorePolicy.self,
            from: encoded
        ) == policy)
    }

    @Test func operationCatalogPoliciesCoverEveryMutationRestoreRecipe() {
        var expected = Set(QualificationTransport.trackCreateRestoreOperations)
        expected.formUnion(QualificationTransport.valueRestoreReadbackField.keys)
        expected.formUnion(QualificationTransport.booleanToggleReadbackField.keys)
        expected.formUnion(QualificationTransport.historyRestoreDirection.keys)
        expected.formUnion(QualificationTransport.transportExpectedPlaying.keys)
        expected.formUnion(QualificationTransport.parameterlessToggleField.keys)
        expected.formUnion(QualificationTransport.playheadStepDirections.keys)
        expected.formUnion(QualificationTransport.playheadRestoreOperations)
        expected.formUnion(QualificationTransport.markerStagedRestoreMode.keys)
        expected.formUnion([
            .tracksRename, .tracksSelect, .tracksDelete, .transportSetTempo,
            .navigateGotoMarker, .navigateCreateMarker, .systemExportSupportBundle,
        ])
        let catalogued = Set(OperationRegistry.specs.compactMap { spec in
            QualificationTransport.mutationRestorePolicy(for: spec.id) == nil ? nil : spec.id
        })

        #expect(catalogued == expected)
        #expect(expected.allSatisfy {
            QualificationTransport.mutationRestorePolicy(for: $0)?.isValid == true
        })
    }

    @Test func publicEvidenceRefusalDoesNotDisclosePrivateVerifierDetails() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = "PRIVATE /Users/sentinel/project.logicx"
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            var waivers = try #require(object["waivers"] as? [[String: Any]])
            try #require(!waivers.isEmpty)
            waivers[0]["caseID"] = sentinel
            object["waivers"] = waivers
        }
        let result = publicEvidenceCommand("export-public", fixture: fixture, directory: directory)
        #expect(result.exitCode != 0)
        #expect(!(result.stdout + result.stderr).contains(sentinel))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("qualification-public.json").path))
    }

    @Test func publicEvidenceWithholdsActualPrivateWaiverText() async throws {
        let fixture = try trustedFixture()
        defer { fixture.remove() }
        let sentinel = "PRIVATE-WAIVER /Users/private-owner/project.logicx"
        let original = try JSONDecoder().decode([QualificationWaiver].self, from: Data(contentsOf: fixture.waiversURL))
        try #require(!original.isEmpty)
        let changed = original.map { item in
            QualificationWaiver(caseID: item.caseID, reasonCode: item.reasonCode, owningIssue: item.owningIssue,
                userImpact: sentinel, affectedCapability: item.affectedCapability,
                affectsDefaultProfile: item.affectsDefaultProfile, expiryVersion: item.expiryVersion,
                releaseNoteVisible: item.releaseNoteVisible)
        }
        try JSONEncoder().encode(changed).write(to: fixture.waiversURL)
        let qualified = await fixture.runQualification(waiversURL: fixture.waiversURL)
        try #require(qualified.exitCode == 0)
        let signed = QualificationRunner.signTrusted(candidateURL: fixture.executableURL, bundleURL: fixture.directory,
            releaseVersion: "1.2.3", expectedCommitSHA: fixture.commitSHA, signingPrivateKeyData: fixture.signingKeyData)
        try #require(signed.exitCode == 0)
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(publicEvidenceCommand("export-public", fixture: fixture, directory: directory).exitCode == 0)
        let data = try Data(contentsOf: directory.appendingPathComponent("qualification-public.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require(object["payload"] as? String)
        let decoded = try #require(Data(base64Encoded: encoded))
        let text = String(decoding: decoded, as: UTF8.self)
        #expect(!text.contains(sentinel) && !text.contains("/Users/private-owner"))
        #expect(text.contains(SupportBundleBuilder.sha256(Data(sentinel.utf8))))
        #expect(publicEvidenceCommand("verify-public", fixture: fixture, directory: directory).exitCode == 0)
    }

    @Test(arguments: ["private_manifest", "existing_output", "projection_symlink", "artifact_fifo"])
    func publicEvidenceRetainsPrivateGateAndSafeFileBoundaries(fault: String) async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("qualification-public.json")
        if fault == "private_manifest" {
            try Data("forged".utf8).write(to: fixture.manifestURL)
            #expect(publicEvidenceCommand("export-public", fixture: fixture, directory: directory).exitCode != 0)
            #expect(!FileManager.default.fileExists(atPath: output.path))
        } else if fault == "existing_output" {
            try Data("original-owned-output".utf8).write(to: output)
            #expect(publicEvidenceCommand("export-public", fixture: fixture, directory: directory).exitCode != 0)
            #expect(try Data(contentsOf: output) == Data("original-owned-output".utf8))
        } else {
            try #require(publicEvidenceCommand("export-public", fixture: fixture, directory: directory).exitCode == 0)
            let target = fault == "projection_symlink" ? output : directory.appendingPathComponent("LogicProMCP")
            let original = directory.appendingPathComponent("saved-original")
            try FileManager.default.moveItem(at: target, to: original)
            if fault == "projection_symlink" {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
            } else { try #require(mkfifo(target.path, 0o600) == 0) }
            #expect(publicEvidenceCommand("verify-public", fixture: fixture, directory: directory).exitCode != 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func publicEvidenceStandaloneConsumerNeverExecutesCandidate() async throws {
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("public-candidate-executed-\(UUID())")
        let fixture = try await signedTrustedFixture(candidateExecutionSentinelURL: sentinel)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: sentinel) }
        let directory = try publicEvidenceDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(FileManager.default.isExecutableFile(atPath: Self.trustedVerifierExecutableURL.path))
        func run(_ command: String) throws -> QualificationCommandResult {
            let process = Process()
            process.executableURL = Self.trustedVerifierExecutableURL
            var arguments = [command, "--public-directory", directory.path,
                                 "--release-version", "1.2.3", "--expected-commit", fixture.commitSHA]
            if command == "export-public" {
                arguments += ["--candidate", fixture.executableURL.path, "--bundle", fixture.directory.path]
            } else { arguments += ["--expected-axis", QualificationAxis.defaultAxis.key] }
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin",
                "LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY": fixture.signingKeyData.base64EncodedString(),
                "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY": fixture.trustedPublicKeyData.base64EncodedString()]
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let error = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(exitCode: Int(process.terminationStatus), stdout: String(decoding: output, as: UTF8.self),
                         stderr: String(decoding: error, as: UTF8.self))
        }
        let exported = try run("export-public")
        try #require(exported.exitCode == 0, "\(exported.stdout)\(exported.stderr)")
        let accepted = try run("verify-public")
        #expect(accepted.exitCode == 0, "\(accepted.stdout)\(accepted.stderr)")
        try Data("replaced".utf8).write(to: directory.appendingPathComponent("LogicProMCP-macOS-arm64.tar.gz"))
        #expect(try run("verify-public").exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test func trustedVerifierRejectsNoOpReadbackInMutationArtifact() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let artifactURL = fixture.directory.appendingPathComponent(
            "mutation-restore-compensation.json"
        )
        var artifact = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: artifactURL)) as? [String: Any]
        )
        var records = try #require(artifact["records"] as? [[String: Any]])
        let recordIndex = try #require(records.firstIndex {
            $0["operation_id"] as? String == OperationID.tracksRename.rawValue
        })
        let preState = try #require(records[recordIndex]["pre_state"] as? String)
        records[recordIndex]["readback"] = preState
        artifact["records"] = records
        let artifactData = try JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys])
        try artifactData.write(to: artifactURL, options: .atomic)

        // Keep the artifact entry's digest current so the schema check sees the no-op record.
        // The signed bundle's other bindings may also reject this tampering; this witness checks
        // that the trusted artifact validator itself rejects the recipe shape.
        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL)) as? [String: Any]
        )
        var entries = try #require(manifest["files"] as? [[String: Any]])
        let entryIndex = try #require(entries.firstIndex {
            $0["path"] as? String == "mutation-restore-compensation.json"
        })
        entries[entryIndex]["sha256"] = SupportBundleBuilder.sha256(artifactData)
        manifest["files"] = entries
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: fixture.manifestURL, options: .atomic)

        let result = QualificationRunner.verifyTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            trustedPublicKeyData: fixture.trustedPublicKeyData
        )
        #expect(result.exitCode != 0)
        let json = try Self.resultObject(result)
        let rejections = try #require(json["rejections"] as? [[String: Any]])
        #expect(rejections.contains {
            $0["reason"] as? String == "requiredArtifactSchemaInvalid"
                && $0["name"] as? String == "mutation-restore-compensation.json"
        })
    }

    @Test func promotionVerifierRejectsUnrestoredOrMalformedCycle() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let invalid = [
            Self.recipeShapedRecord(
                restoreReadback: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"After"}]}"#),
            Self.recipeShapedRecord(mutation: "After"),
            Self.recipeShapedRecord(restoreReadback: "Before"),
        ]
        for record in invalid {
            let driveResult = Self.driveResult(specs: [spec], mutationRestoreRecords: [record])
            let fixture = try Fixture(specs: [spec], drive: { _ in driveResult })
            defer { fixture.remove() }
            try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)
            _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
            let result = await fixture.verify(
                expectedSHA256: fixture.binarySHA256,
                requiredArtifacts: "raw-transcript.json,mutation-restore-compensation.json"
            )
            #expect(result.exitCode != 0)
            #expect(Self.rejectionReasons(try Self.resultObject(result))
                .contains("requiredArtifactSchemaInvalid"))
        }
    }

    @Test func standaloneVerifierRejectsEveryPromotionBypassWithTypedReasons() async throws {
        do {
            let fixture = try trustedFixture()
            defer { fixture.remove() }
            try #require((await fixture.runQualification(waiversURL: fixture.waiversURL)).exitCode == 0)
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(result, reason: "provenanceSignatureMissing")
        }

        do {
            let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent(
                "trusted-verifier-rejected-candidate-\(UUID().uuidString)"
            )
            let fixture = try await signedTrustedFixture(candidateExecutionSentinelURL: sentinel)
            defer {
                fixture.remove()
                try? FileManager.default.removeItem(at: sentinel)
            }
            try Self.mutateJSONObject(at: fixture.attestationURL) { object in
                var cases = try #require(object["cases"] as? [[String: Any]])
                let index = try #require(cases.firstIndex { $0["id"] as? String == QualificationAxis.defaultAxis.key })
                cases[index]["status"] = "failed"
                object["cases"] = cases
                object["failed"] = 1
            }
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(result, reason: "requiredCaseFailed")
            #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        }

        do {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            let foreignKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 9, count: 32)
            )
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: foreignKey.publicKey.rawRepresentation
            )
            try Self.expectRejection(result, reason: "provenanceSignatureInvalid")
        }

        do {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            try Data("different-candidate-bytes".utf8).write(to: fixture.executableURL)
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(result, reason: "binarySHAMismatch")
        }

        do {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            let version = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.4",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(version, reason: "releaseVersionMismatch")
            let stale = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: String(repeating: "d", count: 40),
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(stale, reason: "releaseCommitMismatch")
        }

        for filename in ["evidence-manifest.json", "case-manifest.json"] {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            let url = fixture.directory.appendingPathComponent(filename)
            var data = try Data(contentsOf: url)
            data.append(Data("\n ".utf8))
            try data.write(to: url)
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(result, reason: "evidenceBindingMismatch")
        }

        do {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            let attestation = try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: fixture.attestationURL)
            )
            let evidence = try #require(attestation.cases.first?.evidenceFiles.first)
            try Data("tampered".utf8).write(
                to: fixture.directory.appendingPathComponent(evidence)
            )
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(result, reason: "evidenceBindingMismatch")
        }

        do {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(
                at: fixture.directory.appendingPathComponent("raw-transcript.json")
            )
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(result, reason: "missingArtifact")
        }

        do {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            try Data("{}".utf8).write(
                to: fixture.directory.appendingPathComponent("mutation-restore-compensation.json")
            )
            let result = QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
            try Self.expectRejection(result, reason: "requiredArtifactSchemaInvalid")
        }

        do {
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
                "missing-trusted-verifier-bundle-\(UUID().uuidString)"
            )
            let result = QualificationRunner.verifyTrusted(
                candidateURL: missing.appendingPathComponent("candidate"),
                bundleURL: missing,
                releaseVersion: "1.2.3",
                expectedCommitSHA: String(repeating: "c", count: 40),
                trustedPublicKeyData: Data(repeating: 1, count: 32)
            )
            try Self.expectRejection(result, reason: "verifierFailure")
        }

        do {
            let fixture = try trustedFixture()
            defer { fixture.remove() }
            try #require((await fixture.runQualification(waiversURL: fixture.waiversURL)).exitCode == 0)
            let result = QualificationRunner.runTrusted(arguments: [
                "trusted-verifier", "sign",
                "--candidate", fixture.executableURL.path,
                "--bundle", fixture.directory.path,
                "--release-version", "1.2.3",
                "--expected-commit", fixture.commitSHA,
            ], environment: [:])
            try Self.expectRejection(result, reason: "signingKeyUnavailable")
            let attestation = try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: fixture.attestationURL)
            )
            #expect(attestation.provenanceSignature == nil)
        }

        do {
            let fixture = try trustedFixture()
            defer { fixture.remove() }
            try #require((await fixture.runQualification(waiversURL: fixture.waiversURL)).exitCode == 0)
            try Self.mutateJSONObject(at: fixture.attestationURL) { object in
                var cases = try #require(object["cases"] as? [[String: Any]])
                let index = try #require(cases.firstIndex { $0["id"] as? String == QualificationAxis.defaultAxis.key })
                cases[index]["status"] = "failed"
                object["cases"] = cases
            }
            let signing = QualificationRunner.signTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                signingPrivateKeyData: fixture.signingKeyData
            )
            try Self.expectRejection(signing, reason: "requiredCaseFailed")
            let attestation = try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: fixture.attestationURL)
            )
            #expect(attestation.provenanceSignature == nil)
        }
    }

    private static func summaryCountRejections(_ result: QualificationCommandResult) throws -> [[String: Any]] {
        let rejections = try resultObject(result)["rejections"] as? [[String: Any]] ?? []
        return rejections.filter { $0["reason"] as? String == "summaryCountMismatch" }
    }

    /// #373 Q4. `total`/`passed`/`failed`/`waived` are not in the signed provenance record, so
    /// before the gate recomputed them a signed bundle with one count edited verified unchanged.
    /// Each field is edited alone -- a check keyed on one field would pass the other three.
    @Test func aSignedBundleWhoseCountDisagreesWithItsCasesIsRejected() async throws {
        for field in ["total", "passed", "failed", "waived"] {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            let verify = {
                QualificationRunner.verifyTrusted(
                    candidateURL: fixture.executableURL,
                    bundleURL: fixture.directory,
                    releaseVersion: "1.2.3",
                    expectedCommitSHA: fixture.commitSHA,
                    trustedPublicKeyData: fixture.trustedPublicKeyData
                )
            }
            let control = verify()
            try #require(control.exitCode == 0, "\(field): \(control.stdout)")

            var recomputed = 0
            try Self.mutateJSONObject(at: fixture.attestationURL) { object in
                recomputed = try #require(object[field] as? Int)
                object[field] = recomputed + 1
            }
            let result = verify()

            try Self.expectRejection(result, reason: "summaryCountMismatch")
            let mismatches = try Self.summaryCountRejections(result)
            #expect(mismatches.count == 1, "\(field): \(result.stdout)")
            #expect(mismatches.first?["key"] as? String == field)
            #expect(mismatches.first?["actual"] as? String == String(recomputed + 1))
            #expect(mismatches.first?["expected"] as? String == String(recomputed))
        }
    }

    @Test func theSignerRefusesCountsItsCasesDoNotImplyAndLeavesTheBundleUnsigned() async throws {
        let fixture = try trustedFixture()
        defer { fixture.remove() }
        try #require((await fixture.runQualification(waiversURL: fixture.waiversURL)).exitCode == 0)
        let sign = {
            QualificationRunner.signTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                signingPrivateKeyData: fixture.signingKeyData
            )
        }
        var original = 0
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            original = try #require(object["passed"] as? Int)
            object["passed"] = original + 1
        }

        let refused = sign()

        try Self.expectRejection(refused, reason: "summaryCountMismatch")
        let unsigned = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(unsigned.provenanceSignature == nil)

        // Positive control on the same bundle: put the count back and the same signer signs it,
        // so the refusal above was the count and nothing else about this fixture.
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            object["passed"] = original
        }
        let signed = sign()
        #expect(signed.exitCode == 0, "\(signed.stdout)")
    }

    @Test func promotionVerifierRejectsCountsItsCasesDoNotImply() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let control = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        try #require(control.exitCode == 0, "\(control.stdout)")

        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            object["failed"] = try #require(object["failed"] as? Int) + 1
        }
        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        try Self.expectRejection(result, reason: "summaryCountMismatch")
        #expect(try Self.summaryCountRejections(result).first?["key"] as? String == "failed")
    }

    /// #373 Q4. A blocking `O_RDONLY` open of a FIFO waits for a writer, and nothing here ever
    /// opens one for writing: before `readNoFollow` opened without blocking, each call below
    /// never returned. Each site is a different read -- the attestation, the evidence manifest,
    /// the candidate, the bundle directory itself -- through the verifier, the signer and
    /// `--verify-promotion`.
    @Test func aFIFOPlantedInTheBundleOrAsTheCandidateIsRefusedWithoutWaitingForAWriter() async throws {
        func plantFIFO(at url: URL) throws {
            try FileManager.default.removeItem(at: url)
            try #require(mkfifo(url.path, 0o600) == 0)
        }
        func verifyTrusted(_ fixture: Fixture, bundleURL: URL? = nil) -> QualificationCommandResult {
            QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: bundleURL ?? fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
        }

        for planted in ["attestation", "evidence-manifest", "candidate"] {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            try #require(verifyTrusted(fixture).exitCode == 0, "\(planted): control")
            switch planted {
            case "attestation": try plantFIFO(at: fixture.attestationURL)
            case "evidence-manifest": try plantFIFO(at: fixture.manifestURL)
            default: try plantFIFO(at: fixture.executableURL)
            }
            let result = verifyTrusted(fixture)
            #expect(result.exitCode != 0, "\(planted): \(result.stdout)")
            let v1 = try #require(try Self.resultObject(result)["promotable"] as? Bool)
            #expect(!v1, "\(planted)")
        }

        do {
            let fixture = try await signedTrustedFixture()
            defer { fixture.remove() }
            let bundleFIFO = fixture.directory.appendingPathComponent("bundle-fifo")
            try #require(mkfifo(bundleFIFO.path, 0o600) == 0)
            let result = verifyTrusted(fixture, bundleURL: bundleFIFO)
            #expect(result.exitCode != 0, "\(result.stdout)")
            #expect(result.stdout.contains("verifierFailure"), "\(result.stdout)")
        }

        do {
            let fixture = try trustedFixture()
            defer { fixture.remove() }
            try #require((await fixture.runQualification(waiversURL: fixture.waiversURL)).exitCode == 0)
            try plantFIFO(at: fixture.attestationURL)
            let signing = QualificationRunner.signTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                signingPrivateKeyData: fixture.signingKeyData
            )
            #expect(signing.exitCode != 0, "\(signing.stdout)")
            #expect(signing.stdout.contains("signerFailure"), "\(signing.stdout)")
        }

        do {
            let fixture = try promotableFixture()
            defer { fixture.remove() }
            _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
            try plantFIFO(at: fixture.attestationURL)
            let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)
            #expect(result.exitCode != 0, "\(result.stdout)\(result.stderr)")
        }
    }

    /// RV-1076-01, at the rule. The runner passes an axis on `allChecksPass`, so the verifier
    /// must read each of those observations from the file rather than the axis's own `status`
    /// and `verified`. The evidence is the fixture's own passed axis, so the valid starting
    /// point is what the runner writes, and each observation is flipped on its own.
    @Test func anAxisCasePassesOnlyOnTheObservationsTheRunnerPassedItOn() async throws {
        let fixture = try trustedFixture()
        defer { fixture.remove() }
        let qualification = await fixture.runQualification(waiversURL: fixture.waiversURL)
        try #require(qualification.exitCode == 0, "\(qualification.stderr)")
        let original = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: try Self.passedAxisEvidenceURL(fixture))
            ) as? [String: Any]
        )
        func shapeIsValid(_ edit: (inout [String: Any]) -> Void) throws -> Bool {
            var object = original
            edit(&object)
            let evidence = try JSONDecoder().decode(
                CaseEvidence.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            return QualificationRunner.evidenceShapeIsValid(evidence)
        }

        #expect(try shapeIsValid { _ in }, "the runner's own passed axis is the positive control")
        // Health warms during cache polling and MCU registration, which is why
        // `isFailClosedAndStable` leaves it out; the verifier must not ask for more.
        #expect(try shapeIsValid { $0["health_read_stable"] = false })

        let refusals: [(String, (inout [String: Any]) -> Void)] = [
            ("negative_write_attempted true", { $0["negative_write_attempted"] = true }),
            ("negative_write_attempted absent", { $0.removeValue(forKey: "negative_write_attempted") }),
            ("negative_failclosed false", { $0["negative_failclosed"] = false }),
            ("negative_state B", { $0["negative_state"] = "B" }),
            ("negative_state absent", { $0.removeValue(forKey: "negative_state") }),
            ("catalog_read_stable false", { $0["catalog_read_stable"] = false }),
            ("handshake_ok false", { $0["handshake_ok"] = false }),
            ("health_ok false", { $0["health_ok"] = false }),
            ("catalog_count_match false", { $0["catalog_count_match"] = false }),
            ("trace_ok false", { $0["trace_ok"] = false }),
        ]
        for (label, edit) in refusals {
            #expect(try !shapeIsValid(edit), "\(label)")
        }
    }

    /// RV-1076-01, end to end: the reviewer's counterexample. The passed axis's evidence says its
    /// probe wrote and did not fail closed, and every digest above it is resealed, so the only
    /// thing left to refuse is what the file says. Signing must refuse and leave no signature,
    /// and an authentically signed copy must not verify. The same bundle with its original bytes
    /// is the control for both, and a force-signed original is the control on the forced
    /// signature, so neither refusal can come from a digest or a signature this test broke.
    @Test func anAxisWhoseProbeWroteIsNeitherSignedNorVerified() async throws {
        let fixture = try trustedFixture()
        defer { fixture.remove() }
        let qualification = await fixture.runQualification(waiversURL: fixture.waiversURL)
        try #require(qualification.exitCode == 0, "\(qualification.stderr)")
        let evidenceURL = try Self.passedAxisEvidenceURL(fixture)
        let originals = try [evidenceURL, fixture.manifestURL, fixture.attestationURL].map {
            ($0, try Data(contentsOf: $0))
        }
        func restoreOriginals() throws {
            for (url, data) in originals { try data.write(to: url, options: .atomic) }
        }
        func writeCounterexample() throws {
            try Self.rewritePassedAxisEvidence(fixture) {
                $0["negative_write_attempted"] = true
                $0["negative_failclosed"] = false
            }
        }
        func sign() -> QualificationCommandResult {
            QualificationRunner.signTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                signingPrivateKeyData: fixture.signingKeyData
            )
        }
        func verify() -> QualificationCommandResult {
            QualificationRunner.verifyTrusted(
                candidateURL: fixture.executableURL,
                bundleURL: fixture.directory,
                releaseVersion: "1.2.3",
                expectedCommitSHA: fixture.commitSHA,
                trustedPublicKeyData: fixture.trustedPublicKeyData
            )
        }

        try writeCounterexample()
        let refused = sign()
        #expect(refused.exitCode != 0, "\(refused.stdout)")
        try Self.expectOnlyTheAxisShapeRejection(refused)
        let unsigned = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(unsigned.provenanceSignature == nil, "a refused signing must leave no signature")

        try restoreOriginals()
        let signed = sign()
        try #require(signed.exitCode == 0, "the original bytes sign: \(signed.stdout)")
        let verified = verify()
        #expect(verified.exitCode == 0, "the signed original verifies: \(verified.stdout)")

        try fixture.forceSignForDiagnosticFixture()
        let forcedOriginal = verify()
        #expect(forcedOriginal.exitCode == 0, "a forced signature verifies: \(forcedOriginal.stdout)")

        try writeCounterexample()
        try fixture.forceSignForDiagnosticFixture()
        let forcedCounterexample = verify()
        #expect(forcedCounterexample.exitCode != 0, "\(forcedCounterexample.stdout)")
        try Self.expectOnlyTheAxisShapeRejection(forcedCounterexample)
    }

    /// The evidence file of the one axis case the fixture passes, as the attestation names it.
    private static func passedAxisEvidenceURL(_ fixture: Fixture) throws -> URL {
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        let axisCases = attestation.cases.filter {
            $0.verificationKind == .independentReadback && $0.status == .passed
        }
        try #require(axisCases.count == 1, "\(axisCases.map(\.id))")
        let path = try #require(axisCases[0].evidenceFiles.first)
        return fixture.directory.appendingPathComponent(path)
    }

    /// Rewrites the passed axis's evidence and reseals every digest above it: its manifest
    /// entry, the manifest, and the attestation's and the provenance's copies of the manifest
    /// digest. The signature is left as it was, so a caller that wants a signed bundle signs it.
    private static func rewritePassedAxisEvidence(
        _ fixture: Fixture,
        _ edit: (inout [String: Any]) -> Void
    ) throws {
        let evidenceURL = try passedAxisEvidenceURL(fixture)
        let path = String(evidenceURL.path.dropFirst(fixture.directory.path.count + 1))
        var evidence = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String: Any]
        )
        edit(&evidence)
        let evidenceData = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        try evidenceData.write(to: evidenceURL, options: .atomic)

        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL)) as? [String: Any]
        )
        var entries = try #require(manifest["files"] as? [[String: Any]])
        let entryIndex = try #require(entries.firstIndex { $0["path"] as? String == path })
        entries[entryIndex]["sha256"] = SupportBundleBuilder.sha256(evidenceData)
        manifest["files"] = entries
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: fixture.manifestURL, options: .atomic)

        let manifestSHA256 = SupportBundleBuilder.sha256(manifestData)
        try mutateJSONObject(at: fixture.attestationURL) { attestation in
            attestation["evidenceManifestSHA256"] = manifestSHA256
            var provenance = try #require(attestation["provenance"] as? [String: Any])
            provenance["evidenceManifestSHA256"] = manifestSHA256
            attestation["provenance"] = provenance
        }
    }

    /// Exactly one rejection, and it is the case-evidence check, not a digest or a signature.
    private static func expectOnlyTheAxisShapeRejection(_ result: QualificationCommandResult) throws {
        let rejections = try #require(try resultObject(result)["rejections"] as? [[String: Any]])
        #expect(rejections.count == 1, "\(result.stdout)")
        #expect(rejections.first?["reason"] as? String == "evidenceBindingMismatch", "\(result.stdout)")
        #expect(rejections.first?["actual"] as? String == "case evidence binding", "\(result.stdout)")
    }

    @Test func cachedConsumerMatrixCopiesRemainVerifierAcceptedAndIndependent() async throws {
        let verifier = Self.releaseConsumerVerifierURL
        try #require(FileManager.default.isExecutableFile(atPath: verifier.path))
        let first = try await cachedConsumerSignedTrustedMatrixFixture()
        let second = try await cachedConsumerSignedTrustedMatrixFixture()
        defer {
            first.remove()
            second.remove()
        }

        #expect(first.directory != second.directory)
        #expect(first.executableURL != second.executableURL)
        #expect(first.binarySHA256 == second.binarySHA256)
        let secondAttestation = try Data(contentsOf: second.enMatrixAttestationURL)
        for fixture in [first, second] {
            let accepted = try Self.runTrustedMatrixVerifierExecutable(
                fixture,
                verifierURL: verifier
            )
            try #require(accepted.exitCode == 0, "\(accepted.stdout)\(accepted.stderr)")
        }

        try Self.mutateJSONObject(at: first.enMatrixAttestationURL) { object in
            object["passed"] = try #require(object["passed"] as? Int) + 1
        }
        let rejected = try Self.runTrustedMatrixVerifierExecutable(first, verifierURL: verifier)
        #expect(rejected.exitCode != 0, "\(rejected.stdout)\(rejected.stderr)")
        #expect(try Data(contentsOf: second.enMatrixAttestationURL) == secondAttestation)
        let stillAccepted = try Self.runTrustedMatrixVerifierExecutable(second, verifierURL: verifier)
        #expect(stillAccepted.exitCode == 0, "\(stillAccepted.stdout)\(stillAccepted.stderr)")
    }


    /// #373 Q4 through the shipped `trusted-verifier` executable, not the in-process entry point:
    /// one signed bundle is accepted as built, rejected once a count is edited, and refused -- by
    /// returning, not by waiting for a writer -- once its attestation is a FIFO. The in-process
    /// answer on the same bundle is the control, so a wrapper that lost the exit code, the
    /// arguments or the trusted key would fail the first comparison rather than pass as a refusal.
    ///
    /// A missing executable FAILS rather than skips. `swift test` builds every product in the
    /// package, this one included (2026-10-01: removed, the next filtered `swift test` rebuilt
    /// it), so absence means a run that skipped the build or started outside the package root,
    /// and a skip would have passed a run that never drove the shipped binary.
    @Test(.timeLimit(.minutes(2)))
    func theTrustedVerifierExecutableRejectsAnEditedCountAndAFIFOAttestation() async throws {
        try #require(
            FileManager.default.isExecutableFile(atPath: Self.trustedVerifierExecutableURL.path),
            "no trusted-verifier at \(Self.trustedVerifierExecutableURL.path): build the product"
        )
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let inProcess = QualificationRunner.verifyTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            trustedPublicKeyData: fixture.trustedPublicKeyData
        )
        try #require(inProcess.exitCode == 0, "\(inProcess.stdout)")

        let control = try Self.runTrustedVerifierExecutable(fixture)
        #expect(control.exitCode == inProcess.exitCode, "\(control.stdout)\(control.stderr)")
        let promotable = try #require(try Self.resultObject(control)["promotable"] as? Bool)
        #expect(promotable)

        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            let passed = try #require(object["passed"] as? Int)
            object["passed"] = passed + 1
        }
        try Self.expectRejection(try Self.runTrustedVerifierExecutable(fixture), reason: "summaryCountMismatch")

        try FileManager.default.removeItem(at: fixture.attestationURL)
        try #require(mkfifo(fixture.attestationURL.path, 0o600) == 0)
        let fifo = try Self.runTrustedVerifierExecutable(fixture)
        #expect(fifo.exitCode != 0, "\(fifo.stdout)\(fifo.stderr)")
        let fifoPromotable = try #require(try Self.resultObject(fifo)["promotable"] as? Bool)
        #expect(!fifoPromotable)
    }

    /// #816 controlled directory representation, not a public live release or deployed anchor.
    /// The consumer executable and synthetic trust input remain outside the copied bundle.
    @Test(.timeLimit(.minutes(2)))
    func controlledPublicationCopyVerifiesWithExistingDebugConsumer() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.trustedVerifierExecutableURL.path))
        let toolBytes = try Data(contentsOf: Self.trustedVerifierExecutableURL)
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("issue816-candidate-executed-\(UUID().uuidString)")
        let fixture = try await signedTrustedFixture(candidateExecutionSentinelURL: sentinel)
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: sentinel)
        }
        let original = try Self.runTrustedVerifierExecutable(fixture)
        try #require(original.exitCode == 0, "\(original.stdout)\(original.stderr)")
        let copy = try Self.copiedControlledPublication(fixture)
        defer { try? FileManager.default.removeItem(at: copy.root) }
        #expect(try Self.controlledPublicationFiles(copy.bundle)
            == Self.controlledPublicationFiles(fixture.directory))
        let result = try Self.runTrustedVerifierExecutable(
            fixture,
            candidateURL: copy.bundle.appendingPathComponent(fixture.executableURL.lastPathComponent),
            bundleURL: copy.bundle
        )
        #expect(result.exitCode == 0, "\(result.stdout)\(result.stderr)")
        let promotable = try #require(try Self.resultObject(result)["promotable"] as? Bool)
        #expect(promotable)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(try Data(contentsOf: Self.trustedVerifierExecutableURL) == toolBytes)
    }

    /// Existing security contract: repairing adjacent hashes cannot repair an old signature.
    /// Whitespace changes a raw artifact's bytes without changing frames/schema/public hashes.
    @Test(.timeLimit(.minutes(2)))
    func debugConsumerRejectsPublishedFileAndCoherentAdjacentDigestReplacement() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.trustedVerifierExecutableURL.path))
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let copy = try Self.copiedControlledPublication(fixture)
        defer { try? FileManager.default.removeItem(at: copy.root) }
        let candidateURL = copy.bundle.appendingPathComponent(fixture.executableURL.lastPathComponent)
        let verify = {
            try Self.runTrustedVerifierExecutable(fixture, candidateURL: candidateURL, bundleURL: copy.bundle)
        }
        let control = try verify()
        try #require(control.exitCode == 0, "\(control.stdout)\(control.stderr)")
        let rawURL = copy.bundle.appendingPathComponent("raw-transcript.json")
        let manifestURL = copy.bundle.appendingPathComponent("evidence-manifest.json")
        let attestationURL = copy.bundle.appendingPathComponent("release-qualification-attestation.json")
        let originalRaw = try Data(contentsOf: rawURL)
        let originalManifest = try Data(contentsOf: manifestURL)
        let originalAttestation = try Data(contentsOf: attestationURL)
        let signed = try JSONDecoder().decode(ReleaseQualificationAttestation.self, from: originalAttestation)
        let signature = try #require(signed.provenanceSignature)
        var changedRaw = originalRaw
        changedRaw.append(0x0a)
        try changedRaw.write(to: rawURL, options: .atomic)
        var manifest = try #require(JSONSerialization.jsonObject(with: originalManifest) as? [String: Any])
        var entries = try #require(manifest["files"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { $0["path"] as? String == "raw-transcript.json" })
        entries[index]["sha256"] = SupportBundleBuilder.sha256(changedRaw)
        manifest["files"] = entries
        let changedManifest = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try changedManifest.write(to: manifestURL, options: .atomic)
        let changedManifestDigest = SupportBundleBuilder.sha256(changedManifest)
        try Self.mutateJSONObject(at: attestationURL) { object in
            object["evidenceManifestSHA256"] = changedManifestDigest
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["evidenceManifestSHA256"] = changedManifestDigest
            object["provenance"] = provenance
        }
        let changed = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self, from: Data(contentsOf: attestationURL))
        #expect(changed.provenanceSignature == signature)
        let result = try verify()
        #expect(result.exitCode != 0, "\(result.stdout)\(result.stderr)")
        let promotable = try #require(try Self.resultObject(result)["promotable"] as? Bool)
        #expect(!promotable)
        let rejections = try #require(try Self.resultObject(result)["rejections"] as? [[String: Any]])
        #expect(rejections.count == 1, "\(result.stdout)")
        #expect(rejections.first?["reason"] as? String == "provenanceSignatureInvalid", "\(result.stdout)")
        try originalRaw.write(to: rawURL, options: .atomic)
        try originalManifest.write(to: manifestURL, options: .atomic)
        try originalAttestation.write(to: attestationURL, options: .atomic)
        let restored = try verify()
        #expect(restored.exitCode == 0, "\(restored.stdout)\(restored.stderr)")
        #expect(try Self.controlledPublicationFiles(copy.bundle)
            == Self.controlledPublicationFiles(fixture.directory))
    }

    /// Separate metadata characterization; source suggests a gap, but no runtime RED is assumed.
    /// The debug consumer's actual typed report must decide whether this becomes a repair lead.
    @Test(.timeLimit(.minutes(2)))
    func debugConsumerCharacterizesLogicVersionOnlyUnsignedMetadataMutation() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.trustedVerifierExecutableURL.path))
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let copy = try Self.copiedControlledPublication(fixture)
        defer { try? FileManager.default.removeItem(at: copy.root) }
        let candidateURL = copy.bundle.appendingPathComponent(fixture.executableURL.lastPathComponent)
        let verify = {
            try Self.runTrustedVerifierExecutable(fixture, candidateURL: candidateURL, bundleURL: copy.bundle)
        }
        let control = try verify()
        try #require(control.exitCode == 0, "\(control.stdout)\(control.stderr)")
        let originalFiles = try Self.controlledPublicationFiles(copy.bundle)
        let attestationURL = copy.bundle.appendingPathComponent("release-qualification-attestation.json")
        let originalData = try Data(contentsOf: attestationURL)
        let original = try JSONDecoder().decode(ReleaseQualificationAttestation.self, from: originalData)
        let originalSignature = try #require(original.provenanceSignature)
        let originalObject = try #require(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        let replacement = original.logicVersion == "999.0" ? "998.0" : "999.0"
        try Self.mutateJSONObject(at: attestationURL) { $0["logicVersion"] = replacement }
        let changedData = try Data(contentsOf: attestationURL)
        let changed = try JSONDecoder().decode(ReleaseQualificationAttestation.self, from: changedData)
        #expect(changed.logicVersion == replacement)
        #expect(changed.provenanceSignature == originalSignature)
        var expectedObject = originalObject
        expectedObject["logicVersion"] = replacement
        #expect(try JSONSerialization.data(withJSONObject: expectedObject, options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject:
                JSONSerialization.jsonObject(with: changedData), options: [.sortedKeys]))
        var changedFiles = try Self.controlledPublicationFiles(copy.bundle)
        changedFiles.removeValue(forKey: "release-qualification-attestation.json")
        var unchangedFiles = originalFiles
        unchangedFiles.removeValue(forKey: "release-qualification-attestation.json")
        #expect(changedFiles == unchangedFiles)
        let result = try verify()
        print("#816 logicVersion-only characterization: \(result.stdout)")
        let promotable = try #require(try Self.resultObject(result)["promotable"] as? Bool)
        #expect(!promotable, "metadata changed under unchanged signature: \(result.stdout)")
        #expect(result.exitCode != 0, "\(result.stdout)\(result.stderr)")
        try originalData.write(to: attestationURL, options: .atomic)
        let restored = try verify()
        #expect(restored.exitCode == 0, "\(restored.stdout)\(restored.stderr)")
        #expect(try Self.controlledPublicationFiles(copy.bundle) == originalFiles)
    }

    /// Historical v1 bytes remain readable, never silently upgraded to the current schema.
    @Test func legacyV1ProvenanceRemainsDecodableWithoutInventedLogicVersion() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let data = try Data(contentsOf: fixture.attestationURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var legacy = try #require(object["provenance"] as? [String: Any])
        legacy["schema"] = "qualification-provenance/v1"
        legacy.removeValue(forKey: "logicVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(QualificationProvenanceRecord.self, from: legacyData)
        #expect(decoded.schema == "qualification-provenance/v1")
        let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(roundTrip["logicVersion"] == nil)
        #expect(try JSONSerialization.data(withJSONObject: roundTrip, options: [.sortedKeys]) == legacyData)
    }

    /// Force-signing is test-only: it proves legacy refusal is not an invalid-key artifact.
    @Test func legacyV1ProvenanceCannotBeNewlySignedOrTrustedAsQualified() async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["schema"] = "qualification-provenance/v1"
            provenance.removeValue(forKey: "logicVersion")
            object["provenance"] = provenance
            object.removeValue(forKey: "provenanceSignature")
        }
        let sign = QualificationRunner.signTrusted(
            candidateURL: fixture.executableURL, bundleURL: fixture.directory,
            releaseVersion: "1.2.3", expectedCommitSHA: fixture.commitSHA,
            signingPrivateKeyData: fixture.signingKeyData)
        try Self.expectRejection(sign, reason: "provenanceSignatureInvalid")
        let unsigned = try JSONDecoder().decode(ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL))
        #expect(unsigned.provenanceSignature == nil)
        try fixture.forceSignForDiagnosticFixture()
        try Self.expectRejection(try Self.runTrustedVerifierExecutable(fixture),
            reason: "provenanceSignatureInvalid")
    }

    /// Re-signed counterexamples isolate binding, not signature damage or missing trust.
    @Test(arguments: ["missing", "different"])
    func signedCurrentProvenanceRequiresExactLogicVersionBinding(_ mutation: String) async throws {
        let fixture = try await signedTrustedFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.attestationURL)
        try Self.mutateJSONObject(at: fixture.attestationURL) { object in
            var provenance = try #require(object["provenance"] as? [String: Any])
            try #require(provenance["schema"] as? String == "qualification-provenance/v3")
            if mutation == "missing" {
                provenance.removeValue(forKey: "logicVersion")
            } else {
                let version = try #require(object["logicVersion"] as? String)
                provenance["logicVersion"] = version == "999.0" ? "998.0" : "999.0"
            }
            object["provenance"] = provenance
        }
        try fixture.forceSignForDiagnosticFixture()
        try Self.expectRejection(try Self.runTrustedVerifierExecutable(fixture),
            reason: "provenanceSignatureInvalid")
        try original.write(to: fixture.attestationURL, options: .atomic)
        let restored = try Self.runTrustedVerifierExecutable(fixture)
        #expect(restored.exitCode == 0, "\(restored.stdout)\(restored.stderr)")
    }

    private static func copiedControlledPublication(_ fixture: Fixture) throws -> (root: URL, bundle: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue816-consumer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: fixture.directory, to: bundle)
            return (root, bundle)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Synthetic fixture census only, not a second public manifest or archive extraction policy.
    private static func controlledPublicationFiles(_ directory: URL) throws -> [String: Data] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let isSymbolicLink = try #require(values.isSymbolicLink)
            #expect(!isSymbolicLink)
            if values.isRegularFile ?? false {
                let enumeratedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                try #require(enumeratedPath.hasPrefix(prefix))
                let relativePath = String(enumeratedPath.dropFirst(prefix.count))
                files[relativePath] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private static let trustedVerifierExecutableURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(".build/debug/trusted-verifier")

    private static var releaseConsumerVerifierURL: URL {
        if let path = ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_TEST_RELEASE_VERIFIER"] {
            return URL(fileURLWithPath: path)
        }
        return trustedVerifierExecutableURL
    }

    private static let consumerMatrixSnapshotCache = ConsumerMatrixSnapshotCache()

    private static func runTrustedVerifierExecutable(
        _ fixture: Fixture,
        candidateURL: URL? = nil,
        bundleURL: URL? = nil,
        verifierURL: URL? = nil
    ) throws -> QualificationCommandResult {
        let process = Process()
        process.executableURL = verifierURL ?? trustedVerifierExecutableURL
        process.arguments = [
            "verify",
            "--candidate", (candidateURL ?? fixture.executableURL).path,
            "--bundle", (bundleURL ?? fixture.directory).path,
            "--release-version", "1.2.3",
            "--expected-commit", fixture.commitSHA,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY"] =
            fixture.trustedPublicKeyData.base64EncodedString()
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return QualificationCommandResult(
            exitCode: Int(process.terminationStatus),
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    private static func runTrustedMatrixVerifierExecutable(
        _ fixture: any TrustedMatrixFixtureView,
        verifierURL: URL? = nil
    ) throws -> QualificationCommandResult {
        let process = Process()
        process.executableURL = verifierURL ?? trustedVerifierExecutableURL
        process.arguments = [
            "verify-matrix",
            "--candidate", fixture.executableURL.path,
            "--matrix-index", fixture.inputURL.path,
            "--release-version", "1.2.3",
            "--expected-commit", fixture.commitSHA,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY"] =
            fixture.trustedPublicKeyData.base64EncodedString()
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return QualificationCommandResult(
            exitCode: Int(process.terminationStatus),
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    @Test func qualificationRequiresCommitIdentityForSignedProvenance() async throws {
        let fixture = try Fixture(
            specs: Array(OperationRegistry.specs.prefix(1)),
            commitSHA: "unknown"
        )
        defer { fixture.remove() }

        let result = await fixture.runQualification()

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("commit identity"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func candidateQualificationProducesUnsignedBundleWithoutSigningKey() async throws {
        let fixture = try Fixture(
            specs: Array(OperationRegistry.specs.prefix(1)),
            includeSigningKey: false
        )
        defer { fixture.remove() }

        let result = await fixture.runQualification()

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        try #require(result.exitCode == 1)
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(attestation.provenance != nil)
        #expect(attestation.provenanceSignature == nil)
        let provenance = try #require(attestation.provenance)
        #expect(provenance.schema == "qualification-provenance/v3")
        #expect(provenance.logicVersion == attestation.logicVersion)
        #expect(provenance.logicVersion == "11.2")
    }

    @Test func signingKeyIsNotForwardedToQualificationSubprocess() async throws {
        let specs = Array(OperationRegistry.specs.prefix(1))
        let driveResult = Self.driveResult(specs: specs)
        let fixture = try Fixture(specs: specs, includeSigningKey: true, drive: { request in
            #expect(request.environment["LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY"] == nil)
            #expect(request.environment["LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY"] == nil)
            return driveResult
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(result.exitCode == 1)
    }

    @Test func qualificationDrivesImmutableSnapshotOfHashedExecutable() async throws {
        let specs = Array(OperationRegistry.specs.prefix(1))
        let originalData = Data("qualification-binary-fixture".utf8)
        let fixture = try Fixture(specs: specs, drive: { request in
            #expect(request.executableURL.deletingLastPathComponent().lastPathComponent.hasPrefix(
                "qualification-executable-snapshot-"
            ))
            let snapshotData = try Data(contentsOf: request.executableURL)
            #expect(snapshotData == originalData)
            return Self.driveResult(specs: specs)
        })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()

        #expect(attestation.binarySHA256 == SupportBundleBuilder.sha256(originalData))
    }

    @Test func symlinkSwapAtEvidenceReadBoundaryRejectsBundle() async throws {
        let swapper = EvidenceSymlinkSwap(targetName: "evidence-manifest.json")
        let fixture = try promotableFixture(beforeEvidenceRead: swapper.swap)
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(swapper.didSwap)
        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains(
            "evidenceBindingMismatch"
        ))
    }

    @Test func evidenceReplacedBetweenHashAndDecodeRejectsBundle() async throws {
        let replacer = EvidenceRegularFileReplacement(
            targetName: "operation-system.health-readback.json"
        )
        let fixture = try promotableFixture(beforeEvidenceRead: replacer.replaceAfterFirstRead)
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(replacer.didReplace)
        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains(
            "evidenceBindingMismatch"
        ))
    }

    @Test func hardLinkedEvidenceFileRejectsBundle() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let alias = fixture.directory.appendingPathComponent("manifest-hardlink.json")
        #expect(link(fixture.manifestURL.path, alias.path) == 0)

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains(
            "evidenceBindingMismatch"
        ))
    }

    @Test func emptyTraceListFailsWithoutObservedEvents() throws {
        let empty = Self.driveResult(
            specs: Array(OperationRegistry.specs.prefix(1)),
            tracePresent: false
        )
        let zeroEvent = Self.driveResult(
            specs: Array(OperationRegistry.specs.prefix(1)),
            tracePhases: []
        )
        let incomplete = Self.driveResult(
            specs: Array(OperationRegistry.specs.prefix(1)),
            tracePhases: ["request.received"]
        )
        let staleOperation = Self.driveResult(
            specs: Array(OperationRegistry.specs.prefix(1)),
            traceOperationID: .tracksRename
        )
        let observed = Self.driveResult(specs: Array(OperationRegistry.specs.prefix(1)))

        let v1 = try #require(empty.traceList?.traces.isEmpty)
        #expect(v1)
        #expect(!empty.traceOK)
        #expect(!empty.allChecksPass)
        #expect(!zeroEvent.traceOK)
        #expect(!incomplete.traceOK)
        #expect(!staleOperation.traceOK)
        #expect(observed.traceOK)
    }

    @Test func logicUILanguageMustMatchRequestedLocale() async throws {
        let specs = Array(OperationRegistry.specs.prefix(1))
        let driveResult = Self.driveResult(
            specs: specs,
            observedVariant: "desktop",
            observedLocale: "en-US"
        )
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--variant", "desktop",
            "--locale", "ko",
            "--release-version", "1.2.3",
        ])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Logic Pro UI locale"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func driveDerivesPassFromLiveProtocolNotRegistryBooleans() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let fixture = try Fixture(
            specs: [spec],
            registryValidationErrors: ["synthetic registry failure"],
            handlerValidationErrors: ["synthetic handler failure"],
            handlerExists: { _, _ in false }
        )
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let operationCase = try #require(attestation.cases.first {
            $0.tool == spec.tool.rawValue && $0.command == spec.command
        })
        let evidence = try fixture.evidence(for: operationCase)

        #expect(operationCase.status == .passed)
        #expect(operationCase.verified)
        let v1 = try #require(evidence["handshake_ok"] as? Bool)
        #expect(v1)
        let v2 = try #require(evidence["health_ok"] as? Bool)
        #expect(v2)
        let v3 = try #require(evidence["catalog_count_match"] as? Bool)
        #expect(v3)
        let v4 = try #require(evidence["trace_ok"] as? Bool)
        #expect(v4)
        let v5 = try #require(evidence["negative_failclosed"] as? Bool)
        #expect(v5)
        let v6 = try #require(evidence["registry_spec_found"] as? Bool)
        #expect(!v6)
        let v7 = try #require(evidence["handler_bound"] as? Bool)
        #expect(!v7)
    }

    @Test func handshakeTimeoutStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.requestTimeout(phase: "handshake")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        let cause = QualificationTransportError.requestTimeout(phase: "handshake")
        #expect(result.stderr == "Qualification failed: \(cause.description)\n")
        #expect(!result.stderr.contains("Logic Pro variant mismatch"))
        #expect(!result.stderr.contains("Logic Pro UI locale mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func nonZeroExitStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.nonZeroExit(status: 17, stderr: "fixture exit")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        let cause = QualificationTransportError.nonZeroExit(status: 17, stderr: "fixture exit")
        #expect(result.stderr == "Qualification failed: \(cause.description)\n")
        #expect(!result.stderr.contains("Logic Pro variant mismatch"))
        #expect(!result.stderr.contains("Logic Pro UI locale mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func malformedFrameStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.malformedFrame("not-json")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        let cause = QualificationTransportError.malformedFrame("not-json")
        #expect(result.stderr == "Qualification failed: \(cause.description)\n")
        #expect(!result.stderr.contains("Logic Pro variant mismatch"))
        #expect(!result.stderr.contains("Logic Pro UI locale mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func closedPipeStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.closedPipe(phase: "handshake")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        let cause = QualificationTransportError.closedPipe(phase: "handshake")
        #expect(result.stderr == "Qualification failed: \(cause.description)\n")
        #expect(!result.stderr.contains("Logic Pro variant mismatch"))
        #expect(!result.stderr.contains("Logic Pro UI locale mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func genuineObservedVariantMismatchStopsBeforeAttestation() async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let driveResult = Self.driveResult(
            specs: specs,
            observedVariant: "creator_studio",
            observedLocale: "en-US"
        )
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--variant", "desktop",
            "--locale", "en",
            "--release-version", "1.2.3",
        ])

        #expect(result.exitCode != 0)
        #expect(result.stderr ==
            "Qualification failed: Logic Pro variant mismatch: expected desktop, observed creator\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func catalogCountMismatchFailsCase() async throws {
        let specs = Array(OperationRegistry.specs.prefix(1))
        let driveResult = Self.driveResult(
            specs: specs,
            catalogCount: specs.count + 1
        )
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let operationCase = try #require(attestation.cases.first {
            $0.tool == specs[0].tool.rawValue && $0.command == specs[0].command
        })
        let evidence = try fixture.evidence(for: operationCase)

        #expect(operationCase.status == .notQualified)
        #expect(!operationCase.verified)
        let v1 = try #require(evidence["catalog_count_match"] as? Bool)
        #expect(!v1)
        let observedAxis = try #require(attestation.cases.first {
            $0.id == QualificationAxis.defaultAxis.key
        })
        #expect(observedAxis.status == .failed)
    }

    @Test func negativeFailclosedUsesCatalogAnchorDespiteHealthWarmup() {
        let healthBefore = Data(
            #"{"cache":{"track_count":0},"mcu":{"connected":false,"registered_as_device":false}}"#.utf8
        )
        let healthAfter = Data(
            #"{"cache":{"track_count":2},"mcu":{"connected":true,"registered_as_device":true}}"#.utf8
        )
        // DERIVED: a deliberately WRONG count, as "one fewer than the registry has". Pinning
        // `108` made this a test about a number rather than about a mismatch.
        let catalog = Data("{\"operation_count\":\(OperationRegistry.specs.count - 1)}".utf8)

        func result(
            state: String = "C",
            writeAttempted: Bool = false,
            catalogAfter: Data? = nil
        ) -> QualificationNegativeResult {
            QualificationNegativeResult(
                toolIsError: true,
                state: state,
                error: "invalid_params",
                writeAttempted: writeAttempted,
                healthBefore: healthBefore,
                healthAfter: healthAfter,
                catalogBefore: catalog,
                catalogAfter: catalogAfter ?? catalog
            )
        }

        let failClosed = result()
        #expect(!failClosed.healthReadStable)
        #expect(failClosed.catalogReadStable)
        #expect(failClosed.isFailClosedAndStable)
        #expect(!result(writeAttempted: true).isFailClosedAndStable)
        #expect(!result(catalogAfter: Data(#"{"operation_count":107}"#.utf8)).isFailClosedAndStable)
        #expect(!result(state: "B").isFailClosedAndStable)
    }

    @Test func observedAxisReadbackStaysVerifiedWhenHealthWarms() async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let driveResult = Self.driveResult(specs: specs, healthChangesAfterNegativeProbe: true)
        let v1 = try #require(driveResult.negative?.healthReadStable)
        #expect(!v1)
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }
        try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)

        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let verification = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(verification.exitCode == 0)
    }

    @Test func promotionAcceptsDigestBoundNonObjectOperationResponse() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .projectIsRunning })
        let driveResult = Self.driveResult(
            specs: [spec],
            nonObjectResponseOperationID: spec.id
        )
        let fixture = try Fixture(specs: [spec], drive: { _ in driveResult })
        defer { fixture.remove() }
        let waivers = [Self.waiver(caseID: "in-process/\(spec.id.rawValue)")] + Self.axisWaivers()
        try JSONEncoder().encode(waivers).write(to: fixture.waiversURL)

        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let verification = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(!Self.rejectionReasons(try Self.resultObject(verification)).contains(
            "evidenceBindingMismatch"
        ))
    }

    @Test func negativeMutatingCallOverTransportIsStateCZeroWrite() async throws {
        let spec = try #require(OperationRegistry.specs.first)
        let fixture = try Fixture(
            specs: [spec],
            registryValidationErrors: ["secondary registry evidence must not gate"],
            handlerExists: { _, _ in false }
        )
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let operationCase = try #require(attestation.cases.first {
            $0.tool == spec.tool.rawValue && $0.command == spec.command
        })
        let evidence = try fixture.evidence(for: operationCase)

        #expect(operationCase.status == .notQualified)
        #expect(!operationCase.verified)
        let v1 = try #require(evidence["negative_failclosed"] as? Bool)
        #expect(v1)
        #expect(evidence["negative_state"] as? String == "C")
        let v2 = try #require(evidence["negative_write_attempted"] as? Bool)
        #expect(!v2)
        let v3 = try #require(evidence["health_read_stable"] as? Bool)
        #expect(v3)
        let v4 = try #require(evidence["catalog_read_stable"] as? Bool)
        #expect(v4)
    }

    @Test func absentAxesRequireLocaleEvidenceOrWaiver() async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let fixture = try Fixture(specs: specs)
        defer { fixture.remove() }

        let withoutWaiver = try await fixture.qualify()
        let matchingID = "desktop/en-US/core/cold/empty"
        let matching = try #require(withoutWaiver.cases.first { $0.id == matchingID })
        let unavailable = withoutWaiver.cases.filter {
            QualificationAxis.requiredCombinations.map(\.key).contains($0.id)
                && $0.status == .notQualified
        }

        #expect(matching.status == .passed)
        #expect(unavailable.count == QualificationAxis.requiredCombinations.count - 1)
        #expect(unavailable.allSatisfy {
            $0.reason?.hasPrefix("required axis unavailable:") == true
                && $0.verificationKind == .typedDeferral
                && $0.deferral?.code == .operationUnavailable
                && $0.availabilityReason != nil
                && $0.readback?.verified == false
        })
        #expect(withoutWaiver.waivers.isEmpty)
        let rejected = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(rejected.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(rejected)).contains(
            "requiredCombinationNotQualified"
        ))
    }

    @Test func productionAxisVocabularyCanonicalizesLocaleAndKeepsCreatorOutOfShipAxes() async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let observedLocale = QualificationTransport.qualificationLocaleIdentifier("ko_KR")
        let driveResult = Self.driveResult(
            specs: specs,
            observedVariant: "creator_studio",
            observedLocale: observedLocale
        )
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }

        #expect(QualificationTransport.qualificationLocaleIdentifier("en_US") == "en-US")
        #expect(observedLocale == "ko-KR")
        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--variant", "creator",
            "--locale", "ko",
            "--release-version", "1.2.3",
        ])
        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(result.exitCode == 0)
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        // Creator Studio is permanently out of ship scope (owner decision,
        // ADR-001). A `--variant creator` run still canonicalizes the observed
        // axis vocabulary ("creator_studio" -> "creator", "ko_KR" -> "ko-KR")
        // for honest health reporting, but must NOT synthesize a promotable
        // creator required-axis case: only the desktop ship axes populate the
        // required matrix.
        #expect(attestation.cases.first { $0.id == "creator/ko-KR/core/cold/empty" } == nil)
        let requiredAxisIDs = attestation.cases
            .filter { !$0.id.hasPrefix("in-process/") }
            .map(\.id)
        #expect(requiredAxisIDs == QualificationAxis.requiredCombinations.map(\.key))
        #expect(requiredAxisIDs.allSatisfy { $0.hasPrefix("desktop/") })
        // The observed operation case still records the canonicalized creator
        // vocabulary — that is where canonicalization is asserted now that no
        // creator aggregate axis case exists.
        let observedOperation = try #require(attestation.cases.first {
            $0.id == "in-process/\(OperationID.systemHealth.rawValue)"
        })
        let evidence = try fixture.evidence(for: observedOperation)

        #expect(attestation.logicVariant == .creatorStudio)
        #expect(attestation.logicVersion == "11.2")
        #expect(attestation.locale == .koKR)
        #expect(evidence["observed_variant"] as? String == "creator")
        #expect(evidence["observed_locale"] as? String == "ko-KR")
    }

    @Test func handshakeSucceedsWhenFirstFrameArrivesAfterPerCallButWithinStartupBudget() throws {
        let fixture = try SlowHandshakeFixture()
        defer { fixture.remove() }
        var environment = ProcessInfo.processInfo.environment
        environment["HANDSHAKE_DELAY"] = "0.2"
        let productionTransport = QualificationTransport()
        #expect(productionTransport.handshakeTimeout >= 30)
        #expect(productionTransport.requestTimeout == 10)

        do {
            let result = try QualificationTransport(
                handshakeTimeout: 5,
                requestTimeout: 0.1,
                shutdownGrace: 1
            ).drive(.init(
                executableURL: fixture.executableURL,
                environment: environment,
                expectedOperationCount: 0
            ))
            #expect(result.allChecksPass)
            #expect(result.traceDetail?.operationID == OperationID.systemSagaExecute.rawValue)
        } catch {
            Issue.record("Handshake first frame within startup budget should succeed: \(error)")
        }
    }

    @Test func liveGateSummaryNamesReadbackTimeoutAndMissingRefusal() throws {
        let readSpec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let mutatingSpec = try #require(OperationRegistry.specs.first { $0.id == .transportStop })
        let readbackTimeout = QualificationOperationResult(
            operationID: readSpec.id.rawValue,
            tool: readSpec.tool.rawValue,
            command: readSpec.command,
            mutability: readSpec.mutability,
            requestID: "timed-out-read",
            responseData: Data(#"{"logic_pro_running":true}"#.utf8),
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "timed-out-readback",
            readbackData: nil,
            failureReason: QualificationTransport.observedFailureReason(
                from: QualificationTransportError.requestTimeout(phase: "timed-out-readback"),
                during: "independent readback"
            )
        )
        let missingRefusal = QualificationOperationResult(
            operationID: mutatingSpec.id.rawValue,
            tool: mutatingSpec.tool.rawValue,
            command: mutatingSpec.command,
            mutability: mutatingSpec.mutability,
            requestID: "missing-refusal",
            responseData: Data(#"{"state":"A","write_attempted":false}"#.utf8),
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://transport/state",
            readbackRequestID: "missing-refusal-readback",
            readbackData: Data(#"{"is_playing":false}"#.utf8),
            failureReason: nil
        )

        let summary = QualificationLiveGateSummary(
            operationResults: [readbackTimeout, missingRefusal]
        )
        let readbackFailure = try #require(summary.failures.first {
            $0.operationID == readSpec.id.rawValue
        })
        let refusalFailure = try #require(summary.failures.first {
            $0.operationID == mutatingSpec.id.rawValue
        })
        let failureLine = try #require(summary.failureLine)

        #expect(readbackFailure.failureReason.contains("independent readback timeout"))
        #expect(refusalFailure.failureReason.contains("missing expected typed zero-write refusal"))
        #expect(readbackFailure.failureReason != refusalFailure.failureReason)
        #expect(failureLine.contains("failureReason=independent readback timeout"))
        #expect(failureLine.contains("failureReason=operation request missing expected typed zero-write refusal"))
    }

    @Test func liveGateSummaryFailsAnInScopeSemanticShortfall() throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let shortfall = QualificationOperationResult(
            operationID: spec.id.rawValue,
            tool: spec.tool.rawValue,
            command: spec.command,
            mutability: spec.mutability,
            requestID: "semantic-shortfall",
            responseData: Data(#"{"logic_pro_running":true}"#.utf8),
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "semantic-shortfall-readback",
            readbackData: Data(#"{"logic_pro_running":false}"#.utf8),
            failureReason: nil
        )

        let summary = QualificationLiveGateSummary(operationResults: [shortfall])
        let failure = try #require(summary.failures.first)

        #expect(shortfall.status == .notQualified)
        #expect(shortfall.liveGateDisposition == .failed)
        #expect(failure.failureReason.contains("semantic readback mismatch"))
    }

    @Test func qualificationProbeSuppliesSpectralOperationPaths() throws {
        let spectrum = try #require(OperationRegistry.specs.first { $0.id == .audioAnalyzeSpectrum })
        let recommendEQ = try #require(OperationRegistry.specs.first { $0.id == .audioRecommendEQ })
        let compare = try #require(OperationRegistry.specs.first { $0.id == .audioCompareSpectra })

        let spectrumPath = QualificationTransport.probeParams(
            for: spectrum,
            traceID: "trace"
        )["path"] as? String
        let recommendationPath = QualificationTransport.probeParams(
            for: recommendEQ,
            traceID: "trace"
        )["path"] as? String
        let recommendationMinimumLevel = QualificationTransport.probeParams(
            for: recommendEQ,
            traceID: "trace"
        )["minimum_level"] as? Double
        let suppliesRealPathToBothSpectralOperations = spectrumPath
            == QualificationTransport.qualificationAudioProbePath
            && recommendationPath == QualificationTransport.qualificationAudioProbePath
            && recommendationMinimumLevel == 0.5

        #expect(suppliesRealPathToBothSpectralOperations)
        let comparison = QualificationTransport.probeParams(for: compare, traceID: "trace")
        #expect(comparison["before_path"] as? String == QualificationTransport.qualificationAudioProbePath)
        #expect(comparison["after_path"] as? String == QualificationTransport.qualificationAudioProbePath)
    }

    @Test func comparisonProbeReachesAnalysisAndPreservesMissingFileRefusal() throws {
        let compare = try #require(OperationRegistry.specs.first { $0.id == .audioCompareSpectra })
        let params = QualificationTransport.probeParams(for: compare, traceID: "trace")
            .compactMapValues { ($0 as? String).map(Value.string) }
        var requestedPaths: [String] = []
        let runtime = AudioAnalyzer.Runtime(
            fileExists: { path, _ in requestedPaths.append(path); return false },
            attributesOfItem: { _ in Issue.record("Missing input must not reach metadata reads"); return [:] },
            resolveSymlinks: { $0 }
        )
        let result = AudioDispatcher.handle(command: compare.command, params: params, runtime: runtime)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(requestedPaths == [QualificationTransport.qualificationAudioProbePath])
        let isError = try #require(result.isError)
        #expect(isError)
        #expect(body["error"] as? String == "spectral_analysis_failed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
    }

    @Test func qualificationProbeConfirmsTraceClear() throws {
        let clearTraces = try #require(OperationRegistry.specs.first { $0.id == .systemClearTraces })
        let confirmed = QualificationTransport.probeParams(
            for: clearTraces,
            traceID: "trace"
        )["confirmed"] as? Bool
        let sendsDocumentedConfirmation = confirmed == true

        #expect(sendsDocumentedConfirmation)
    }

    @Test func liveGateSummarySeparatesPreconditionsEnvironmentAndFailures() throws {
        let readSpec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let mutatingSpec = try #require(OperationRegistry.specs.first { $0.id == .transportPlay })
        let passed = try #require(
            Self.driveResult(specs: [readSpec]).operationResults[readSpec.id.rawValue]
        )
        let outOfScope = try #require(
            Self.driveResult(specs: [mutatingSpec]).operationResults[mutatingSpec.id.rawValue]
        )
        let failed = QualificationOperationResult(
            operationID: "synthetic.readback.timeout",
            tool: readSpec.tool.rawValue,
            command: readSpec.command,
            mutability: .readOnly,
            requestID: "failed-request",
            responseData: Data(#"{}"#.utf8),
            isError: false,
            state: "A",
            error: nil,
            hint: nil,
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "failed-readback",
            readbackData: nil,
            failureReason: QualificationTransport.observedFailureReason(
                from: QualificationTransportError.requestTimeout(phase: "failed-readback"),
                during: "independent readback"
            )
        )
        let missingPath = QualificationOperationResult(
            operationID: OperationID.audioAnalyzeSpectrum.rawValue,
            tool: "logic_audio",
            command: "analyze_spectrum",
            mutability: .readOnly,
            requestID: "missing-path-request",
            responseData: Data(#"{"state":"C","error":"invalid_params","write_attempted":false}"#.utf8),
            isError: true,
            state: "C",
            error: "invalid_params",
            hint: "analyze_spectrum requires non-empty string 'path'",
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "missing-path-readback",
            readbackData: Data(#"{}"#.utf8),
            failureReason: nil
        )
        let missingPluginWindow = QualificationOperationResult(
            operationID: OperationID.tracksScanPluginPresets.rawValue,
            tool: "logic_tracks",
            command: "scan_plugin_presets",
            mutability: .readOnly,
            requestID: "missing-plugin-window-request",
            responseData: Data(#"{"state":"C","error":"plugin_window_unavailable","write_attempted":false}"#.utf8),
            isError: true,
            state: "C",
            error: HonestContract.FailureError.pluginWindowUnavailable.rawValue,
            hint: AccessibilityChannel.pluginWindowUnavailableHint,
            writeAttempted: false,
            readbackSource: "logic://library/inventory",
            readbackRequestID: "missing-plugin-window-readback",
            readbackData: Data(#"{}"#.utf8),
            failureReason: nil
        )

        let summary = QualificationLiveGateSummary(
            operationResults: [passed, outOfScope, missingPath, missingPluginWindow, failed]
        )

        let scopesRemainDistinct = passed.liveGateScope == .inScope
            && outOfScope.liveGateScope == .outOfScope
        let bucketsAreSeparated = summary.inScopePassed == 1
            && summary.outOfScope == 1
            && summary.notExercisableWithoutPreconditions == [
                .init(
                    operationID: OperationID.audioAnalyzeSpectrum.rawValue,
                    reason: "requires non-empty string 'path'"
                ),
            ]
            && summary.environmentalPreconditions == [
                .init(
                    operationID: OperationID.tracksScanPluginPresets.rawValue,
                    reason: "requires an open plugin window with a Setting dropdown"
                ),
            ]
            && summary.failed == 1
        let everyDispositionIsAccountedFor = summary.accounted == summary.total

        #expect(scopesRemainDistinct)
        #expect(bucketsAreSeparated)
        #expect(everyDispositionIsAccountedFor)
    }

    @Test func liveGateClassifiesExactLibraryInventoryPreconditionAsEnvironmental() {
        let summary = QualificationLiveGateSummary(operationResults: [
            Self.tracksListLibraryRefusal()
        ])
        let classifiesClosedPanelAsEnvironmental = summary.environmentalPreconditions == [
            .init(
                operationID: OperationID.tracksListLibrary.rawValue,
                reason: "requires an exact open Library panel with readable inventory"
            ),
        ] && summary.failed == 0

        #expect(classifiesClosedPanelAsEnvironmental)
    }

    @Test func liveGateClassifiesOnlyTheExactZeroWriteSelectedRegionScopeRefusalAsAPrecondition() {
        func result(
            state: String = "C",
            error: String = "selected_region_event_read_unavailable",
            reason: String = "selection_scope_incomplete",
            writeAttempted: Bool = false,
            rowSelectionWriteAttempted: Bool = false,
            rowSelectionRestored: Bool = false
        ) -> QualificationOperationResult {
            QualificationOperationResult(
                operationID: OperationID.midiReadSelectedRegionEvents.rawValue,
                tool: "logic_midi",
                command: "read_selected_region_events",
                mutability: .readOnly,
                requestID: "selected-region-request",
                responseData: Data(#"{"state":"C","error":"selected_region_event_read_unavailable","reason":"selection_scope_incomplete","write_attempted":false,"row_selection_write_attempted":false,"row_selection_restored":false}"#.utf8),
                isError: true,
                state: state,
                error: error,
                hint: nil,
                reason: reason,
                writeAttempted: writeAttempted,
                rowSelectionWriteAttempted: rowSelectionWriteAttempted,
                rowSelectionRestored: rowSelectionRestored,
                readbackSource: "logic://midi/selected-region-events",
                readbackRequestID: "selected-region-readback",
                readbackData: Data(#"{}"#.utf8),
                failureReason: nil
            )
        }

        let exact = QualificationLiveGateSummary(operationResults: [
            result(),
        ])
        #expect(exact.notExercisableWithoutPreconditions == [
            .init(
                operationID: OperationID.midiReadSelectedRegionEvents.rawValue,
                reason: "requires a complete selected Arrange-region scope"
            ),
        ])
        #expect(exact.failed == 0)

        let changed = [
            result(state: "B"),
            result(error: "different_error"),
            result(reason: "different_scope_failure"),
            result(writeAttempted: true),
            result(rowSelectionWriteAttempted: true),
            result(rowSelectionRestored: true),
        ]
        for candidate in changed {
            let summary = QualificationLiveGateSummary(operationResults: [candidate])
            #expect(summary.notExercisableWithoutPreconditions.isEmpty)
            #expect(summary.failed == 1)
        }
    }

    @Test func liveGateRejectsDifferentTracksListLibraryHintAsFailure() {
        let summary = QualificationLiveGateSummary(operationResults: [
            Self.tracksListLibraryRefusal(hint: "A different library-panel refusal.")
        ])
        let differentHintRemainsFailure = summary.environmentalPreconditions.isEmpty
            && summary.failed == 1

        #expect(differentHintRemainsFailure)
    }

    @Test func liveGateRejectsDifferentTracksListLibraryErrorAsFailure() {
        let summary = QualificationLiveGateSummary(operationResults: [
            Self.tracksListLibraryRefusal(error: "different_error")
        ])
        let differentErrorRemainsFailure = summary.environmentalPreconditions.isEmpty
            && summary.failed == 1

        #expect(differentErrorRemainsFailure)
    }

    /// A red live run names each failing operation and its observed reason.
    @Test func liveGateFailureDescriptionNamesEachOperationAndItsReason() {
        let described = Self.describe([
            .init(operationID: "tracks.list_library", failureReason: "semantic readback mismatch"),
            .init(operationID: "marker.list", failureReason: "no response"),
        ])
        let namesBothOperations = described.contains("tracks.list_library")
            && described.contains("marker.list")
        let carriesBothReasons = described.contains("semantic readback mismatch")
            && described.contains("no response")
        let oneLineEach = described.split(separator: "\n").count == 2

        #expect(namesBothOperations)
        #expect(carriesBothReasons)
        #expect(oneLineEach)
    }

    @Test func liveGateFailureDescriptionSaysNoneRatherThanNothing() {
        let described = Self.describe([])
        let saysNone = described.contains("none")

        #expect(saysNone)
    }

    /// The language is read from Logic's own `AppleLanguages`, not from the host locale. This
    /// machine ran `ko-KR` throughout the campaign while Logic was switched between `en` and
    /// `ja`, so a reading taken from the host would have named the wrong condition on every run.
    ///
    /// The first shape of this test wrote into a throwaway `UserDefaults(suiteName:)` and read it
    /// back, and `absentIsUnset` failed: a suite's search list includes `NSGlobalDomain`, where
    /// `AppleLanguages` actually lives, so removing the key from the suite did not make the read
    /// empty — it made it fall through and answer `ko-KR`. That is the exact confusion the helper
    /// exists to prevent, committed inside the helper. Taking a DOMAIN DICTIONARY instead of a
    /// defaults object removes the fall-through by construction rather than by hoping.
    @Test func logicUILanguageIsReadFromLogicsOwnDefaultsNotTheHostLocale() {
        let readsTheFirstEntry =
            Self.logicUILanguage(domain: ["AppleLanguages": ["ja", "en"]]) == "ja"
        let emptyArrayIsUnset =
            Self.logicUILanguage(domain: ["AppleLanguages": [String]()]).contains("unset")
        // Logic's domain exists but has never carried a language: the answer is "unset", NOT the
        // machine's `ko-KR`, and there is no search list here that could supply one.
        let absentKeyIsUnset =
            Self.logicUILanguage(domain: ["SomethingElse": 1]).contains("unset")
        let noDomainIsUnset = Self.logicUILanguage(domain: nil).contains("unset")
        // A value of the wrong shape is not a language. Logic writes an array; anything else is
        // read as "we do not know" rather than coerced into a plausible string.
        let wrongTypeIsUnset =
            Self.logicUILanguage(domain: ["AppleLanguages": "ja"]).contains("unset")
        let emptyStringIsUnset =
            Self.logicUILanguage(domain: ["AppleLanguages": [""]]).contains("unset")

        #expect(readsTheFirstEntry)
        #expect(emptyArrayIsUnset)
        #expect(absentKeyIsUnset)
        #expect(noDomainIsUnset)
        #expect(wrongTypeIsUnset)
        #expect(emptyStringIsUnset)
    }

    @Test func liveGateSummaryStatesMutatingOperationExclusion() throws {
        let mutatingSpec = try #require(OperationRegistry.specs.first { $0.id == .transportPlay })
        let operation = try #require(
            Self.driveResult(specs: [mutatingSpec]).operationResults[mutatingSpec.id.rawValue]
        )
        let summary = QualificationLiveGateSummary(operationResults: [operation])

        #expect(summary.mutatingOperationExclusionLine.contains("mutating operations are not exercised"))
        #expect(summary.mutatingOperationExclusionLine.contains("zero-write refusal probes"))
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_RUN_LIVE_QA"] == "1"
            && FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires LOGIC_PRO_MCP_RUN_LIVE_QA=1 and a release build; use Scripts/release-qualify.sh."
    ))
    func realReleaseBinaryExecutesEveryOperationWithIndependentReadback() throws {
        let result = try QualificationTransport().drive(.init(
            executableURL: Self.releaseExecutableURL,
            environment: ProcessInfo.processInfo.environment,
            expectedOperationCount: OperationRegistry.specs.count,
            // THE SAME ORDER THE RUNNER DRIVES. `QualificationRunner.qualify` sorts by id before
            // driving; this test passed the registry's DECLARATION order, so it exercised a
            // sequence the shipped path never runs. Measured 2026-09-15: sequence changes outcomes
            // here — a marker operation opens Logic's Marker List and disarms the track-menu
            // operations after it — so a test driving a different sequence is not testing the
            // runner, and it was the difference behind a leak that reproduced under this test and
            // not under the CLI.
            operations: OperationRegistry.specs.sorted { $0.id.rawValue < $1.id.rawValue }
        ))

        #expect(result.handshakeOK)
        #expect(result.catalogCountMatch)
        #expect(result.traceOK)

        let operationResults = Array(result.operationResults.values)
        let mutating = operationResults.filter { $0.mutability == .mutating }
        let readOnly = operationResults.filter { $0.mutability == .readOnly }
        let liveGate = QualificationLiveGateSummary(operationResults: operationResults)

        #expect(operationResults.count == OperationRegistry.specs.count)
        #expect(operationResults.allSatisfy { $0.status != .failed })
        #expect(liveGate.accounted == operationResults.count)
        let uiLanguage = Self.logicUILanguage()
        #expect(
            liveGate.failures.isEmpty,
            """
            live-gate failures:
            \(Self.describe(liveGate.failures))
            Logic's UI language for this run: \(uiLanguage).
            """
        )
        #expect(operationResults.allSatisfy { $0.responseData != nil && $0.readback != nil })
        #expect(Set(operationResults.compactMap(\.requestID)).count == operationResults.count)
        #expect(Set(operationResults.compactMap(\.readbackRequestID)).count == operationResults.count)
        // #373 Phase B. This used to assert that EVERY mutating operation is `.notQualified` —
        // a universal that was true only while no write-and-readback recipe existed, and that
        // would have to be deleted the moment one did. Deleting it would take the guard with it,
        // so it is split by the thing that actually decides: whether a VERIFIED
        // mutation-restore record exists for that operation.
        //
        // The guard that matters is the first branch below: without a record, a mutating
        // operation still cannot reach anything but the typed zero-write deferral. An operation
        // that starts passing without producing evidence fails here.
        let (withEvidence, withoutEvidence) = mutating.reduce(
            into: ([QualificationOperationResult](), [QualificationOperationResult]())
        ) { split, result in
            if result.mutationRestore == nil { split.1.append(result) } else { split.0.append(result) }
        }
        // A record alone does not promote: the operation's own probe must have behaved as
        // contracted AND the recipe's independent readback must be admissible. That ordering was
        // wrong once — a record short-circuited above every other check and laundered an injected
        // fault — so this asserts what the rule actually permits. `.failed` is what it must never
        // be: a record cannot coexist with a failed probe.
        // `allSatisfy` on an empty collection is true, so every line below would hold for a run in
        // which no recipe produced evidence at all -- delete every Phase-B recipe and this block
        // stays green. The positive control has to come first.
        #expect(!withEvidence.isEmpty)
        // And specifically: the VALUE cycle ran. `withEvidence` being non-empty only says SOME
        // recipe produced a record, and the boolean and transport cycles can supply that on their
        // own, so the two operations whose recipe restores a continuous value could be absent from
        // every run with nothing here to say so.
        //
        // WHAT IT DOES NOT CONTROL FOR, stated because the first version of this comment claimed it
        // did: it does not prove the cycle addressed the track by `track_ref`, nor that a failed
        // cycle compensated. Revert the mutation to `["index": trackIndex, …]` and delete the
        // compensation and this assertion still passes — a cycle that verifies still emits a
        // record. It controls for "a value cycle ran", which is what the live gate could not
        // otherwise tell you at all. The targeting and compensation properties have no regression
        // control below the live gate; making one needs a Phase-B fixture, and the attempt that
        // produced this branch died building exactly that.
        let valueCycleOperations = Set(
            QualificationTransport.valueRestoreReadbackField.keys.map(\.rawValue))
        let valueCycleEvidence = withEvidence.filter { valueCycleOperations.contains($0.operationID) }
        #expect(
            !valueCycleEvidence.isEmpty,
            """
            no value-restore cycle produced evidence in this run. Expected one of \
            \(valueCycleOperations.sorted()); saw records for \
            \(withEvidence.map(\.operationID).sorted()); the value recipes answered \
            \(mutating.filter { valueCycleOperations.contains($0.operationID) }
                .map { "\($0.operationID): \($0.mutationRestoreRefusal ?? "no refusal recorded")" })
            """
        )
        #expect(withEvidence.allSatisfy {
            ($0.status == .passed || $0.status == .notQualified)
                && $0.mutationRestore?.operationID == $0.operationID
                // Every step is present. The record type has no failure case, so the fields being
                // populated is what "the cycle verified" looks like from here.
                && !($0.mutationRestore?.preState.isEmpty ?? true)
                && !($0.mutationRestore?.readback.isEmpty ?? true)
                && !($0.mutationRestore?.restoreReadback.isEmpty ?? true)
        })
        #expect(withoutEvidence.allSatisfy {
            $0.status == .notQualified
                && $0.expectedZeroWriteRefusalObserved
                && $0.deferral?.code == .liveMutationNotRun
        })
        #expect(readOnly.allSatisfy {
            $0.status == .passed || $0.status == .notQualified || $0.status == .protocolSmoke
        })
        print(liveGate.classificationLine)
        print(liveGate.mutatingOperationExclusionLine)
        if let preconditionLine = liveGate.unmetOperationPreconditionsLine {
            print(preconditionLine)
        }
        if let environmentalPreconditionsLine = liveGate.environmentalPreconditionsLine {
            print(environmentalPreconditionsLine)
        }
        if let failureLine = liveGate.failureLine {
            print(failureLine)
        }

        // #373 Phase A. The classification line above says how many reached each status; it cannot
        // say WHICH, and the difference is the whole remaining question. `SemanticOracleTable`'s
        // KNOWN GAPS note still names six operations as unable to reach `passed` for want of probe
        // parameters -- all six have had them for some time, so the note prescribes work already
        // done, and nobody could tell because no run ever printed the names.
        //
        // Read-only only, and the reason is scope rather than impossibility. This used to say a
        // mutating operation "cannot reach `passed` at all today". That stopped being true when
        // Phase B started promoting on a mutation/restore record, and a blind review found the
        // sentence still sitting here: the `phaseBPasses` expectation below requires a mutating
        // operation to be `.passed` on a recorded write cycle, and it passes on a live run. That is
        // a pass, and since #984 it is credit too when its restore verified -- asserted below.
        // Listing mutating operations here would still be listing the Phase-B gap rather than
        // Phase A's, which is why this filter stays as it is.
        let readOnlyShort = readOnly
            .filter { $0.status != .passed }
            .map { "\($0.operationID)=\($0.status.rawValue)" }
            .sorted()
        print("read-only short of passed (\(readOnlyShort.count) of \(readOnly.count)): "
                + (readOnlyShort.isEmpty ? "none" : readOnlyShort.joined(separator: ", ")))

        // #373 — the credit chain, end to end, on THIS run's real results.
        //
        // Review named this as the thing that stayed untested: the producer and the static
        // evaluator were each tested against hand-built cases, and nothing showed that a real live
        // run reaches R-SEM at all. Everything above this line is a real drive of the release
        // binary against a running Logic, so the cases it produced are the honest input.
        //
        // The line is printed in a machine-readable shape because a live harness outside this
        // process reads it (`live_373_live_credit_reaches_the_debt_board`), and a number nobody can
        // extract is a number nobody checks.
        let liveCases: [QualificationCase] = operationResults.map { result in
            QualificationCase(
                id: "in-process/\(result.operationID)",
                status: result.status,
                tool: "qualification",
                command: result.operationID,
                traceID: "lpmcp_00000000-0000-0000-0000-000000000000",
                verified: result.status == .passed,
                evidenceFiles: [],
                operationID: result.operationID,
                verificationKind: result.verificationKind,
                deferral: result.deferral,
                readback: result.readback,
                restore: result.restore
            )
        }
        let attestation = ReleaseQualificationAttestation(
            schema: "release-qualification-attestation/v2",
            serverVersion: "0.0.0",
            commitSHA: String(repeating: "0", count: 40),
            binarySHA256: String(repeating: "0", count: 64),
            logicVariant: .desktop,
            logicVersion: "unknown",
            locale: .enUS,
            profile: .core,
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 0),
            total: liveCases.count,
            passed: liveCases.filter { $0.status == .passed }.count,
            failed: 0,
            waived: 0,
            cases: liveCases,
            waivers: [],
            evidenceManifestSHA256: String(repeating: "0", count: 64)
        )
        let credited = PromotionGate.liveCreditedOperationIDs(in: attestation)
        let registered = OperationRegistry.specs.map(\.id.rawValue)

        func missingCount(crediting: Set<String>) -> Int {
            ProductionReadinessContractEvaluator.evaluate(
                releaseWorkflowYAML: "",
                registeredOperationIDs: registered,
                semanticValidatorOperationIDs: [],
                requiredMatrixAxisCount: 0,
                debtBoardMarkdown: nil,
                expectedAuthorityBaseSHA: nil,
                publishedReleaseEvidencePresent: false,
                mutationRestoreCompensationEvidencePresent: false,
                independentProvenanceEnforced: false,
                liveCreditedOperationIDs: crediting
            ).findings
                .filter { $0.id == .semanticCoverageIncomplete }
                .compactMap { finding -> Int? in
                    // "semantic coverage missing (…) for <n>/<total> operations (…)"
                    guard let after = finding.detail.components(separatedBy: " for ").dropFirst().first,
                          let n = after.components(separatedBy: "/").first else { return nil }
                    return Int(n)
                }
                .first ?? 0
        }

        let withoutCredit = missingCount(crediting: [])
        let withCredit = missingCount(crediting: credited)
        // The drop is EXACTLY the credited set, not merely smaller. A change that credited an
        // operation twice, or credited one the registry does not list, would still shrink the count.
        let dropIsExactlyTheCreditedSet = withoutCredit - withCredit == credited.count
        let everyCreditedOperationIsRegistered = credited.isSubset(of: Set(registered))

        print("373 live-credit: credited=\(credited.count) registered=\(registered.count) "
              + "missingWithoutCredit=\(withoutCredit) missingWithCredit=\(withCredit) "
              + "dropIsExactlyTheCreditedSet=\(dropIsExactlyTheCreditedSet) "
              + "everyCreditedOperationIsRegistered=\(everyCreditedOperationIsRegistered)")

        #expect(withoutCredit == registered.count)
        #expect(dropIsExactlyTheCreditedSet)
        #expect(everyCreditedOperationIsRegistered)
        // A live run that credits nothing would satisfy every line above, so the run has to have
        // produced credit at all. This is the same positive control the other live harnesses carry.
        //
        // `credited` includes read-only semantic credit, which a run with every Phase-B recipe
        // removed still earns, so `!credited.isEmpty` on its own cannot tell a working Phase B from
        // an absent one -- the same vacuity as the `allSatisfy` above, one level out.
        #expect(!credited.isEmpty)
        // The Phase-B control is a mutating PASS that rests on a recorded write cycle. On
        // 2026-09-25 (v3.17.0 preflight) the first version of this assertion asked for mutating
        // CREDIT, which could not exist then: `operationIsLiveCredited` credited
        // `.semanticReadback` alone (credited=21, none mutating). #984 decided a verified write
        // cycle credits, so the assertion is the stronger one again, in two parts:
        //   * a mutating operation passed on a recorded write cycle. Kept because a mutant that
        //     files every pass `.semanticReadback` would satisfy the credit half on its own -- it
        //     would credit mutating operations through the READ rule;
        //   * EVERY such pass is credited. A pass is filed `.verifiedWriteCycle` only with a
        //     record whose readings all happened, which is what `restore.verified` states, so a
        //     pass the rule does not credit is the producer and the rule disagreeing.
        let phaseBPasses = mutating.filter {
            $0.status == .passed && $0.verificationKind == .verifiedWriteCycle
        }
        #expect(
            !phaseBPasses.isEmpty,
            "no mutating operation passed on a recorded write cycle, so Phase B did nothing this run"
        )
        let phaseBUncredited = Set(phaseBPasses.map(\.operationID)).subtracting(credited)
        #expect(
            phaseBUncredited.isEmpty,
            "write-cycle passes the credit rule refused: \(phaseBUncredited.sorted())"
        )
        print("phase-b passes: \(phaseBPasses.map(\.operationID).sorted().joined(separator: ", "))")
    }

    /// #399 (CEO audit P0) — INVERTED. This test used to prove the runner CAUGHT
    /// a real env-induced `partial_state` fault; that capability was the
    /// vulnerability. With the fault seam compiled out of release, driving the
    /// real release binary through the full runner with the fault env set must now
    /// yield the normal typed zero-write refusal — no `readback_unavailable`, no
    /// failed case. (The generic "a failed required case is not promotable"
    /// rejection stays covered by `verificationEmitsEveryApplicableRejection`.)
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_RUN_LIVE_QA"] == "1"
            && FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires LOGIC_PRO_MCP_RUN_LIVE_QA=1 and a release build; use Scripts/release-qualify.sh."
    ))
    func runnerIgnoresPartialStateFaultEnvOnRealServer() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportPlay })
        let executableData = try Data(contentsOf: Self.releaseExecutableURL)
        let fixture = try Fixture(
            specs: [spec],
            executableData: executableData,
            environmentAdditions: [
                "LOGIC_PRO_MCP_FAULT_INJECT": "partial_state",
                "LOGIC_PRO_MCP_FAULT_INJECT_STEP": "0",
            ],
            drive: { request in
                let observed = try QualificationTransport(
                    requestTimeout: 30,
                    shutdownGrace: 1
                ).drive(request)
                let baseline = Self.driveResult(specs: [spec])
                return QualificationDriveResult(
                    handshake: baseline.handshake,
                    health: baseline.health,
                    catalog: baseline.catalog,
                    expectedOperationCount: baseline.expectedOperationCount,
                    traceList: baseline.traceList,
                    traceDetail: baseline.traceDetail,
                    negative: baseline.negative,
                    observedLocale: baseline.observedLocale,
                    operationResults: observed.operationResults,
                    wireFrames: observed.wireFrames,
                    mutationRestoreRecords: observed.mutationRestoreRecords,
                    failureReason: observed.failureReason
                )
            }
        )
        defer { fixture.remove() }

        let qualification = await fixture.runQualification()
        let attestationData = try #require(
            try? Data(contentsOf: fixture.attestationURL),
            "qualification failed: \(qualification.stderr)"
        )
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: attestationData
        )
        let operationCase = try #require(
            attestation.cases.first { $0.id == "in-process/transport.play" }
        )
        let transcript = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory
                .appendingPathComponent("raw-transcript.json"))) as? [String: Any]
        )
        let frames = try #require(transcript["frames"] as? [[String: Any]])
        let response = try #require(frames.first {
            $0["operation_id"] as? String == "operation_probe.transport.play"
                && $0["direction"] as? String == "response"
        })
        let responsePayload = try #require(response["payload"] as? String)

        // `--qualify` exits non-zero exactly when a case FAILED (its own test is
        // `qualifyExitCodeReportsWhetherAnythingFailed`). This fixture's operation results come from
        // the REAL release binary, not a fake that fails by construction, and `transport.play`
        // passes on its Phase B recipe against a live Logic, so the code this run owes is whatever
        // its own attestation says rather than a fixed 1 -- which it failed with on 2026-09-25.
        let anyCaseFailed = attestation.cases.contains { $0.status == .failed }
        #expect(qualification.exitCode == (anyCaseFailed ? 1 : 0))
        // The fault env engaged nothing: the release binary emitted the normal
        // typed zero-write refusal, never the injected readback_unavailable fault.
        #expect(!responsePayload.contains("readback_unavailable"))
        #expect(responsePayload.contains(#"\"error\":\"invalid_params\""#))
        // This test's subject is that the fault env engaged NOTHING, and the two assertions above
        // are what carry it: the normal typed refusal is on the wire and the injected
        // `readback_unavailable` is not. The status assertion was a proxy for the same thing while
        // no mutating operation could ever pass — `transport.play` now has a #373 Phase B recipe,
        // so its normal outcome is `.passed`. Asserting `.notQualified` here would be pinning the
        // absence of the recipe, not the absence of the fault.
        //
        // What a fault-induced failure looks like is `.failed`, which the sibling test
        // `runnerRejectsPartialStateObservedFromRealServer` asserts. So the honest claim here is
        // that this is NOT that.
        #expect(operationCase.status != .failed)
    }

    /// FINDING 3 (#399) — debug-gated restoration of the runner-rejection
    /// contract. The inverted `runnerIgnoresPartialStateFaultEnvOnRealServer`
    /// proves the RELEASE binary ignores the fault env, but it can no longer prove
    /// the runner REJECTS a real fault-induced failure, because release has no
    /// seam. This drives the DEBUG binary (which HAS the seam) so `partial_state`
    /// really induces `readback_unavailable`, then re-asserts the original exact
    /// contract: the transport.play case is present and FAILED, and verification
    /// refuses to promote it (exit 1, promotable=false). Compiled solely under
    /// `FAULT_TEST_SEAM` (see Package.swift) — references excluded symbols.
    #if FAULT_TEST_SEAM
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_RUN_LIVE_QA"] == "1"
            && FileManager.default.isExecutableFile(atPath: Self.debugExecutableURL.path),
        "Requires LOGIC_PRO_MCP_RUN_LIVE_QA=1 and a debug build with the fault seam."
    ))
    func runnerRejectsPartialStateObservedFromRealServer() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportPlay })
        let executableData = try Data(contentsOf: Self.debugExecutableURL)
        let fixture = try Fixture(
            specs: [spec],
            executableData: executableData,
            environmentAdditions: [
                QualificationFaultInjection.environmentKey:
                    QualificationFaultInjection.Mode.partialState.rawValue,
            ],
            drive: { request in
                let observed = try QualificationTransport(
                    requestTimeout: 30,
                    shutdownGrace: 1
                ).drive(request)
                let baseline = Self.driveResult(specs: [spec])
                return QualificationDriveResult(
                    handshake: baseline.handshake,
                    health: baseline.health,
                    catalog: baseline.catalog,
                    expectedOperationCount: baseline.expectedOperationCount,
                    traceList: baseline.traceList,
                    traceDetail: baseline.traceDetail,
                    negative: baseline.negative,
                    observedLocale: baseline.observedLocale,
                    operationResults: observed.operationResults,
                    wireFrames: observed.wireFrames,
                    mutationRestoreRecords: observed.mutationRestoreRecords,
                    failureReason: observed.failureReason
                )
            }
        )
        defer { fixture.remove() }

        let qualification = await fixture.runQualification()
        let attestationData = try #require(
            try? Data(contentsOf: fixture.attestationURL),
            "qualification failed: \(qualification.stderr)"
        )
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: attestationData
        )
        let operationCase = try #require(
            attestation.cases.first { $0.id == "in-process/transport.play" }
        )
        let transcript = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory
                .appendingPathComponent("raw-transcript.json"))) as? [String: Any]
        )
        let frames = try #require(transcript["frames"] as? [[String: Any]])
        let response = try #require(frames.first {
            $0["operation_id"] as? String == "operation_probe.transport.play"
                && $0["direction"] as? String == "response"
        })
        let responsePayload = try #require(response["payload"] as? String)
        let promotion = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        let promotionJSON = try Self.resultObject(promotion)

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(qualification.exitCode == 1)
        #expect(responsePayload.contains(#"\"error\":\"readback_unavailable\""#))
        #expect(operationCase.status == .failed)
        #expect(promotion.exitCode == 1)
        let promotable = try #require(promotionJSON["promotable"] as? Bool)
        #expect(!promotable)
    }
    #endif

    @Test func handshakeStillFailsClosedBeyondStartupBudget() throws {
        let fixture = try SlowHandshakeFixture()
        defer { fixture.remove() }
        var environment = ProcessInfo.processInfo.environment
        environment["HANDSHAKE_DELAY"] = "0.2"

        do {
            _ = try QualificationTransport(
                handshakeTimeout: 0.1,
                requestTimeout: 0.05,
                shutdownGrace: 1
            ).drive(.init(
                executableURL: fixture.executableURL,
                environment: environment,
                expectedOperationCount: 0
            ))
            Issue.record("A first frame beyond the startup budget must fail closed")
        } catch let error as QualificationTransportError {
            #expect(error == .requestTimeout(phase: "handshake"))
        } catch {
            Issue.record("Unexpected subprocess error: \(error)")
        }
    }

    @Test func subprocessAlwaysReapedNoOrphan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualification-reap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("hang.sh")
        let pidURL = directory.appendingPathComponent("pid")
        try Data("#!/bin/sh\necho $$ > \"$PID_FILE\"\ntrap '' TERM\nwhile :; do :; done\n".utf8)
            .write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        var environment = ProcessInfo.processInfo.environment
        environment["PID_FILE"] = pidURL.path
        do {
            _ = try QualificationTransport(
                handshakeTimeout: 0.5,
                requestTimeout: 0.5,
                shutdownGrace: 2
            ).drive(.init(
                executableURL: scriptURL,
                environment: environment,
                expectedOperationCount: 0
            ))
            Issue.record("A helper that never handshakes must time out")
        } catch let error as QualificationTransportError {
            #expect(error == .requestTimeout(phase: "handshake"))
        } catch {
            Issue.record("Unexpected subprocess error: \(error)")
        }

        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: pidURL.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func fakeTransportQualificationToPromotionIntegration() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }

        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)
        #expect(attestation.cases.allSatisfy { $0.command != "registry_handler_trace" })
        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        let json = try Self.resultObject(result)

        #expect(result.exitCode == 0)
        let v1 = try #require(json["promotable"] as? Bool)
        #expect(v1)
        #expect(Self.rejectionReasons(json).isEmpty)
    }

    @Test func trustedVerifierUsesTheCandidatesSignedOperationCatalog() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let fixture = try trustedFixture(specs: [spec])
        defer { fixture.remove() }

        let qualification = await fixture.runQualification(waiversURL: fixture.waiversURL)
        #expect(qualification.exitCode == 0)
        fixture.sign()

        let result = QualificationRunner.verifyTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            trustedPublicKeyData: fixture.trustedPublicKeyData
        )
        let json = try Self.resultObject(result)

        #expect(result.exitCode == 0)
        #expect(try #require(json["promotable"] as? Bool))
        #expect(Self.rejectionReasons(json).isEmpty)
    }

    @Test func trustedSignerSignsTheValidatedCandidateCatalogInsteadOfItsLocalRegistry() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let fixture = try trustedFixture(specs: [spec])
        defer { fixture.remove() }
        let qualification = await fixture.runQualification(waiversURL: fixture.waiversURL)
        #expect(qualification.exitCode == 0)

        let result = QualificationRunner.signTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            signingPrivateKeyData: fixture.signingKeyData
        )

        #expect(result.exitCode == 0, "\(result.stdout)\(result.stderr)")
        #expect(try #require(try Self.resultObject(result)["promotable"] as? Bool))
    }

    @Test func operationCatalogRejectsDuplicateMissingAndPolicyDigestMutants() async throws {
        let specs = try [OperationID.systemHealth, .systemPermissions].map { operation in
            try #require(OperationRegistry.specs.first { $0.id == operation })
        }
        let fixture = try trustedFixture(specs: specs, includeRequiredAtlas: false)
        defer { fixture.remove() }
        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let catalog = try JSONDecoder().decode(
            QualificationOperationCatalog.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent(
                "operation-catalog.json"
            ))
        )
        #expect(QualificationRunner.operationCatalogContentIssue(
            catalog, attestation: attestation
        ) == nil)

        let duplicate = QualificationOperationCatalog(
            schema: catalog.schema,
            binarySHA256: catalog.binarySHA256,
            semanticPolicySHA256: catalog.semanticPolicySHA256,
            operations: [catalog.operations[0], catalog.operations[0], catalog.operations[1]]
        )
        #expect(QualificationRunner.operationCatalogContentIssue(
            duplicate, attestation: attestation
        ) == "operation catalog contains missing, duplicate, or non-bijective IDs")

        let missing = QualificationOperationCatalog(
            schema: catalog.schema,
            binarySHA256: catalog.binarySHA256,
            semanticPolicySHA256: try QualificationRunner.operationCatalogPolicyDigest(
                Array(catalog.operations.dropLast())
            ),
            operations: Array(catalog.operations.dropLast())
        )
        #expect(QualificationRunner.operationCatalogContentIssue(
            missing, attestation: attestation
        ) == "operation catalog does not bijectively bind the attested operation cases")

        let changedPolicyDigest = QualificationOperationCatalog(
            schema: catalog.schema,
            binarySHA256: catalog.binarySHA256,
            semanticPolicySHA256: String(repeating: "0", count: 64),
            operations: catalog.operations
        )
        #expect(QualificationRunner.operationCatalogContentIssue(
            changedPolicyDigest, attestation: attestation
        ) == "operation catalog semantic policy digest mismatch")

        let first = catalog.operations[0]
        let invalidMutationEntry = QualificationOperationCatalog.Entry(
            operationID: first.operationID,
            caseID: first.caseID,
            oracleDisposition: first.oracleDisposition,
            semanticPolicy: first.semanticPolicy,
            mutationRestorePolicy: .playheadStep(direction: 0)
        )
        let invalidMutationOperations = [invalidMutationEntry] + catalog.operations.dropFirst()
        let invalidMutationPolicy = QualificationOperationCatalog(
            schema: catalog.schema,
            binarySHA256: catalog.binarySHA256,
            semanticPolicySHA256: try QualificationRunner.operationCatalogPolicyDigest(
                Array(invalidMutationOperations)
            ),
            operations: Array(invalidMutationOperations)
        )
        #expect(QualificationRunner.operationCatalogContentIssue(
            invalidMutationPolicy, attestation: attestation
        ) == "operation catalog mutation restore policy is invalid")
    }

    @Test func trustedVerifierRejectsCatalogBytesChangedAfterSigning() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let fixture = try trustedFixture(specs: [spec])
        defer { fixture.remove() }
        let qualification = await fixture.runQualification(waiversURL: fixture.waiversURL)
        #expect(qualification.exitCode == 0)
        fixture.sign()
        let catalogURL = fixture.directory.appendingPathComponent("operation-catalog.json")
        var catalogData = try Data(contentsOf: catalogURL)
        catalogData.append(0x20)
        try catalogData.write(to: catalogURL)

        let result = QualificationRunner.verifyTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            trustedPublicKeyData: fixture.trustedPublicKeyData
        )

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains(
            "evidenceBindingMismatch"
        ))
    }

    @Test func qualifyEmitsRequiredReleaseArtifactsAndManifestDigests() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        let attestation = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let artifacts = [
            "raw-transcript.json": ("qualification-raw-transcript/v1", "frames"),
            "mutation-restore-compensation.json": (
                "qualification-mutation-restore-compensation/v1", "records"
            ),
        ]
        let manifestData = try Data(contentsOf: fixture.manifestURL)
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let entries = try #require(manifest["files"] as? [[String: Any]])
        let catalogData = try Data(contentsOf: fixture.directory.appendingPathComponent(
            "operation-catalog.json"
        ))
        let catalogDigest = SupportBundleBuilder.sha256(catalogData)
        let catalog = try JSONDecoder().decode(
            QualificationOperationCatalog.self,
            from: catalogData
        )
        #expect(catalog.schema == "qualification-operation-catalog/v2")
        #expect(catalog.binarySHA256 == attestation.binarySHA256)
        #expect(catalog.operations.map(\.operationID) == [OperationID.systemHealth.rawValue])
        #expect(manifest["operation_catalog_path"] as? String == "operation-catalog.json")
        #expect(manifest["operation_catalog_sha256"] as? String == catalogDigest)
        #expect(attestation.operationCatalogSHA256 == catalogDigest)
        #expect(attestation.provenance?.operationCatalogSHA256 == catalogDigest)

        for (filename, expected) in artifacts {
            let data = try #require(try? Data(
                contentsOf: fixture.directory.appendingPathComponent(filename)
            ))
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(object["schema"] as? String == expected.0)
            let values = try #require(object[expected.1] as? [[String: Any]])
            if filename == "raw-transcript.json" {
                let firstFrame = try #require(values.first)
                let v1 = try #require((firstFrame["operation_id"] as? String)?.isEmpty)
                #expect(!v1)
            }
            let entry = try #require(entries.first { $0["path"] as? String == filename })
            #expect(entry["sha256"] as? String == SupportBundleBuilder.sha256(data))
            #expect(attestation.cases.contains { $0.evidenceFiles.contains(filename) })
        }
    }

    @Test func qualifyEmitsManifestBoundPublicTranscriptWithoutPrivatePayloadValues() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let privatePayload = #"{"id":9,"jsonrpc":"2.0","result":{"project_title":"Project Mothership","host_path":"/Users/private/Secret.logicx","permissions":{"accessibility":"granted"}}}"#
        let frames: [QualificationWireFrame] = [
            .init(
                sequence: 0,
                direction: .request,
                operationID: "operation_probe.system.health",
                payload: #"{"id":9,"jsonrpc":"2.0","method":"tools/call"}"#
            ),
            .init(
                sequence: 1,
                direction: .response,
                operationID: "operation_probe.system.health",
                payload: privatePayload
            ),
        ]
        let fixture = try Fixture(specs: [spec], drive: { _ in
            Self.driveResult(specs: [spec], wireFrames: frames)
        })
        defer { fixture.remove() }
        try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let publicURL = fixture.directory.appendingPathComponent("public-transcript.json")
        let publicData = try Data(contentsOf: publicURL)
        let publicText = try #require(String(data: publicData, encoding: .utf8))
        let object = try #require(
            JSONSerialization.jsonObject(with: publicData) as? [String: Any]
        )
        let publicFrames = try #require(object["frames"] as? [[String: Any]])
        let response = try #require(publicFrames.last)

        #expect(object["schema"] as? String == "qualification-public-transcript/v1")
        #expect(!publicText.contains("Project Mothership"))
        #expect(!publicText.contains("/Users/private/Secret.logicx"))
        #expect(!publicText.contains("permissions"))
        #expect(response["payload"] == nil)
        #expect(
            response["payload_sha256"] as? String
                == SupportBundleBuilder.sha256(Data(privatePayload.utf8))
        )

        let manifestData = try Data(contentsOf: fixture.manifestURL)
        let manifest = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let entries = try #require(manifest["files"] as? [[String: Any]])
        let entry = try #require(entries.first { $0["path"] as? String == "public-transcript.json" })
        #expect(entry["kind"] as? String == "public_transcript")
        #expect(entry["sha256"] as? String == SupportBundleBuilder.sha256(publicData))
    }

    @Test func verifyPromotionRejectsIncoherentOrLeakyPublicTranscript() async throws {
        for mutation in PublicTranscriptMutation.allCases {
            let fixture = try promotableFixture()
            defer { fixture.remove() }
            _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
            try Self.mutatePublicTranscript(mutation, in: fixture)

            let result = await fixture.verify(
                expectedSHA256: fixture.binarySHA256,
                requiredArtifacts: "raw-transcript.json,public-transcript.json"
            )
            let json = try Self.resultObject(result)
            let rejections = try #require(json["rejections"] as? [[String: Any]])

            #expect(result.exitCode == 1)
            #expect(rejections.contains {
                $0["reason"] as? String == "requiredArtifactSchemaInvalid"
                    && $0["name"] as? String == "public-transcript.json"
            }, "\(mutation) must invalidate the public transcript schema")
        }
    }

    @Test func runnerRecordsExactExecutableSHAAndCodableSchema() async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let observedAxis = QualificationAxis(
            variant: .desktop,
            locale: .koKR,
            profile: .full,
            cache: .warm,
            fixture: .empty
        )
        let driveResult = Self.driveResult(
            specs: specs,
            observedVariant: "desktop",
            observedLocale: "ko-KR"
        )
        let fixture = try Fixture(specs: specs, drive: { _ in driveResult })
        defer { fixture.remove() }
        let waivers = Self.axisWaivers(observedAxis: observedAxis)
        try JSONEncoder().encode(waivers).write(to: fixture.waiversURL)

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--waivers", fixture.waiversURL.path,
            "--release-version", "1.2.3",
            "--variant", "desktop",
            "--locale", "ko",
            "--profile", "full",
            "--cache", "warm",
        ])

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty,
                "a run with nothing failed says nothing")
        let data = try Data(contentsOf: fixture.attestationURL)
        let attestation = try JSONDecoder().decode(ReleaseQualificationAttestation.self, from: data)
        let roundTripped = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: JSONEncoder().encode(attestation)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(attestation == roundTripped)
        #expect(attestation.schema == "release-qualification-attestation/v3")
        #expect(attestation.serverVersion == "1.2.3")
        #expect(attestation.commitSHA == fixture.commitSHA)
        #expect(attestation.binarySHA256 == SupportBundleBuilder.sha256(fixture.executableData))
        #expect(attestation.logicVariant == .desktop)
        #expect(attestation.logicVersion == "11.2")
        #expect(attestation.locale == .koKR)
        #expect(attestation.profile == .full)
        let provenance = try #require(attestation.provenance)
        #expect(provenance.schema == "qualification-provenance/v3")
        #expect(provenance.logicVersion == attestation.logicVersion)
        #expect(attestation.cache == .warm)
        #expect(attestation.fixture == .empty)
        #expect(json["cache"] as? String == "warm")
        #expect(attestation.waivers == waivers)
        // 1 operation case (system.health) + the 2 desktop ship axes.
        // The one non-observed ship axis (desktop/en-US) is covered by the
        // per-axis waiver; the observed axis (desktop/ko-KR) passes.
        #expect(attestation.total == 3)
        #expect(attestation.total == attestation.cases.count)
        let aggregateIDs = attestation.cases
            .filter { !$0.id.hasPrefix("in-process/") }
            .map(\.id)
        let expectedAxes = QualificationAxis.requiredCombinations.map {
            QualificationAxis(
                variant: $0.variant,
                locale: $0.locale,
                profile: .full,
                cache: .warm,
                fixture: .empty
            )
        }
        #expect(aggregateIDs == expectedAxes.map(\.key))
        fixture.sign()
        let verification = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(verification.exitCode == 0)
    }

    @Test(arguments: [
        QualificationAxis(
            variant: .desktop,
            locale: .koKR,
            profile: .core,
            cache: .cold,
            fixture: .empty
        ),
        QualificationAxis(
            variant: .desktop,
            locale: .enUS,
            profile: .full,
            cache: .warm,
            fixture: .empty
        ),
    ])
    func singleAxisSignerRejectsForeignLiveAxisEvenWhenSplicedFilesAreInternallyConsistent(
        foreignAxis: QualificationAxis
    ) async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let executableData = Data("matrix-splice-candidate".utf8)
        let commitSHA = String(repeating: "a", count: 40)
        let enDrive = Self.driveResult(specs: specs, observedLocale: "en-US")
        let foreignDrive = Self.driveResult(
            specs: specs,
            observedLocale: foreignAxis.locale.rawValue
        )
        let en = try Fixture(
            specs: specs,
            executableData: executableData,
            commitSHA: commitSHA,
            drive: { _ in enDrive }
        )
        let foreign = try Fixture(
            specs: specs,
            executableData: executableData,
            commitSHA: commitSHA,
            drive: { _ in foreignDrive }
        )
        defer {
            en.remove()
            foreign.remove()
        }

        let enAxis = QualificationAxis(
            variant: .desktop,
            locale: .enUS,
            profile: .core,
            cache: .cold,
            fixture: .empty
        )
        let enResult = await en.runQualification(mutateOpenProject: false)
        let foreignResult = await foreign.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", foreign.attestationURL.path,
            "--release-version", "1.2.3",
            "--locale", foreignAxis.locale == .koKR ? "ko" : "en",
            "--profile", foreignAxis.profile.rawValue,
            "--cache", foreignAxis.cache.rawValue,
        ])
        try #require(enResult.exitCode == 0, "\(enResult.stdout)\(enResult.stderr)")
        try #require(
            foreignResult.exitCode == 0,
            "\(foreignResult.stdout)\(foreignResult.stderr)"
        )

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let enAttestation = try decoder.decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: en.attestationURL)
        )
        let foreignAttestation = try decoder.decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: foreign.attestationURL)
        )
        let existingForeignIndex = enAttestation.cases.firstIndex { $0.id == foreignAxis.key }
        let foreignLiveCaseWithSharedArtifacts = try #require(foreignAttestation.cases.first {
            $0.id == foreignAxis.key && $0.status == .passed && $0.verified
        })
        let sharedObservedArtifacts = Set([
            "raw-transcript.json",
            "public-transcript.json",
            "mutation-restore-compensation.json",
        ])
        let foreignLiveCase = QualificationCase(
            id: foreignLiveCaseWithSharedArtifacts.id,
            status: foreignLiveCaseWithSharedArtifacts.status,
            tool: foreignLiveCaseWithSharedArtifacts.tool,
            command: foreignLiveCaseWithSharedArtifacts.command,
            traceID: foreignLiveCaseWithSharedArtifacts.traceID,
            verified: foreignLiveCaseWithSharedArtifacts.verified,
            evidenceFiles: foreignLiveCaseWithSharedArtifacts.evidenceFiles.filter {
                !sharedObservedArtifacts.contains($0)
            },
            reason: foreignLiveCaseWithSharedArtifacts.reason,
            binarySHA256: foreignLiveCaseWithSharedArtifacts.binarySHA256,
            axis: foreignLiveCaseWithSharedArtifacts.axis,
            operationID: foreignLiveCaseWithSharedArtifacts.operationID,
            operationRequestID: foreignLiveCaseWithSharedArtifacts.operationRequestID,
            verificationKind: foreignLiveCaseWithSharedArtifacts.verificationKind,
            deferral: foreignLiveCaseWithSharedArtifacts.deferral,
            readback: foreignLiveCaseWithSharedArtifacts.readback,
            restore: foreignLiveCaseWithSharedArtifacts.restore,
            availabilityReason: foreignLiveCaseWithSharedArtifacts.availabilityReason,
            availabilityObservation: foreignLiveCaseWithSharedArtifacts.availabilityObservation
        )
        #expect(enAttestation.cases.contains {
            $0.id == enAxis.key && $0.status == .passed && $0.verified
        })
        if let existingForeignIndex {
            #expect(enAttestation.cases[existingForeignIndex].status == .notQualified)
        } else {
            #expect(!QualificationAxis.requiredAxes(
                profile: enAttestation.profile,
                cache: enAttestation.cache,
                fixture: enAttestation.fixture
            ).contains(foreignAxis))
        }

        var splicedCases = enAttestation.cases
        if let existingForeignIndex {
            splicedCases[existingForeignIndex] = foreignLiveCase
        } else {
            splicedCases.append(foreignLiveCase)
        }
        let splicedCaseJSON = try JSONSerialization.jsonObject(with: encoder.encode(splicedCases))
        try Self.mutateJSONObject(at: en.caseManifestURL) { object in
            object["cases"] = splicedCaseJSON
        }

        let replacementCases = [foreignLiveCase]
        for replacementCase in replacementCases {
            for relativePath in replacementCase.evidenceFiles {
                let source = foreign.directory.appendingPathComponent(relativePath)
                let destination = en.directory.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(contentsOf: source).write(to: destination, options: .atomic)
            }
        }

        let foreignManifest = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: foreign.manifestURL)
            ) as? [String: Any]
        )
        let replacementIDs = Set(replacementCases.map(\.id))
        let foreignEntries = try #require(foreignManifest["files"] as? [[String: Any]])
            .filter { entry in
                guard let caseID = entry["case_id"] as? String else { return false }
                guard let path = entry["path"] as? String else { return false }
                return replacementIDs.contains(caseID)
                    && foreignLiveCase.evidenceFiles.contains(path)
            }
        try #require(!foreignEntries.isEmpty)
        let caseManifestData = try Data(contentsOf: en.caseManifestURL)
        try Self.mutateJSONObject(at: en.manifestURL) { object in
            var entries = try #require(object["files"] as? [[String: Any]])
            entries.removeAll { entry in
                guard let caseID = entry["case_id"] as? String else { return false }
                return replacementIDs.contains(caseID)
            }
            entries.append(contentsOf: foreignEntries)
            entries.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
            object["files"] = entries
            object["case_manifest_sha256"] = SupportBundleBuilder.sha256(caseManifestData)
        }

        let manifestSHA256 = SupportBundleBuilder.sha256(try Data(contentsOf: en.manifestURL))
        let counts = QualificationSummaryCounts(cases: splicedCases)
        let splicedManifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: en.manifestURL)) as? [String: Any]
        )
        let splicedEntries = try #require(splicedManifest["files"] as? [[String: Any]])
        let manifestPaths = splicedEntries.compactMap { $0["path"] as? String }
        let expectedPaths = Set(splicedCases.flatMap(\.evidenceFiles))
        let actualPaths = Set(manifestPaths)
        let duplicatePaths = Dictionary(grouping: manifestPaths, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        #expect(duplicatePaths.isEmpty, "duplicates=\(duplicatePaths)")
        #expect(
            actualPaths == expectedPaths,
            "missing=\(expectedPaths.subtracting(actualPaths).sorted()) extra=\(actualPaths.subtracting(expectedPaths).sorted())"
        )
        try Self.mutateJSONObject(at: en.attestationURL) { object in
            object["cases"] = splicedCaseJSON
            object["total"] = counts.total
            object["passed"] = counts.passed
            object["failed"] = counts.failed
            object["waived"] = counts.waived
            object["evidenceManifestSHA256"] = manifestSHA256
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["evidenceManifestSHA256"] = manifestSHA256
            object["provenance"] = provenance
        }

        let signing = QualificationRunner.signTrusted(
            candidateURL: en.executableURL,
            bundleURL: en.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            signingPrivateKeyData: en.signingKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        #expect(signing.exitCode == 1, "a single-run signer must not bless another run's live axis")
        let rejections = try #require(try Self.resultObject(signing)["rejections"] as? [[String: Any]])
        #expect(rejections.contains {
            $0["reason"] as? String == "foreignLiveAxisInSingleRun"
        }, "\(signing.stdout)")

        try en.forceSignForDiagnosticFixture()
        let verification = await en.verify(expectedSHA256: en.binarySHA256)
        #expect(verification.exitCode == 1)
        let verificationRejections = try #require(
            try Self.resultObject(verification)["rejections"] as? [[String: Any]]
        )
        #expect(verificationRejections.contains {
            $0["reason"] as? String == "foreignLiveAxisInSingleRun"
        }, "\(verification.stdout)")
    }

    @Test func matrixEnvelopeBindsTwoIntactAxisBundlesAndRejectsChildMutation() async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let executableData = Data("matrix-envelope-candidate".utf8)
        let commitSHA = String(repeating: "b", count: 40)
        let en = try Fixture(
            specs: specs,
            executableData: executableData,
            commitSHA: commitSHA,
            drive: { _ in Self.driveResult(specs: specs, observedLocale: "en-US") }
        )
        let ko = try Fixture(
            specs: specs,
            executableData: executableData,
            commitSHA: commitSHA,
            drive: { _ in Self.driveResult(specs: specs, observedLocale: "ko-KR") }
        )
        let matrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualification-matrix-\(UUID().uuidString)", isDirectory: true)
        defer {
            en.remove()
            ko.remove()
            try? FileManager.default.removeItem(at: matrix)
        }

        try #require((await en.runQualification(mutateOpenProject: false)).exitCode == 0)
        let koResult = await ko.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", ko.attestationURL.path,
            "--release-version", "1.2.3",
            "--locale", "ko",
        ])
        try #require(koResult.exitCode == 0, "\(koResult.stdout)\(koResult.stderr)")

        try FileManager.default.createDirectory(at: matrix, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: en.directory, to: matrix.appendingPathComponent("en"))
        try FileManager.default.copyItem(at: ko.directory, to: matrix.appendingPathComponent("ko"))
        let input: [String: Any] = [
            "schema": "qualification-matrix-input/v1",
            "runs": [["path": "en"], ["path": "ko"]],
        ]
        try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])
            .write(to: matrix.appendingPathComponent("qualification-matrix-input.json"))

        let excessiveInputMatrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualification-matrix-excessive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: matrix, to: excessiveInputMatrix)
        defer { try? FileManager.default.removeItem(at: excessiveInputMatrix) }
        try Self.mutateJSONObject(
            at: excessiveInputMatrix.appendingPathComponent("qualification-matrix-input.json")
        ) { object in
            var runs = try #require(object["runs"] as? [[String: Any]])
            runs.append(["path": "missing"])
            object["runs"] = runs
        }
        let excessiveInput = QualificationRunner.signTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: excessiveInputMatrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            signingPrivateKeyData: en.signingKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        let excessiveInputReasons = Self.rejectionReasons(try Self.resultObject(excessiveInput))
        #expect(excessiveInputReasons.contains("evidenceBindingMismatch"), "\(excessiveInput.stdout)")
        #expect(!excessiveInputReasons.contains("matrixSignerFailure"), "\(excessiveInput.stdout)")

        let duplicateRunMatrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualification-matrix-duplicate-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: matrix, to: duplicateRunMatrix)
        defer { try? FileManager.default.removeItem(at: duplicateRunMatrix) }
        let duplicateRunID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try Self.mutateJSONObject(at: duplicateRunMatrix.appendingPathComponent(
            "en/release-qualification-attestation.json"
        )) { object in
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["runID"] = duplicateRunID
            object["provenance"] = provenance
        }
        try Self.mutateJSONObject(at: duplicateRunMatrix.appendingPathComponent(
            "ko/release-qualification-attestation.json"
        )) { object in
            var provenance = try #require(object["provenance"] as? [String: Any])
            provenance["runID"] = duplicateRunID.uppercased()
            object["provenance"] = provenance
        }
        let duplicateRun = QualificationRunner.signTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: duplicateRunMatrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            signingPrivateKeyData: en.signingKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        let duplicateRunReasons = Self.rejectionReasons(try Self.resultObject(duplicateRun))
        #expect(duplicateRunReasons.contains("evidenceBindingMismatch"), "\(duplicateRun.stdout)")

        let custodyMatrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualification-matrix-custody-\(UUID().uuidString)", isDirectory: true)
        let displacedMatrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualification-matrix-displaced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: matrix, to: custodyMatrix)
        let replacer = MatrixDirectoryReplacement(
            requested: custodyMatrix,
            displaced: displacedMatrix
        )
        defer {
            try? FileManager.default.removeItem(at: custodyMatrix)
            try? FileManager.default.removeItem(at: displacedMatrix)
        }
        let custodyRefusal = QualificationRunner.signTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: custodyMatrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            signingPrivateKeyData: en.signingKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs,
            beforeMatrixAttestationPublish: replacer.replace
        )
        #expect(replacer.didReplace)
        #expect(custodyRefusal.exitCode == 1, "\(custodyRefusal.stdout)\(custodyRefusal.stderr)")
        let custodyRejections = try #require(
            try Self.resultObject(custodyRefusal)["rejections"] as? [[String: Any]]
        )
        #expect(custodyRejections.contains {
            $0["reason"] as? String == "matrixSignerFailure"
                && ($0["actual"] as? String)?.contains(
                    "Matrix directory changed before publication"
                ) == true
        }, "\(custodyRefusal.stdout)")
        for directory in [custodyMatrix, displacedMatrix] {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(
                "release-qualification-matrix.json"
            ).path))
        }

        let signing = QualificationRunner.signTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: matrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            signingPrivateKeyData: en.signingKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        try #require(signing.exitCode == 0, "\(signing.stdout)")
        let accepted = QualificationRunner.verifyTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: matrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            trustedPublicKeyData: en.trustedPublicKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        #expect(accepted.exitCode == 0, "\(accepted.stdout)")

        let envelopeURL = matrix.appendingPathComponent("release-qualification-matrix.json")
        let signedEnvelopeData = try Data(contentsOf: envelopeURL)
        try Self.mutateJSONObject(at: envelopeURL) { object in
            var runs = try #require(object["runs"] as? [[String: Any]])
            runs[0]["path"] = "missing"
            object["runs"] = runs
        }
        let invalidRoot = QualificationRunner.verifyTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: matrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            trustedPublicKeyData: en.trustedPublicKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        let invalidRootReasons = Self.rejectionReasons(try Self.resultObject(invalidRoot))
        #expect(invalidRootReasons.contains("matrixSignatureInvalid"), "\(invalidRoot.stdout)")
        #expect(!invalidRootReasons.contains("matrixVerifierFailure"), "\(invalidRoot.stdout)")
        try signedEnvelopeData.write(to: envelopeURL, options: .atomic)

        let signedEnvelope = try JSONDecoder().decode(
            ReleaseQualificationMatrixAttestation.self,
            from: signedEnvelopeData
        )
        let firstRun = try #require(signedEnvelope.runs.first)
        let excessiveRuns = signedEnvelope.runs + [ReleaseQualificationMatrixAttestation.Run(
            axis: firstRun.axis,
            path: "missing",
            childAttestationSHA256: String(repeating: "0", count: 64)
        )]
        let excessiveUnsigned = ReleaseQualificationMatrixAttestation(
            schema: signedEnvelope.schema,
            releaseVersion: signedEnvelope.releaseVersion,
            commitSHA: signedEnvelope.commitSHA,
            binarySHA256: signedEnvelope.binarySHA256,
            logicVersion: signedEnvelope.logicVersion,
            profile: signedEnvelope.profile,
            cache: signedEnvelope.cache,
            fixture: signedEnvelope.fixture,
            operationCatalogSHA256: signedEnvelope.operationCatalogSHA256,
            runs: excessiveRuns,
            signature: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: en.signingKeyData)
        let excessiveSignature = QualificationProvenanceSignature(
            algorithm: "ed25519",
            keyID: SupportBundleBuilder.sha256(signingKey.publicKey.rawRepresentation),
            value: try signingKey.signature(for: encoder.encode(excessiveUnsigned.payload))
                .base64EncodedString()
        )
        let excessiveEnvelope = ReleaseQualificationMatrixAttestation(
            schema: excessiveUnsigned.schema,
            releaseVersion: excessiveUnsigned.releaseVersion,
            commitSHA: excessiveUnsigned.commitSHA,
            binarySHA256: excessiveUnsigned.binarySHA256,
            logicVersion: excessiveUnsigned.logicVersion,
            profile: excessiveUnsigned.profile,
            cache: excessiveUnsigned.cache,
            fixture: excessiveUnsigned.fixture,
            operationCatalogSHA256: excessiveUnsigned.operationCatalogSHA256,
            runs: excessiveUnsigned.runs,
            signature: excessiveSignature
        )
        try encoder.encode(excessiveEnvelope).write(to: envelopeURL, options: .atomic)
        let excessiveRoot = QualificationRunner.verifyTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: matrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            trustedPublicKeyData: en.trustedPublicKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        let excessiveRootReasons = Self.rejectionReasons(try Self.resultObject(excessiveRoot))
        #expect(excessiveRootReasons.contains("evidenceBindingMismatch"), "\(excessiveRoot.stdout)")
        #expect(!excessiveRootReasons.contains("matrixVerifierFailure"), "\(excessiveRoot.stdout)")
        try signedEnvelopeData.write(to: envelopeURL, options: .atomic)

        let childAttestation = matrix.appendingPathComponent(
            "en/release-qualification-attestation.json"
        )
        var mutated = try Data(contentsOf: childAttestation)
        mutated[mutated.startIndex] = 0x5b
        try mutated.write(to: childAttestation, options: .atomic)

        let rejected = QualificationRunner.verifyTrustedMatrix(
            candidateURL: en.executableURL,
            matrixURL: matrix,
            releaseVersion: "1.2.3",
            expectedCommitSHA: commitSHA,
            trustedPublicKeyData: en.trustedPublicKeyData,
            requiredArtifacts: [],
            requiredOperationIDs: en.requiredOperationIDs
        )
        #expect(rejected.exitCode == 1)
        let rejections = try #require(
            try Self.resultObject(rejected)["rejections"] as? [[String: Any]]
        )
        #expect(rejections.contains {
            $0["reason"] as? String == "matrixChildDigestMismatch"
                && $0["key"] as? String == "en"
        }, "\(rejected.stdout)")
    }

    @Test func trustedCLIDispatchesMatrixVerificationThroughTheMatrixBoundary() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-qualification-matrix-\(UUID().uuidString)")
        let result = QualificationRunner.runTrusted(arguments: [
            "trusted-verifier", "verify-matrix",
            "--candidate", missing.appendingPathComponent("LogicProMCP").path,
            "--matrix-index", missing.appendingPathComponent("qualification-matrix-input.json").path,
            "--release-version", "1.2.3",
            "--expected-commit", String(repeating: "c", count: 40),
        ], environment: [
            "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY": Data(repeating: 1, count: 32)
                .base64EncodedString(),
        ])

        try Self.expectRejection(result, reason: "matrixVerifierFailure")
    }

    @Test func inProcessCasesMatchRegistryHandlersAndTraces() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--release-version", "1.2.3",
        ])

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("case(s) failed"),
                "the run says what failed instead of leaving the caller to parse JSON")
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        let operationCases = attestation.cases.filter { $0.id.hasPrefix("in-process/") }
        let aggregateCases = attestation.cases.filter { !$0.id.hasPrefix("in-process/") }
        let expectedOperations = Set(OperationRegistry.specs.map(\.id.rawValue))
        let actualOperations = Set(operationCases.map { String($0.id.dropFirst("in-process/".count)) })

        #expect(operationCases.count == OperationRegistry.specs.count)
        #expect(actualOperations == expectedOperations, "missing operation cases: \(expectedOperations.subtracting(actualOperations).sorted())")
        #expect(aggregateCases.map(\.id) == QualificationAxis.requiredCombinations.map(\.key))
        #expect(attestation.cases.map(\.id).count == Set(attestation.cases.map(\.id)).count)
        #expect(aggregateCases.filter { $0.status == .passed }.isEmpty)
        // Desktop-only ship matrix (2 axes): the observed axis (desktop/en-US)
        // fails because mutating ops are not live-run, and the sole remaining
        // ship axis (desktop/ko-KR) is not qualified (no waiver supplied).
        #expect(aggregateCases.filter { $0.status == .failed }.count == 1)
        #expect(aggregateCases.filter { $0.status == .notQualified }.count == 1)
        // Derive credit from the declared independent-readback scope, not oracle presence alone.
        let readOnlyCount = OperationRegistry.specs.filter { $0.mutability == .readOnly }.count
        let marked = Set(SemanticOracleTable.all
            .filter { $0.independentReadbackDeferral != nil }.map(\.operationID))
        #expect(marked == Set<OperationID>([.midiListPorts, .tracksListLibrary, .midiReadSelectedRegionEvents, .mixerGetOutputVerified, .mixerGetSendDestinationVerified,
            .mixerGetInputBusVerified, .mixerGetSendBypassVerified, .pluginsPlanParameterChanges,
            .pluginsGetHostParameterManifest, .pluginsGetParamVerified, .pluginsGetChannelEQStateVerified]))
        let smokeOnly = marked.subtracting([.midiListPorts, .tracksListLibrary])
        let smokeOnlyIDs = Set(smokeOnly.map(\.rawValue))
        let readOnlyIDs = Set(OperationRegistry.specs.filter { $0.mutability == .readOnly }.map(\.id.rawValue))
        let passed = operationCases.filter { $0.status == .passed }
        #expect(passed.count == readOnlyCount - smokeOnly.count)
        #expect(Set(passed.map(\.operationID)) == readOnlyIDs.subtracting(smokeOnlyIDs))
        let smoke = operationCases.filter { $0.status == .protocolSmoke }
        #expect(smoke.count == smokeOnly.count)
        #expect(Set(smoke.map(\.operationID)) == smokeOnlyIDs)
        // DERIVED: everything the registry has, minus the read-only specs this fixture qualifies.
        // It was `90`, and the day main added `system.setup_control_surface` it read 91 -- a number
        // that tracks the registry turns every new operation into a failing test that says
        // nothing about the product.
        #expect(operationCases.filter { $0.status == .notQualified }.count
                    == OperationRegistry.specs.count - readOnlyCount)
        // Other semantic reads + health's bespoke validator pass; the same-handler smoke
        // and aggregate axes contribute no passes here.
        #expect(attestation.passed == readOnlyCount - smokeOnly.count)
        #expect(attestation.failed == 1)

        for qualificationCase in operationCases {
            let spec = try #require(OperationRegistry.spec(
                tool: qualificationCase.tool,
                command: qualificationCase.command
            ))
            #expect(qualificationCase.id == "in-process/\(spec.id.rawValue)")
            #expect(OperationHandlerRegistry.handler(tool: qualificationCase.tool, command: qualificationCase.command) != nil)
            if spec.mutability == .readOnly {
                if smokeOnly.contains(spec.id) {
                    let declared = try #require(QualificationSemanticReadbackValidator.independentReadbackDeferral(
                        for: spec.id.rawValue))
                    #expect(qualificationCase.status == .protocolSmoke)
                    #expect(!qualificationCase.verified)
                    #expect(qualificationCase.verificationKind == .protocolSmoke)
                    #expect(qualificationCase.deferral == declared)
                    #expect(declared.code == .semanticValidatorUnavailable)
                    let readback = try #require(qualificationCase.readback)
                    #expect(!readback.verified)
                    #expect(!PromotionGate.operationIsLiveCredited(qualificationCase))
                } else {
                    // Every other read-only operation retains semantic credit and evidence.
                    #expect(qualificationCase.status == .passed)
                    #expect(qualificationCase.verified)
                    #expect(qualificationCase.verificationKind == .semanticReadback)
                    #expect(qualificationCase.deferral == nil)
                    let readback = try #require(qualificationCase.readback)
                    #expect(readback.verified)
                }
            } else {
                #expect(qualificationCase.status == .notQualified)
                #expect(!qualificationCase.verified)
                #expect(qualificationCase.verificationKind == .typedDeferral)
                #expect(qualificationCase.deferral?.code == .liveMutationNotRun)
                let v1 = try #require(qualificationCase.deferral?.detail.contains("ADR-001-c"))
                #expect(v1)
            }
            #expect(qualificationCase.readback != nil)
            if spec.id == .systemSagaExecute {
                #expect(TraceID.isValid(qualificationCase.traceID))
            } else {
                #expect(qualificationCase.traceID.isEmpty)
            }
            let evidencePath = try #require(qualificationCase.evidenceFiles.first)
            let evidenceURL = fixture.directory.appendingPathComponent(evidencePath)
            let evidence = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String: Any]
            )
            let v2 = try #require(evidence["registry_spec_found"] as? Bool)
            #expect(v2)
            let v3 = try #require(evidence["handler_bound"] as? Bool)
            #expect(v3)
            let traceStarted = evidence["trace_started"] as? Bool ?? false
            #expect(spec.id == .systemSagaExecute ? traceStarted : !traceStarted)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        let manifestData = try Data(contentsOf: fixture.manifestURL)
        #expect(attestation.evidenceManifestSHA256 == SupportBundleBuilder.sha256(manifestData))
    }

    @Test func atlasEvidenceCannotOverwriteExternalEvidence() async throws {
        let flag = "LOGIC_MCP_ADR007_SELECTOR_ATLAS"
        let previous = getenv(flag).map { String(cString: $0) }
        setenv(flag, "1", 1)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        for (path, reason) in [
            ("evidence/atlas-drift-diff.json", "External evidence binding mismatch"),
            ("evidence/./atlas-drift-diff.json", "Invalid evidence path"),
            ("evidence/ATLAS-DRIFT-DIFF.JSON", "External evidence binding mismatch"),
        ] {
            let spec = try #require(OperationRegistry.spec(tool: "logic_system", command: "health"))
            let fixture = try Fixture(specs: [spec])
            defer { fixture.remove() }
            let external = QualificationCase(id: "external/atlas-path-control", status: .failed,
                tool: "external", command: "observe", traceID: "controlled-external-case", verified: false,
                evidenceFiles: [path], reason: "controlled failure", binarySHA256: fixture.binarySHA256,
                axis: .defaultAxis, operationID: "qualification.external-control", verificationKind: .typedDeferral)
            let evidence = CaseEvidence(schema: "qualification-case-evidence/v3", caseID: external.id,
                operationID: external.operationID, tool: external.tool, command: external.command,
                registrySpecFound: false, handlerBound: false, traceStarted: false, traceCompleted: false,
                failureReason: external.reason, binarySHA256: fixture.binarySHA256, axis: .defaultAxis,
                status: .failed, verified: false, verificationKind: .typedDeferral)
            #expect(QualificationRunner.evidence(evidence, binds: external))
            #expect(QualificationRunner.evidenceShapeIsValid(evidence))
            let original = try JSONEncoder().encode(evidence)
            let evidenceURL = fixture.directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: evidenceURL)
            try JSONEncoder().encode(QualificationCaseManifest(schema: "qualification-case-manifest/v1",
                binarySHA256: fixture.binarySHA256, cases: [external])).write(to: fixture.externalCasesURL)
            let result = await fixture.runner.run(arguments: ["LogicProMCP", "--qualify",
                "--out", fixture.attestationURL.path, "--release-version", "1.2.3",
                "--cases", fixture.externalCasesURL.path])
            #expect(try Data(contentsOf: evidenceURL) == original, "\(path)")
            #expect(result.exitCode != 0)
            #expect(result.stderr.contains(reason), "\(path)")
        }
    }

    @Test func externalCasesRequireExactManifestBinding() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }
        let responseArtifact = QualificationOperationResponseArtifact(
            operationID: OperationID.systemHealth.rawValue,
            tool: "logic_system",
            command: "health",
            requestID: "external-health-operation",
            isError: false,
            payload: #"{"success":true}"#
        )
        let responseData = try JSONEncoder().encode(responseArtifact)
        let readbackArtifact = QualificationReadbackArtifact(
            source: "logic://system/health",
            requestID: "external-health-readback",
            payload: #"{"logic_pro_running":true}"#
        )
        let readbackData = try JSONEncoder().encode(readbackArtifact)
        let readback = QualificationReadbackEvidence(
            source: "logic://system/health",
            requestID: "external-health-readback",
            verified: true,
            sha256: SupportBundleBuilder.sha256(readbackData)
        )
        let evidenceFiles = [
            "external/live-case.json",
            "external/live-case-response.json",
            "external/live-case-readback.json",
        ]
        let external = QualificationCase(
            id: "external/live-case",
            status: .passed,
            tool: "logic_system",
            command: "health",
            traceID: "lpmcp_00000000-0000-0000-0000-000000000000",
            verified: true,
            evidenceFiles: evidenceFiles,
            binarySHA256: fixture.binarySHA256,
            axis: .defaultAxis,
            operationID: OperationID.systemHealth.rawValue,
            operationRequestID: responseArtifact.requestID,
            verificationKind: .readResponse,
            readback: readback
        )
        let externalEvidenceURL = fixture.directory.appendingPathComponent("external/live-case.json")
        try FileManager.default.createDirectory(
            at: externalEvidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let externalEvidence = CaseEvidence(
            schema: "qualification-case-evidence/v3",
            caseID: external.id,
            operationID: external.operationID,
            tool: external.tool,
            command: external.command,
            registrySpecFound: true,
            handlerBound: true,
            traceStarted: true,
            traceCompleted: true,
            binarySHA256: fixture.binarySHA256,
            axis: external.axis,
            status: .passed,
            verified: true,
            verificationKind: .readResponse,
            readback: readback,
            operationResponseSHA256: SupportBundleBuilder.sha256(responseData),
            operationRequestID: responseArtifact.requestID,
            operationIsError: false
        )
        try JSONEncoder().encode(externalEvidence).write(to: externalEvidenceURL)
        try responseData.write(
            to: fixture.directory.appendingPathComponent(evidenceFiles[1])
        )
        try readbackData.write(
            to: fixture.directory.appendingPathComponent(evidenceFiles[2])
        )
        try JSONEncoder().encode(QualificationCaseManifest(
            schema: "qualification-case-manifest/v1",
            binarySHA256: fixture.binarySHA256,
            cases: [external]
        )).write(to: fixture.externalCasesURL)

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--cases", fixture.externalCasesURL.path,
            "--release-version", "1.2.3",
        ])

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("case(s) failed"),
                "the run says what failed instead of leaving the caller to parse JSON")
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(attestation.cases.last == external)
        // 1 operation case (specs.prefix(1)) + 2 desktop ship axes + 1 bound
        // external case.
        #expect(attestation.total == 4)
    }

    @Test func tamperedExternalCaseBindingRejectsPromotion() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }
        let readback = QualificationReadbackEvidence(
            source: "logic://system/health",
            requestID: "tampered-axis-readback",
            verified: true,
            sha256: String(repeating: "e", count: 64)
        )
        let external = QualificationCase(
            id: "external/tampered-case",
            status: .passed,
            tool: "logic_system",
            command: "health",
            traceID: "lpmcp_00000000-0000-0000-0000-000000000000",
            verified: true,
            evidenceFiles: ["external/tampered-case.json"],
            binarySHA256: fixture.binarySHA256,
            axis: .defaultAxis,
            operationID: OperationID.systemHealth.rawValue,
            verificationKind: .readResponse,
            readback: readback
        )
        let evidenceURL = fixture.directory.appendingPathComponent("external/tampered-case.json")
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let swappedAxis = QualificationAxis(
            variant: .creatorStudio,
            locale: .koKR,
            profile: .core,
            cache: .cold,
            fixture: .empty
        )
        try JSONEncoder().encode(CaseEvidence(
            schema: "qualification-case-evidence/v3",
            caseID: external.id,
            operationID: external.operationID,
            tool: external.tool,
            command: external.command,
            registrySpecFound: true,
            handlerBound: true,
            traceStarted: true,
            traceCompleted: true,
            binarySHA256: fixture.binarySHA256,
            axis: swappedAxis,
            status: .passed,
            verified: true,
            verificationKind: .readResponse,
            readback: readback,
            operationResponseSHA256: String(repeating: "f", count: 64)
        )).write(to: evidenceURL)
        try JSONEncoder().encode(QualificationCaseManifest(
            schema: "qualification-case-manifest/v1",
            binarySHA256: fixture.binarySHA256,
            cases: [external]
        )).write(to: fixture.externalCasesURL)

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--cases", fixture.externalCasesURL.path,
            "--variant", "desktop",
            "--locale", "en",
            "--profile", "core",
            "--cache", "cold",
            "--release-version", "1.2.3",
        ])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("evidence binding"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func passedExternalCaseWithoutResponseOrReadbackArtifactsRejects() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }
        let external = QualificationCase(
            id: "external/missing-artifacts",
            status: .passed,
            tool: "logic_system",
            command: "health",
            traceID: "",
            verified: true,
            evidenceFiles: ["external/missing-artifacts.json"],
            binarySHA256: fixture.binarySHA256,
            axis: .defaultAxis,
            operationID: OperationID.systemHealth.rawValue,
            verificationKind: .readResponse
        )
        let evidenceURL = fixture.directory.appendingPathComponent(external.evidenceFiles[0])
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(CaseEvidence(
            schema: "qualification-case-evidence/v3",
            caseID: external.id,
            operationID: external.operationID,
            tool: external.tool,
            command: external.command,
            registrySpecFound: true,
            handlerBound: true,
            traceStarted: false,
            traceCompleted: false,
            binarySHA256: fixture.binarySHA256,
            axis: external.axis,
            status: .passed,
            verified: true,
            verificationKind: .readResponse
        )).write(to: evidenceURL)
        try JSONEncoder().encode(QualificationCaseManifest(
            schema: "qualification-case-manifest/v1",
            binarySHA256: fixture.binarySHA256,
            cases: [external]
        )).write(to: fixture.externalCasesURL)

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--cases", fixture.externalCasesURL.path,
            "--release-version", "1.2.3",
        ])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("evidence binding"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func waiverIngestionEmbedsValidatedSet() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }
        let waiver = Self.waiver(caseID: "optional/live-case")
        try JSONEncoder().encode([waiver]).write(to: fixture.waiversURL)

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--waivers", fixture.waiversURL.path,
            "--release-version", "1.2.3",
        ])

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(result.exitCode == 1)
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(attestation.waivers == [waiver])
    }

    @Test func malformedWaiverRejectsQualify() async throws {
        let invalidWaivers: [(field: String, waiver: QualificationWaiver)] = [
            ("caseID", Self.waiver(caseID: "")),
            ("reasonCode", Self.waiver(caseID: "optional/live-case", reasonCode: "unknown")),
            ("owningIssue", Self.waiver(caseID: "optional/live-case", owningIssue: "")),
            ("userImpact", Self.waiver(caseID: "optional/live-case", userImpact: "")),
            ("affectedCapability", Self.waiver(caseID: "optional/live-case", affectedCapability: "")),
            ("expiryVersion", Self.waiver(caseID: "optional/live-case", expiryVersion: "soon")),
        ]

        for invalid in invalidWaivers {
            let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
            defer { fixture.remove() }
            try JSONEncoder().encode([invalid.waiver]).write(to: fixture.waiversURL)

            let result = await fixture.runner.run(arguments: [
                "LogicProMCP", "--qualify",
                "--out", fixture.attestationURL.path,
                "--waivers", fixture.waiversURL.path,
                "--release-version", "1.2.3",
            ])

            #expect(result.exitCode != 0)
            #expect(result.stderr.contains(invalid.field))
            #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.directory.appendingPathComponent("evidence").path
            ))
        }
    }

    @Test func duplicateWaiverRejectsQualify() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }
        let waiver = Self.waiver(caseID: "optional/live-case")
        try JSONEncoder().encode([waiver, waiver]).write(to: fixture.waiversURL)

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--waivers", fixture.waiversURL.path,
            "--release-version", "1.2.3",
        ])

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Duplicate waiver"))
        #expect(result.stderr.contains(waiver.caseID))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("evidence").path
        ))
    }

    @Test func sameSHAApprovesWithExitZero() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData))
        let json = try Self.resultObject(result)
        let promotable = try #require(json["promotable"] as? Bool)
        let rejections = try #require(json["rejections"] as? [[String: Any]])

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(result.exitCode == 0)
        #expect(promotable)
        #expect(rejections.isEmpty)
    }

    @Test func verifyPromotionRejectsReleaseCommitMismatch() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)
        let releasedCommit = String(repeating: "b", count: 40)
        #expect(releasedCommit != fixture.commitSHA)

        let result = await fixture.verify(
            expectedSHA256: fixture.binarySHA256,
            expectedCommit: releasedCommit
        )
        let json = try Self.resultObject(result)

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(json).contains("releaseCommitMismatch"))
    }

    @Test func verifyPromotionAcceptsMatchingExpectedCommit() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(
            expectedSHA256: fixture.binarySHA256,
            expectedCommit: fixture.commitSHA
        )

        #expect(result.exitCode == 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).isEmpty)
    }

    /// The PUBLISHED-vs-candidate digest comparison is a SECOND site, separate from the gate's
    /// attestation-vs-candidate check. Splitting the unparseable cause in `PromotionGate` and not
    /// here left `--expected-binary-sha256 not-a-sha` still reporting `binarySHAMismatch` — the fix
    /// applied to one named instance rather than to the property, and a review caught it.
    ///
    /// This drives the real CLI path. The `PromotionGate`-level test cannot reach this site: the
    /// gate is handed the COMPUTED candidate digest, never the supplied one.
    @Test func malformedPublishedSHAIsReportedUnparseableNotMismatched() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: "not-a-sha")
        let json = try Self.resultObject(result)
        let reasons = Self.rejectionReasons(json)

        #expect(result.exitCode != 0)
        #expect(reasons.contains("binarySHAUnparseable"))
        // The distinction is the whole point: a malformed value is not a disagreement.
        #expect(!reasons.contains("binarySHAMismatch"))
    }

    /// The other side, so moving every case to `Unparseable` cannot satisfy the test above: a
    /// well-formed published digest that genuinely differs must still read as a mismatch.
    @Test func wellFormedDifferentPublishedSHAStillReportsMismatch() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let otherDigest = String(repeating: "a", count: 64)
        #expect(otherDigest != fixture.binarySHA256)

        let result = await fixture.verify(expectedSHA256: otherDigest)
        let reasons = Self.rejectionReasons(try Self.resultObject(result))

        #expect(result.exitCode != 0)
        #expect(reasons.contains("binarySHAMismatch"))
        #expect(!reasons.contains("binarySHAUnparseable"))
    }

    @Test func differentPublishedSHARejects() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: String(repeating: "b", count: 64))
        let json = try Self.resultObject(result)
        let promotable = try #require(json["promotable"] as? Bool)

        #expect(result.exitCode != 0)
        #expect(!promotable)
        #expect(Self.rejectionReasons(json).contains("binarySHAMismatch"))
    }

    @Test func releaseVersionMismatchRejectsThroughCLI() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        _ = try await fixture.qualify()

        let result = await fixture.verify(
            releaseVersion: "1.2.4",
            expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData)
        )

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("releaseVersionMismatch"))
    }

    @Test func missingRequiredArtifactRejectsThroughCLI() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        _ = try await fixture.qualify()

        let result = await fixture.verify(
            expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData),
            requiredArtifacts: "missing-artifact.json"
        )

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("missingArtifact"))
    }

    @Test func verifyPromotionAcceptsValidRequiredArtifactSchemas() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let driveResult = Self.driveResult(
            specs: [spec],
            mutationRestoreRecords: [Self.recipeShapedRecord()]
        )
        let fixture = try Fixture(specs: [spec], drive: { _ in driveResult })
        defer { fixture.remove() }
        try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(
            expectedSHA256: fixture.binarySHA256,
            requiredArtifacts: "raw-transcript.json,mutation-restore-compensation.json"
        )

        #expect(result.exitCode == 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).isEmpty)
    }

    @Test func verifyPromotionRejectsInvalidRequiredArtifactSchema() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(
            expectedSHA256: fixture.binarySHA256,
            requiredArtifacts: "raw-transcript.json,mutation-restore-compensation.json"
        )
        let json = try Self.resultObject(result)

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(json).contains("requiredArtifactSchemaInvalid"))
        let rejections = try #require(json["rejections"] as? [[String: Any]])
        #expect(rejections.contains {
            $0["reason"] as? String == "requiredArtifactSchemaInvalid"
                && $0["name"] as? String == "mutation-restore-compensation.json"
        })
    }

    @Test func expiredWaiverRejectsThroughCLI() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let original = try await fixture.qualify()
        try fixture.writeAttestation(original, waivers: [QualificationWaiver(
            caseID: "optional-case",
            reasonCode: "known-limitation",
            owningIssue: "#284",
            userImpact: "Optional capability unavailable",
            affectedCapability: "optional-capability",
            affectsDefaultProfile: false,
            expiryVersion: "1.2.3",
            releaseNoteVisible: true
        )])

        let result = await fixture.verify(expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData))

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("expiredWaiver"))
    }

    @Test func verificationEmitsEveryApplicableRejection() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let original = try await fixture.qualify()
        var cases = original.cases
        let aggregateIndex = try #require(cases.firstIndex {
            $0.id == QualificationAxis.requiredCombinations[0].key
        })
        let first = cases[aggregateIndex]
        cases[aggregateIndex] = QualificationCase(
            id: first.id,
            status: .failed,
            tool: first.tool,
            command: first.command,
            traceID: first.traceID,
            verified: false,
            evidenceFiles: first.evidenceFiles
        )
        let changed = fixture.copy(
            original,
            serverVersion: "1.2.2",
            binarySHA256: String(repeating: "a", count: 64),
            cases: cases,
            waivers: [QualificationWaiver(
                caseID: "optional-case",
                reasonCode: "known-limitation",
                owningIssue: "#284",
                userImpact: "Optional capability unavailable",
                affectedCapability: "optional-capability",
                affectsDefaultProfile: false,
                expiryVersion: "1.2.3",
                releaseNoteVisible: true
            )]
        )
        try JSONEncoder().encode(changed).write(to: fixture.attestationURL)

        let result = await fixture.verify(
            releaseVersion: "1.2.3",
            expectedSHA256: String(repeating: "b", count: 64),
            requiredArtifacts: "missing-artifact.json"
        )
        let reasons = Self.rejectionReasons(try Self.resultObject(result))

        #expect(result.exitCode != 0)
        #expect(reasons.contains("requiredCaseFailed"))
        #expect(reasons.contains("binarySHAMismatch"))
        #expect(reasons.contains("missingArtifact"))
        #expect(reasons.contains("expiredWaiver"))
        #expect(reasons.contains("releaseVersionMismatch"))
    }

    @Test func verificationEmitsWaiverAndDuplicateRejectionsThroughCLI() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let original = try await fixture.qualify()
        let passedCase = try #require(original.cases.first { $0.status == .passed })
        let changed = fixture.copy(
            original,
            cases: original.cases + [passedCase],
            waivers: [
                Self.waiver(caseID: "missing-case"),
                Self.waiver(caseID: passedCase.id),
            ]
        )
        try JSONEncoder().encode(changed).write(to: fixture.attestationURL)

        let result = await fixture.verify(
            expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData)
        )
        let reasons = Self.rejectionReasons(try Self.resultObject(result))

        #expect(result.exitCode != 0)
        #expect(reasons.contains("duplicateCaseID"))
        #expect(reasons.contains("waiverForUnknownCase"))
        #expect(reasons.contains("waiverForPassingCase"))
    }

    @Test func verificationRejectsMalformedDuplicateAndImplicitWaivers() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let original = try await fixture.qualify()
        let first = try #require(original.cases.first)
        let waivedCase = QualificationCase(
            id: first.id,
            status: .waived,
            tool: first.tool,
            command: first.command,
            traceID: first.traceID,
            verified: false,
            evidenceFiles: first.evidenceFiles
        )
        var cases = original.cases
        cases[0] = waivedCase
        let validWaiver = Self.waiver(caseID: waivedCase.id)
        let scenarios: [(waivers: [QualificationWaiver], reason: String)] = [
            ([Self.waiver(caseID: waivedCase.id, reasonCode: "unsupported-reason")], "invalidWaiver"),
            ([Self.waiver(caseID: waivedCase.id, owningIssue: "")], "invalidWaiver"),
            ([validWaiver, validWaiver], "duplicateWaiver"),
            ([], "waivedCaseMissingWaiver"),
        ]

        for scenario in scenarios {
            try JSONEncoder().encode(fixture.copy(
                original,
                cases: cases,
                waivers: scenario.waivers
            )).write(to: fixture.attestationURL)

            let result = await fixture.verify(
                expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData)
            )

            #expect(result.exitCode != 0)
            #expect(Self.rejectionReasons(try Self.resultObject(result)).contains(scenario.reason))
        }
    }

    @Test func rebuildAfterQualificationRejects() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        _ = try await fixture.qualify()
        let qualifiedSHA256 = SupportBundleBuilder.sha256(fixture.executableData)
        try Data("rebuilt-after-qualification".utf8).write(to: fixture.executableURL)

        let result = await fixture.verify(expectedSHA256: qualifiedSHA256)

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("binarySHAMismatch"))
    }

    @Test func releaseVersionDifferentFromBinaryRejectsQualification() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--release-version", "9.9.9",
        ])

        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func vPrefixedReleaseTagMatchesBinaryVersion() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }

        let qualification = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--waivers", fixture.waiversURL.path,
            "--release-version", "v1.2.3",
        ])
        fixture.sign(releaseVersion: "v1.2.3")
        let verification = await fixture.verify(
            releaseVersion: "v1.2.3",
            expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData)
        )

        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(qualification.exitCode == 0)
        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(verification.exitCode == 0)
    }

    @Test func tamperedEvidenceRejectsPromotion() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let attestation = try await fixture.qualify()
        let evidencePath = try #require(attestation.cases.first?.evidenceFiles.first)
        try Data("tampered evidence".utf8).write(
            to: fixture.directory.appendingPathComponent(evidencePath),
            options: .atomic
        )

        let result = await fixture.verify(expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData))

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("evidenceBindingMismatch"))
    }

    @Test func tamperedOperationResponseArtifactRejectsPromotion() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let attestation = try await fixture.qualify()
        let operationCase = try #require(attestation.cases.first { $0.id.hasPrefix("in-process/") })
        let responsePath = try #require(operationCase.evidenceFiles.dropFirst().first)
        try Data(#"{"forged":true}"#.utf8).write(
            to: fixture.directory.appendingPathComponent(responsePath),
            options: .atomic
        )

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("evidenceBindingMismatch"))
    }

    @Test func tamperedManifestRejectsPromotion() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        _ = try await fixture.qualify()
        try Data("tampered manifest".utf8).write(to: fixture.manifestURL, options: .atomic)

        let result = await fixture.verify(expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData))

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("evidenceBindingMismatch"))
    }

    @Test func tamperedCaseManifestRejectsPromotionWithTypedBindingReason() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        _ = try await fixture.qualify()
        try Data("tampered case manifest".utf8).write(to: fixture.caseManifestURL, options: .atomic)

        let result = await fixture.verify(expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData))

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("evidenceBindingMismatch"))
    }

    @Test func reservedManifestOutputPathRejectsQualification() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }

        for filename in [
            "evidence-manifest.json", "EVIDENCE-MANIFEST.JSON",
            "case-manifest.json", "CASE-MANIFEST.JSON",
            "operation-catalog.json", "OPERATION-CATALOG.JSON",
        ] {
            let outputURL = fixture.directory.appendingPathComponent(filename)
            let result = await fixture.runner.run(arguments: [
                "LogicProMCP", "--qualify",
                "--out", outputURL.path,
                "--release-version", "1.2.3",
            ])

            #expect(result.exitCode != 0)
            #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    @Test func mainEntrypointRoutesQualificationBeforeSideEffects() async {
        for (subcommand, expectedExitCode) in [("--qualify", 0), ("--verify-promotion", 1)] {
            var receivedArguments: [String] = []
            var stdout = ""
            var stderr = ""
            let result = await MainEntrypoint.run(
                arguments: ["LogicProMCP", subcommand, "--sentinel", "value"],
                permissionCheck: {
                    Issue.record("Permission check must not run for \(subcommand)")
                    return .init(accessibility: false, automationLogicPro: false)
                },
                serverFactory: {
                    Issue.record("Server must not start for \(subcommand)")
                    return MockQualificationServer()
                },
                approvalStoreFactory: {
                    Issue.record("Approval store must not be created for \(subcommand)")
                    return ManualValidationStore()
                },
                qualificationCommand: { arguments in
                    receivedArguments = arguments
                    return QualificationCommandResult(
                        exitCode: expectedExitCode,
                        stdout: "{\"subcommand\":\"\(subcommand)\"}\n",
                        stderr: "qualification-stderr\n"
                    )
                },
                writeStdout: { stdout += $0 },
                writeStderr: { stderr += $0 }
            )

            #expect(result == expectedExitCode)
            #expect(receivedArguments == ["LogicProMCP", subcommand, "--sentinel", "value"])
            #expect(stdout == "{\"subcommand\":\"\(subcommand)\"}\n")
            #expect(stderr == "qualification-stderr\n")
        }
    }

    @Test func helpExplainsRequiredSelectedAtlasWithoutLosingSafetyWording() async {
        var stdout = ""
        var stderr = ""
        let result = await MainEntrypoint.run(
            arguments: ["LogicProMCP", "--help"],
            permissionCheck: {
                Issue.record("Help must not check permissions")
                return .init(accessibility: false, automationLogicPro: false)
            },
            serverFactory: {
                Issue.record("Help must not construct the server")
                return MockQualificationServer()
            },
            approvalStoreFactory: {
                Issue.record("Help must not construct the approval store")
                return ManualValidationStore()
            },
            qualificationCommand: { _ in
                Issue.record("Help must not run qualification")
                return .init(exitCode: 1, stdout: "", stderr: "")
            },
            writeStdout: { stdout += $0 },
            writeStderr: { stderr += $0 })
        #expect(result == 0)
        #expect(stdout == MainEntrypoint.usageText + "\n")
        #expect(stderr.isEmpty)
        #expect(stdout.contains(
            "LogicProMCP --qualify --out <attestation.json> [--require-atlas] [--mutate-open-project]"))
        #expect(stdout.contains(
            "--require-atlas captures required Desktop en/ko scopes: trackHeaderRail and controlBar."))
        #expect(stdout.contains(
            "Set LOGIC_MCP_ATLAS_BASELINES to a matching locale directory containing both baselines."))
        #expect(stdout.contains("--mutate-open-project WRITES TO THE PROJECT LOGIC HAS OPEN"))
        #expect(stdout.contains(
            "non-authoritative local diagnostic; emits a JSON decision with no promotion authority"))
    }

    @Test func helpListsQualificationSubcommands() async {
        var stdout = ""
        let result = await MainEntrypoint.run(
            arguments: ["LogicProMCP", "--help"],
            serverFactory: {
                Issue.record("Server must not start for --help")
                return MockQualificationServer()
            },
            writeStdout: { stdout += $0 },
            writeStderr: { _ in }
        )

        #expect(result == 0)
        #expect(stdout.contains("--qualify --out <attestation.json>"))
        #expect(stdout.contains("--waivers <waivers.json>"))
        #expect(stdout.contains("--verify-promotion --attestation <attestation.json>"))
        #expect(stdout.contains("--expected-binary-sha256 <hex>"))
        #expect(stdout.contains("--expected-commit <sha>"))
        #expect(stdout.contains("non-authoritative local diagnostic"))
    }

    // REMOVED 2026-09-19 with the gate steps it pinned. It asserted that `release.yml` carries
    // seven qualification steps and a verifier pinned at a specific commit. Those steps are not
    // in this change: all seven were `if: vars.ADR001_QUALIFICATION_ENFORCED == 'true'` and that
    // variable is set nowhere, so restoring them would have changed what a release does by
    // nothing, and the pinned verifier they named is 7,522 lines behind this tree and rejects
    // every semantic case it would be asked to check. Wiring the gate is its own change, with a
    // run URL as its acceptance; a test that pins the shape of steps nobody executes is a test
    // about a file, not about a release.


    private static func resultObject(_ result: QualificationCommandResult) throws -> [String: Any] {
        let data = try #require(result.stdout.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func rejectionReasons(_ json: [String: Any]) -> Set<String> {
        let rejections = json["rejections"] as? [[String: Any]] ?? []
        return Set(rejections.compactMap { $0["reason"] as? String })
    }

    private static func expectRejection(
        _ result: QualificationCommandResult,
        reason: String
    ) throws {
        #expect(result.exitCode != 0)
        #expect(rejectionReasons(try resultObject(result)).contains(reason), "\(result.stdout)")
    }

    private static func mutateJSONObject(
        at url: URL,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        try mutate(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url)
    }

    private static func waiver(
        caseID: String,
        reasonCode: String = "known-limitation",
        owningIssue: String = "#284",
        userImpact: String = "Optional capability unavailable",
        affectedCapability: String = "optional-capability",
        expiryVersion: String = "1.3.0"
    ) -> QualificationWaiver {
        QualificationWaiver(
            caseID: caseID,
            reasonCode: reasonCode,
            owningIssue: owningIssue,
            userImpact: userImpact,
            affectedCapability: affectedCapability,
            affectsDefaultProfile: true,
            expiryVersion: expiryVersion,
            releaseNoteVisible: true
        )
    }

    private func promotableFixture(
        trustedPublicKeyData: Data? = nil,
        beforeEvidenceRead: @escaping @Sendable (URL) -> Void = { _ in }
    ) throws -> Fixture {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let fixture = try Fixture(
            specs: [spec],
            trustedPublicKeyData: trustedPublicKeyData,
            beforeEvidenceRead: beforeEvidenceRead
        )
        try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)
        return fixture
    }

    private func trustedFixture(
        specs: [OperationSpec] = OperationRegistry.specs,
        candidateExecutionSentinelURL: URL? = nil,
        includeRequiredAtlas: Bool = true,
        observedLocale: QualificationLocale = .enUS,
        includeAxisWaivers: Bool = true
    ) throws -> Fixture {
        let driveResult = Self.driveResult(
            specs: specs,
            observedLocale: observedLocale.rawValue,
            mutationRestoreRecords: [Self.recipeShapedRecord()]
        )
        let observedAxis = QualificationAxis(
            variant: .desktop,
            locale: observedLocale,
            profile: .core,
            cache: .cold,
            fixture: .empty
        )
        let executableData: Data
        if let candidateExecutionSentinelURL {
            executableData = Data("""
                #!/bin/sh
                touch "\(candidateExecutionSentinelURL.path)"
                exit 0
                """.utf8)
        } else {
            executableData = Data("qualification-binary-fixture".utf8)
        }
        let fixture = try Fixture(
            specs: specs,
            executableData: executableData,
            qualificationIncludesExternalCases: includeRequiredAtlas,
            drive: { _ in driveResult }
        )
        let operationWaivers = specs.compactMap { spec in
            driveResult.operationResults[spec.id.rawValue]?.status == .passed
                ? nil
                : Self.waiver(
                    caseID: "in-process/\(spec.id.rawValue)",
                    affectedCapability: "operation:\(spec.id.rawValue)"
                )
        }
        let waivers = operationWaivers + (includeAxisWaivers
            ? Self.axisWaivers(observedAxis: observedAxis)
            : [])
        try JSONEncoder().encode(waivers)
            .write(to: fixture.waiversURL)
        if includeRequiredAtlas {
            // Controlled archived roots, not a native capture. Current version comes from
            // the same injected drive that establishes this fixture's independent host.
            let pairs = try Self.atlasProducerVersionPairs(
                driveResult.logicProVersion,
                locale: observedLocale
            )
            let atlas = try #require(AtlasQualification.evidenceCaseFor(armed: true,
                pairs: pairs, axis: observedAxis, binarySHA256: fixture.binarySHA256,
                traceID: "trusted-required-atlas-fixture"))
            #expect(atlas.qualificationCase.status == .passed)
            #expect(atlas.qualificationCase.verified)
            let path = try #require(atlas.qualificationCase.evidenceFiles.first)
            let evidenceURL = fixture.directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(atlas.evidence).write(to: evidenceURL)
            try JSONEncoder().encode(QualificationCaseManifest(schema: "qualification-case-manifest/v1",
                binarySHA256: fixture.binarySHA256, cases: [atlas.qualificationCase]))
                .write(to: fixture.externalCasesURL)
        }
        return fixture
    }

    private static func recipeShapedRecord(
        mutation: String = #"{"state":"A","success":true}"#,
        restoreReadback: String = #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"Before"}]}"#
    ) -> QualificationMutationRestoreRecord {
        QualificationMutationRestoreRecord(
            operationID: OperationID.tracksRename.rawValue,
            preState: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"Before"}]}"#,
            mutation: mutation,
            readback: #"{"source":"ax_live","data":[{"track_ref":"track-1","name":"After"}]}"#,
            restore: #"{"state":"A","success":true}"#,
            restoreReadback: restoreReadback
        )
    }

    private func signedTrustedFixture(
        candidateExecutionSentinelURL: URL? = nil
    ) async throws -> Fixture {
        let fixture = try trustedFixture(
            candidateExecutionSentinelURL: candidateExecutionSentinelURL
        )
        let qualification = await fixture.runQualification(waiversURL: fixture.waiversURL)
        guard qualification.exitCode == 0 else {
            fixture.remove()
            throw NSError(
                domain: "TrustedVerifierTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "qualification failed: \(qualification.stderr)"]
            )
        }
        let signing = QualificationRunner.signTrusted(
            candidateURL: fixture.executableURL,
            bundleURL: fixture.directory,
            releaseVersion: "1.2.3",
            expectedCommitSHA: fixture.commitSHA,
            signingPrivateKeyData: fixture.signingKeyData
        )
        guard signing.exitCode == 0 else {
            fixture.remove()
            throw NSError(
                domain: "TrustedVerifierTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "signing failed: \(signing.stdout)"]
            )
        }
        return fixture
    }

    private func signedTrustedMatrixFixture(
        candidateExecutionSentinelURL: URL? = nil
    ) async throws -> SignedMatrixFixture {
        let en = try trustedFixture(
            candidateExecutionSentinelURL: candidateExecutionSentinelURL,
            observedLocale: .enUS,
            includeAxisWaivers: false
        )
        let ko: Fixture
        do {
            ko = try trustedFixture(
                candidateExecutionSentinelURL: candidateExecutionSentinelURL,
                observedLocale: .koKR,
                includeAxisWaivers: false
            )
        } catch {
            en.remove()
            throw error
        }
        let matrix = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-release-matrix-\(UUID().uuidString)", isDirectory: true)
        do {
            let enResult = await en.runQualification(waiversURL: en.waiversURL, locale: .enUS)
            try #require(enResult.exitCode == 0, "\(enResult.stdout)\(enResult.stderr)")
            let koResult = await ko.runQualification(waiversURL: ko.waiversURL, locale: .koKR)
            try #require(koResult.exitCode == 0, "\(koResult.stdout)\(koResult.stderr)")
            try FileManager.default.createDirectory(at: matrix, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: en.directory, to: matrix.appendingPathComponent("en"))
            try FileManager.default.copyItem(at: ko.directory, to: matrix.appendingPathComponent("ko"))
            let input = QualificationMatrixInput(
                schema: QualificationMatrixInput.currentSchema,
                runs: [.init(path: "en"), .init(path: "ko")]
            )
            let inputURL = matrix.appendingPathComponent("qualification-matrix-input.json")
            try QualificationPublicEvidence.encode(input).write(to: inputURL)
            let signing = QualificationRunner.signTrustedMatrix(
                candidateURL: en.executableURL,
                matrixURL: matrix,
                releaseVersion: "1.2.3",
                expectedCommitSHA: en.commitSHA,
                signingPrivateKeyData: en.signingKeyData
            )
            try #require(signing.exitCode == 0, "\(signing.stdout)\(signing.stderr)")
            return SignedMatrixFixture(en: en, ko: ko, directory: matrix)
        } catch {
            en.remove()
            ko.remove()
            try? FileManager.default.removeItem(at: matrix)
            throw error
        }
    }

    private func cachedConsumerSignedTrustedMatrixFixture() async throws
        -> ConsumerSignedMatrixFixture
    {
        let snapshot: ConsumerMatrixSnapshot
        if let cached = await Self.consumerMatrixSnapshotCache.current() {
            snapshot = cached
        } else {
            let source = try await signedTrustedMatrixFixture()
            defer { source.remove() }
            let captured = try ConsumerMatrixSnapshot(source)
            snapshot = await Self.consumerMatrixSnapshotCache.installIfAbsent(captured)
        }
        return try ConsumerSignedMatrixFixture(snapshot)
    }

    private static func axisWaivers(
        observedAxis: QualificationAxis = .defaultAxis
    ) -> [QualificationWaiver] {
        QualificationAxis.requiredAxes(
            profile: observedAxis.profile,
            cache: observedAxis.cache,
            fixture: observedAxis.fixture
        ).filter { $0 != observedAxis }.map {
            waiver(
                caseID: $0.key,
                affectedCapability: QualificationWaiver.hostAxisAvailabilityCapability
            )
        }
    }

    private final class EvidenceSymlinkSwap: @unchecked Sendable {
        private let targetName: String
        private let lock = NSLock()
        private var swapped = false

        init(targetName: String) {
            self.targetName = targetName
        }

        var didSwap: Bool {
            lock.withLock { swapped }
        }

        func swap(_ url: URL) {
            lock.withLock {
                guard !swapped, url.lastPathComponent == targetName else { return }
                let replacement = url.deletingLastPathComponent()
                    .appendingPathComponent("symlink-swap-replacement.json")
                guard let data = try? Data(contentsOf: url),
                      (try? data.write(to: replacement, options: .atomic)) != nil,
                      (try? FileManager.default.removeItem(at: url)) != nil,
                      (try? FileManager.default.createSymbolicLink(
                          at: url,
                          withDestinationURL: replacement
                      )) != nil else {
                    return
                }
                swapped = true
            }
        }
    }

    private final class MatrixDirectoryReplacement: @unchecked Sendable {
        private let requested: URL
        private let displaced: URL
        private let lock = NSLock()
        private var replaced = false

        init(requested: URL, displaced: URL) {
            self.requested = requested
            self.displaced = displaced
        }

        var didReplace: Bool {
            lock.withLock { replaced }
        }

        func replace() {
            lock.withLock {
                guard !replaced,
                      (try? FileManager.default.moveItem(at: requested, to: displaced)) != nil,
                      (try? FileManager.default.createDirectory(
                          at: requested,
                          withIntermediateDirectories: false
                      )) != nil else {
                    return
                }
                replaced = true
            }
        }
    }

    private final class CatalogSecondReadReplacement: @unchecked Sendable {
        private let replacement: Data
        private let lock = NSLock()
        private var catalogURL: URL?
        private var replaced = false

        init(replacement: Data) {
            self.replacement = replacement
        }

        var didReplace: Bool {
            lock.withLock { replaced }
        }

        func replaceOnSecondCatalogRead(_ url: URL) {
            lock.withLock {
                if url.lastPathComponent == "operation-catalog.json" {
                    catalogURL = catalogURL ?? url
                    return
                }
                guard let catalogURL, !replaced,
                      (try? replacement.write(to: catalogURL, options: .atomic)) != nil else {
                    return
                }
                replaced = true
            }
        }
    }

    private final class EvidenceRegularFileReplacement: @unchecked Sendable {
        private let targetName: String
        private let lock = NSLock()
        private var targetURL: URL?
        private var replaced = false

        init(targetName: String) {
            self.targetName = targetName
        }

        var didReplace: Bool {
            lock.withLock { replaced }
        }

        func replaceAfterFirstRead(_ url: URL) {
            lock.withLock {
                if url.lastPathComponent == targetName {
                    targetURL = targetURL ?? url
                    return
                }
                guard let targetURL, !replaced,
                      let data = try? Data(contentsOf: targetURL),
                      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return
                }
                object["untrusted_replacement"] = true
                guard let replacement = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                ), (try? replacement.write(to: targetURL, options: .atomic)) != nil else {
                    return
                }
                replaced = true
            }
        }
    }

    private static let releaseExecutableURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(".build/release/LogicProMCP")

    // #399 (CEO audit P0) — the DEBUG executable HAS the fault seam compiled in,
    // so it is what the debug-gated runner-rejection test drives. Only referenced
    // under `FAULT_TEST_SEAM`.
    #if FAULT_TEST_SEAM
    private static let debugExecutableURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(".build/debug/LogicProMCP")
    #endif

    private enum PublicTranscriptMutation: String, CaseIterable, CustomStringConvertible {
        case digestMismatch
        case wrongManifestKind
        case leakedPayload

        var description: String { rawValue }
    }

    private static func mutatePublicTranscript(
        _ mutation: PublicTranscriptMutation,
        in fixture: Fixture
    ) throws {
        let publicURL = fixture.directory.appendingPathComponent("public-transcript.json")
        var publicObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: publicURL)) as? [String: Any]
        )
        var frames = try #require(publicObject["frames"] as? [[String: Any]])
        switch mutation {
        case .digestMismatch:
            frames[0]["payload_sha256"] = String(repeating: "0", count: 64)
        case .wrongManifestKind:
            break
        case .leakedPayload:
            frames[0]["payload"] = "private payload must never be public"
        }
        publicObject["frames"] = frames
        let publicData = try JSONSerialization.data(
            withJSONObject: publicObject,
            options: [.sortedKeys]
        )
        try publicData.write(to: publicURL, options: .atomic)

        var manifestObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL))
                as? [String: Any]
        )
        var entries = try #require(manifestObject["files"] as? [[String: Any]])
        let entryIndex = try #require(entries.firstIndex {
            $0["path"] as? String == "public-transcript.json"
        })
        entries[entryIndex]["sha256"] = SupportBundleBuilder.sha256(publicData)
        if mutation == .wrongManifestKind {
            entries[entryIndex]["kind"] = "raw_transcript"
        }
        manifestObject["files"] = entries
        try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
            .write(to: fixture.manifestURL, options: .atomic)
    }

    /// Logic's UI language for THIS run, read from Logic's OWN defaults domain.
    ///
    /// `AppleLanguages` under `com.apple.logic10` is what the language switch writes and what a
    /// relaunched Logic picks up, so it is the same fact the run depended on rather than a guess
    /// from the host's locale.
    ///
    /// Read through `persistentDomain(forName:)` rather than `UserDefaults(suiteName:)`, and the
    /// difference is the whole point of the function. A suite's SEARCH LIST includes
    /// `NSGlobalDomain`, and `AppleLanguages` lives there — so a suite read falls through and
    /// answers with the machine's language whenever Logic's own domain is silent. Measured
    /// 2026-09-07 on this machine: `com.apple.logic10` holds `en` while the global domain holds
    /// `ko-KR`, which is exactly the pair that would have been confused. A helper written to
    /// avoid reporting the host locale that reports the host locale is worse than no helper, and
    /// `logicUILanguageIsReadFromLogicsOwnDefaultsNotTheHostLocale` caught this before it shipped.
    ///
    /// A domain with no such key means Logic has never been switched and follows the system,
    /// which is stated as such instead of being filled in with a plausible value.
    private static func logicUILanguage(
        domain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "com.apple.logic10")
    ) -> String {
        guard let languages = domain?["AppleLanguages"] as? [String],
              let first = languages.first, !first.isEmpty else {
            return "unset (Logic follows the system language)"
        }
        return first
    }

    /// Failures as one line each, because a red run that prints nothing is why #803 was opened.
    private static func describe(_ failures: [QualificationLiveGateSummary.Failure]) -> String {
        guard !failures.isEmpty else { return "  (none)" }
        return failures
            .map { "  \($0.operationID): \($0.failureReason)" }
            .joined(separator: "\n")
    }

    private static func tracksListLibraryRefusal(
        error: String = HonestContract.FailureError.libraryPanelUnavailable.rawValue,
        hint: String = AccessibilityChannel.libraryListPanelUnavailableHint
    ) -> QualificationOperationResult {
        QualificationOperationResult(
            operationID: OperationID.tracksListLibrary.rawValue,
            tool: "logic_tracks",
            command: "list_library",
            mutability: .readOnly,
            requestID: "missing-library-panel-request",
            responseData: Data(#"{\"state\":\"C\",\"error\":\"\#(error)\",\"write_attempted\":false}"#.utf8),
            isError: true,
            state: "C",
            error: error,
            hint: hint,
            writeAttempted: false,
            readbackSource: QualificationSemanticReadbackValidator.libraryPanelReadbackSource,
            readbackRequestID: "missing-library-panel-readback",
            readbackData: Data(
                #"{"available":false,"reason":"explicit_library_panel_unavailable"}"#.utf8
            ),
            failureReason: nil
        )
    }

    private static func driveResult(
        specs: [OperationSpec],
        catalogCount: Int? = nil,
        observedVariant: String = "desktop",
        observedLocale: String = "en-US",
        tracePresent: Bool = true,
        traceOperationID: OperationID = .systemSagaExecute,
        tracePhases: [String] = ["request.received", "result.emitted"],
        failedOperationID: OperationID? = nil,
        qualifiedReadOperationCount: Int? = nil,
        healthChangesAfterNegativeProbe: Bool = false,
        nonObjectResponseOperationID: OperationID? = nil,
        mutationRestoreRecords: [QualificationMutationRestoreRecord] = [],
        wireFrames: [QualificationWireFrame]? = nil
    ) -> QualificationDriveResult {
        let expectedCount = specs.count
        let actualCount = catalogCount ?? expectedCount
        let catalogEntries = Array(OperationCatalog.snapshot(now: Date(timeIntervalSince1970: 1_000))
            .operations.prefix(actualCount))
        let stableCatalog = Data("{\"operation_count\":\(actualCount)}".utf8)
        let traceID = "lpmcp_00000000-0000-0000-0000-000000000000"
        let activeVariant: LogicVariant = observedVariant == LogicProVariant.creatorStudio.rawValue
            ? .creatorStudio
            : .desktop
        let activeBundleID = activeVariant == .creatorStudio
            ? LogicProVariant.creatorStudio.bundleID
            : LogicProVariant.desktop.bundleID
        let variantAvailability = LogicVariant.allCases.map { variant in
            QualificationVariantAvailability(
                variant: variant,
                bundleID: variant == .creatorStudio
                    ? LogicProVariant.creatorStudio.bundleID
                    : LogicProVariant.desktop.bundleID,
                installed: variant == activeVariant,
                running: variant == activeVariant
            )
        }
        let stableHealth = try! JSONSerialization.data(withJSONObject: [
            "logic_pro_running": true,
            "logic_pro_version": "11.2",
            "logic_pro_bundle_id": activeBundleID,
            "logic_pro_variant": observedVariant,
            "logic_pro_ui_locale": observedLocale,
            "logic_pro_variants": variantAvailability.map {
                [
                    "variant": $0.variant == .creatorStudio
                        ? LogicProVariant.creatorStudio.rawValue
                        : LogicProVariant.desktop.rawValue,
                    "bundle_id": $0.bundleID,
                    "installed": $0.installed,
                    "running": $0.running,
                ] as [String: Any]
            },
            "process_metadata_resolved": true,
        ], options: [.sortedKeys])
        var remainingQualifiedReads = qualifiedReadOperationCount
        let operationResults: [String: QualificationOperationResult] = Dictionary(
            uniqueKeysWithValues: specs.map { spec in
            let isMutation = spec.mutability == .mutating
            let readIsQualified = !isMutation && (remainingQualifiedReads.map { $0 > 0 } ?? true)
            if !isMutation, remainingQualifiedReads != nil {
                remainingQualifiedReads? -= 1
            }
            // #373 Phase A: read-only ops now have real semantic oracles, so a
            // generic {"operation":…,"state":"A"} stub no longer models a
            // qualifying read — the oracle would (correctly) reject it. Read-only
            // specs are driven with the realistic per-operation payloads the
            // oracle fixtures pin, which are themselves derived from the real
            // dispatcher shapes. systemHealth keeps its bespoke full-payload
            // equality, so it is fed the same health body on both sides.
            let oracleFixture = spec.mutability == .readOnly
                ? SemanticOracleFixtures.byOperationID[spec.id]
                : nil
            let response = spec.id == nonObjectResponseOperationID
                ? Data("plain text response".utf8)
                : spec.id == .systemHealth
                ? stableHealth
                : oracleFixture.map(\.responseData)
                ?? Data((isMutation
                    ? "{\"operation\":\"\(spec.id.rawValue)\",\"state\":\"C\",\"error\":\"invalid_params\",\"write_attempted\":false}"
                    : "{\"operation\":\"\(spec.id.rawValue)\",\"state\":\"A\",\"write_attempted\":false}"
                ).utf8)
            let readback = spec.id == .systemHealth
                ? stableHealth
                : oracleFixture.map(\.readbackData)
                ?? Data("{\"operation_readback\":\"\(spec.id.rawValue)\"}".utf8)
            // Preserve the same envelope metadata the signed response artifact carries. A
            // response-only oracle may deliberately return State B; stamping every read fixture
            // as State A makes the producer's evidence disagree with its retained payload.
            let responseEnvelope = (try? JSONSerialization.jsonObject(with: response))
                as? [String: Any]
            return (
                spec.id.rawValue,
                QualificationOperationResult(
                    operationID: spec.id.rawValue,
                    tool: spec.tool.rawValue,
                    command: spec.command,
                    mutability: spec.mutability,
                    requestID: "fake-operation-\(spec.id.rawValue)",
                    responseData: response,
                    isError: isMutation || !readIsQualified,
                    state: spec.id == nonObjectResponseOperationID ? nil
                        : isMutation ? "C"
                        : responseEnvelope?["state"] as? String
                            ?? (spec.id == .midiListPorts ? nil : "A"),
                    error: isMutation ? "invalid_params" : responseEnvelope?["error"] as? String,
                    hint: nil,
                    writeAttempted: responseEnvelope?["write_attempted"] as? Bool
                        ?? (spec.id == .midiListPorts ? nil : false),
                    readbackSource: spec.id == .midiListPorts
                        ? QualificationSemanticReadbackValidator.coreMIDIPortReadbackSource
                        : spec.id == .tracksListLibrary
                            ? QualificationSemanticReadbackValidator.libraryPanelReadbackSource
                        : spec.tool == .logicTransport
                            ? "logic://transport/state"
                            : spec.tool == .logicMixer
                                ? "logic://mixer"
                                : "logic://system/health",
                    readbackRequestID: "fake-readback-\(spec.id.rawValue)",
                    readbackData: readback,
                    failureReason: spec.id == failedOperationID ? "synthetic operation failure" : nil,
                    mutationRestore: mutationRestoreRecords.first { $0.operationID == spec.id.rawValue }
                )
            )
            }
        )
        return QualificationDriveResult(
            handshake: .init(
                protocolVersion: "2025-11-25",
                serverName: "logic-pro-mcp",
                serverVersion: "1.2.3"
            ),
            health: .init(
                logicProRunning: true,
                logicProVersion: "11.2",
                logicProBundleID: activeBundleID,
                logicProVariant: observedVariant,
                logicProUILocale: observedLocale,
                processMetadataResolved: true,
                variants: variantAvailability
            ),
            catalog: .init(
                schemaVersion: 1,
                generatedAt: "1970-01-01T00:16:40Z",
                operationCount: actualCount,
                operations: catalogEntries
            ),
            expectedOperationCount: expectedCount,
            traceList: .init(traces: tracePresent ? [
                .init(
                    traceID: traceID,
                    operationID: traceOperationID.rawValue,
                    phaseCount: tracePhases.count,
                    readbackState: "C"
                ),
            ] : []),
            traceDetail: tracePresent ? .init(
                traceID: traceID,
                operationID: traceOperationID.rawValue,
                phases: tracePhases
            ) : nil,
            negative: .init(
                toolIsError: true,
                state: "C",
                error: "invalid_params",
                writeAttempted: false,
                healthBefore: stableHealth,
                healthAfter: healthChangesAfterNegativeProbe
                    ? stableHealth + Data("\n".utf8)
                    : stableHealth,
                catalogBefore: stableCatalog,
                catalogAfter: stableCatalog
            ),
            observedLocale: observedLocale,
            operationResults: operationResults,
            wireFrames: wireFrames ?? [
                .init(
                    sequence: 0,
                    direction: .request,
                    operationID: "initialize",
                    payload: #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{}}"#
                ),
                .init(
                    sequence: 1,
                    direction: .response,
                    operationID: "initialize",
                    payload: #"{"id":1,"jsonrpc":"2.0","result":{}}"#
                ),
            ],
            mutationRestoreRecords: mutationRestoreRecords,
            failureReason: nil
        )
    }

    private actor MockQualificationServer: ServerStarting {
        func start() async throws {}
        func stop() async {}
    }

    private struct SlowHandshakeFixture {
        let directory: URL
        let executableURL: URL

        init(transportRefusal: Bool = false, transportNativePause: Bool = false,
             libraryReadback: Bool = false,
             initialTransportMotion: String = "stopped", cachedTransport: Bool = false,
             nameRecipe: OperationID? = nil, nameIdentityFault: String = "none",
             nameCleanupContention: String = "none", nameStageDelay: TimeInterval = 0,
             nameCleanupDelay: TimeInterval = 0,
             nameStageFailure: String = "none",
             countInCycle: String? = nil, autopunchCycle: String? = nil,
             playheadStep: OperationID? = nil, playheadFault: String = "none", playheadAtBoundary: Bool = false,
             playheadOrigin: String? = nil, valueCycle: OperationID? = nil,
             valueFault: String = "none", supportBundleCycle: Bool = false,
             supportBundleFault: String = "none") throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qualification-slow-handshake-\(UUID().uuidString)", isDirectory: true)
            executableURL = directory.appendingPathComponent("server.sh")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var script = #"""
            #!/bin/sh
            IFS= read -r request_line || exit 0
            sleep "$HANDSHAKE_DELAY"
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"fixture","version":"1.0"}}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"logic_pro_running\":true,\"logic_pro_version\":\"11.2\",\"logic_pro_bundle_id\":\"com.apple.logic10\",\"logic_pro_variant\":\"desktop\",\"logic_pro_ui_locale\":\"en-US\",\"logic_pro_variants\":[{\"variant\":\"desktop\",\"bundle_id\":\"com.apple.logic10\",\"installed\":true,\"running\":true},{\"variant\":\"creator_studio\",\"bundle_id\":\"com.apple.mobilelogic\",\"installed\":false,\"running\":false}],\"process_metadata_resolved\":true}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"contents":[{"uri":"logic://system/operations","text":"{\"schema_version\":1,\"generated_at\":\"1970-01-01T00:00:00Z\",\"operation_count\":0,\"operations\":[]}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"traces\":[{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000001\",\"operation_id\":\"system.saga_execute\",\"phase_count\":3,\"readback_state\":\"C\"}]}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"isError":true,"content":[{"type":"text","text":"{\"state\":\"C\",\"error\":\"invalid_params\",\"write_attempted\":false}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"{\"traces\":[{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000002\",\"operation_id\":\"system.saga_execute\",\"phase_count\":3,\"readback_state\":\"C\"},{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000001\",\"operation_id\":\"system.saga_execute\",\"phase_count\":3,\"readback_state\":\"C\"}]}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000002\",\"operation_id\":\"system.saga_execute\",\"events\":[{\"phase\":\"request.received\"},{\"phase\":\"verification.completed\"},{\"phase\":\"result.emitted\"}]}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":8,"result":{"isError":true,"content":[{"type":"text","text":"{\"state\":\"C\",\"error\":\"invalid_params\",\"write_attempted\":false}"}]}}'
            # id 9 — #373 saga seed. A REFUSED saga: the journal records the outcome and no step
            # runs. The double must simulate it, because the transport's request sequence is
            # pinned here BY ID — an unscripted step silently consumes the next response.
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":9,"result":{"isError":true,"content":[{"type":"text","text":"{}"}]}}'
            # AFTER SEED
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":10,"result":{"content":[{"type":"text","text":"{\"logic_pro_running\":true,\"logic_pro_version\":\"11.2\",\"logic_pro_bundle_id\":\"com.apple.logic10\",\"logic_pro_variant\":\"desktop\",\"logic_pro_ui_locale\":\"en-US\",\"logic_pro_variants\":[{\"variant\":\"desktop\",\"bundle_id\":\"com.apple.logic10\",\"installed\":true,\"running\":true},{\"variant\":\"creator_studio\",\"bundle_id\":\"com.apple.mobilelogic\",\"installed\":false,\"running\":false}],\"process_metadata_resolved\":true}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":11,"result":{"contents":[{"uri":"logic://system/operations","text":"{\"schema_version\":1,\"generated_at\":\"1970-01-01T00:00:00Z\",\"operation_count\":0,\"operations\":[]}"}]}}'
            exec 1>&-
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            IFS= read -r request_line || exit 0
            """#
            if transportRefusal || transportNativePause || libraryReadback || nameRecipe != nil || countInCycle != nil
                || autopunchCycle != nil || playheadStep != nil || valueCycle != nil || supportBundleCycle {
                script = try #require(script.components(separatedBy: "# AFTER SEED").first) + #"""
                cd "$(dirname "$0")" || exit 1
                initial_playing=false
                initial_moving=false
                playing=$initial_playing
                native_pause=false
                resource_source=ax_live
                resource_unverified=false
                moving=$initial_moving
                position=1
                name_recipe=none
                name_fault=none
                name_cleanup_contention=none
                name_stage_delay=0
                name_cleanup_delay=0
                name_stage_failure=none
                rename_attempts=0
                count_in_cycle=none
                count_in=false
                count_in_reads=0
                count_in_attempts=0
                playhead_step=none
                step_position=9.3.2.120
                step_origin=9.3.2.120
                step_boundary=false
                step_fault=none
                step_reads=0
                step_project_reads=0
                step_project_ref=prj_step
                step_restore_attempts=0
                value_cycle=none
                value_fault=none
                value_reads=0
                value_writes=0
                support_bundle_fault=none
                scalar_value=0.4
                printf '%s\n' "$scalar_value" > scalar-value
                printf '%s\n' "$step_position" > step-position
                track_name='Before'
                printf '%s\n' "$track_name" > track-name
                track_ref=held-track
                peer_name='Other'
                peer_ref=peer-track
                fault_pending=false
                fault_consumed=false
                printf '%s\n' "$playing" > playing
                printf '%s\n' "$moving" > moving
                while IFS= read -r request; do
                    printf '%s\n' "$count_in" > count_in
                    id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
                    [ -n "$id" ] || continue
                    [ "$id" -ge 10 ] || continue
                    request=$(printf '%s' "$request" | /usr/bin/sed 's#\\/#/#g')
                    printf '%s\n' "$request" >> requests
                    case "$request" in
                      *'"uri":"logic://project/info"'*)
                        step_project_reads=$((step_project_reads + 1))
                        case "$step_fault:$step_project_reads" in
                          project_pre:1) step_project_ref=unobserved; touch step-fault-consumed ;;
                          project_after:3|project_during_after:4) step_project_ref=prj_foreign; touch step-fault-consumed ;;
                          stage_project_loss:3|stage_cleanup_project_loss:7) step_project_ref=prj_foreign; touch step-fault-consumed ;;
                        esac
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://project/info","text":"{\\"source\\":\\"ax_live\\",\\"cache_age_sec\\":0,\\"identity_source\\":\\"current_document_project_file\\",\\"identity_fetched_at\\":\\"%s\\",\\"data\\":{\\"project_ref\\":\\"%s\\",\\"filePath\\":\\"/tmp/qualification-step.logicx\\"}}"}]}}\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$step_project_ref" ;;
                      *'"uri":"logic://tracks"'*)
                        if [ "$name_cleanup_delay" != 0 ] && [ "$rename_attempts" -ge 3 ]; then
                            touch cleanup-readback
                        fi
                        if [ "$value_cycle" != none ]; then
                            value_reads=$((value_reads + 1))
                            if [ "$value_reads" = 2 ]; then
                                case "$value_fault" in
                                  malformed_after|malformed_after_compensation_noop)
                                    touch value-fault-consumed
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://tracks","text":"not-json"}]}}\n' "$id"
                                    continue ;;
                                  wrong_target_after)
                                    touch value-fault-consumed
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://tracks","text":"{\\"source\\":\\"ax_live\\",\\"cache_age_sec\\":0,\\"readable\\":true,\\"ax_occluded\\":false,\\"data\\":[{\\"name\\":\\"Before\\",\\"track_ref\\":\\"foreign-track\\",\\"volume\\":%s,\\"pan\\":%s}]}"}]}}\n' "$id" "$scalar_value" "$scalar_value"
                                    continue ;;
                                esac
                            fi
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://tracks","text":"{\\"source\\":\\"ax_live\\",\\"cache_age_sec\\":0,\\"readable\\":true,\\"ax_occluded\\":false,\\"data\\":[{\\"name\\":\\"Before\\",\\"track_ref\\":\\"held-track\\",\\"volume\\":%s,\\"pan\\":%s}]}"}]}}\n' "$id" "$scalar_value" "$scalar_value"
                            continue
                        fi
                        if [ "$fault_pending" = true ]; then
                            fault_pending=false
                            fault_consumed=true
                            touch identity-fault-consumed
                            if [ "$name_fault" = reordered ]; then
                                peer_name=$track_name
                                first_ref=$peer_ref; first_name=$peer_name
                                second_ref=$track_ref; second_name=$track_name
                            else
                                track_ref=replaced-track
                                first_ref=$track_ref; first_name=$track_name
                                second_ref=$peer_ref; second_name=$peer_name
                            fi
                        elif [ "$fault_consumed" = true ] && [ "$name_fault" = reordered ]; then
                            first_ref=$peer_ref; first_name=$peer_name
                            second_ref=$track_ref; second_name=$track_name
                        else
                            first_ref=$track_ref; first_name=$track_name
                            second_ref=$peer_ref; second_name=$peer_name
                        fi
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://tracks","text":"{\\"source\\":\\"ax_live\\",\\"cache_age_sec\\":0,\\"readable\\":true,\\"ax_occluded\\":false,\\"data\\":[{\\"name\\":\\"%s\\",\\"track_ref\\":\\"%s\\"},{\\"name\\":\\"%s\\",\\"track_ref\\":\\"%s\\"}]}"}]}}\n' "$id" "$first_name" "$first_ref" "$second_name" "$second_ref" ;;
                      *'"uri":"logic://transport/state"'*)
                        if [ "$playhead_step" != none ]; then
                            step_reads=$((step_reads + 1))
                            step_value=$step_position
                            step_components='[\"bar\",\"beat\",\"subdivision\",\"tick\"]'
                            step_source=ax_live; step_age=0; step_unverified=false
                            step_playing=false; step_recording=false; step_cycle=false
                            case "$step_fault:$step_reads" in
                              partial2_pre:1) step_value=9.3; step_components='[\"bar\",\"beat\"]'; touch step-fault-consumed ;;
                              partial3_pre:1) step_value=9.3.2; step_components='[\"bar\",\"beat\",\"subdivision\"]'; touch step-fault-consumed ;;
                              missing_pre:1|partial_after:2|missing_restore:3) step_components='[]'; touch step-fault-consumed ;;
                              malformed_pre:1) step_value=9.bad.2.120; touch step-fault-consumed ;;
                              playing_pre:1) step_playing=true; touch step-fault-consumed ;;
                              recording_pre:1) step_recording=true; touch step-fault-consumed ;;
                              unknown_stop_pre:1) step_playing=null; touch step-fault-consumed ;;
                              missing_cycle_pre:1) step_cycle=null; touch step-fault-consumed ;;
                              cycle_pre:1) step_cycle=true; touch step-fault-consumed ;;
                              cache_pre:1) step_source=cache; touch step-fault-consumed ;;
                              stale_pre:1|stale_after:2) step_age=1000; touch step-fault-consumed ;;
                              unverified_pre:1) step_unverified=true; touch step-fault-consumed ;;
                              unknown_age_pre:1) step_age=null; touch step-fault-consumed ;;
                              wrong_components_after:2) step_position=${step_position%.*}.121; step_value=$step_position; touch step-fault-consumed ;;
                              stage_missing_read:2) step_components='[]'; touch step-fault-consumed ;;
                              stage_cache_read:2) step_source=cache; touch step-fault-consumed ;;
                              stage_stale_read:2) step_age=1000; touch step-fault-consumed ;;
                              stage_cleanup_position_loss:4) step_position=7.2.2.99; step_value=$step_position; touch step-fault-consumed ;;
                            esac
                            printf '%s\n' "$step_position" > step-position
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://transport/state","text":"{\\"source\\":\\"%s\\",\\"unverified\\":%s,\\"cache_age_sec\\":%s,\\"data\\":{\\"state\\":{\\"isPlaying\\":%s,\\"isRecording\\":%s,\\"observedCycleEnabled\\":%s,\\"position\\":\\"%s\\",\\"positionReadback\\":{\\"value\\":\\"%s\\",\\"observedComponents\\":%s}}}}"}]}}\n' "$id" "$step_source" "$step_unverified" "$step_age" "$step_playing" "$step_recording" "$step_cycle" "$step_value" "$step_value" "$step_components"
                            continue
                        fi
                        if [ "$count_in_cycle" != none ]; then
                            count_in_reads=$((count_in_reads + 1))
                            count_in_source=$resource_source
                            count_in_unverified=$resource_unverified
                            count_in_age=0
                            count_in_value=$count_in
                            case "$count_in_cycle:$count_in_reads" in
                              missing_pre:1|missing_after:2) count_in_value=null; touch count-in-fault-consumed ;;
                              malformed_pre:1) count_in_value='\"unreadable\"'; touch count-in-fault-consumed ;;
                              cache_pre:1|cache_after:2) count_in_source=cache; touch count-in-fault-consumed ;;
                              stale_pre:1) count_in_age=1000; touch count-in-fault-consumed ;;
                              unknown_age_pre:1) count_in_age=null; touch count-in-fault-consumed ;;
                              unverified_pre:1) count_in_unverified=true; touch count-in-fault-consumed ;;
                            esac
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://transport/state","text":"{\\"source\\":\\"%s\\",\\"unverified\\":%s,\\"cache_age_sec\\":%s,\\"data\\":{\\"state\\":{\\"isCountInEnabled\\":%s}}}"}]}}\n' "$id" "$count_in_source" "$count_in_unverified" "$count_in_age" "$count_in_value"
                            continue
                        fi
                        if [ "$moving" = true ]; then position=$((position + 1)); fi
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://transport/state","text":"{\\"source\\":\\"%s\\",\\"unverified\\":%s,\\"cache_age_sec\\":0,\\"observed_tempo\\":120,\\"data\\":{\\"state\\":{\\"isPlaying\\":%s,\\"isRecording\\":false,\\"isCycleEnabled\\":false,\\"observedCycleEnabled\\":false,\\"tempo\\":120,\\"position\\":\\"%s.1\\",\\"positionReadback\\":{\\"value\\":\\"%s.1\\",\\"observedComponents\\":[\\"bar\\",\\"beat\\"]}}}}"}]}}\n' "$id" "$resource_source" "$resource_unverified" "$playing" "$position" "$position" ;;
                      *'"uri":"logic://system/operations"'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://system/operations","text":"{\\"schema_version\\":1,\\"generated_at\\":\\"1970-01-01T00:00:00Z\\",\\"operation_count\\":0,\\"operations\\":[]}"}]}}\n' "$id" ;;
                      *'"uri":"logic://system/health"'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://system/health","text":"{\\"logic_pro_running\\":true,\\"logic_pro_version\\":\\"11.2\\",\\"logic_pro_bundle_id\\":\\"com.apple.logic10\\",\\"logic_pro_variant\\":\\"desktop\\",\\"logic_pro_ui_locale\\":\\"en-US\\",\\"process_metadata_resolved\\":true}"}]}}\n' "$id" ;;
                      *'"command":"health"'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"logic_pro_running\\":true,\\"logic_pro_version\\":\\"11.2\\",\\"logic_pro_bundle_id\\":\\"com.apple.logic10\\",\\"logic_pro_variant\\":\\"desktop\\",\\"logic_pro_ui_locale\\":\\"en-US\\",\\"process_metadata_resolved\\":true,\\"logic_pro_variants\\":[{\\"variant\\":\\"desktop\\",\\"bundle_id\\":\\"com.apple.logic10\\",\\"installed\\":true,\\"running\\":true},{\\"variant\\":\\"creator_studio\\",\\"bundle_id\\":\\"com.apple.mobilelogic\\",\\"installed\\":false,\\"running\\":false}]}"}]}}\n' "$id" ;;
                      *'__adr001b_no_write_probe'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"invalid_params\\",\\"write_attempted\\":false}"}]}}\n' "$id" ;;
                      *'"command":"export_support_bundle"'*)
                        support_root=${LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE:?}
                        leaf=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"dir":"\([^"]*\)".*/\1/p')
                        case "$leaf" in qualification-[0-9a-f-]*) ;; *) exit 41 ;; esac
                        bundle="$support_root/$leaf"
                        if [ "$support_bundle_fault" = late_timeout ]; then
                            inner='{"state":"C","error":"operation_timeout","write_attempted":true}'
                            escaped=$(printf '%s' "$inner" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"%s"}]}}\n' "$id" "$escaped"
                            /bin/sleep 0.2
                        fi
                        /bin/mkdir "$bundle" || exit 42
                        files_json=
                        for name in doctor.json manifest.json metadata.json redaction_report.json traces.json SHA256SUMS; do
                            printf 'fixture-%s\n' "$name" > "$bundle/$name" || exit 43
                            digest=$(/usr/bin/shasum -a 256 "$bundle/$name" | /usr/bin/awk '{print $1}')
                            entry="{\"name\":\"$name\",\"sha256\":\"$digest\"}"
                            if [ -n "$files_json" ]; then files_json="$files_json,$entry"; else files_json=$entry; fi
                        done
                        if [ "$support_bundle_fault" = late_timeout ]; then
                            continue
                        fi
                        if [ "$support_bundle_fault" = lost_reply ]; then
                            printf '{"jsonrpc":"2.0","id":%s}\n' "$id"
                            continue
                        fi
                        if [ "$support_bundle_fault" = lost_reply_nonzero ]; then
                            printf '{"jsonrpc":"2.0","id":%s}\n' "$id"
                            exit 47
                        fi
                        if [ "$support_bundle_fault" = missing_manifest ]; then
                            inner="{\"state\":\"A\",\"bundle_path\":\"$bundle\"}"
                        else
                            inner="{\"state\":\"A\",\"bundle_path\":\"$bundle\",\"files\":[$files_json]}"
                        fi
                        escaped=$(printf '%s' "$inner" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}]}}\n' "$id" "$escaped" ;;
                      *'"command":"list_library"'*)
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"categories\\":[\\"Bass\\"],\\"presetsByCategory\\":{}}"}]}}\n' "$id" ;;
                      *'"command":"set_volume"'*|*'"command":"set_pan"'*)
                        value_writes=$((value_writes + 1))
                        if ! printf '%s' "$request" | grep -q '"target_ref":"held-track"'; then
                            printf '%s\n' "$request" >> unsafe-writes
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"stale_target_reference\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                            continue
                        fi
                        if [ "$value_fault" = refused_forward ] && [ "$value_writes" = 1 ]; then
                            touch value-fault-consumed
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"refused\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                            continue
                        fi
                        requested_value=0.5
                        if [ "$value_writes" -gt 1 ]; then requested_value=0.4; fi
                        if [ "$value_fault" = malformed_after_compensation_noop ] && [ "$value_writes" = 2 ]; then
                            :
                        else
                            scalar_value=$requested_value
                            printf '%s\n' "$scalar_value" > scalar-value
                        fi
                        if [ "$value_fault" = lost_mutation_reply ] && [ "$value_writes" = 1 ]; then
                            touch value-fault-consumed
                            continue
                        fi
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true,\\"write_attempted\\":true}"}]}}\n' "$id" ;;
                      *'"command":"fast_forward"'*|*'"command":"rewind"'*)
                        if [ "$step_fault" = stage_lost_step_reply ]; then
                            touch step-fault-consumed
                            continue
                        fi
                        case "$step_fault" in
                          step_noop_boundary)
                            touch step-fault-consumed
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"verified\\":false,\\"reason\\":\\"readback_unavailable\\",\\"write_attempted\\":false,\\"unchanged\\":true}"}]}}\n' "$id"
                            continue ;;
                          step_noop_race)
                            touch step-fault-consumed
                            case "$request" in
                              *'"command":"fast_forward"'*) step_position=10.1.1.1 ;;
                              *) step_position=8.1.1.1 ;;
                            esac
                            printf '%s\n' "$step_position" > step-position
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"verified\\":false,\\"reason\\":\\"readback_unavailable\\",\\"write_attempted\\":false,\\"unchanged\\":true}"}]}}\n' "$id"
                            continue ;;
                          stage_unknown_step)
                            touch step-fault-consumed
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"fallback_unsafe\\":true}"}]}}\n' "$id"
                            continue ;;
                          stage_step_no_effect)
                            touch step-fault-consumed
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"method\\":\\"cgevent\\",\\"sent\\":true}"}]}}\n' "$id"
                            continue ;;
                          stage_foreign_position)
                            touch step-fault-consumed; step_position=7.2.2.99
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"method\\":\\"cgevent\\",\\"sent\\":true}"}]}}\n' "$id"
                            continue ;;
                        esac
                        if [ "$step_fault" = refused_forward ] || [ "$step_fault" = stage_cleanup_project_loss ] || [ "$step_fault" = stage_cleanup_position_loss ]; then
                            touch step-fault-consumed
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                            continue
                        fi
                        case "$request" in
                          *'"command":"fast_forward"'*)
                            if [ "$step_boundary" = true ]; then step_position=10.1.1.1; else step_position=10.3.2.120; fi ;;
                          *) if [ "$step_boundary" = true ]; then step_position=8.1.1.1; else step_position=8.3.2.120; fi ;;
                        esac
                        printf '%s\n' "$step_position" > step-position
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"verified\\":false,\\"reason\\":\\"readback_unavailable\\",\\"method\\":\\"cgevent\\",\\"sent\\":true}"}]}}\n' "$id" ;;
                      *'"command":"goto_position"'*)
                        if [ "$step_fault" = refused_restore ] && [ "$step_position" != "$step_origin" ] && [ "$step_restore_attempts" = 0 ]; then
                            step_restore_attempts=$((step_restore_attempts + 1))
                            touch step-fault-consumed
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                            continue
                        fi
                        case "$request" in
                          *'"position":"9.3.2.120"'*|*'"position":"9.1.1.1"'*)
                            if [ "$step_origin" != 9.1.1.1 ] && printf '%s' "$request" | grep -q '"position":"9.1.1.1"'; then
                                case "$step_fault" in
                                  stage_refused)
                                    touch step-fault-consumed
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                                    continue ;;
                                  stage_noop_race)
                                    touch step-fault-consumed; step_position=9.1.1.1; step_boundary=true
                                    printf '%s\n' "$step_position" > step-position
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true,\\"write_attempted\\":false,\\"unchanged\\":true}"}]}}\n' "$id"
                                    continue ;;
                                  stage_no_effect)
                                    touch step-fault-consumed
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true,\\"write_attempted\\":true}"}]}}\n' "$id"
                                    continue ;;
                                esac
                                step_before=$step_position
                                step_position=9.1.1.1; step_boundary=true
                                printf '%s\n' "$step_position" > step-position
                                if [ "$step_fault" = stage_unverified ]; then
                                    touch step-fault-consumed
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"verified\\":false}"}]}}\n' "$id"
                                    continue
                                fi
                                if [ "$step_fault" = cgevent_goto_reply ]; then
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true,\\"operation\\":\\"transport.goto_position\\",\\"method\\":\\"cgevent\\",\\"sent\\":true,\\"verification_source\\":\\"transport_state\\",\\"requested\\":\\"%s\\",\\"observed\\":\\"%s\\",\\"observed_before\\":\\"%s\\",\\"observed_before_position_components\\":[\\"bar\\",\\"beat\\",\\"subdivision\\",\\"tick\\"],\\"observed_position_components\\":[\\"bar\\",\\"beat\\",\\"subdivision\\",\\"tick\\"],\\"unobserved_position_components\\":[]}"}]}}\n' "$id" "$step_position" "$step_position" "$step_before"
                                    continue
                                fi
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true,\\"write_attempted\\":true}"}]}}\n' "$id"
                                continue
                            fi
                            step_restore_attempts=$((step_restore_attempts + 1))
                            if [ "$step_fault" = stage_refused_restore ] && [ "$step_restore_attempts" = 1 ]; then
                                touch step-fault-consumed
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                                continue
                            fi
                            if [ "$step_fault" = stage_attempted_restore_failure ] && [ "$step_restore_attempts" = 1 ]; then
                                touch step-fault-consumed
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"write_attempted\\":true}"}]}}\n' "$id"
                                continue
                            fi
                            step_before=$step_position
                            if [ "$step_fault" = mismatch_restore ]; then touch step-fault-consumed
                            else step_position=$step_origin; fi
                            printf '%s\n' "$step_position" > step-position
                            if [ "$step_fault" = unsafe_restore ]; then
                                touch step-fault-consumed
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"B\\",\\"success\\":true,\\"verified\\":false,\\"fallback_unsafe\\":true,\\"verification_withheld\\":\\"fallback_unsafe\\"}"}]}}\n' "$id"
                                continue
                            fi
                            if [ "$step_fault" = unverified_restore ]; then
                                touch step-fault-consumed
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":false}"}]}}\n' "$id"
                                continue
                            fi
                            if [ "$step_fault" = cgevent_goto_reply ]; then
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true,\\"operation\\":\\"transport.goto_position\\",\\"method\\":\\"cgevent\\",\\"sent\\":true,\\"verification_source\\":\\"transport_state\\",\\"requested\\":\\"%s\\",\\"observed\\":\\"%s\\",\\"observed_before\\":\\"%s\\",\\"observed_before_position_components\\":[\\"bar\\",\\"beat\\",\\"subdivision\\",\\"tick\\"],\\"observed_position_components\\":[\\"bar\\",\\"beat\\",\\"subdivision\\",\\"tick\\"],\\"unobserved_position_components\\":[]}"}]}}\n' "$id" "$step_position" "$step_position" "$step_before"
                                continue
                            fi
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true,\\"write_attempted\\":true}"}]}}\n' "$id" ;;
                          *) printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"write_attempted\\":false}"}]}}\n' "$id" ;;
                        esac ;;
                      *'"command":"toggle_count_in"'*)
                        count_in_attempts=$((count_in_attempts + 1))
                        case "$count_in_cycle:$count_in_attempts" in
                          refused_forward:1|refused_restore:2)
                            touch count-in-fault-consumed
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":false,\\"write_attempted\\":false}"}]}}\n' "$id"
                            continue ;;
                          mismatch_after:1|mismatch_restore:2) touch count-in-fault-consumed ;;
                          *) if [ "$count_in" = false ]; then count_in=true; else count_in=false; fi ;;
                        esac
                        printf '%s\n' "$count_in" > count_in
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true}"}]}}\n' "$id" ;;
                      *'"command":"rename"'*|*'"command":"undo"'*|*'"command":"redo"'*)
                        if [ "$name_cleanup_contention" != none ] && [ "$name_recipe" = edit.redo ] && [ "$rename_attempts" = 1 ]; then
                            case "$request" in
                              *'"command":"undo"'*)
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"operation_timeout\\",\\"write_attempted\\":true}"}]}}\n' "$id"
                                continue ;;
                            esac
                        fi
                        case "$request" in
                          *'"command":"rename"'*)
                            rename_attempts=$((rename_attempts + 1))
                            if [ "$rename_attempts" = 1 ] && [ "$name_stage_delay" != 0 ]; then
                                sleep "$name_stage_delay"
                            fi
                            if [ "$rename_attempts" = 1 ] && [ "$name_stage_failure" = timeout_after_write ]; then
                                track_name=qualification_phase_b_probe
                                printf '%s\n' "$track_name" > track-name
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":false,\\"error\\":\\"operation_timeout\\",\\"safe_to_retry\\":false,\\"write_attempted\\":true,\\"mutation_gate\\":\\"reclaimable_after_grace\\",\\"gate_reclaim_after_sec\\":0.25}"}]}}\n' "$id"
                                continue
                            fi
                            if [ "$name_stage_failure" = timeout_after_write ] && [ "$rename_attempts" -ge 2 ] && [ ! -f gate-reclaimed ]; then
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":false,\\"error\\":\\"mutating_operation_in_progress\\",\\"safe_to_retry\\":true,\\"write_attempted\\":false,\\"mutation_gate\\":\\"reclaimable_after_grace\\",\\"gate_reclaim_after_sec\\":0.25}"}]}}\n' "$id"
                                continue
                            fi
                            if [ "$rename_attempts" -ge 3 ] && [ "$name_cleanup_delay" != 0 ]; then
                                sleep "$name_cleanup_delay"
                            fi
                            if [ "$name_cleanup_contention" != none ] && [ "$rename_attempts" = 2 ]; then
                                printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"operation_timeout\\",\\"write_attempted\\":true}"}]}}\n' "$id"
                                continue
                            fi
                            if [ "$name_cleanup_contention" != none ] && [ "$rename_attempts" -ge 3 ] && [ ! -f gate-reclaimed ]; then
                                if [ "$name_cleanup_contention" = reclaimable ]; then
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":false,\\"error\\":\\"mutating_operation_in_progress\\",\\"safe_to_retry\\":true,\\"write_attempted\\":false,\\"mutation_gate\\":\\"reclaimable_after_grace\\",\\"gate_reclaim_after_sec\\":0.25}"}]}}\n' "$id"
                                elif [ "$name_cleanup_contention" = boolean_delay ]; then
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":false,\\"error\\":\\"mutating_operation_in_progress\\",\\"safe_to_retry\\":true,\\"write_attempted\\":false,\\"mutation_gate\\":\\"reclaimable_after_grace\\",\\"gate_reclaim_after_sec\\":true}"}]}}\n' "$id"
                                elif [ "$name_cleanup_contention" = successful_error ]; then
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":true,\\"error\\":\\"mutating_operation_in_progress\\",\\"safe_to_retry\\":true,\\"write_attempted\\":false,\\"mutation_gate\\":\\"reclaimable_after_grace\\",\\"gate_reclaim_after_sec\\":0.25}"}]}}\n' "$id"
                                elif [ "$name_cleanup_contention" = numeric_boole ]; then
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":false,\\"error\\":\\"mutating_operation_in_progress\\",\\"safe_to_retry\\":1,\\"write_attempted\\":0,\\"mutation_gate\\":\\"reclaimable_after_grace\\",\\"gate_reclaim_after_sec\\":0.25}"}]}}\n' "$id"
                                elif [ "$name_cleanup_contention" = missing_success ]; then
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"mutating_operation_in_progress\\",\\"safe_to_retry\\":true,\\"write_attempted\\":false,\\"mutation_gate\\":\\"reclaimable_after_grace\\",\\"gate_reclaim_after_sec\\":0.25}"}]}}\n' "$id"
                                else
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"mutating_operation_in_progress\\",\\"safe_to_retry\\":true,\\"write_attempted\\":false}"}]}}\n' "$id"
                                fi
                                continue
                            fi ;;
                        esac
                        if [ "$fault_consumed" = true ]; then
                            case "$request" in
                              *'"command":"rename"'*'"target_ref":"held-track"'*)
                                if [ "$track_ref" != held-track ]; then
                                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"stale_target_reference\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                                    continue
                                fi ;;
                              *) printf '%s\n' "$request" >> unsafe-writes ;;
                            esac
                        fi
                        case "$request" in
                          *'"command":"rename"'*)
                            if printf '%s' "$request" | grep -q 'qualification_phase_b_probe'; then track_name=qualification_phase_b_probe
                            else track_name=Before; fi
                            [ "$name_recipe" = tracks.rename ] && [ "$name_fault" != none ] && [ "$fault_consumed" = false ] && fault_pending=true ;;
                          *'"command":"undo"'*) track_name=Before
                            [ "$name_recipe" = edit.undo ] && [ "$name_fault" != none ] && [ "$fault_consumed" = false ] && fault_pending=true ;;
                          *'"command":"redo"'*) track_name=qualification_phase_b_probe
                            [ "$name_recipe" = edit.redo ] && [ "$name_fault" != none ] && [ "$fault_consumed" = false ] && fault_pending=true ;;
                        esac
                        printf '%s\n' "$track_name" > track-name
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true}"}]}}\n' "$id" ;;
                      *'"command":"pause"'*)
                        if [ "$native_pause" = true ]; then
                            playing=true
                            moving=false
                            printf '%s\n' "$playing" > playing
                            printf '%s\n' "$moving" > moving
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true}"}]}}\n' "$id"
                        else
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"error\\":\\"readback_unavailable\\",\\"write_attempted\\":false}"}]}}\n' "$id"
                        fi ;;
                      *)
                        case "$request" in
                          *'"command":"play"'*) playing=true; moving=true ;;
                          *'"command":"stop"'*) playing=false; moving=false ;;
                        esac
                        printf '%s\n' "$playing" > playing
                        printf '%s\n' "$moving" > moving
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"verified\\":true}"}]}}\n' "$id" ;;
                    esac
                done
                """#
                if transportNativePause { script = script.replacingOccurrences(of: "native_pause=false", with: "native_pause=true") }
                if let countInCycle = countInCycle ?? autopunchCycle {
                    script = script.replacingOccurrences(of: "count_in_cycle=none", with: "count_in_cycle=\(countInCycle)")
                }
                if autopunchCycle != nil {
                    script = script.replacingOccurrences(of: "toggle_count_in", with: "toggle_autopunch")
                        .replacingOccurrences(of: "isCountInEnabled", with: "isAutopunchEnabled")
                        .replacingOccurrences(of: "count_in", with: "autopunch")
                        .replacingOccurrences(of: "count-in", with: "autopunch")
                }
                if let playheadStep {
                    script = script.replacingOccurrences(of: "playhead_step=none", with: "playhead_step=\(playheadStep.rawValue)")
                        .replacingOccurrences(of: "step_fault=none", with: "step_fault=\(playheadFault)")
                }
                if playheadAtBoundary {
                    script = script.replacingOccurrences(of: "step_position=9.3.2.120", with: "step_position=9.1.1.1")
                        .replacingOccurrences(of: "step_origin=9.3.2.120", with: "step_origin=9.1.1.1")
                        .replacingOccurrences(of: "step_boundary=false", with: "step_boundary=true")
                }
                if let playheadOrigin {
                    script = script.replacingOccurrences(of: "step_position=9.3.2.120", with: "step_position=\(playheadOrigin)")
                        .replacingOccurrences(of: "step_origin=9.3.2.120", with: "step_origin=\(playheadOrigin)")
                }
                if let nameRecipe {
                    script = script.replacingOccurrences(of: "name_recipe=none", with: "name_recipe=\(nameRecipe.rawValue)")
                        .replacingOccurrences(of: "name_fault=none", with: "name_fault=\(nameIdentityFault)")
                        .replacingOccurrences(
                            of: "name_cleanup_contention=none",
                            with: "name_cleanup_contention=\(nameCleanupContention)")
                        .replacingOccurrences(
                            of: "name_stage_delay=0",
                            with: "name_stage_delay=\(nameStageDelay)")
                        .replacingOccurrences(
                            of: "name_cleanup_delay=0",
                            with: "name_cleanup_delay=\(nameCleanupDelay)")
                        .replacingOccurrences(
                            of: "name_stage_failure=none",
                            with: "name_stage_failure=\(nameStageFailure)")
                }
                if let valueCycle {
                    script = script.replacingOccurrences(
                        of: "value_cycle=none", with: "value_cycle=\(valueCycle.rawValue)")
                        .replacingOccurrences(of: "value_fault=none", with: "value_fault=\(valueFault)")
                }
                if supportBundleFault != "none" {
                    script = script.replacingOccurrences(
                        of: "support_bundle_fault=none",
                        with: "support_bundle_fault=\(supportBundleFault)")
                }
                if cachedTransport {
                    script = script.replacingOccurrences(of: "resource_source=ax_live", with: "resource_source=cache")
                        .replacingOccurrences(of: "resource_unverified=false", with: "resource_unverified=true")
                }
                if initialTransportMotion != "stopped" {
                    script = script.replacingOccurrences(of: "initial_playing=false", with: "initial_playing=true")
                }
                if initialTransportMotion == "moving" {
                    script = script.replacingOccurrences(of: "initial_moving=false", with: "initial_moving=true")
                }
            }
            try Data(script.utf8).write(to: executableURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private protocol TrustedMatrixFixtureView: Sendable {
        var executableURL: URL { get }
        var commitSHA: String { get }
        var trustedPublicKeyData: Data { get }
        var inputURL: URL { get }
    }

    private struct ConsumerMatrixSnapshot: Sendable {
        struct File: Sendable {
            let data: Data
            let permissions: Int

            init(_ url: URL) throws {
                data = try Data(contentsOf: url)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            }

            func write(to url: URL) throws {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: url.path
                )
            }
        }

        let candidate: File
        let matrixFiles: [String: File]
        let commitSHA: String
        let signingKeyData: Data
        let trustedPublicKeyData: Data
        let binarySHA256: String

        init(_ fixture: SignedMatrixFixture) throws {
            candidate = try File(fixture.executableURL)
            commitSHA = fixture.commitSHA
            signingKeyData = fixture.signingKeyData
            trustedPublicKeyData = fixture.trustedPublicKeyData
            binarySHA256 = fixture.binarySHA256

            let root = fixture.directory.standardizedFileURL
            let prefix = root.path + "/"
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
            let enumerator = try #require(FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys)
            ))
            var files: [String: File] = [:]
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: keys)
                let isSymbolicLink = values.isSymbolicLink ?? false
                try #require(!isSymbolicLink, "signed matrix contains a symlink: \(url.path)")
                if values.isDirectory == true { continue }
                let isRegularFile = values.isRegularFile ?? false
                try #require(isRegularFile, "signed matrix contains a nonregular file: \(url.path)")
                let path = url.standardizedFileURL.path
                try #require(path.hasPrefix(prefix), "signed matrix entry escaped its root: \(path)")
                let relativePath = String(path.dropFirst(prefix.count))
                try #require(!relativePath.isEmpty && files[relativePath] == nil)
                files[relativePath] = try File(url)
            }
            try #require(!files.isEmpty, "signed matrix snapshot is empty")
            matrixFiles = files
        }
    }

    private actor ConsumerMatrixSnapshotCache {
        private var snapshot: ConsumerMatrixSnapshot?

        func current() -> ConsumerMatrixSnapshot? {
            snapshot
        }

        func installIfAbsent(_ candidate: ConsumerMatrixSnapshot) -> ConsumerMatrixSnapshot {
            if let snapshot { return snapshot }
            snapshot = candidate
            return candidate
        }
    }

    private final class ConsumerSignedMatrixFixture: TrustedMatrixFixtureView, @unchecked Sendable {
        let root: URL
        let directory: URL
        let executableURL: URL
        let commitSHA: String
        let signingKeyData: Data
        let trustedPublicKeyData: Data
        let binarySHA256: String

        var inputURL: URL { directory.appendingPathComponent("qualification-matrix-input.json") }
        var matrixURL: URL { directory.appendingPathComponent("release-qualification-matrix.json") }
        var enMatrixAttestationURL: URL {
            directory.appendingPathComponent("en/release-qualification-attestation.json")
        }

        init(_ snapshot: ConsumerMatrixSnapshot) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("consumer-release-matrix-\(UUID().uuidString)", isDirectory: true)
            directory = root.appendingPathComponent("matrix", isDirectory: true)
            executableURL = root.appendingPathComponent("LogicProMCP")
            commitSHA = snapshot.commitSHA
            signingKeyData = snapshot.signingKeyData
            trustedPublicKeyData = snapshot.trustedPublicKeyData
            binarySHA256 = snapshot.binarySHA256

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try snapshot.candidate.write(to: executableURL)
                for relativePath in snapshot.matrixFiles.keys.sorted() {
                    let target = directory.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let file = try #require(snapshot.matrixFiles[relativePath])
                    try file.write(to: target)
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class SignedMatrixFixture: TrustedMatrixFixtureView, @unchecked Sendable {
        let en: Fixture
        let ko: Fixture
        let directory: URL

        init(en: Fixture, ko: Fixture, directory: URL) {
            self.en = en
            self.ko = ko
            self.directory = directory
        }

        var executableURL: URL { en.executableURL }
        var commitSHA: String { en.commitSHA }
        var signingKeyData: Data { en.signingKeyData }
        var trustedPublicKeyData: Data { en.trustedPublicKeyData }
        var binarySHA256: String { en.binarySHA256 }
        var inputURL: URL { directory.appendingPathComponent("qualification-matrix-input.json") }
        var matrixURL: URL { directory.appendingPathComponent("release-qualification-matrix.json") }
        var enMatrixAttestationURL: URL {
            directory.appendingPathComponent("en/release-qualification-attestation.json")
        }

        func remove() {
            en.remove()
            ko.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let executableURL: URL
        let executableData: Data
        let attestationURL: URL
        let manifestURL: URL
        let caseManifestURL: URL
        let externalCasesURL: URL
        let waiversURL: URL
        let commitSHA: String
        let signingKeyData: Data
        let trustedPublicKeyData: Data
        let requiredOperationIDs: Set<String>
        let runner: QualificationRunner
        let qualificationIncludesExternalCases: Bool

        var binarySHA256: String { SupportBundleBuilder.sha256(executableData) }

        init(
            specs: [OperationSpec],
            executableData: Data = Data("qualification-binary-fixture".utf8),
            binaryVersion: String = "1.2.3",
            registryValidationErrors: [String] = [],
            handlerValidationErrors: [String] = [],
            handlerExists: @escaping @Sendable (String, String) -> Bool = {
                OperationHandlerRegistry.handler(tool: $0, command: $1) != nil
            },
            commitSHA: String = String(repeating: "c", count: 40),
            includeSigningKey: Bool = false,
            trustedPublicKeyData: Data? = nil,
            beforeEvidenceRead: @escaping @Sendable (URL) -> Void = { _ in },
            environmentAdditions: [String: String] = [:],
            qualificationIncludesExternalCases: Bool = false,
            drive: (@Sendable (QualificationDriveRequest) async throws -> QualificationDriveResult)? = nil
        ) throws {
            self.commitSHA = commitSHA
            self.qualificationIncludesExternalCases = qualificationIncludesExternalCases
            signingKeyData = Data(repeating: 7, count: 32)
            requiredOperationIDs = Set(specs.map { $0.id.rawValue })
            self.executableData = executableData
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qualification-runner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executableURL = directory.appendingPathComponent("LogicProMCP")
            attestationURL = directory.appendingPathComponent(
                "release-qualification-attestation.json"
            )
            manifestURL = directory.appendingPathComponent("evidence-manifest.json")
            caseManifestURL = directory.appendingPathComponent("case-manifest.json")
            externalCasesURL = directory.appendingPathComponent("cases.json")
            waiversURL = directory.appendingPathComponent("waivers.json")
            try executableData.write(to: executableURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
            let signingKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: signingKeyData
            )
            let trustedKeyData = trustedPublicKeyData
                ?? signingKey.publicKey.rawRepresentation
            self.trustedPublicKeyData = trustedKeyData
            let signingKeyBase64 = signingKeyData.base64EncodedString()
            let trustedKeyBase64 = trustedKeyData.base64EncodedString()
            let defaultDriveResult = QualificationRunnerTests.driveResult(specs: specs)
            let drive = drive ?? { _ in defaultDriveResult }
            runner = QualificationRunner(runtime: .init(
                executableURL: { [executableURL] in executableURL },
                environment: { [commitSHA, environmentAdditions] in
                    var environment = environmentAdditions
                    environment["GIT_COMMIT"] = commitSHA
                    if includeSigningKey {
                        environment["LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY"] = signingKeyBase64
                    }
                    environment["LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY"] = trustedKeyBase64
                    return environment
                },
                now: { Date(timeIntervalSince1970: 1_000) },
                serverVersion: { binaryVersion },
                specs: { specs },
                registryValidationErrors: { registryValidationErrors },
                handlerValidationErrors: { handlerValidationErrors },
                handlerExists: handlerExists,
                beforeEvidenceRead: beforeEvidenceRead,
                drive: drive,
                // No atlas pairs. These fixtures do not run Logic, and the ADR-007 step is off
                // unless `adr007SelectorAtlas` is set — so it emits no case and every count below
                // is about the same cases it was about before. Spelled rather than defaulted: a
                // default here would let the step appear in these runs the day the flag flips,
                // and the first sign would be an arithmetic failure in an unrelated assertion.
                atlasPairs: { (pairs: [], dropped: []) }
            ))
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func qualify(
            waiversURL: URL? = nil,
            mutateOpenProject: Bool = true
        ) async throws -> ReleaseQualificationAttestation {
            let result = await runQualification(
                waiversURL: waiversURL, mutateOpenProject: mutateOpenProject)
            // NOT an exit-code assertion. `--qualify` exits non-zero when a case FAILED, and these
            // fixtures drive a fake transport where most operations fail by construction -- so a
            // zero here would mean the contract had been removed, not that the harness worked.
            // What this helper needs is an attestation to read, and the decode below is that
            // assertion. The exit code has its own test:
            // `qualifyExitCodeReportsWhetherAnythingFailed`.
            #expect(result.exitCode == 0 || result.exitCode == 1, "the command ran")
            try forceSignForDiagnosticFixture()
            return try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: attestationURL)
            )
        }

        func forceSignForDiagnosticFixture() throws {
            let original = try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: attestationURL)
            )
            let provenance = try #require(original.provenance)
            let signingKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: signingKeyData
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let signature = QualificationProvenanceSignature(
                algorithm: "ed25519",
                keyID: SupportBundleBuilder.sha256(signingKey.publicKey.rawRepresentation),
                value: try signingKey.signature(for: encoder.encode(provenance)).base64EncodedString()
            )
            try JSONEncoder().encode(copy(
                original,
                provenanceSignature: signature
            )).write(to: attestationURL, options: .atomic)
        }

        func sign(releaseVersion: String = "1.2.3") {
            let signing = QualificationRunner.signTrusted(
                candidateURL: executableURL,
                bundleURL: directory,
                releaseVersion: releaseVersion,
                expectedCommitSHA: commitSHA,
                signingPrivateKeyData: signingKeyData,
                requiredArtifacts: [],
                requiredOperationIDs: requiredOperationIDs
            )
            #expect(signing.exitCode == 0)
        }

        /// - Parameter mutateOpenProject: whether this run consents to the write recipes. The
        ///   harness drives a FAKE transport with no Logic and no project, so consenting costs
        ///   nothing here and is what an operator does; the WITHHELD path has its own test
        ///   (`withoutConsentEveryMutatingOperationIsWithheldAndSaysSo`) rather than being the
        ///   silent default of every fixture.
        func runQualification(
            waiversURL: URL? = nil,
            mutateOpenProject: Bool = true,
            locale: QualificationLocale = .enUS
        ) async -> QualificationCommandResult {
            var arguments = [
                "LogicProMCP", "--qualify",
                "--out", attestationURL.path,
                "--release-version", "1.2.3",
                "--locale", locale == .koKR ? "ko" : "en",
            ]
            if mutateOpenProject {
                arguments.append("--mutate-open-project")
            }
            if let waiversURL {
                arguments.append(contentsOf: ["--waivers", waiversURL.path])
            }
            if qualificationIncludesExternalCases {
                arguments.append(contentsOf: ["--cases", externalCasesURL.path])
            }
            return await runner.run(arguments: arguments)
        }

        func evidence(for qualificationCase: QualificationCase) throws -> [String: Any] {
            let relativePath = try #require(qualificationCase.evidenceFiles.first)
            let data = try Data(contentsOf: directory.appendingPathComponent(relativePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func verify(
            releaseVersion: String = "1.2.3",
            expectedSHA256: String,
            expectedCommit: String? = nil,
            requiredArtifacts: String = "LogicProMCP,evidence-manifest.json"
        ) async -> QualificationCommandResult {
            await runner.run(arguments: [
                "LogicProMCP", "--verify-promotion",
                "--attestation", attestationURL.path,
                "--release-version", releaseVersion,
                "--expected-binary-sha256", expectedSHA256,
                "--expected-commit", expectedCommit ?? commitSHA,
                "--required-artifacts", requiredArtifacts,
            ])
        }

        func writeAttestation(
            _ original: ReleaseQualificationAttestation,
            waivers: [QualificationWaiver]
        ) throws {
            try JSONEncoder().encode(copy(original, waivers: waivers)).write(to: attestationURL)
        }

        func copy(
            _ original: ReleaseQualificationAttestation,
            serverVersion: String? = nil,
            binarySHA256: String? = nil,
            cases: [QualificationCase]? = nil,
            waivers: [QualificationWaiver]? = nil,
            provenanceSignature: QualificationProvenanceSignature? = nil
        ) -> ReleaseQualificationAttestation {
            let copiedCases = cases ?? original.cases
            return ReleaseQualificationAttestation(
                schema: original.schema,
                serverVersion: serverVersion ?? original.serverVersion,
                commitSHA: original.commitSHA,
                binarySHA256: binarySHA256 ?? original.binarySHA256,
                logicVariant: original.logicVariant,
                logicVersion: original.logicVersion,
                locale: original.locale,
                profile: original.profile,
                cache: original.cache,
                fixture: original.fixture,
                startedAt: original.startedAt,
                completedAt: original.completedAt,
                total: copiedCases.count,
                passed: copiedCases.filter { $0.status == .passed }.count,
                failed: copiedCases.filter { $0.status == .failed }.count,
                waived: copiedCases.filter { $0.status == .waived }.count,
                cases: copiedCases,
                waivers: waivers ?? original.waivers,
                evidenceManifestSHA256: original.evidenceManifestSHA256,
                operationCatalogSHA256: original.operationCatalogSHA256,
                provenance: original.provenance,
                provenanceSignature: provenanceSignature ?? original.provenanceSignature
            )
        }
    }
}
