import Foundation
import Darwin
import CryptoKit
import Testing
@testable import LogicProMCP

@Suite("ADR-001 qualification runner", .serialized)
struct QualificationRunnerTests {
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

    @Test func operationQualificationSeparatesSemanticReadSmokeAndTypedDeferrals() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        let operationCases = attestation.cases.filter { $0.id.hasPrefix("in-process/") }

        #expect(operationCases.count == 107)
        #expect(operationCases.filter { $0.status == .passed }.count == 1)
        #expect(operationCases.filter { $0.status == .protocolSmoke }.count == 20)
        #expect(operationCases.filter { $0.status == .notQualified }.count == 86)
        #expect(operationCases.filter { $0.status == .failed }.isEmpty)
        #expect(operationCases.filter { $0.status == .protocolSmoke }.allSatisfy {
            $0.verificationKind == .protocolSmoke
                && $0.deferral?.code == .semanticValidatorUnavailable
                && $0.readback?.verified == false
        })
        #expect(operationCases.filter { $0.status == .notQualified }.allSatisfy {
            $0.verificationKind == .typedDeferral
                && $0.deferral?.code == .liveMutationNotRun
                && $0.deferral?.detail.contains("ADR-001-c") == true
                && $0.readback != nil
        })
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
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "semantic-readback",
            readbackData: mismatchedReadback,
            failureReason: nil
        )

        #expect(result.status != .passed)
        #expect(!result.verified)
        #expect(result.readback?.verified == false)
    }

    @Test func readOperationWithoutValidatorIsProtocolSmoke() throws {
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
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "smoke-readback",
            readbackData: Data(#"{"logic_pro_running":true}"#.utf8),
            failureReason: nil
        )

        #expect(result.status.rawValue == "protocol_smoke")
        #expect(!result.verified)
        #expect(result.readback?.verified == false)
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
            writeAttempted: false,
            readbackSource: "logic://system/health",
            readbackRequestID: "semantic-readback",
            readbackData: health,
            failureReason: nil
        )

        #expect(result.status == .passed)
        #expect(result.verified)
        #expect(result.verificationKind == .semanticReadback)
        #expect(result.readback?.verified == true)
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

    @Test func zeroOf107QualifiedOperationsRejectsPromotion() async throws {
        let specs = OperationRegistry.specs
        let driveResult = Self.driveResult(specs: specs, qualifiedReadOperationCount: 0)
        #expect(driveResult.operationResults.values.filter { $0.status == .passed }.isEmpty)
        #expect(driveResult.operationResults.values.filter { $0.status == .notQualified }.count == 107)
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

    @Test func thirteenLegacyTransportSuccessesAndNinetyFourDeferralsRejectPromotion() async throws {
        let specs = OperationRegistry.specs
        let driveResult = Self.driveResult(specs: specs, qualifiedReadOperationCount: 13)
        #expect(driveResult.operationResults.values.filter { $0.isError == false }.count == 13)
        #expect(driveResult.operationResults.values.filter { $0.isError == true }.count == 94)
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
        #expect(try Self.resultObject(decision)["promotable"] as? Bool == true)
    }

    @Test func individualGovernedProtocolSmokeWaiverSatisfiesRequiredOperation() async throws {
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
        #expect(operationCase.status == .waived)
        #expect(operationCase.verificationKind == .typedDeferral)
        #expect(operationCase.deferral?.code == .semanticValidatorUnavailable)

        let decision = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(decision.exitCode == 0)
        #expect(try Self.resultObject(decision)["promotable"] as? Bool == true)
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

    @Test func trustedSignedProvenancePromotes() async throws {
        let fixture = try promotableFixture()
        defer { fixture.remove() }
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)

        #expect(result.exitCode == 0, "\(result.stdout)")
        #expect(try Self.resultObject(result)["promotable"] as? Bool == true)
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

        try #require(result.exitCode == 0)
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(attestation.provenance != nil)
        #expect(attestation.provenanceSignature == nil)
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

        #expect(result.exitCode == 0)
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

    @Test func emptyTraceListFailsWithoutObservedEvents() {
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

        #expect(empty.traceList?.traces.isEmpty == true)
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
        #expect(evidence["handshake_ok"] as? Bool == true)
        #expect(evidence["health_ok"] as? Bool == true)
        #expect(evidence["catalog_count_match"] as? Bool == true)
        #expect(evidence["trace_ok"] as? Bool == true)
        #expect(evidence["negative_failclosed"] as? Bool == true)
        #expect(evidence["registry_spec_found"] as? Bool == false)
        #expect(evidence["handler_bound"] as? Bool == false)
    }

    @Test func handshakeTimeoutStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.requestTimeout(phase: "handshake")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Logic Pro variant mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func nonZeroExitStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.nonZeroExit(status: 17, stderr: "fixture exit")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Logic Pro variant mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func malformedFrameStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.malformedFrame("not-json")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Logic Pro variant mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.attestationURL.path))
    }

    @Test func closedPipeStopsBeforeAttestation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.closedPipe(phase: "handshake")
        })
        defer { fixture.remove() }

        let result = await fixture.runQualification()
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Logic Pro variant mismatch"))
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
        #expect(evidence["catalog_count_match"] as? Bool == false)
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
        let catalog = Data(#"{"operation_count":107}"#.utf8)

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
        #expect(!result(catalogAfter: Data(#"{"operation_count":106}"#.utf8)).isFailClosedAndStable)
        #expect(!result(state: "B").isFailClosedAndStable)
    }

    @Test func observedAxisReadbackStaysVerifiedWhenHealthWarms() async throws {
        let specs = [try #require(OperationRegistry.specs.first { $0.id == .systemHealth })]
        let driveResult = Self.driveResult(specs: specs, healthChangesAfterNegativeProbe: true)
        #expect(driveResult.negative?.healthReadStable == false)
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
        #expect(evidence["negative_failclosed"] as? Bool == true)
        #expect(evidence["negative_state"] as? String == "C")
        #expect(evidence["negative_write_attempted"] as? Bool == false)
        #expect(evidence["health_read_stable"] as? Bool == true)
        #expect(evidence["catalog_read_stable"] as? Bool == true)
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

    @Test func productionAxisVocabularyCanonicalizesCreatorAndKoreanLocale() async throws {
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
        #expect(result.exitCode == 0)
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        let observed = try #require(attestation.cases.first {
            $0.id == "creator/ko-KR/core/cold/empty"
        })
        let evidence = try fixture.evidence(for: observed)

        #expect(observed.status == .passed)
        #expect(observed.verified)
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

    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before running the real-process qualification QA."
    ))
    func realReleaseBinaryExecutesEveryOperationWithIndependentReadback() throws {
        let result = try QualificationTransport().drive(.init(
            executableURL: Self.releaseExecutableURL,
            environment: ProcessInfo.processInfo.environment,
            expectedOperationCount: OperationRegistry.specs.count,
            operations: OperationRegistry.specs
        ))

        #expect(result.handshakeOK)
        #expect(result.catalog?.operationCount == 107)
        #expect(result.catalogCountMatch)
        #expect(result.traceOK)

        let operationResults = Array(result.operationResults.values)
        let mutating = operationResults.filter { $0.mutability == .mutating }
        let readOnly = operationResults.filter { $0.mutability == .readOnly }
        let qualified = operationResults.filter { $0.status == .passed }
        let deferred = operationResults.filter { $0.status == .notQualified }
        let smoke = operationResults.filter { $0.status == .protocolSmoke }

        #expect(operationResults.count == OperationRegistry.specs.count)
        #expect(mutating.count == 86)
        #expect(readOnly.count == 21)
        #expect(operationResults.allSatisfy { $0.status != .failed })
        #expect(operationResults.allSatisfy { $0.responseData != nil && $0.readback != nil })
        #expect(Set(operationResults.compactMap(\.requestID)).count == operationResults.count)
        #expect(Set(operationResults.compactMap(\.readbackRequestID)).count == operationResults.count)
        #expect(mutating.allSatisfy {
            $0.status == .notQualified
                && $0.isError == true
                && $0.state == "C"
                && $0.error == "invalid_params"
                && $0.writeAttempted == false
                && $0.deferral?.code == .liveMutationNotRun
        })
        #expect(readOnly.allSatisfy {
            $0.status == .passed || $0.status == .notQualified || $0.status == .protocolSmoke
        })
        print(
            "qualification operation classification: "
                + "qualified=\(qualified.count), protocol_smoke=\(smoke.count), "
                + "deferred=\(deferred.count), failed=0"
        )
    }

    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before running the Runner fault probe."
    ))
    func runnerRejectsPartialStateObservedFromRealServer() async throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportPlay })
        let executableData = try Data(contentsOf: Self.releaseExecutableURL)
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

        #expect(qualification.exitCode == 0)
        #expect(responsePayload.contains(#"\"error\":\"readback_unavailable\""#))
        #expect(operationCase.status == .failed)
        #expect(promotion.exitCode == 1)
        #expect(promotionJSON["promotable"] as? Bool == false)
    }

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
        #expect(json["promotable"] as? Bool == true)
        #expect(Self.rejectionReasons(json).isEmpty)
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
                #expect((firstFrame["operation_id"] as? String)?.isEmpty == false)
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
            variant: .creatorStudio,
            locale: .koKR,
            profile: .full,
            cache: .warm,
            fixture: .empty
        )
        let driveResult = Self.driveResult(
            specs: specs,
            observedVariant: "creator_studio",
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
            "--variant", "creator",
            "--locale", "ko",
            "--profile", "full",
            "--cache", "warm",
        ])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let data = try Data(contentsOf: fixture.attestationURL)
        let attestation = try JSONDecoder().decode(ReleaseQualificationAttestation.self, from: data)
        let roundTripped = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: JSONEncoder().encode(attestation)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(attestation == roundTripped)
        #expect(attestation.schema == "release-qualification-attestation/v2")
        #expect(attestation.serverVersion == "1.2.3")
        #expect(attestation.commitSHA == fixture.commitSHA)
        #expect(attestation.binarySHA256 == SupportBundleBuilder.sha256(fixture.executableData))
        #expect(attestation.logicVariant == .creatorStudio)
        #expect(attestation.logicVersion == "11.2")
        #expect(attestation.locale == .koKR)
        #expect(attestation.profile == .full)
        #expect(attestation.cache == .warm)
        #expect(attestation.fixture == .empty)
        #expect(json["cache"] as? String == "warm")
        #expect(attestation.waivers == waivers)
        #expect(attestation.total == 5)
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

    @Test func inProcessCasesMatchRegistryHandlersAndTraces() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--release-version", "1.2.3",
        ])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
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
        #expect(aggregateCases.filter { $0.status == .failed }.count == 1)
        #expect(aggregateCases.filter { $0.status == .notQualified }.count == 3)
        #expect(operationCases.filter { $0.status == .passed }.count == 1)
        #expect(operationCases.filter { $0.status == .protocolSmoke }.count == 20)
        #expect(operationCases.filter { $0.status == .notQualified }.count == 86)
        #expect(attestation.passed == 1)
        #expect(attestation.failed == 1)

        for qualificationCase in operationCases {
            let spec = try #require(OperationRegistry.spec(
                tool: qualificationCase.tool,
                command: qualificationCase.command
            ))
            #expect(qualificationCase.id == "in-process/\(spec.id.rawValue)")
            #expect(OperationHandlerRegistry.handler(tool: qualificationCase.tool, command: qualificationCase.command) != nil)
            if spec.id == .systemHealth {
                #expect(qualificationCase.status == .passed)
                #expect(qualificationCase.verified)
                #expect(qualificationCase.verificationKind == .semanticReadback)
            } else if spec.mutability == .readOnly {
                #expect(qualificationCase.status == .protocolSmoke)
                #expect(!qualificationCase.verified)
                #expect(qualificationCase.verificationKind == .protocolSmoke)
                #expect(qualificationCase.deferral?.code == .semanticValidatorUnavailable)
            } else {
                #expect(qualificationCase.status == .notQualified)
                #expect(!qualificationCase.verified)
                #expect(qualificationCase.verificationKind == .typedDeferral)
                #expect(qualificationCase.deferral?.code == .liveMutationNotRun)
                #expect(qualificationCase.deferral?.detail.contains("ADR-001-c") == true)
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
            #expect(evidence["registry_spec_found"] as? Bool ?? false)
            #expect(evidence["handler_bound"] as? Bool ?? false)
            #expect((evidence["trace_started"] as? Bool ?? false) == (spec.id == .systemSagaExecute))
        }

        #expect(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        let manifestData = try Data(contentsOf: fixture.manifestURL)
        #expect(attestation.evidenceManifestSHA256 == SupportBundleBuilder.sha256(manifestData))
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

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: fixture.attestationURL)
        )
        #expect(attestation.cases.last == external)
        #expect(attestation.total == 6)
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

        #expect(result.exitCode == 0)
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
            mutationRestoreRecords: [.init(
                operationID: "tracks.rename",
                preState: "Before",
                mutation: "After",
                readback: "After",
                restore: "Before",
                restoreReadback: "Before"
            )]
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

        #expect(qualification.exitCode == 0)
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

    @Test func releaseWorkflowRequiresTrustedIndependentQualificationBeforePublication() throws {
        let workflow = try scriptContents(".github/workflows/release.yml")
        let package = try #require(workflow.range(of: "name: Package"))
        let formula = try #require(workflow.range(of: "name: Verify Formula install paths against tarball"))
        let checkout = try #require(workflow.range(of: "name: Checkout pinned trusted verifier"))
        let buildVerifier = try #require(workflow.range(of: "name: Build pinned trusted verifier"))
        let release = try #require(workflow.range(of: "name: Create GitHub Release"))

        #expect(package.lowerBound < formula.lowerBound)
        #expect(formula.lowerBound < release.lowerBound)
        #expect(!workflow.contains("LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY"))
        let qualification = try #require(workflow.range(
            of: "name: Enforce independent exact-artifact qualification"
        ))
        #expect(formula.lowerBound < checkout.lowerBound)
        #expect(checkout.lowerBound < buildVerifier.lowerBound)
        #expect(buildVerifier.lowerBound < qualification.lowerBound)
        #expect(qualification.lowerBound < release.lowerBound)
        #expect(!workflow.contains("./LogicProMCP --qualify"))
        #expect(!workflow.contains("./LogicProMCP --verify-promotion"))
        #expect(workflow.contains("uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"))
        #expect(workflow.contains("ref: 67fec5fccf817f9978022f0ca262b80a789e2dce"))
        #expect(workflow.contains("path: trusted-verifier-src"))
        #expect(workflow.contains("working-directory: trusted-verifier-src"))
        #expect(workflow.contains("swift build -c release --product trusted-verifier"))
        #expect(workflow.contains("LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY=\"$TRUSTED_QUALIFICATION_PUBLIC_KEY\""))
        #expect(workflow.contains("trusted-verifier-src/.build/release/trusted-verifier verify"))
        #expect(workflow.contains("--candidate LogicProMCP"))
        #expect(workflow.contains("--bundle qualification-evidence"))
        #expect(workflow.contains("--release-version \"${GITHUB_REF_NAME#v}\""))
        #expect(workflow.contains("--expected-commit \"$GITHUB_SHA\""))
        let releaseStep = workflow.split(
            separator: "- name: Create GitHub Release",
            maxSplits: 1
        ).last.map(String.init) ?? ""
        #expect(releaseStep.contains("qualification-evidence/public-transcript.json"))
        #expect(!releaseStep.contains("qualification-evidence/raw-transcript.json"))
        let waiverData = try Data(contentsOf: URL(
            fileURLWithPath: ".github/qualification/waivers.json"
        ))
        let waivers = try JSONDecoder().decode([QualificationWaiver].self, from: waiverData)
        #expect(QualificationWaiverValidator.issues(in: waivers).isEmpty)
        // B0: blanket coverage-by-waiver is forbidden. Semantic coverage is
        // enforced at release time by PromotionGate (requiredOperationNotSatisfied
        // per uncovered operation); a future waiver must be individually governed
        // with a bounded expiry, not a repo-wide census filler.
        #expect(waivers.isEmpty)
        #expect(workflow.contains("tags:"))
        #expect(workflow.contains("validate-install:"))
        #expect(workflow.contains("needs: build"))
    }

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
        candidateExecutionSentinelURL: URL? = nil
    ) throws -> Fixture {
        let specs = OperationRegistry.specs
        let driveResult = Self.driveResult(
            specs: specs,
            mutationRestoreRecords: [.init(
                operationID: "tracks.rename",
                preState: "Before",
                mutation: "After",
                readback: "After",
                restore: "Before",
                restoreReadback: "Before"
            )]
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
        try JSONEncoder().encode(operationWaivers + Self.axisWaivers())
            .write(to: fixture.waiversURL)
        return fixture
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
            let response = spec.id == nonObjectResponseOperationID
                ? Data("plain text response".utf8)
                : spec.id == .systemHealth
                ? stableHealth
                : Data((isMutation
                    ? "{\"operation\":\"\(spec.id.rawValue)\",\"state\":\"C\",\"error\":\"invalid_params\",\"write_attempted\":false}"
                    : "{\"operation\":\"\(spec.id.rawValue)\",\"state\":\"A\",\"write_attempted\":false}"
                ).utf8)
            let readback = spec.id == .systemHealth
                ? stableHealth
                : Data("{\"operation_readback\":\"\(spec.id.rawValue)\"}".utf8)
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
                    state: spec.id == nonObjectResponseOperationID ? nil : isMutation ? "C" : "A",
                    error: isMutation ? "invalid_params" : nil,
                    writeAttempted: false,
                    readbackSource: spec.tool == .logicTransport
                        ? "logic://transport/state"
                        : spec.tool == .logicMixer
                            ? "logic://mixer"
                            : "logic://system/health",
                    readbackRequestID: "fake-readback-\(spec.id.rawValue)",
                    readbackData: readback,
                    failureReason: spec.id == failedOperationID ? "synthetic operation failure" : nil
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

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qualification-slow-handshake-\(UUID().uuidString)", isDirectory: true)
            executableURL = directory.appendingPathComponent("server.sh")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = #"""
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
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":9,"result":{"content":[{"type":"text","text":"{\"logic_pro_running\":true,\"logic_pro_version\":\"11.2\",\"logic_pro_bundle_id\":\"com.apple.logic10\",\"logic_pro_variant\":\"desktop\",\"logic_pro_ui_locale\":\"en-US\",\"logic_pro_variants\":[{\"variant\":\"desktop\",\"bundle_id\":\"com.apple.logic10\",\"installed\":true,\"running\":true},{\"variant\":\"creator_studio\",\"bundle_id\":\"com.apple.mobilelogic\",\"installed\":false,\"running\":false}],\"process_metadata_resolved\":true}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":10,"result":{"contents":[{"uri":"logic://system/operations","text":"{\"schema_version\":1,\"generated_at\":\"1970-01-01T00:00:00Z\",\"operation_count\":0,\"operations\":[]}"}]}}'
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
        let signingKeyData: Data
        let trustedPublicKeyData: Data
        let requiredOperationIDs: Set<String>
        let runner: QualificationRunner

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
            drive: (@Sendable (QualificationDriveRequest) async throws -> QualificationDriveResult)? = nil
        ) throws {
            self.commitSHA = commitSHA
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
                drive: drive
            ))
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func qualify(waiversURL: URL? = nil) async throws -> ReleaseQualificationAttestation {
            let result = await runQualification(waiversURL: waiversURL)
            #expect(result.exitCode == 0)
            try forceSignForDiagnosticFixture()
            return try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: attestationURL)
            )
        }

        private func forceSignForDiagnosticFixture() throws {
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

        func runQualification(waiversURL: URL? = nil) async -> QualificationCommandResult {
            var arguments = [
                "LogicProMCP", "--qualify",
                "--out", attestationURL.path,
                "--release-version", "1.2.3",
            ]
            if let waiversURL {
                arguments.append(contentsOf: ["--waivers", waiversURL.path])
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
                provenance: original.provenance,
                provenanceSignature: provenanceSignature ?? original.provenanceSignature
            )
        }
    }
}
