import Foundation
import Darwin
import Testing
@testable import LogicProMCP

@Suite("ADR-001 qualification runner", .serialized)
struct QualificationRunnerTests {
    @Test func driveDerivesPassFromLiveProtocolNotRegistryBooleans() async throws {
        let spec = try #require(OperationRegistry.specs.first)
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

    @Test func handshakeTimeoutYieldsFailedCaseNotPassed() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.requestTimeout(phase: "handshake")
        })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        #expect(attestation.cases.allSatisfy { $0.status == .failed && !$0.verified })
        let evidence = try fixture.evidence(for: #require(attestation.cases.first))
        #expect((evidence["failure_reason"] as? String)?.contains("timeout:handshake") == true)
        #expect(evidence["handshake_ok"] as? Bool == false)
    }

    @Test func nonZeroExitYieldsFailedCase() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.nonZeroExit(status: 17, stderr: "fixture exit")
        })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        #expect(attestation.cases.allSatisfy { $0.status == .failed && !$0.verified })
        let evidence = try fixture.evidence(for: #require(attestation.cases.first))
        #expect((evidence["failure_reason"] as? String)?.contains("nonzero_exit:17") == true)
    }

    @Test func malformedFrameYieldsFailedCase() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.malformedFrame("not-json")
        })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        #expect(attestation.cases.allSatisfy { $0.status == .failed && !$0.verified })
        let evidence = try fixture.evidence(for: #require(attestation.cases.first))
        #expect((evidence["failure_reason"] as? String)?.contains("malformed_frame") == true)
    }

    @Test func closedPipeYieldsFailedCase() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)), drive: { _ in
            throw QualificationTransportError.closedPipe(phase: "handshake")
        })
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        #expect(attestation.cases.allSatisfy { $0.status == .failed && !$0.verified })
        let evidence = try fixture.evidence(for: #require(attestation.cases.first))
        #expect((evidence["failure_reason"] as? String)?.contains("closed_pipe:handshake") == true)
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

        #expect(operationCase.status == .failed)
        #expect(!operationCase.verified)
        #expect(evidence["catalog_count_match"] as? Bool == false)
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

        #expect(operationCase.status == .passed)
        #expect(evidence["negative_failclosed"] as? Bool == true)
        #expect(evidence["negative_state"] as? String == "C")
        #expect(evidence["negative_write_attempted"] as? Bool == false)
        #expect(evidence["health_read_stable"] as? Bool == true)
        #expect(evidence["catalog_read_stable"] as? Bool == true)
    }

    @Test func absentAxisEmitsSkippedGovernedByWaiver() async throws {
        let specs = Array(OperationRegistry.specs.prefix(1))
        let fixture = try Fixture(specs: specs)
        defer { fixture.remove() }

        let withoutWaiver = try await fixture.qualify()
        let matchingID = "desktop/en-US/core/cold/empty"
        let matching = try #require(withoutWaiver.cases.first { $0.id == matchingID })
        let skipped = withoutWaiver.cases.filter { $0.status == .skipped }

        #expect(matching.status == .passed)
        #expect(skipped.count == QualificationAxis.requiredCombinations.count - 1)
        #expect(skipped.allSatisfy { $0.reason?.isEmpty == false })
        let rejected = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(rejected.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(rejected)).contains(
            "requiredCombinationNotQualified"
        ))

        let waivers = skipped.map {
            Self.waiver(
                caseID: $0.id,
                userImpact: "Required axis is unavailable on this qualification host",
                affectedCapability: "ADR-001-a host-axis availability"
            )
        }
        try JSONEncoder().encode(waivers).write(to: fixture.waiversURL)
        let withWaiver = try await fixture.qualify(waiversURL: fixture.waiversURL)
        #expect(withWaiver.cases.filter { $0.status == .waived }.count == waivers.count)
        #expect(withWaiver.waivers == waivers)
        let approved = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        #expect(approved.exitCode == 0)
        #expect(try Self.resultObject(approved)["promotable"] as? Bool == true)
    }

    @Test func productionAxisVocabularyCanonicalizesCreatorAndKoreanLocale() async throws {
        let specs = Array(OperationRegistry.specs.prefix(1))
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
        let attestation = try await fixture.qualify()
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
        } catch {
            Issue.record("Handshake first frame within startup budget should succeed: \(error)")
        }
    }

    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before running the real-process qualification QA."
    ))
    func realReleaseBinaryDeliversHandshakeCatalogAndTraceOverQualificationTransport() throws {
        let result = try QualificationTransport().drive(.init(
            executableURL: Self.releaseExecutableURL,
            environment: ProcessInfo.processInfo.environment,
            expectedOperationCount: 107
        ))

        #expect(result.handshakeOK)
        #expect(result.catalog?.operationCount == 107)
        #expect(result.catalogCountMatch)
        #expect(result.traceOK)
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
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }

        let attestation = try await fixture.qualify()
        #expect(attestation.cases.allSatisfy { $0.command != "registry_handler_trace" })
        let result = await fixture.verify(expectedSHA256: fixture.binarySHA256)
        let json = try Self.resultObject(result)

        #expect(result.exitCode == 1)
        #expect(json["promotable"] as? Bool == false)
        #expect(Self.rejectionReasons(json).contains("requiredCombinationNotQualified"))
    }

    @Test func runnerRecordsExactExecutableSHAAndCodableSchema() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }

        let result = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
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
        #expect(attestation.schema == "release-qualification-attestation/v1")
        #expect(attestation.serverVersion == "1.2.3")
        #expect(attestation.commitSHA == fixture.commitSHA)
        #expect(attestation.binarySHA256 == SupportBundleBuilder.sha256(fixture.executableData))
        #expect(attestation.logicVariant == .desktop)
        #expect(attestation.logicVersion == "11.2")
        #expect(attestation.locale == .enUS)
        #expect(attestation.profile == .full)
        #expect(json["cache"] as? String == "warm")
        #expect(attestation.waivers.isEmpty)
        #expect(attestation.total == 5)
        #expect(attestation.total == attestation.cases.count)
        let aggregateIDs = attestation.cases
            .filter { !$0.id.hasPrefix("in-process/") }
            .map(\.id)
        #expect(aggregateIDs.allSatisfy { $0.contains("/full/warm/") })
        let requiredIDs = Set(QualificationAxis.requiredCombinations.map { "\($0.key)/empty" })
        #expect(requiredIDs.isDisjoint(with: aggregateIDs))
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
        #expect(aggregateCases.map(\.id) == QualificationAxis.requiredCombinations.map { "\($0.key)/empty" })
        #expect(attestation.cases.map(\.id).count == Set(attestation.cases.map(\.id)).count)
        #expect(aggregateCases.filter { $0.status == .passed }.count == 1)
        #expect(aggregateCases.filter { $0.status == .skipped }.count == 3)
        #expect(attestation.passed == operationCases.count + 1)
        #expect(attestation.failed == 0)

        for qualificationCase in operationCases {
            let spec = try #require(OperationRegistry.spec(
                tool: qualificationCase.tool,
                command: qualificationCase.command
            ))
            #expect(qualificationCase.id == "in-process/\(spec.id.rawValue)")
            #expect(OperationHandlerRegistry.handler(tool: qualificationCase.tool, command: qualificationCase.command) != nil)
            #expect(qualificationCase.status == .passed)
            #expect(qualificationCase.verified)
            #expect(TraceID.isValid(qualificationCase.traceID))
            let evidencePath = try #require(qualificationCase.evidenceFiles.first)
            let evidenceURL = fixture.directory.appendingPathComponent(evidencePath)
            let evidence = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String: Any]
            )
            #expect(evidence["registry_spec_found"] as? Bool ?? false)
            #expect(evidence["handler_bound"] as? Bool ?? false)
            #expect(evidence["trace_started"] as? Bool ?? false)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        let manifestData = try Data(contentsOf: fixture.manifestURL)
        #expect(attestation.evidenceManifestSHA256 == SupportBundleBuilder.sha256(manifestData))
    }

    @Test func externalCasesAreInjectedWithoutTransformation() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }
        let external = QualificationCase(
            id: "external/live-case",
            status: .passed,
            tool: "logic_system",
            command: "health",
            traceID: "lpmcp_00000000-0000-0000-0000-000000000000",
            verified: true,
            evidenceFiles: ["external/live-case.json"]
        )
        let externalEvidenceURL = fixture.directory.appendingPathComponent("external/live-case.json")
        try FileManager.default.createDirectory(
            at: externalEvidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("external evidence".utf8).write(to: externalEvidenceURL)
        try JSONEncoder().encode([external]).write(to: fixture.externalCasesURL)

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
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let initial = try await fixture.qualify()
        let waivers = Self.hostAxisWaivers(for: initial)
        try JSONEncoder().encode(waivers).write(to: fixture.waiversURL)
        _ = try await fixture.qualify(waiversURL: fixture.waiversURL)

        let result = await fixture.verify(expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData))
        let json = try Self.resultObject(result)
        let promotable = try #require(json["promotable"] as? Bool)
        let rejections = try #require(json["rejections"] as? [[String: Any]])

        #expect(result.exitCode == 0)
        #expect(promotable)
        #expect(rejections.isEmpty)
    }

    @Test func differentPublishedSHARejects() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        _ = try await fixture.qualify()

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
            $0.id == "\(QualificationAxis.requiredCombinations[0].key)/empty"
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
        let passedCase = try #require(original.cases.first)
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
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        let initial = try await fixture.qualify()
        let waivers = Self.hostAxisWaivers(for: initial)
        try JSONEncoder().encode(waivers).write(to: fixture.waiversURL)

        let qualification = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--release-version", "v1.2.3",
            "--waivers", fixture.waiversURL.path,
        ])
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
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("missingArtifact"))
    }

    @Test func tamperedManifestRejectsPromotion() async throws {
        let fixture = try Fixture(specs: OperationRegistry.specs)
        defer { fixture.remove() }
        _ = try await fixture.qualify()
        try Data("tampered manifest".utf8).write(to: fixture.manifestURL, options: .atomic)

        let result = await fixture.verify(expectedSHA256: SupportBundleBuilder.sha256(fixture.executableData))

        #expect(result.exitCode != 0)
        #expect(Self.rejectionReasons(try Self.resultObject(result)).contains("missingArtifact"))
    }

    @Test func reservedManifestOutputPathRejectsQualification() async throws {
        let fixture = try Fixture(specs: Array(OperationRegistry.specs.prefix(1)))
        defer { fixture.remove() }

        for filename in ["evidence-manifest.json", "EVIDENCE-MANIFEST.JSON"] {
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
    }

    @Test func releaseWorkflowQualifiesFinalBinaryBeforePublication() throws {
        let workflow = try scriptContents(".github/workflows/release.yml")
        let package = try #require(workflow.range(of: "name: Package"))
        let formula = try #require(workflow.range(of: "name: Verify Formula install paths against tarball"))
        let gate = try #require(workflow.range(of: "name: Qualify and verify promotion"))
        let release = try #require(workflow.range(of: "name: Create GitHub Release"))
        let gateText = String(workflow[gate.lowerBound..<release.lowerBound])

        #expect(package.lowerBound < gate.lowerBound)
        #expect(formula.lowerBound < gate.lowerBound)
        #expect(gate.lowerBound < release.lowerBound)
        #expect(gateText.contains("shasum -a 256 LogicProMCP"))
        #expect(gateText.contains("./LogicProMCP --qualify"))
        #expect(gateText.contains("--out release-qualification-attestation.json"))
        #expect(gateText.contains("--waivers .github/qualification/waivers.json"))
        #expect(gateText.contains("./LogicProMCP --verify-promotion"))
        #expect(gateText.contains("--expected-binary-sha256 \"$binary_sha256\""))
        #expect(gateText.contains("--release-version \"$RELEASE_VERSION\""))
        #expect(!gateText.contains("swift build"))
        let waiverData = try Data(contentsOf: URL(
            fileURLWithPath: ".github/qualification/waivers.json"
        ))
        let waiverArray = try #require(JSONSerialization.jsonObject(with: waiverData) as? [Any])
        #expect(waiverArray.isEmpty)
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
            affectsDefaultProfile: false,
            expiryVersion: expiryVersion,
            releaseNoteVisible: true
        )
    }

    private static func hostAxisWaivers(
        for attestation: ReleaseQualificationAttestation
    ) -> [QualificationWaiver] {
        attestation.cases.filter { $0.status == .skipped }.map {
            waiver(
                caseID: $0.id,
                userImpact: "Required axis is unavailable on this qualification host",
                affectedCapability: QualificationWaiver.hostAxisAvailabilityCapability
            )
        }
    }

    private static let releaseExecutableURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(".build/release/LogicProMCP")

    private static func driveResult(
        specs: [OperationSpec],
        catalogCount: Int? = nil,
        observedVariant: String = "desktop",
        observedLocale: String = "en-US"
    ) -> QualificationDriveResult {
        let expectedCount = specs.count
        let actualCount = catalogCount ?? expectedCount
        let catalogEntries = Array(OperationCatalog.snapshot(now: Date(timeIntervalSince1970: 1_000))
            .operations.prefix(actualCount))
        let stableHealth = Data("{\"logic_pro_variant\":\"\(observedVariant)\"}".utf8)
        let stableCatalog = Data("{\"operation_count\":\(actualCount)}".utf8)
        return QualificationDriveResult(
            handshake: .init(
                protocolVersion: "2025-11-25",
                serverName: "logic-pro-mcp",
                serverVersion: "1.2.3"
            ),
            health: .init(
                logicProRunning: true,
                logicProVersion: "11.2",
                logicProVariant: observedVariant,
                processMetadataResolved: true
            ),
            catalog: .init(
                schemaVersion: 1,
                generatedAt: "1970-01-01T00:16:40Z",
                operationCount: actualCount,
                operations: catalogEntries
            ),
            expectedOperationCount: expectedCount,
            traceList: .init(traces: []),
            negative: .init(
                toolIsError: true,
                state: "C",
                error: "invalid_params",
                writeAttempted: false,
                healthBefore: stableHealth,
                healthAfter: stableHealth,
                catalogBefore: stableCatalog,
                catalogAfter: stableCatalog
            ),
            observedLocale: observedLocale,
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
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"logic_pro_running\":true,\"logic_pro_version\":\"11.2\",\"logic_pro_variant\":\"desktop\",\"process_metadata_resolved\":true}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"contents":[{"uri":"logic://system/operations","text":"{\"schema_version\":1,\"generated_at\":\"1970-01-01T00:00:00Z\",\"operation_count\":0,\"operations\":[]}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"traces\":[]}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"isError":true,"content":[{"type":"text","text":"{\"state\":\"C\",\"error\":\"invalid_params\",\"write_attempted\":false}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"{\"logic_pro_running\":true,\"logic_pro_version\":\"11.2\",\"logic_pro_variant\":\"desktop\",\"process_metadata_resolved\":true}"}]}}'
            /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":7,"result":{"contents":[{"uri":"logic://system/operations","text":"{\"schema_version\":1,\"generated_at\":\"1970-01-01T00:00:00Z\",\"operation_count\":0,\"operations\":[]}"}]}}'
            exec 1>&-
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
        let executableData = Data("qualification-binary-fixture".utf8)
        let attestationURL: URL
        let manifestURL: URL
        let externalCasesURL: URL
        let waiversURL: URL
        let commitSHA = String(repeating: "c", count: 40)
        let runner: QualificationRunner

        var binarySHA256: String { SupportBundleBuilder.sha256(executableData) }

        init(
            specs: [OperationSpec],
            binaryVersion: String = "1.2.3",
            registryValidationErrors: [String] = [],
            handlerValidationErrors: [String] = [],
            handlerExists: @escaping @Sendable (String, String) -> Bool = {
                OperationHandlerRegistry.handler(tool: $0, command: $1) != nil
            },
            drive: (@Sendable (QualificationDriveRequest) async throws -> QualificationDriveResult)? = nil
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qualification-runner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executableURL = directory.appendingPathComponent("LogicProMCP")
            attestationURL = directory.appendingPathComponent("attestation.json")
            manifestURL = directory.appendingPathComponent("evidence-manifest.json")
            externalCasesURL = directory.appendingPathComponent("cases.json")
            waiversURL = directory.appendingPathComponent("waivers.json")
            try executableData.write(to: executableURL)
            let defaultDriveResult = QualificationRunnerTests.driveResult(specs: specs)
            let drive = drive ?? { _ in defaultDriveResult }
            runner = QualificationRunner(runtime: .init(
                executableURL: { [executableURL] in executableURL },
                environment: { [commitSHA] in ["GIT_COMMIT": commitSHA] },
                now: { Date(timeIntervalSince1970: 1_000) },
                serverVersion: { binaryVersion },
                specs: { specs },
                registryValidationErrors: { registryValidationErrors },
                handlerValidationErrors: { handlerValidationErrors },
                handlerExists: handlerExists,
                drive: drive
            ))
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func qualify(waiversURL: URL? = nil) async throws -> ReleaseQualificationAttestation {
            var arguments = [
                "LogicProMCP", "--qualify",
                "--out", attestationURL.path,
                "--release-version", "1.2.3",
            ]
            if let waiversURL {
                arguments.append(contentsOf: ["--waivers", waiversURL.path])
            }
            let result = await runner.run(arguments: arguments)
            #expect(result.exitCode == 0)
            return try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: attestationURL)
            )
        }

        func evidence(for qualificationCase: QualificationCase) throws -> [String: Any] {
            let relativePath = try #require(qualificationCase.evidenceFiles.first)
            let data = try Data(contentsOf: directory.appendingPathComponent(relativePath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func verify(
            releaseVersion: String = "1.2.3",
            expectedSHA256: String,
            requiredArtifacts: String = "LogicProMCP,evidence-manifest.json"
        ) async -> QualificationCommandResult {
            await runner.run(arguments: [
                "LogicProMCP", "--verify-promotion",
                "--attestation", attestationURL.path,
                "--release-version", releaseVersion,
                "--expected-binary-sha256", expectedSHA256,
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
            waivers: [QualificationWaiver]? = nil
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
                startedAt: original.startedAt,
                completedAt: original.completedAt,
                total: copiedCases.count,
                passed: copiedCases.filter { $0.status == .passed }.count,
                failed: copiedCases.filter { $0.status == .failed }.count,
                waived: copiedCases.filter { $0.status == .waived }.count,
                cases: copiedCases,
                waivers: waivers ?? original.waivers,
                evidenceManifestSHA256: original.evidenceManifestSHA256
            )
        }
    }
}
