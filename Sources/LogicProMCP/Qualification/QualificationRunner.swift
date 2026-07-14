import Foundation
import CryptoKit
import Darwin

struct QualificationCommandResult: Sendable {
    let exitCode: Int
    let stdout: String
    let stderr: String
}

struct QualificationRunner: Sendable {
    struct Runtime: Sendable {
        let executableURL: @Sendable () throws -> URL
        let environment: @Sendable () -> [String: String]
        let now: @Sendable () -> Date
        let serverVersion: @Sendable () -> String
        let specs: @Sendable () -> [OperationSpec]
        let registryValidationErrors: @Sendable () -> [String]
        let handlerValidationErrors: @Sendable () -> [String]
        let handlerExists: @Sendable (String, String) -> Bool
        let beforeEvidenceRead: @Sendable (URL) -> Void
        let drive: @Sendable (QualificationDriveRequest) async throws -> QualificationDriveResult

        static let production = Runtime(
            executableURL: { try QualificationRunner.currentExecutableURL() },
            environment: { ProcessInfo.processInfo.environment },
            now: Date.init,
            serverVersion: { ServerConfig.serverVersion },
            specs: { OperationRegistry.specs },
            registryValidationErrors: { OperationRegistry.validationErrors() },
            handlerValidationErrors: { OperationHandlerRegistry.validationErrors() },
            handlerExists: { tool, command in
                OperationHandlerRegistry.bindings.contains {
                    $0.tool == tool && $0.command == command
                }
            },
            beforeEvidenceRead: { _ in },
            drive: { request in
                try QualificationTransport().drive(request)
            }
        )
    }

    private struct QualifyOptions {
        let outputURL: URL
        let externalCasesURL: URL?
        let waiversURL: URL?
        let releaseVersion: String
        let variant: LogicVariant
        let locale: QualificationLocale
        let profile: SetupProfile
        let cache: CacheState
    }

    private struct VerifyOptions {
        let attestationURL: URL
        let releaseVersion: String
        let expectedBinarySHA256: String
        let requiredArtifacts: Set<String>
    }

    private struct VerificationOutput: Codable {
        struct Rejection: Codable {
            let reason: String
            let caseID: String?
            let key: String?
            let name: String?
            let expected: String?
            let actual: String?
        }

        let promotable: Bool
        let rejections: [Rejection]
    }

    private struct EvidenceManifest: Codable {
        enum Kind: String, Codable {
            case caseEvidence = "case_evidence"
            case operationResponse = "operation_response"
            case readbackResponse = "readback_response"
        }

        struct Entry: Codable {
            let path: String
            let sha256: String
            let caseID: String
            let binarySHA256: String
            let axis: QualificationAxis
            let kind: Kind

            enum CodingKeys: String, CodingKey {
                case path
                case sha256
                case caseID = "case_id"
                case binarySHA256 = "binary_sha256"
                case axis
                case kind
            }
        }

        let schema: String
        let binarySHA256: String
        let caseManifestPath: String
        let caseManifestSHA256: String
        let waiversSHA256: String
        let files: [Entry]

        enum CodingKeys: String, CodingKey {
            case schema
            case binarySHA256 = "binary_sha256"
            case caseManifestPath = "case_manifest_path"
            case caseManifestSHA256 = "case_manifest_sha256"
            case waiversSHA256 = "waivers_sha256"
            case files
        }
    }

    private enum RunnerError: Error, CustomStringConvertible {
        case invalidArguments(String)
        case missingOption(String)
        case invalidOption(String, String)
        case malformedWaiver(caseID: String, field: String)
        case duplicateWaiver(caseID: String)
        case releaseVersionMismatch(expected: String, actual: String)
        case logicVariantMismatch(expected: String, actual: String)
        case logicUILocaleMismatch(expected: String, actual: String)
        case evidenceBindingMismatch(String)
        case commitIdentityUnavailable
        case signingKeyUnavailable
        case invalidSigningKey
        case executableUnavailable

        var description: String {
            switch self {
            case .invalidArguments(let detail): detail
            case .missingOption(let option): "Missing required option: \(option)"
            case .invalidOption(let option, let value): "Invalid value for \(option): \(value)"
            case .malformedWaiver(let caseID, let field):
                "Malformed waiver \(caseID.isEmpty ? "<empty>" : caseID): invalid \(field)"
            case .duplicateWaiver(let caseID): "Duplicate waiver for caseID: \(caseID)"
            case .releaseVersionMismatch(let expected, let actual):
                "Release version does not match this binary: expected \(expected), got \(actual)"
            case .logicVariantMismatch(let expected, let actual):
                "Logic Pro variant mismatch: expected \(expected), observed \(actual)"
            case .logicUILocaleMismatch(let expected, let actual):
                "Logic Pro UI locale mismatch: expected \(expected), observed \(actual)"
            case .evidenceBindingMismatch(let detail):
                "External evidence binding mismatch: \(detail)"
            case .commitIdentityUnavailable:
                "Qualification provenance commit identity is unavailable"
            case .signingKeyUnavailable:
                "Qualification provenance signing key is unavailable"
            case .invalidSigningKey:
                "Qualification provenance signing key is invalid"
            case .executableUnavailable: "Unable to resolve the running executable"
            }
        }
    }

    private let runtime: Runtime

    init(runtime: Runtime = .production) {
        self.runtime = runtime
    }

    func run(arguments: [String]) async -> QualificationCommandResult {
        do {
            switch arguments.dropFirst().first {
            case "--qualify":
                let options = try parseQualifyOptions(Array(arguments.dropFirst(2)))
                try await qualify(options)
                return QualificationCommandResult(exitCode: 0, stdout: "", stderr: "")
            case "--verify-promotion":
                return try verify(parseVerifyOptions(Array(arguments.dropFirst(2))))
            default:
                throw RunnerError.invalidArguments("Expected --qualify or --verify-promotion")
            }
        } catch {
            return failure(String(describing: error))
        }
    }

