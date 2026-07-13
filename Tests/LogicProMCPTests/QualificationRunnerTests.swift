import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-001 qualification runner", .serialized)
struct QualificationRunnerTests {
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
        #expect(attestation.logicVariant == .creatorStudio)
        #expect(attestation.locale == .koKR)
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
        #expect(attestation.passed == attestation.total)
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
        _ = try await fixture.qualify()

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

        let qualification = await fixture.runner.run(arguments: [
            "LogicProMCP", "--qualify",
            "--out", fixture.attestationURL.path,
            "--release-version", "v1.2.3",
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

    private actor MockQualificationServer: ServerStarting {
        func start() async throws {}
        func stop() async {}
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

        init(specs: [OperationSpec], binaryVersion: String = "1.2.3") throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qualification-runner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executableURL = directory.appendingPathComponent("LogicProMCP")
            attestationURL = directory.appendingPathComponent("attestation.json")
            manifestURL = directory.appendingPathComponent("evidence-manifest.json")
            externalCasesURL = directory.appendingPathComponent("cases.json")
            waiversURL = directory.appendingPathComponent("waivers.json")
            try executableData.write(to: executableURL)
            runner = QualificationRunner(runtime: .init(
                executableURL: { [executableURL] in executableURL },
                environment: { [commitSHA] in ["GIT_COMMIT": commitSHA] },
                now: { Date(timeIntervalSince1970: 1_000) },
                serverVersion: { binaryVersion },
                specs: { specs },
                registryValidationErrors: { OperationRegistry.validationErrors() },
                handlerValidationErrors: { OperationHandlerRegistry.validationErrors() },
                handlerExists: { OperationHandlerRegistry.handler(tool: $0, command: $1) != nil }
            ))
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func qualify() async throws -> ReleaseQualificationAttestation {
            let result = await runner.run(arguments: [
                "LogicProMCP", "--qualify",
                "--out", attestationURL.path,
                "--release-version", "1.2.3",
            ])
            #expect(result.exitCode == 0)
            return try JSONDecoder().decode(
                ReleaseQualificationAttestation.self,
                from: Data(contentsOf: attestationURL)
            )
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
