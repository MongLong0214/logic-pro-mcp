@preconcurrency import ApplicationServices
import Foundation
import Darwin
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
            "requested_domains": ["strips"],
            "sources": ["strips": "ax_request_read"],
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
                    "mixer_strip_ref": "mix_irrelevant",
                    "output_observation": [
                        "state": "observed_destination", "destination": "Stereo Out",
                    ],
                    "send_slots": [[
                        "ordinal": 9, "state": "occupied_unknown_destination", "bypassed": true,
                    ]],
                ],
                ],
            ],
            "ui_effects": [
                "navigation_performed": false,
                "restoration": "not_applicable",
                "attempted": [],
                "changed": [],
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

    @Test func sessionInspectionSeedPurposesKeepPlannerAndMixerReadsPassive() throws {
        let planner = QualificationTransport.sessionInspectionSeedRequestParams(for: .planner)
        let mixer = QualificationTransport.sessionInspectionSeedRequestParams(for: .mixerRead)

        #expect(planner.isEmpty)
        #expect(mixer["scope"] as? String == "whole_project")
        #expect(mixer["domains"] as? [String] == ["strips"])
        let allowsNavigation = try #require(mixer["allow_ui_navigation"] as? Bool)
        #expect(!allowsNavigation)
        #expect(QualificationTransport.mixerReadProbeOperationIDs == [
            .mixerGetOutputVerified,
            .mixerGetInputBusVerified,
            .mixerGetSendDestinationVerified,
            .mixerGetSendBypassVerified,
        ])
    }

    @Test func preparedMixerProbeParamsReplaceTheEmptyCatalogFallback() throws {
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

    @Test func mixerReadProbeParamsAcceptRequestOwnedFreshInspectionRows() throws {
        let inspection: [String: Any] = [
            "schema": "logic_pro_mcp_session_population.v1",
            "read_only": true,
            "snapshot_id": "snap_fresh",
            "scope": "whole_project",
            "requested_domains": ["strips"],
            "sources": ["strips": "ax_request_read"],
            "strips": [
                "coverage": "partial",
                "rows": [[
                    "mixer_strip_ref": "mix_fresh_output",
                    "output_observation": [
                        "state": "observed_destination", "destination": "출력 3-4",
                    ],
                ]],
            ],
            "ui_effects": [
                "navigation_performed": false,
                "restoration": "not_applicable",
                "attempted": [],
                "changed": [],
            ],
        ]

        let params = QualificationTransport.mixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: inspection)
        )

        #expect(params[.mixerGetOutputVerified]?["target_ref"] as? String
            == "mix_fresh_output")
    }

    @Test func mixerReadProbeValidationDistinguishesAnEmptyFixtureFromUnsafeEvidence() throws {
        let validButEmpty: [String: Any] = [
            "schema": "logic_pro_mcp_session_population.v1",
            "read_only": true,
            "snapshot_id": "snap_empty",
            "scope": "whole_project",
            "requested_domains": ["strips"],
            "sources": ["strips": "ax_request_read"],
            "strips": ["coverage": "partial", "rows": []],
            "ui_effects": [
                "navigation_performed": false,
                "restoration": "not_applicable",
                "attempted": [],
                "changed": [],
            ],
        ]
        var unsafe = validButEmpty
        unsafe["read_only"] = false
        var unsafeReference = validButEmpty
        unsafeReference["strips"] = [
            "coverage": "partial",
            "rows": [["mixer_strip_ref": "track_1"]],
        ]
        var unknownObservation = validButEmpty
        unknownObservation["strips"] = [
            "coverage": "partial",
            "rows": [[
                "mixer_strip_ref": "mix_unknown",
                "output_observation": ["state": "future_state"],
            ]],
        ]
        var unknownSend = validButEmpty
        unknownSend["strips"] = [
            "coverage": "partial",
            "rows": [[
                "mixer_strip_ref": "mix_unknown",
                "send_slots": [["ordinal": 0, "state": "future_state"]],
            ]],
        ]

        let empty = QualificationTransport.validatedMixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: validButEmpty)
        )
        let rejected = QualificationTransport.validatedMixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: unsafe)
        )
        let rejectedReference = QualificationTransport.validatedMixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: unsafeReference)
        )
        let rejectedObservation = QualificationTransport.validatedMixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: unknownObservation)
        )
        let rejectedSend = QualificationTransport.validatedMixerReadProbeParams(
            from: try JSONSerialization.data(withJSONObject: unknownSend)
        )

        let emptyParams = try #require(empty)
        #expect(emptyParams.isEmpty)
        #expect(rejected == nil)
        #expect(rejectedReference == nil)
        #expect(rejectedObservation == nil)
        #expect(rejectedSend == nil)
    }

    @Test func mixerReadProbeParamsRejectUnsafeOrUnboundInspectionRows() throws {
        func inspection(
            schema: String = "logic_pro_mcp_session_population.v1",
            readOnly: Bool = true,
            snapshotID: String = "snap_fresh",
            scope: String = "whole_project",
            domains: [String] = ["strips"],
            stripSource: String = "ax_request_read",
            stripCoverage: String = "partial",
            stripRef: String = "mix_fresh_output",
            navigationPerformed: Bool = false,
            restoration: String = "not_applicable",
            attempted: [String] = [],
            changed: [String] = [],
            reason: Any = NSNull()
        ) -> [String: Any] {
            [
                "schema": schema,
                "read_only": readOnly,
                "snapshot_id": snapshotID,
                "scope": scope,
                "requested_domains": domains,
                "sources": ["strips": stripSource],
                "strips": [
                    "coverage": stripCoverage,
                    "rows": [[
                        "mixer_strip_ref": stripRef,
                        "output_observation": [
                            "state": "observed_destination", "destination": "출력 3-4",
                        ],
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
            inspection(schema: "legacy"),
            inspection(readOnly: false),
            inspection(snapshotID: ""),
            inspection(scope: "selected_tracks"),
            inspection(domains: ["tracks", "strips"]),
            inspection(stripSource: "cache"),
            inspection(stripCoverage: "unstable"),
            inspection(stripRef: "track_1"),
            inspection(navigationPerformed: true),
            inspection(restoration: "restored"),
            inspection(attempted: ["track_selection"]),
            inspection(changed: ["track_selection"]),
            inspection(reason: "unexpected_ui_effect"),
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
                    "plugin_id": NSNull(),
                    "plugin_insert_ref": "ins_unverified",
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

    @Test func pluginReadProbeValidationSeparatesEmptyFixturesFromMalformedDiscovery() throws {
        let validEmpty = try JSONSerialization.data(withJSONObject: [
            "state": "A", "complete": true, "plugins": [],
        ])
        let incomplete = try JSONSerialization.data(withJSONObject: [
            "state": "B", "complete": false, "plugins": [],
        ])
        let malformedOccupied = try JSONSerialization.data(withJSONObject: [
            "state": "A", "complete": true,
            "plugins": [[
                "read_status": "ok", "occupied": true,
                "plugin_id": "logic.stock.effect.gain", "plugin_insert_ref": "wrong_ref",
            ]],
        ])
        let unknownStatus = try JSONSerialization.data(withJSONObject: [
            "state": "A", "complete": true,
            "plugins": [[
                "read_status": "future_status", "occupied": false,
                "plugin_id": NSNull(), "plugin_insert_ref": "ins_future",
            ]],
        ])
        let missingPluginID = try JSONSerialization.data(withJSONObject: [
            "state": "A", "complete": true,
            "plugins": [[
                "read_status": "ok", "occupied": true,
                "plugin_insert_ref": "ins_missing_id",
            ]],
        ])
        let contradictoryPluginID = try JSONSerialization.data(withJSONObject: [
            "state": "A", "complete": true,
            "plugins": [[
                "read_status": "ok", "occupied": true,
                "plugin_id": "not.a.catalog.id",
                "plugin_insert_ref": "ins_contradictory_id",
            ]],
        ])

        let validEmptyParams = try #require(
            QualificationTransport.validatedPluginReadProbeParams(from: [validEmpty])
        )
        #expect(validEmptyParams.isEmpty)
        #expect(QualificationTransport.validatedPluginReadProbeParams(
            from: [incomplete]
        ) == nil)
        #expect(QualificationTransport.validatedPluginReadProbeParams(
            from: [malformedOccupied]
        ) == nil)
        #expect(QualificationTransport.validatedPluginReadProbeParams(
            from: [unknownStatus]
        ) == nil)
        #expect(QualificationTransport.validatedPluginReadProbeParams(
            from: [missingPluginID]
        ) == nil)
        #expect(QualificationTransport.validatedPluginReadProbeParams(
            from: [contradictoryPluginID]
        ) == nil)
        #expect(QualificationTransport.validatedPluginReadProbeParams(
            from: [Data("not-json".utf8)]
        ) == nil)
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

    @Test func pluginReadProbePreparationPropagatesMalformedDiscoveryAsFailure() throws {
        let malformedTracks = try JSONSerialization.data(withJSONObject: [
            "source": "project_file", "readable": false, "data": [],
        ])
        var inventoryRead = false
        #expect(throws: QualificationTransportError.self) {
            _ = try QualificationTransport.preparePluginReadProbeParams(
                tracksRead: { malformedTracks },
                inventoryRead: { _ in inventoryRead = true; return Data() }
            )
        }
        #expect(!inventoryRead)

        let liveTracks = try JSONSerialization.data(withJSONObject: [
            "source": "ax_live", "readable": true,
            "data": [["id": 0, "track_ref": "trk_zero"]],
        ])
        let incompleteInventory = try JSONSerialization.data(withJSONObject: [
            "state": "B", "complete": false, "plugins": [],
        ])
        #expect(throws: QualificationTransportError.self) {
            _ = try QualificationTransport.preparePluginReadProbeParams(
                tracksRead: { liveTracks },
                inventoryRead: { _ in incompleteInventory }
            )
        }

        let duplicateTracks = try JSONSerialization.data(withJSONObject: [
            "source": "ax_live", "readable": true,
            "data": [
                ["id": 0, "track_ref": "trk_zero_a"],
                ["id": 0, "track_ref": "trk_zero_b"],
            ],
        ])
        inventoryRead = false
        #expect(throws: QualificationTransportError.self) {
            _ = try QualificationTransport.preparePluginReadProbeParams(
                tracksRead: { duplicateTracks },
                inventoryRead: { _ in inventoryRead = true; return Data() }
            )
        }
        #expect(!inventoryRead)

        let unknownStatusInventory = try JSONSerialization.data(withJSONObject: [
            "state": "A", "complete": true,
            "plugins": [[
                "read_status": "future_status", "occupied": false,
                "plugin_id": NSNull(), "plugin_insert_ref": "ins_future",
            ]],
        ])
        #expect(throws: QualificationTransportError.self) {
            _ = try QualificationTransport.preparePluginReadProbeParams(
                tracksRead: { liveTracks },
                inventoryRead: { _ in unknownStatusInventory }
            )
        }
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
                ["id": 0, "track_ref": "trk_zero"],
                ["id": 2, "track_ref": "trk_two"],
            ],
        ]
        let ambiguous: [String: Any] = [
            "source": "ax_live", "readable": true,
            "data": [
                ["id": 2, "track_ref": "trk_two"],
                ["id": 2, "track_ref": "trk_duplicate"],
            ],
        ]
        let malformed: [String: Any] = [
            "source": "ax_live", "readable": true,
            "data": [["id": -1, "track_ref": "trk_negative"]],
        ]
        let placeholder: [String: Any] = [
            "source": "project_file", "readable": false,
            "data": [["id": 0], ["id": 1]],
        ]

        #expect(QualificationTransport.pluginInventoryTrackIndices(
            from: try JSONSerialization.data(withJSONObject: live)
        ) == [0, 2])
        #expect(QualificationTransport.pluginInventoryTrackIndices(
            from: try JSONSerialization.data(withJSONObject: placeholder)
        ).isEmpty)
        #expect(QualificationTransport.validatedPluginInventoryTrackIndices(
            from: try JSONSerialization.data(withJSONObject: malformed)
        ) == nil)
        #expect(QualificationTransport.validatedPluginInventoryTrackIndices(
            from: try JSONSerialization.data(withJSONObject: ambiguous)
        ) == nil)
        #expect(QualificationTransport.validatedPluginInventoryTrackIndices(
            from: try JSONSerialization.data(withJSONObject: placeholder)
        ) == nil)
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
        let readCase = try #require(attestation.cases.first { $0.operationID == read.id.rawValue })
        #expect(readCase.status == (shape == "missing_readonly" ? .failed : .passed))
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
        let fixture = try qualificationFixture(includeRequiredAtlas: false)
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


    // The deferral count is DERIVED, not typed. It was written out twice — in the body and in the
    // test's own name — so adding an operation broke the assertion and, had only the number been
    // updated, would have left the name asserting something false. Registry size is already pinned
    // by `OperationRegistry.specs.count` elsewhere; repeating it here bought no coverage and cost a
    // second place to drift.


    /// #373 Phase A inverted this test's premise, and the inversion is the
    /// point. This used to waive system.permissions because it could only reach
    /// protocolSmoke — a validator-shaped hole a waiver had to paper over. The
    /// op now qualifies on its own semantics, so waiving it is no longer
    /// governance, it is noise: the gate must reject a waiver for a passing
    /// case rather than let a stale waiver linger over a healthy operation.



    /// Synthetic archived EN scopes, fake transport and existing fixture trust only. No candidate
    /// executable or Logic is launched. A prior baseline version is intentionally still diffable.

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
        if shape == .complete {
            #expect(run.exitCode == 0, "\(run.stdout)")
            #expect(run.stderr.isEmpty, "\(run.stderr)")
            #expect(atlas.status == .passed)
            #expect(atlas.verified)
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
        }
    }

    @Test(arguments: [QualificationLocale.enUS, .koKR])
    func requireAtlasInvokesSelectedCaptureWithOptionalFlagOff(locale: QualificationLocale) async throws {
        try await assertRequiredAtlasProducer(locale: locale, shape: .complete)
    }

    @Test(arguments: [RequiredAtlasCaptureShape.absent, .partial, .dropped])
    private func requireAtlasRefusesIncompleteCapture(shape: RequiredAtlasCaptureShape) async throws {
        try await assertRequiredAtlasProducer(locale: .enUS, shape: shape)
    }

    /// AFTER-only MainEntrypoint composition with the real runner and entirely injected data.
    @Test(arguments: [RequiredAtlasCaptureShape.complete, .absent])
    private func mainEntrypointRequiredAtlasComposesWithInjectedRunner(shape: RequiredAtlasCaptureShape) async throws {
        try await assertRequiredAtlasProducer(locale: .enUS, shape: shape, viaEntrypoint: true)
    }




    @Test func declarativePolicyRoundTripsWithoutRuntimeRegistryMembership() throws {
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

    @Test func mutationRestorePolicyRoundTripsWithoutRuntimeRegistryMembership() throws {
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

    @Test func anAxisCasePassesOnlyOnTheObservationsTheRunnerPassedItOn() async throws {
        let fixture = try qualificationFixture()
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
        // Health warms during cache polling and MCU registration, so it is not a
        // stable observation required by the direct qualification evidence shape.
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

    @Test func qualificationRequiresCommitIdentityForEvidence() async throws {
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

    @Test func qualificationProducesBoundEvidenceMetadata() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
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
        let provenance = try #require(attestation.provenance)
        #expect(provenance.schema == "qualification-provenance/v3")
        #expect(provenance.logicVersion == attestation.logicVersion)
        #expect(provenance.logicVersion == "11.2")
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

    @Test func liveGateReportsSuccessfulProtocolSmokeWithoutCallingItAProductFailure() throws {
        let spec = try #require(OperationRegistry.specs.first {
            $0.id == .mixerGetOutputVerified
        })
        let operation = try #require(
            Self.driveResult(specs: [spec]).operationResults[spec.id.rawValue]
        )
        let summary = QualificationLiveGateSummary(operationResults: [operation])

        #expect(operation.status == .protocolSmoke)
        #expect(operation.liveGateDisposition == .protocolSmoke)
        #expect(summary.protocolSmoke == 1)
        #expect(summary.failures.isEmpty)
        #expect(summary.accounted == summary.total)
        #expect(summary.classificationLine.contains("protocol_smoke=1"))
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

    @Test func liveGateClassifiesOnlyExactMissingMixerAndPluginFixturesAsEnvironmental() {
        func refusal(
            _ operationID: OperationID,
            tool: String,
            command: String,
            hint: String,
            fixturePrecondition: QualificationLiveFixturePrecondition?,
            state: String = "C",
            writeAttempted: Bool = false
        ) -> QualificationOperationResult {
            QualificationOperationResult(
                operationID: operationID.rawValue,
                tool: tool,
                command: command,
                mutability: .readOnly,
                requestID: "fixture-request",
                responseData: Data(#"{"state":"C","error":"invalid_params","write_attempted":false}"#.utf8),
                isError: true,
                state: state,
                error: "invalid_params",
                hint: hint,
                writeAttempted: writeAttempted,
                readbackSource: tool == "logic_mixer" ? "logic://mixer" : "logic://plugins/inventory",
                readbackRequestID: "fixture-readback",
                readbackData: Data(#"{}"#.utf8),
                failureReason: nil,
                liveFixturePrecondition: fixturePrecondition
            )
        }

        let cases: [(OperationID, String, String, String, String)] = [
            (
                .mixerGetOutputVerified,
                "logic_mixer",
                "get_output_verified",
                "get_output_verified requires a current physical Mixer target_ref; no track/index selectors or write inputs are accepted",
                "requires a current physical Mixer target with a typed output observation"
            ),
            (
                .mixerGetInputBusVerified,
                "logic_mixer",
                "get_input_bus_verified",
                "get_input_bus_verified requires a current physical Mixer target_ref; no track/index selectors or write inputs are accepted",
                "requires a current physical Mixer target with a typed bus-input observation"
            ),
            (
                .mixerGetSendDestinationVerified,
                "logic_mixer",
                "get_send_destination_verified",
                "get_send_destination_verified requires a current physical Mixer target_ref; no track/index selectors or write inputs are accepted",
                "requires an occupied Send in the fresh read-only strip census"
            ),
            (
                .mixerGetSendBypassVerified,
                "logic_mixer",
                "get_send_bypass_verified",
                "An exact physical Mixer target_ref and occupied source-census ordinal are required",
                "requires an occupied Send in the fresh read-only strip census"
            ),
            (
                .pluginsGetHostParameterManifest,
                "logic_plugins",
                "get_host_parameter_manifest",
                "get_host_parameter_manifest requires an occupied insert target_ref and non-empty expected_build_fingerprint; it accepts no write inputs",
                "requires an occupied catalog-supported plug-in insert in the current Logic project"
            ),
            (
                .pluginsGetParamVerified,
                "logic_plugins",
                "get_param_verified",
                "get_param_verified requires an occupied insert target_ref; scalar reads also require a named param. No value, mode or confirmation is accepted",
                "requires an occupied plug-in insert with a catalog-backed readable parameter"
            ),
            (
                .pluginsGetChannelEQStateVerified,
                "logic_plugins",
                "get_channel_eq_state_verified",
                "get_channel_eq_state_verified requires an occupied insert target_ref; scalar reads also require a named param. No value, mode or confirmation is accepted",
                "requires an occupied Channel EQ insert in the current Logic project"
            ),
            (
                .pluginsPlanParameterChanges,
                "logic_plugins",
                "plan_parameter_changes",
                "plan_parameter_changes requires an occupied insert target_ref; scalar reads also require a named param. No value, mode or confirmation is accepted",
                "requires an occupied plug-in insert with a catalog-backed plannable parameter"
            ),
        ]

        for (operationID, tool, command, hint, reason) in cases {
            let fixturePrecondition: QualificationLiveFixturePrecondition = switch operationID {
            case .mixerGetOutputVerified: .mixerOutputTarget
            case .mixerGetInputBusVerified: .mixerInputBusTarget
            case .mixerGetSendDestinationVerified, .mixerGetSendBypassVerified: .mixerOccupiedSend
            case .pluginsGetHostParameterManifest: .pluginHostManifestTarget
            case .pluginsGetParamVerified: .pluginReadableParameter
            case .pluginsGetChannelEQStateVerified: .pluginChannelEQ
            default: .pluginPlannableParameter
            }
            let exact = QualificationLiveGateSummary(operationResults: [
                refusal(
                    operationID, tool: tool, command: command, hint: hint,
                    fixturePrecondition: fixturePrecondition
                ),
            ])
            #expect(exact.environmentalPreconditions == [
                .init(operationID: operationID.rawValue, reason: reason),
            ])
            #expect(exact.failed == 0)

            let changed = QualificationLiveGateSummary(operationResults: [
                refusal(
                    operationID, tool: tool, command: command, hint: hint + " changed",
                    fixturePrecondition: fixturePrecondition
                ),
            ])
            #expect(changed.environmentalPreconditions.isEmpty)
            #expect(changed.failed == 1)

            let wrongState = QualificationLiveGateSummary(operationResults: [
                refusal(
                    operationID, tool: tool, command: command, hint: hint,
                    fixturePrecondition: fixturePrecondition, state: "B"
                ),
            ])
            #expect(wrongState.environmentalPreconditions.isEmpty)
            #expect(wrongState.failed == 1)

            let wrote = QualificationLiveGateSummary(operationResults: [
                refusal(
                    operationID, tool: tool, command: command, hint: hint,
                    fixturePrecondition: fixturePrecondition, writeAttempted: true
                ),
            ])
            #expect(wrote.environmentalPreconditions.isEmpty)
            #expect(wrote.failed == 1)

            let unprovenFixtureGap = QualificationLiveGateSummary(operationResults: [
                refusal(
                    operationID, tool: tool, command: command, hint: hint,
                    fixturePrecondition: nil
                ),
            ])
            #expect(unprovenFixtureGap.environmentalPreconditions.isEmpty)
            #expect(unprovenFixtureGap.failed == 1)
        }
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

        // A live mutating PASS must be backed by a verified write/restore cycle.
        let phaseBPasses = mutating.filter {
            $0.status == .passed && $0.verificationKind == .verifiedWriteCycle
        }
        #expect(
            !phaseBPasses.isEmpty,
            "no mutating operation passed on a recorded write cycle, so Phase B did nothing this run"
        )
        #expect(phaseBPasses.allSatisfy { $0.restore?.verified == true })
        print("phase-b passes: \(phaseBPasses.map(\.operationID).sorted().joined(separator: ", "))")
    }

    /// #399 (CEO audit P0) — INVERTED. This test used to prove the runner CAUGHT
    /// a real env-induced `partial_state` fault; that capability was the
    /// vulnerability. With the fault seam compiled out of release, driving the
    /// real release binary through the full runner with the fault env set must now
    /// yield the normal typed zero-write refusal — no `readback_unavailable`, no
    /// failed case.
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
        // `--qualify` exits non-zero when a case FAILED, and these fixtures drive a fake
        // transport where operations fail by construction. The contract has its own test:
        // `qualifyExitCodeReportsWhetherAnythingFailed`.
        #expect(qualification.exitCode == 1)
        #expect(responsePayload.contains(#"\"error\":\"readback_unavailable\""#))
        #expect(operationCase.status == .failed)
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




    @Test func qualifyEmitsRequiredReleaseArtifactsAndManifestDigests() async throws {
        let fixture = try artifactFixture()
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

    @Test func tamperedExternalCaseBindingRejectsQualification() async throws {
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
        for (subcommand, expectedExitCode) in [("--qualify", 0)] {
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
        #expect(!stdout.contains("--verify-promotion"))
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

    private func artifactFixture(
        beforeEvidenceRead: @escaping @Sendable (URL) -> Void = { _ in }
    ) throws -> Fixture {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .systemHealth })
        let fixture = try Fixture(
            specs: [spec],
            beforeEvidenceRead: beforeEvidenceRead
        )
        try JSONEncoder().encode(Self.axisWaivers()).write(to: fixture.waiversURL)
        return fixture
    }

    private func qualificationFixture(
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
            beforeEvidenceRead: @escaping @Sendable (URL) -> Void = { _ in },
            environmentAdditions: [String: String] = [:],
            qualificationIncludesExternalCases: Bool = false,
            drive: (@Sendable (QualificationDriveRequest) async throws -> QualificationDriveResult)? = nil
        ) throws {
            self.commitSHA = commitSHA
            self.qualificationIncludesExternalCases = qualificationIncludesExternalCases
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
            let defaultDriveResult = QualificationRunnerTests.driveResult(specs: specs)
            let drive = drive ?? { _ in defaultDriveResult }
            runner = QualificationRunner(runtime: .init(
                executableURL: { [executableURL] in executableURL },
                environment: { [commitSHA, environmentAdditions] in
                    var environment = environmentAdditions
                    environment["GIT_COMMIT"] = commitSHA
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
            return try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: attestationURL)
            )
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

    }
}