    static func currentExecutableURL() throws -> URL {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.resolvingSymlinksInPath()
        }
        guard let argument = CommandLine.arguments.first, !argument.isEmpty else {
            throw RunnerError.executableUnavailable
        }
        let url = URL(
            fileURLWithPath: argument,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func qualify(_ options: QualifyOptions) async throws {
        guard options.outputURL.lastPathComponent.caseInsensitiveCompare(Self.manifestFilename)
            != .orderedSame,
            options.outputURL.lastPathComponent.caseInsensitiveCompare(Self.caseManifestFilename)
            != .orderedSame
        else {
            throw RunnerError.invalidOption("--out", options.outputURL.path)
        }
        let embeddedVersion = runtime.serverVersion()
        if options.releaseVersion != "unknown",
           Self.normalizedVersion(options.releaseVersion) != Self.normalizedVersion(embeddedVersion)
        {
            throw RunnerError.releaseVersionMismatch(
                expected: embeddedVersion,
                actual: options.releaseVersion
            )
        }
        let waivers = try Self.loadWaivers(from: options.waiversURL, beforeRead: runtime.beforeEvidenceRead)
        let startedAt = runtime.now()
        let sourceExecutableURL = try runtime.executableURL()
        let environment = runtime.environment()
        let commitSHA = try Self.commitSHA(from: environment)
        let signingKey = try Self.signingKey(from: environment)
        var driveEnvironment = environment
        driveEnvironment.removeValue(forKey: Self.signingKeyEnvironmentKey)
        driveEnvironment.removeValue(forKey: Self.trustedPublicKeyEnvironmentKey)
        let executableURL = try Self.snapshotExecutable(sourceExecutableURL)
        defer { try? FileManager.default.removeItem(at: executableURL.deletingLastPathComponent()) }
        let executableData = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        let binarySHA256 = SupportBundleBuilder.sha256(executableData)
        let outputDirectory = options.outputURL.deletingLastPathComponent()
        let evidenceDirectory = outputDirectory.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        let specs = runtime.specs().sorted { $0.id.rawValue < $1.id.rawValue }
        let driveResult: QualificationDriveResult
        do {
            driveResult = try await runtime.drive(QualificationDriveRequest(
                executableURL: executableURL,
                environment: driveEnvironment,
                expectedOperationCount: specs.count,
                operations: specs,
                expectedExecutableSHA256: binarySHA256
            ))
        } catch {
            driveResult = QualificationDriveResult(
                handshake: nil,
                health: nil,
                catalog: nil,
                expectedOperationCount: specs.count,
                traceList: nil,
                negative: nil,
                observedLocale: "unknown",
                failureReason: String(describing: error)
            )
        }
        let registryErrors = runtime.registryValidationErrors()
        let handlerErrors = runtime.handlerValidationErrors()
        guard let observedVariant = LogicVariant(rawValue: driveResult.observedVariant),
              observedVariant == options.variant else {
            throw RunnerError.logicVariantMismatch(
                expected: options.variant.rawValue,
                actual: driveResult.observedVariant
            )
        }
        guard let observedLocale = QualificationLocale(rawValue: driveResult.observedLocale),
              observedLocale == options.locale else {
            throw RunnerError.logicUILocaleMismatch(
                expected: options.locale.rawValue,
                actual: driveResult.observedLocale
            )
        }
        let observedAxis = QualificationAxis(
            variant: observedVariant,
            locale: observedLocale,
            profile: options.profile,
            cache: options.cache,
            fixture: .empty
        )
        var cases: [QualificationCase] = []
        var manifestEntries: [EvidenceManifest.Entry] = []
        var registryEvidencePassed = true
        var handlerEvidencePassed = true
        var requiredOperationsSatisfied = driveResult.operationResults.count == specs.count

        for spec in specs {
            let matchingSpecs = specs.filter {
                $0.id == spec.id
                    && $0.tool == spec.tool
                    && $0.command == spec.command
            }
            let registrySpecFound = matchingSpecs.count == 1 && registryErrors.isEmpty
            let handlerBound = runtime.handlerExists(spec.tool.rawValue, spec.command)
                && handlerErrors.isEmpty
            registryEvidencePassed = registryEvidencePassed && registrySpecFound
            handlerEvidencePassed = handlerEvidencePassed && handlerBound
            let operationResult = driveResult.operationResults[spec.id.rawValue]
            let observedStatus = operationResult?.status ?? .failed
            let caseID = "in-process/\(spec.id.rawValue)"
            let operationWaived = (observedStatus == .notQualified
                || observedStatus == .protocolSmoke)
                && waivers.contains {
                    $0.governsOperation(caseID: caseID, operationID: spec.id.rawValue)
                        && Self.waiverIsUnexpired($0, at: options.releaseVersion)
                }
            let status: QualificationStatus = operationWaived ? .waived : observedStatus
            let verificationKind: QualificationVerificationKind = operationWaived
                ? .typedDeferral
                : operationResult?.verificationKind ?? .typedDeferral
            requiredOperationsSatisfied = requiredOperationsSatisfied
                && (status == .passed || status == .waived)
            let passed = status == .passed
            let traceID = spec.id.rawValue == driveResult.traceDetail?.operationID
                ? driveResult.traceDetail?.traceID ?? ""
                : ""
            let relativePath = "evidence/operation-\(spec.id.rawValue).json"
            let evidence = CaseEvidence(
                schema: "qualification-case-evidence/v3",
                caseID: caseID,
                operationID: spec.id.rawValue,
                tool: spec.tool.rawValue,
                command: spec.command,
                registrySpecFound: registrySpecFound,
                handlerBound: handlerBound,
                traceStarted: !traceID.isEmpty,
                traceCompleted: !traceID.isEmpty && driveResult.traceOK,
                handshakeOK: driveResult.handshakeOK,
                healthOK: driveResult.healthOK,
                catalogCountMatch: driveResult.catalogCountMatch,
                traceOK: driveResult.traceOK,
                negativeFailclosed: driveResult.negativeFailclosed,
                observedVariant: driveResult.observedVariant,
                observedLocale: driveResult.observedLocale,
                negativeState: driveResult.negative?.state,
                negativeWriteAttempted: driveResult.negative?.writeAttempted,
                healthReadStable: driveResult.negative?.healthReadStable ?? false,
                catalogReadStable: driveResult.negative?.catalogReadStable ?? false,
                failureReason: operationResult?.failureReason ?? driveResult.failureReason,
                binarySHA256: binarySHA256,
                axis: observedAxis,
                status: status,
                verified: passed,
                verificationKind: verificationKind,
                deferral: operationResult?.deferral,
                readback: operationResult?.readback,
                operationResponseSHA256: operationResult?.responseSHA256,
                operationRequestID: operationResult?.requestID,
                operationIsError: operationResult?.isError,
                operationState: operationResult?.state,
                operationError: operationResult?.error,
                operationWriteAttempted: operationResult?.writeAttempted
            )
            let evidenceData = try Self.encoded(evidence)
            try evidenceData.write(
                to: outputDirectory.appendingPathComponent(relativePath),
                options: .atomic
            )
            manifestEntries.append(.init(
                path: relativePath,
                sha256: SupportBundleBuilder.sha256(evidenceData),
                caseID: evidence.caseID,
                binarySHA256: binarySHA256,
                axis: observedAxis,
                kind: .caseEvidence
            ))
            var evidenceFiles = [relativePath]
            if let responseData = operationResult?.responseArtifactData {
                let responsePath = "evidence/operation-\(spec.id.rawValue)-response.json"
                try responseData.write(
                    to: outputDirectory.appendingPathComponent(responsePath),
                    options: .atomic
                )
                manifestEntries.append(.init(
                    path: responsePath,
                    sha256: SupportBundleBuilder.sha256(responseData),
                    caseID: evidence.caseID,
                    binarySHA256: binarySHA256,
                    axis: observedAxis,
                    kind: .operationResponse
                ))
                evidenceFiles.append(responsePath)
            }
            if let readbackData = operationResult?.readbackArtifactData {
                let readbackPath = "evidence/operation-\(spec.id.rawValue)-readback.json"
                try readbackData.write(
                    to: outputDirectory.appendingPathComponent(readbackPath),
                    options: .atomic
                )
                manifestEntries.append(.init(
                    path: readbackPath,
                    sha256: SupportBundleBuilder.sha256(readbackData),
                    caseID: evidence.caseID,
                    binarySHA256: binarySHA256,
                    axis: observedAxis,
                    kind: .readbackResponse
                ))
                evidenceFiles.append(readbackPath)
            }
            cases.append(QualificationCase(
                id: evidence.caseID,
                status: status,
                tool: spec.tool.rawValue,
                command: spec.command,
                traceID: traceID,
                verified: passed,
                evidenceFiles: evidenceFiles,
                reason: passed
                    ? nil
                    : operationResult?.deferral?.detail
                        ?? operationResult?.failureReason
                        ?? driveResult.failureReason
                        ?? "operation-specific protocol evidence failed",
                binarySHA256: binarySHA256,
                axis: observedAxis,
                operationID: spec.id.rawValue,
                operationRequestID: operationResult?.requestID,
                verificationKind: verificationKind,
                deferral: operationResult?.deferral,
                readback: operationResult?.readback
            ))
        }

        for axis in QualificationAxis.requiredAxes(
            profile: options.profile,
            cache: options.cache,
            fixture: .empty
        ) {
            let caseID = axis.key
            let isObservedAxis = axis == observedAxis
            let status: QualificationStatus
            let reason: String?
            let availabilityReason = Self.availabilityReason(for: axis, observedAxis: observedAxis)
            let axisWaived = axis != observedAxis
                && waivers.contains {
                    $0.caseID == caseID
                        && $0.governsHostAxisAvailability
                        && Self.waiverIsUnexpired($0, at: options.releaseVersion)
                }
            if let failureReason = driveResult.failureReason {
                status = .failed
                reason = failureReason
            } else if isObservedAxis {
                status = driveResult.allChecksPass && requiredOperationsSatisfied ? .passed : .failed
                reason = status == .passed
                    ? nil
                    : requiredOperationsSatisfied
                        ? "live protocol checks failed"
                        : "one or more operation-specific protocol checks failed"
            } else if axisWaived {
                status = .waived
                reason = "required axis covered by a governed per-axis waiver"
            } else {
                status = .notQualified
                reason = "required axis unavailable: different observed Logic variant or UI locale"
            }
            let passed = status == .passed
            let deferral = status == .notQualified || status == .waived
                ? QualificationDeferral(
                    code: .operationUnavailable,
                    detail: reason ?? "required axis unavailable"
                )
                : nil
            let axisReadbackRequestID = "axis-health-\(axis.key)"
            let axisReadbackData = driveResult.negative.flatMap { negative -> Data? in
                guard let payload = String(data: negative.healthAfter, encoding: .utf8) else {
                    return nil
                }
                return try? Self.encoded(QualificationReadbackArtifact(
                    source: "logic://system/health",
                    requestID: axisReadbackRequestID,
                    payload: payload
                ))
            }
            let axisReadback = axisReadbackData.map {
                QualificationReadbackEvidence(
                    source: "logic://system/health",
                    requestID: axisReadbackRequestID,
                    verified: isObservedAxis && (driveResult.negative?.healthReadStable == true),
                    sha256: SupportBundleBuilder.sha256($0)
                )
            }
            let traceID = driveResult.traceDetail?.traceID ?? ""
            let relativePath = "evidence/axis-\(axis.key.replacingOccurrences(of: "/", with: "-")).json"
            let evidence = CaseEvidence(
                schema: "qualification-case-evidence/v3",
                caseID: caseID,
                operationID: "qualification.\(axis.key)",
                tool: "qualification",
                command: "stdio_jsonrpc_drive",
                registrySpecFound: registryEvidencePassed,
                handlerBound: handlerEvidencePassed,
                traceStarted: driveResult.traceDetail != nil,
                traceCompleted: driveResult.traceOK,
                handshakeOK: driveResult.handshakeOK,
                healthOK: driveResult.healthOK,
                catalogCountMatch: driveResult.catalogCountMatch,
                traceOK: driveResult.traceOK,
                negativeFailclosed: driveResult.negativeFailclosed,
                observedVariant: driveResult.observedVariant,
                observedLocale: driveResult.observedLocale,
                negativeState: driveResult.negative?.state,
                negativeWriteAttempted: driveResult.negative?.writeAttempted,
                healthReadStable: driveResult.negative?.healthReadStable ?? false,
                catalogReadStable: driveResult.negative?.catalogReadStable ?? false,
                failureReason: driveResult.failureReason,
                binarySHA256: binarySHA256,
                axis: axis,
                status: status,
                verified: passed,
                verificationKind: passed ? .independentReadback : .typedDeferral,
                deferral: deferral,
                readback: axisReadback,
                availabilityReason: availabilityReason,
                availabilityObservation: driveResult.availabilityObservation
            )
            let evidenceData = try Self.encoded(evidence)
            try evidenceData.write(
                to: outputDirectory.appendingPathComponent(relativePath),
                options: .atomic
            )
            manifestEntries.append(.init(
                path: relativePath,
                sha256: SupportBundleBuilder.sha256(evidenceData),
                caseID: evidence.caseID,
                binarySHA256: binarySHA256,
                axis: axis,
                kind: .caseEvidence
            ))
            var evidenceFiles = [relativePath]
            if let healthData = axisReadbackData {
                let healthPath = "evidence/axis-\(axis.key.replacingOccurrences(of: "/", with: "-"))-health.json"
                try healthData.write(
                    to: outputDirectory.appendingPathComponent(healthPath),
                    options: .atomic
                )
                manifestEntries.append(.init(
                    path: healthPath,
                    sha256: SupportBundleBuilder.sha256(healthData),
                    caseID: evidence.caseID,
                    binarySHA256: binarySHA256,
                    axis: axis,
                    kind: .readbackResponse
                ))
                evidenceFiles.append(healthPath)
            }
            cases.append(QualificationCase(
                id: caseID,
                status: status,
                tool: evidence.tool,
                command: evidence.command,
                traceID: traceID,
                verified: passed,
                evidenceFiles: evidenceFiles,
                reason: reason,
                binarySHA256: binarySHA256,
                axis: axis,
                operationID: evidence.operationID,
                verificationKind: passed ? .independentReadback : .typedDeferral,
                deferral: deferral,
                readback: axisReadback,
                availabilityReason: availabilityReason,
                availabilityObservation: driveResult.availabilityObservation
            ))
        }

        if let externalCasesURL = options.externalCasesURL {
            let externalManifest: QualificationCaseManifest
            do {
                externalManifest = try JSONDecoder().decode(
                    QualificationCaseManifest.self,
                    from: Self.readNoFollow(
                        relativePath: externalCasesURL.lastPathComponent,
                        directory: externalCasesURL.deletingLastPathComponent(),
                        beforeRead: runtime.beforeEvidenceRead
                    )
                )
            } catch {
                throw RunnerError.evidenceBindingMismatch("invalid external case manifest")
            }
            guard externalManifest.schema == "qualification-case-manifest/v1",
                  externalManifest.binarySHA256 == binarySHA256 else {
                throw RunnerError.evidenceBindingMismatch("case manifest binary or schema")
            }
            let externalCases = externalManifest.cases
            let externalCaseIDs = externalCases.map(\.id)
            guard Set(externalCaseIDs).count == externalCaseIDs.count,
                  Set(externalCaseIDs).isDisjoint(with: Set(cases.map(\.id))) else {
                throw RunnerError.evidenceBindingMismatch("duplicate or colliding case id")
            }
            let internalEvidencePaths = Set(manifestEntries.map(\.path))
            let externalEvidencePaths = externalCases.flatMap(\.evidenceFiles)
            guard Set(externalEvidencePaths).count == externalEvidencePaths.count,
                  Set(externalEvidencePaths).isDisjoint(with: internalEvidencePaths) else {
                throw RunnerError.evidenceBindingMismatch("duplicate or colliding evidence path")
            }
            for externalCase in externalCases {
                guard externalCase.binarySHA256 == binarySHA256,
                      let relativePath = externalCase.evidenceFiles.first else {
                    throw RunnerError.evidenceBindingMismatch("case binary or evidence path")
                }
                let evidenceData = try Self.validatedEvidenceData(
                    relativePath: relativePath,
                    outputDirectory: outputDirectory
                )
                let externalEvidence: CaseEvidence
                do {
                    externalEvidence = try JSONDecoder().decode(CaseEvidence.self, from: evidenceData)
                } catch {
                    throw RunnerError.evidenceBindingMismatch("invalid evidence for \(externalCase.id)")
                }
                guard Self.evidence(externalEvidence, binds: externalCase),
                      Self.evidenceShapeIsValid(externalEvidence) else {
                    throw RunnerError.evidenceBindingMismatch("case/evidence mismatch for \(externalCase.id)")
                }
                manifestEntries.append(.init(
                    path: relativePath,
                    sha256: SupportBundleBuilder.sha256(evidenceData),
                    caseID: externalCase.id,
                    binarySHA256: binarySHA256,
                    axis: externalCase.axis,
                    kind: .caseEvidence
                ))
                var artifactIndex = 1
                if let responseSHA256 = externalEvidence.operationResponseSHA256 {
                    guard externalCase.evidenceFiles.indices.contains(artifactIndex) else {
                        throw RunnerError.evidenceBindingMismatch(
                            "missing operation response for \(externalCase.id)"
                        )
                    }
                    let path = externalCase.evidenceFiles[artifactIndex]
                    let data = try Self.validatedEvidenceData(
                        relativePath: path,
                        outputDirectory: outputDirectory
                    )
                    guard SupportBundleBuilder.sha256(data) == responseSHA256,
                          let artifact = try? JSONDecoder().decode(
                              QualificationOperationResponseArtifact.self,
                              from: data
                          ),
                          Self.operationArtifact(artifact, binds: externalEvidence) else {
                        throw RunnerError.evidenceBindingMismatch(
                            "operation response digest for \(externalCase.id)"
                        )
                    }
                    manifestEntries.append(.init(
                        path: path,
                        sha256: responseSHA256,
                        caseID: externalCase.id,
                        binarySHA256: binarySHA256,
                        axis: externalCase.axis,
                        kind: .operationResponse
                    ))
                    artifactIndex += 1
                }
                if let readbackSHA256 = externalEvidence.readback?.sha256 {
                    guard externalCase.evidenceFiles.indices.contains(artifactIndex) else {
                        throw RunnerError.evidenceBindingMismatch(
                            "missing readback response for \(externalCase.id)"
                        )
                    }
                    let path = externalCase.evidenceFiles[artifactIndex]
                    let data = try Self.validatedEvidenceData(
                        relativePath: path,
                        outputDirectory: outputDirectory
                    )
                    guard SupportBundleBuilder.sha256(data) == readbackSHA256,
                          let artifact = try? JSONDecoder().decode(
                              QualificationReadbackArtifact.self,
                              from: data
                          ),
                          artifact.source == externalEvidence.readback?.source,
                          artifact.requestID == externalEvidence.readback?.requestID,
                          Self.availabilityArtifactMatches(
                              artifact,
                              observation: externalEvidence.availabilityObservation
                          ) else {
                        throw RunnerError.evidenceBindingMismatch(
                            "readback response digest for \(externalCase.id)"
                        )
                    }
                    manifestEntries.append(.init(
                        path: path,
                        sha256: readbackSHA256,
                        caseID: externalCase.id,
                        binarySHA256: binarySHA256,
                        axis: externalCase.axis,
                        kind: .readbackResponse
                    ))
                    artifactIndex += 1
                }
                guard artifactIndex == externalCase.evidenceFiles.count else {
                    throw RunnerError.evidenceBindingMismatch(
                        "unexpected evidence artifact for \(externalCase.id)"
                    )
                }
            }
            cases.append(contentsOf: externalCases)
        }

        let caseManifest = QualificationCaseManifest(
            schema: "qualification-case-manifest/v1",
            binarySHA256: binarySHA256,
            cases: cases
        )
        let caseManifestData = try Self.encoded(caseManifest)
        try caseManifestData.write(
            to: outputDirectory.appendingPathComponent(Self.caseManifestFilename),
            options: .atomic
        )
        manifestEntries.sort { $0.path < $1.path }
        let manifest = EvidenceManifest(
            schema: "qualification-evidence-manifest/v3",
            binarySHA256: binarySHA256,
            caseManifestPath: Self.caseManifestFilename,
            caseManifestSHA256: SupportBundleBuilder.sha256(caseManifestData),
            waiversSHA256: SupportBundleBuilder.sha256(try Self.encoded(waivers)),
            files: manifestEntries
        )
        let manifestData = try Self.encoded(manifest)
        try manifestData.write(
            to: outputDirectory.appendingPathComponent(Self.manifestFilename),
            options: .atomic
        )
        let completedAt = runtime.now()
        let manifestSHA256 = SupportBundleBuilder.sha256(manifestData)
        let provenance = QualificationProvenanceRecord(
            schema: "qualification-provenance/v1",
            binarySHA256: binarySHA256,
            commitSHA: commitSHA,
            releaseVersion: options.releaseVersion,
            axis: observedAxis,
            runID: UUID().uuidString.lowercased(),
            startedAt: startedAt,
            completedAt: completedAt,
            evidenceManifestSHA256: manifestSHA256
        )
        let provenanceSignature = try Self.sign(provenance, with: signingKey)
        let attestation = ReleaseQualificationAttestation(
            schema: "release-qualification-attestation/v2",
            serverVersion: options.releaseVersion,
            commitSHA: commitSHA,
            binarySHA256: binarySHA256,
            logicVariant: observedVariant,
            logicVersion: driveResult.logicProVersion,
            locale: observedLocale,
            profile: options.profile,
            cache: options.cache,
            fixture: .empty,
            startedAt: startedAt,
            completedAt: completedAt,
            total: cases.count,
            passed: cases.filter { $0.status == .passed }.count,
            failed: cases.filter { $0.status == .failed }.count,
            waived: cases.filter { $0.status == .waived }.count,
            cases: cases,
            waivers: waivers,
            evidenceManifestSHA256: manifestSHA256,
            provenance: provenance,
            provenanceSignature: provenanceSignature
        )
        try Self.encoded(attestation).write(
            to: options.outputURL,
            options: .atomic
        )
    }

    private func parseQualifyOptions(_ arguments: [String]) throws -> QualifyOptions {
        let values = try Self.optionValues(arguments, allowed: [
            "--out", "--cases", "--waivers", "--release-version", "--variant", "--locale", "--profile", "--cache",
        ])
        guard let output = values["--out"] else { throw RunnerError.missingOption("--out") }
        let environment = runtime.environment()
        let variant = try Self.parseVariant(values["--variant"] ?? "desktop")
        let locale = try Self.parseLocale(values["--locale"] ?? "en")
        let profile = try Self.parseEnum(SetupProfile.self, values["--profile"] ?? "core", option: "--profile")
        let cache = try Self.parseEnum(CacheState.self, values["--cache"] ?? "cold", option: "--cache")
        return QualifyOptions(
            outputURL: URL(fileURLWithPath: output),
            externalCasesURL: values["--cases"].map(URL.init(fileURLWithPath:)),
            waiversURL: values["--waivers"].map(URL.init(fileURLWithPath:)),
            releaseVersion: values["--release-version"] ?? environment["RELEASE_VERSION"] ?? "unknown",
            variant: variant,
            locale: locale,
            profile: profile,
            cache: cache
        )
    }

    private func verify(_ options: VerifyOptions) throws -> QualificationCommandResult {
        let directory = options.attestationURL.deletingLastPathComponent()
        let attestationData = try Self.readNoFollow(
            relativePath: options.attestationURL.lastPathComponent,
            directory: directory,
            beforeRead: runtime.beforeEvidenceRead
        )
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: attestationData
        )
        let manifestArtifact = Self.manifestFilename
        let requiredArtifacts = options.requiredArtifacts.union([manifestArtifact])
        let presentArtifacts = Set(requiredArtifacts.filter { artifact in
            let url = artifact.hasPrefix("/")
                ? URL(fileURLWithPath: artifact)
                : directory.appendingPathComponent(artifact)
            return Self.isReadableRegularFile(url)
        })
        let evidenceBindingIssue = Self.evidenceBindingIssue(
            attestation: attestation,
            directory: directory,
            beforeRead: runtime.beforeEvidenceRead
        )
        let decision = PromotionGate().evaluate(
            attestation: attestation,
            releaseVersion: options.releaseVersion,
            expectedBinarySHA256: options.expectedBinarySHA256,
            presentArtifacts: presentArtifacts,
            requiredArtifacts: requiredArtifacts,
            requiredOperationIDs: Set(runtime.specs().map { $0.id.rawValue })
        )
        let currentExecutableData = try Data(
            contentsOf: runtime.executableURL(),
            options: .mappedIfSafe
        )
        let currentExecutableSHA256 = SupportBundleBuilder.sha256(currentExecutableData)
        var rejections = decision.rejections
        if let evidenceBindingIssue {
            rejections.append(.evidenceBindingMismatch(detail: evidenceBindingIssue))
        }
        if let provenanceRejection = Self.provenanceRejection(
            attestation: attestation,
            environment: runtime.environment()
        ) {
            rejections.append(provenanceRejection)
        }
        if currentExecutableSHA256 != options.expectedBinarySHA256 {
            let replacementRejection = PromotionRejectionReason.binarySHAMismatch(
                expected: options.expectedBinarySHA256,
                actual: currentExecutableSHA256
            )
            if !rejections.contains(replacementRejection) {
                rejections.append(replacementRejection)
            }
        }
        let output = VerificationOutput(
            promotable: rejections.isEmpty,
            rejections: rejections.map(Self.output)
        )
        guard let json = String(data: try Self.encoded(output), encoding: .utf8) else {
            throw RunnerError.invalidArguments("Unable to encode promotion decision")
        }
        return QualificationCommandResult(
            exitCode: rejections.isEmpty ? 0 : 1,
            stdout: json + "\n",
            stderr: ""
        )
    }

    private func parseVerifyOptions(_ arguments: [String]) throws -> VerifyOptions {
        let values = try Self.optionValues(arguments, allowed: [
            "--attestation", "--release-version", "--expected-binary-sha256", "--required-artifacts",
        ])
        guard let attestation = values["--attestation"] else {
            throw RunnerError.missingOption("--attestation")
        }
        guard let releaseVersion = values["--release-version"] else {
            throw RunnerError.missingOption("--release-version")
        }
        guard let expectedBinarySHA256 = values["--expected-binary-sha256"] else {
            throw RunnerError.missingOption("--expected-binary-sha256")
        }
        let requiredArtifacts = Set(
            (values["--required-artifacts"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return VerifyOptions(
            attestationURL: URL(fileURLWithPath: attestation),
            releaseVersion: releaseVersion,
            expectedBinarySHA256: expectedBinarySHA256,
            requiredArtifacts: requiredArtifacts
        )
    }

    private static func output(_ reason: PromotionRejectionReason) -> VerificationOutput.Rejection {
        switch reason {
        case .requiredCaseFailed(let caseID):
            VerificationOutput.Rejection(
                reason: "requiredCaseFailed", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .requiredCombinationNotQualified(let key):
            VerificationOutput.Rejection(
                reason: "requiredCombinationNotQualified", caseID: nil, key: key,
                name: nil, expected: nil, actual: nil
            )
        case .missingArtifact(let name):
            VerificationOutput.Rejection(
                reason: "missingArtifact", caseID: nil, key: nil,
                name: name, expected: nil, actual: nil
            )
        case .binarySHAMismatch(let expected, let actual):
            VerificationOutput.Rejection(
                reason: "binarySHAMismatch", caseID: nil, key: nil,
                name: nil, expected: expected, actual: actual
            )
        case .expiredWaiver(let caseID):
            VerificationOutput.Rejection(
                reason: "expiredWaiver", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .waiverForUnknownCase(let caseID):
            VerificationOutput.Rejection(
                reason: "waiverForUnknownCase", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .waiverForPassingCase(let caseID):
            VerificationOutput.Rejection(
                reason: "waiverForPassingCase", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .waiverForNonWaivedCase(let caseID, let status):
            VerificationOutput.Rejection(
                reason: "waiverForNonWaivedCase", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: status.rawValue
            )
        case .waivedCaseMissingWaiver(let caseID):
            VerificationOutput.Rejection(
                reason: "waivedCaseMissingWaiver", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .invalidWaiver(let caseID, let field):
            VerificationOutput.Rejection(
                reason: "invalidWaiver", caseID: caseID, key: field,
                name: nil, expected: nil, actual: nil
            )
        case .duplicateWaiver(let caseID):
            VerificationOutput.Rejection(
                reason: "duplicateWaiver", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .duplicateCaseID(let caseID):
            VerificationOutput.Rejection(
                reason: "duplicateCaseID", caseID: caseID, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .releaseVersionMismatch(let expected, let actual):
            VerificationOutput.Rejection(
                reason: "releaseVersionMismatch", caseID: nil, key: nil,
                name: nil, expected: expected, actual: actual
            )
        case .evidenceBindingMismatch(let detail):
            VerificationOutput.Rejection(
                reason: "evidenceBindingMismatch", caseID: nil, key: nil,
                name: nil, expected: nil, actual: detail
            )
        case .requiredOperationNotSatisfied(let operationID):
            VerificationOutput.Rejection(
                reason: "requiredOperationNotSatisfied", caseID: nil, key: operationID,
                name: nil, expected: nil, actual: nil
            )
        case .provenanceSignatureMissing:
            VerificationOutput.Rejection(
                reason: "provenanceSignatureMissing", caseID: nil, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .provenanceSignatureInvalid:
            VerificationOutput.Rejection(
                reason: "provenanceSignatureInvalid", caseID: nil, key: nil,
                name: nil, expected: nil, actual: nil
            )
        case .trustedProvenanceKeyUnavailable:
            VerificationOutput.Rejection(
                reason: "trustedProvenanceKeyUnavailable", caseID: nil, key: nil,
                name: nil, expected: nil, actual: nil
            )
        }
    }

    private static func optionValues(
        _ arguments: [String],
        allowed: Set<String>
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else { throw RunnerError.invalidArguments("Unknown option: \(option)") }
            guard arguments.indices.contains(index + 1) else { throw RunnerError.missingOption(option) }
            guard values[option] == nil else { throw RunnerError.invalidArguments("Duplicate option: \(option)") }
            values[option] = arguments[index + 1]
            index += 2
        }
        return values
    }

    private static func parseVariant(_ value: String) throws -> LogicVariant {
        switch value {
        case "desktop": .desktop
        case "creator": .creatorStudio
        default: throw RunnerError.invalidOption("--variant", value)
        }
    }

    private static func parseLocale(_ value: String) throws -> QualificationLocale {
        switch value {
        case "en": .enUS
        case "ko": .koKR
        default: throw RunnerError.invalidOption("--locale", value)
        }
    }

    private static func parseEnum<T: RawRepresentable>(
        _ type: T.Type,
        _ value: String,
        option: String
    ) throws -> T where T.RawValue == String {
        guard let parsed = T(rawValue: value) else { throw RunnerError.invalidOption(option, value) }
        return parsed
    }

    private static let manifestFilename = "evidence-manifest.json"
    private static let caseManifestFilename = "case-manifest.json"
    private static let signingKeyEnvironmentKey =
        "LOGIC_PRO_MCP_QUALIFICATION_SIGNING_KEY"
    private static let trustedPublicKeyEnvironmentKey =
        "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY"

    private static func loadWaivers(
        from url: URL?,
        beforeRead: @Sendable (URL) -> Void
    ) throws -> [QualificationWaiver] {
        guard let url else { return [] }
        let waivers = try JSONDecoder().decode(
            [QualificationWaiver].self,
            from: readNoFollow(
                relativePath: url.lastPathComponent,
                directory: url.deletingLastPathComponent(),
                beforeRead: beforeRead
            )
        )
        if let issue = QualificationWaiverValidator.issues(in: waivers).first {
            switch issue {
            case .invalidField(let caseID, let field):
                throw RunnerError.malformedWaiver(caseID: caseID, field: field)
            case .duplicateCaseID(let caseID):
                throw RunnerError.duplicateWaiver(caseID: caseID)
            }
        }
        return waivers
    }

    private static func normalizedVersion(_ version: String) -> Substring {
        version.first == "v" || version.first == "V" ? version.dropFirst() : version[...]
    }

    private static func waiverIsUnexpired(
        _ waiver: QualificationWaiver,
        at releaseVersion: String
    ) -> Bool {
        guard let expiry = SemanticVersion(waiver.expiryVersion),
              let release = SemanticVersion(releaseVersion) else {
            return false
        }
        return expiry > release
    }

    private static func availabilityReason(
        for axis: QualificationAxis,
        observedAxis: QualificationAxis
    ) -> QualificationAvailabilityReason? {
        let variantDiffers = axis.variant != observedAxis.variant
        let localeDiffers = axis.locale != observedAxis.locale
        switch (variantDiffers, localeDiffers) {
        case (true, true): return .differentLogicVariantAndUILocale
        case (true, false): return .differentLogicVariant
        case (false, true): return .differentLogicUILocale
        case (false, false): return nil
        }
    }

    private static func validatedEvidenceData(
        relativePath: String,
        outputDirectory: URL,
        beforeRead: @Sendable (URL) -> Void = { _ in }
    ) throws -> Data {
        guard safeEvidenceURL(
            relativePath: relativePath,
            outputDirectory: outputDirectory
        ) != nil else {
            throw RunnerError.invalidArguments("Invalid or unreadable evidence file: \(relativePath)")
        }
        return try readNoFollow(
            relativePath: relativePath,
            directory: outputDirectory,
            beforeRead: beforeRead
        )
    }

    private static func evidenceBindingIssue(
        attestation: ReleaseQualificationAttestation,
        directory: URL,
        beforeRead: @Sendable (URL) -> Void
    ) -> String? {
        guard let manifestData = try? readNoFollow(
            relativePath: manifestFilename,
            directory: directory,
            beforeRead: beforeRead
        ) else {
            return "evidence manifest digest, schema, or binary"
        }
        guard SupportBundleBuilder.sha256(manifestData) == attestation.evidenceManifestSHA256,
              let manifest = try? JSONDecoder().decode(EvidenceManifest.self, from: manifestData),
              manifest.schema == "qualification-evidence-manifest/v3",
              manifest.binarySHA256 == attestation.binarySHA256,
              manifest.caseManifestPath == caseManifestFilename,
              manifest.waiversSHA256 == SupportBundleBuilder.sha256(
                  (try? encoded(attestation.waivers)) ?? Data()
              )
        else {
            return "evidence manifest digest, schema, or binary"
        }

        guard let caseManifestData = try? readNoFollow(
                  relativePath: caseManifestFilename,
                  directory: directory,
                  beforeRead: beforeRead
              ),
              SupportBundleBuilder.sha256(caseManifestData) == manifest.caseManifestSHA256,
              let caseManifest = try? JSONDecoder().decode(
                  QualificationCaseManifest.self,
                  from: caseManifestData
              ),
              caseManifest.schema == "qualification-case-manifest/v1",
              caseManifest.binarySHA256 == attestation.binarySHA256,
              caseManifest.cases == attestation.cases else {
            return "case manifest digest or attestation binding"
        }

        let casesByID = Dictionary(grouping: attestation.cases, by: \.id)
        guard casesByID.values.allSatisfy({ $0.count == 1 }),
              attestation.cases.allSatisfy({
                  $0.binarySHA256 == attestation.binarySHA256
                      && !$0.evidenceFiles.isEmpty
                      && Set($0.evidenceFiles).count == $0.evidenceFiles.count
              }) else {
            return "duplicate case id, binary, or evidence cardinality"
        }
        let expectedPaths = Set(attestation.cases.flatMap(\.evidenceFiles))
        let manifestPaths = manifest.files.map(\.path)
        guard Set(manifestPaths).count == manifestPaths.count,
              Set(manifestPaths) == expectedPaths
        else {
            return "evidence path set"
        }

        for entry in manifest.files {
            guard let qualificationCase = casesByID[entry.caseID]?.first,
                  qualificationCase.evidenceFiles.contains(entry.path),
                  entry.binarySHA256 == attestation.binarySHA256,
                  entry.axis == qualificationCase.axis else {
                return "manifest entry case, binary, or axis"
            }
            guard let evidenceData = try? validatedEvidenceData(
                relativePath: entry.path,
                outputDirectory: directory,
                beforeRead: beforeRead
            ), SupportBundleBuilder.sha256(evidenceData) == entry.sha256 else {
                return "evidence digest"
            }
        }

        let entriesByCaseID = Dictionary(grouping: manifest.files, by: \.caseID)
        for qualificationCase in attestation.cases {
            guard let entries = entriesByCaseID[qualificationCase.id],
                  Set(entries.map(\.path)) == Set(qualificationCase.evidenceFiles),
                  let evidenceEntry = entries.first(where: { $0.kind == .caseEvidence }),
                  entries.filter({ $0.kind == .caseEvidence }).count == 1,
                  let evidenceData = try? validatedEvidenceData(
                      relativePath: evidenceEntry.path,
                      outputDirectory: directory,
                      beforeRead: beforeRead
                  ),
                  SupportBundleBuilder.sha256(evidenceData) == evidenceEntry.sha256,
                  let evidence = try? JSONDecoder().decode(CaseEvidence.self, from: evidenceData),
                  Self.evidence(evidence, binds: qualificationCase),
                  Self.evidenceShapeIsValid(evidence) else {
                return "case evidence binding"
            }
            let responseEntries = entries.filter { $0.kind == .operationResponse }
            var responseArtifact: QualificationOperationResponseArtifact?
            if let expectedSHA256 = evidence.operationResponseSHA256 {
                guard responseEntries.count == 1,
                      responseEntries[0].sha256 == expectedSHA256,
                      let data = try? validatedEvidenceData(
                          relativePath: responseEntries[0].path,
                          outputDirectory: directory,
                          beforeRead: beforeRead
                      ),
                      SupportBundleBuilder.sha256(data) == responseEntries[0].sha256,
                      let artifact = try? JSONDecoder().decode(
                          QualificationOperationResponseArtifact.self,
                          from: data
                      ),
                      Self.operationArtifact(artifact, binds: evidence) else {
                    return "operation response binding"
                }
                responseArtifact = artifact
            } else if !responseEntries.isEmpty {
                return "unexpected operation response"
            }
            let readbackEntries = entries.filter { $0.kind == .readbackResponse }
            var readbackArtifact: QualificationReadbackArtifact?
            if let readback = evidence.readback {
                guard readbackEntries.count == 1,
                      readbackEntries[0].sha256 == readback.sha256,
                      let data = try? validatedEvidenceData(
                          relativePath: readbackEntries[0].path,
                          outputDirectory: directory,
                          beforeRead: beforeRead
                      ),
                      SupportBundleBuilder.sha256(data) == readbackEntries[0].sha256,
                      let artifact = try? JSONDecoder().decode(
                          QualificationReadbackArtifact.self,
                          from: data
                      ),
                      artifact.source == readback.source,
                      artifact.requestID == readback.requestID,
                      Self.availabilityArtifactMatches(
                          artifact,
                              observation: evidence.availabilityObservation
                          ) else {
                    return "readback response binding"
                }
                readbackArtifact = artifact
            } else if !readbackEntries.isEmpty {
                return "unexpected readback response"
            }
            if evidence.verificationKind == .semanticReadback {
                guard let responseData = responseArtifact?.payload.data(using: .utf8),
                      let readbackData = readbackArtifact?.payload.data(using: .utf8),
                      QualificationSemanticReadbackValidator.validate(
                          operationID: evidence.operationID,
                          responseData: responseData,
                          readbackData: readbackData
                      ) == true else {
                    return "semantic readback binding"
                }
            }
        }
        return nil
    }

    private static func evidence(
        _ evidence: CaseEvidence,
        binds qualificationCase: QualificationCase
    ) -> Bool {
        evidence.schema == "qualification-case-evidence/v3"
            && evidence.caseID == qualificationCase.id
            && evidence.operationID == qualificationCase.operationID
            && evidence.operationRequestID == qualificationCase.operationRequestID
            && evidence.tool == qualificationCase.tool
            && evidence.command == qualificationCase.command
            && evidence.binarySHA256 == qualificationCase.binarySHA256
            && evidence.axis == qualificationCase.axis
            && evidence.status == qualificationCase.status
            && evidence.verified == qualificationCase.verified
            && evidence.verificationKind == qualificationCase.verificationKind
            && evidence.deferral == qualificationCase.deferral
            && evidence.readback == qualificationCase.readback
            && evidence.availabilityReason == qualificationCase.availabilityReason
            && evidence.availabilityObservation == qualificationCase.availabilityObservation
    }

    private static func operationArtifact(
        _ artifact: QualificationOperationResponseArtifact,
        binds evidence: CaseEvidence
    ) -> Bool {
        guard artifact.operationID == evidence.operationID,
              artifact.tool == evidence.tool,
              artifact.command == evidence.command,
              artifact.requestID == evidence.operationRequestID,
              artifact.isError == evidence.operationIsError,
              let payloadData = artifact.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return false
        }
        if evidence.verificationKind == .semanticReadback {
            return true
        }
        return object["state"] as? String == evidence.operationState
            && object["error"] as? String == evidence.operationError
            && object["write_attempted"] as? Bool == evidence.operationWriteAttempted
    }

    private static func evidenceShapeIsValid(_ evidence: CaseEvidence) -> Bool {
        switch evidence.verificationKind {
        case .readResponse:
            return evidence.status == .passed
                && evidence.verified
                && evidence.operationResponseSHA256 != nil
                && evidence.operationRequestID != nil
                && evidence.operationIsError == false
                && evidence.readback != nil
                && evidence.availabilityObservation == nil
        case .semanticReadback:
            return evidence.status == .passed
                && evidence.verified
                && !evidence.operationID.hasPrefix("qualification.")
                && evidence.operationResponseSHA256 != nil
                && evidence.operationRequestID != nil
                && evidence.operationIsError == false
                && evidence.readback?.verified == true
                && evidence.availabilityObservation == nil
        case .protocolSmoke:
            return evidence.status == .protocolSmoke
                && !evidence.verified
                && evidence.operationResponseSHA256 != nil
                && evidence.operationRequestID != nil
                && evidence.operationIsError == false
                && evidence.deferral?.code == .semanticValidatorUnavailable
                && evidence.readback?.verified == false
                && evidence.availabilityObservation == nil
        case .independentReadback:
            return evidence.status == .passed
                && evidence.verified
                && evidence.operationID.hasPrefix("qualification.")
                && evidence.operationResponseSHA256 == nil
                && evidence.operationRequestID == nil
                && evidence.readback != nil
                && evidence.availabilityObservation != nil
        case .typedDeferral:
            if evidence.status == .failed {
                return !evidence.verified
            }
            guard evidence.status == .notQualified || evidence.status == .waived,
                  !evidence.verified,
                  evidence.deferral != nil,
                  evidence.readback != nil else {
                return false
            }
            if evidence.operationID.hasPrefix("qualification.") {
                return evidence.operationResponseSHA256 == nil
                    && evidence.operationRequestID == nil
                    && evidence.availabilityReason != nil
                    && evidence.availabilityObservation != nil
            }
            guard evidence.operationResponseSHA256 != nil,
                  evidence.operationRequestID != nil,
                  evidence.availabilityObservation == nil else {
                return false
            }
            switch evidence.deferral?.code {
            case .some(.liveMutationNotRun), .some(.operationUnavailable):
                return evidence.operationIsError == true
            case .some(.semanticMismatch), .some(.semanticValidatorUnavailable):
                return evidence.operationIsError == false
                    && evidence.readback?.verified == false
            case .none:
                return false
            }
        }
    }

    private static func availabilityArtifact(
        _ artifact: QualificationReadbackArtifact,
        binds observation: QualificationAvailabilityObservation
    ) -> Bool {
        guard let data = artifact.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["logic_pro_running"] as? Bool == true,
              object["process_metadata_resolved"] as? Bool == true,
              object["logic_pro_bundle_id"] as? String == observation.activeBundleID,
              object["logic_pro_ui_locale"] as? String == observation.logicUILocale.rawValue,
              let rawVariant = object["logic_pro_variant"] as? String,
              Self.qualificationVariant(rawVariant) == observation.activeVariant,
              let rawVariants = object["logic_pro_variants"] as? [[String: Any]] else {
            return false
        }
        let variants = rawVariants.compactMap { value -> QualificationVariantAvailability? in
            guard let rawVariant = value["variant"] as? String,
                  let variant = Self.qualificationVariant(rawVariant),
                  let bundleID = value["bundle_id"] as? String,
                  let installed = value["installed"] as? Bool,
                  let running = value["running"] as? Bool else {
                return nil
            }
            return QualificationVariantAvailability(
                variant: variant,
                bundleID: bundleID,
                installed: installed,
                running: running
            )
        }
        return variants.count == rawVariants.count && variants == observation.variants
    }

    private static func availabilityArtifactMatches(
        _ artifact: QualificationReadbackArtifact,
        observation: QualificationAvailabilityObservation?
    ) -> Bool {
        guard let observation else { return true }
        return availabilityArtifact(artifact, binds: observation)
    }

    private static func qualificationVariant(_ rawValue: String) -> LogicVariant? {
        switch rawValue {
        case LogicProVariant.desktop.rawValue: .desktop
        case LogicProVariant.creatorStudio.rawValue: .creatorStudio
        default: nil
        }
    }

    private static func safeEvidenceURL(
        relativePath: String,
        outputDirectory: URL
    ) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              relativePath.caseInsensitiveCompare(manifestFilename) != .orderedSame,
              relativePath.caseInsensitiveCompare(caseManifestFilename) != .orderedSame
        else {
            return nil
        }
        let directory = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(directory.path + "/"),
              candidate.path == resolved.path
        else {
            return nil
        }
        return candidate
    }

    private static func isReadableRegularFile(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              let isRegularFile = values.isRegularFile,
              let isSymbolicLink = values.isSymbolicLink
        else {
            return false
        }
        return isRegularFile && !isSymbolicLink
    }

    private static func readNoFollow(
        relativePath: String,
        directory: URL,
        beforeRead: @Sendable (URL) -> Void,
        maxBytes: Int64 = 16 * 1024 * 1024
    ) throws -> Data {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RunnerError.invalidArguments("Invalid evidence path")
        }

        let rootFD = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootFD >= 0 else {
            throw RunnerError.invalidArguments("Unable to open evidence directory")
        }
        defer { close(rootFD) }

        var directoryFD = rootFD
        defer {
            if directoryFD != rootFD {
                close(directoryFD)
            }
        }
        for component in components.dropLast() {
            let nextFD = openat(
                directoryFD,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard nextFD >= 0 else {
                throw RunnerError.invalidArguments("Unable to open evidence directory component")
            }
            if directoryFD != rootFD {
                close(directoryFD)
            }
            directoryFD = nextFD
        }

        guard let filename = components.last else {
            throw RunnerError.invalidArguments("Invalid evidence path")
        }
        let fileFD = openat(
            directoryFD,
            filename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard fileFD >= 0 else {
            throw RunnerError.invalidArguments("Unable to open evidence file")
        }
        defer { close(fileFD) }

        var opened = stat()
        guard fstat(fileFD, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1,
              opened.st_size >= 0,
              opened.st_size <= maxBytes else {
            throw RunnerError.invalidArguments("Evidence path is not a regular file")
        }
        beforeRead(directory.appendingPathComponent(relativePath))
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: false)
        var data = Data()
        while true {
            let remaining = maxBytes - Int64(data.count)
            guard remaining > 0 else {
                let overflow = try handle.read(upToCount: 1) ?? Data()
                guard overflow.isEmpty else {
                    throw RunnerError.invalidArguments("Evidence file exceeds size limit")
                }
                break
            }
            let chunk = try handle.read(upToCount: min(64 * 1024, Int(remaining))) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }

        var afterRead = stat()
        var current = stat()
        guard fstat(fileFD, &afterRead) == 0,
              afterRead.st_mode & S_IFMT == S_IFREG,
              afterRead.st_nlink == 1,
              afterRead.st_dev == opened.st_dev,
              afterRead.st_ino == opened.st_ino,
              afterRead.st_size == data.count,
              afterRead.st_size <= maxBytes,
              fstatat(directoryFD, filename, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == opened.st_dev,
              current.st_ino == opened.st_ino,
              current.st_nlink == 1,
              current.st_size == afterRead.st_size else {
            throw RunnerError.invalidArguments("Evidence path changed during read")
        }
        return data
    }

    private static func snapshotExecutable(_ sourceURL: URL) throws -> URL {
        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let sourceData = try readNoFollow(
            relativePath: sourceURL.lastPathComponent,
            directory: sourceDirectory,
            beforeRead: { _ in },
            maxBytes: 256 * 1024 * 1024
        )
        let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "qualification-executable-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let snapshotURL = snapshotDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            try sourceData.write(to: snapshotURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: snapshotURL.path
            )
            return snapshotURL
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }
    }

    private static func signingKey(
        from environment: [String: String]
    ) throws -> Curve25519.Signing.PrivateKey {
        guard let encodedKey = environment[signingKeyEnvironmentKey] else {
            throw RunnerError.signingKeyUnavailable
        }
        guard let rawKey = Data(base64Encoded: encodedKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) else {
            throw RunnerError.invalidSigningKey
        }
        return key
    }

    private static func commitSHA(from environment: [String: String]) throws -> String {
        guard let commitSHA = environment["GIT_COMMIT"],
              commitSHA.count == 40 || commitSHA.count == 64,
              commitSHA.allSatisfy(\.isHexDigit) else {
            throw RunnerError.commitIdentityUnavailable
        }
        return commitSHA
    }

    private static func sign(
        _ provenance: QualificationProvenanceRecord,
        with key: Curve25519.Signing.PrivateKey
    ) throws -> QualificationProvenanceSignature {
        QualificationProvenanceSignature(
            algorithm: "ed25519",
            keyID: SupportBundleBuilder.sha256(key.publicKey.rawRepresentation),
            value: try key.signature(for: encoded(provenance)).base64EncodedString()
        )
    }

    private static func provenanceRejection(
        attestation: ReleaseQualificationAttestation,
        environment: [String: String]
    ) -> PromotionRejectionReason? {
        guard let provenance = attestation.provenance,
              let signature = attestation.provenanceSignature else {
            return .provenanceSignatureMissing
        }
        guard let encodedKey = environment[trustedPublicKeyEnvironmentKey],
              let rawKey = Data(base64Encoded: encodedKey),
              let trustedKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            return .trustedProvenanceKeyUnavailable
        }
        let axis = QualificationAxis(
            variant: attestation.logicVariant,
            locale: attestation.locale,
            profile: attestation.profile,
            cache: attestation.cache,
            fixture: attestation.fixture
        )
        guard provenance.schema == "qualification-provenance/v1",
              provenance.binarySHA256 == attestation.binarySHA256,
              provenance.commitSHA == attestation.commitSHA,
              provenance.releaseVersion == attestation.serverVersion,
              provenance.axis == axis,
              UUID(uuidString: provenance.runID) != nil,
              provenance.startedAt == attestation.startedAt,
              provenance.completedAt == attestation.completedAt,
              provenance.completedAt >= provenance.startedAt,
              provenance.evidenceManifestSHA256 == attestation.evidenceManifestSHA256,
              signature.algorithm == "ed25519",
              signature.keyID == SupportBundleBuilder.sha256(rawKey),
              let signatureData = Data(base64Encoded: signature.value),
              let provenanceData = try? encoded(provenance),
              trustedKey.isValidSignature(signatureData, for: provenanceData) else {
            return .provenanceSignatureInvalid
        }
        return nil
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func failure(_ detail: String) -> QualificationCommandResult {
        QualificationCommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "Qualification failed: \(detail)\n"
        )
    }
}
