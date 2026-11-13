import Foundation
import CryptoKit
import Darwin

package struct QualificationCommandResult: Sendable {
    package let exitCode: Int
    package let stdout: String
    package let stderr: String
}

/// Direct live-qualification runner for the candidate executable.
package struct QualificationRunner: Sendable {
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
        /// Baseline/live pairs for the ADR-007 diff. Empty in a build that cannot capture, which an
        /// ARMED run treats as a refusal rather than as agreement — see `AtlasQualification`.
        let atlasPairs: @Sendable () -> (pairs: [AtlasQualification.Pair], dropped: [String])

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
            },
            atlasPairs: { AtlasCapture.pairsForThisRun() }
        )
    }

    private struct QualifyOptions {
        let outputURL: URL
        /// Whether the run may drive Logic's write recipes against the operator's open project.
        /// Absent, every mutating spec is withheld and reported as `live_mutation_not_run`.
        let mutateOpenProject: Bool
        /// This run must retain the selected atlas comparison; the optional runtime flag
        /// cannot disarm it.
        let requireAtlas: Bool
        let externalCasesURL: URL?
        let waiversURL: URL?
        let releaseVersion: String
        let variant: LogicVariant
        let locale: QualificationLocale
        let profile: SetupProfile
        let cache: CacheState
    }

    private struct EvidenceManifest: Codable {
        enum Kind: String, Codable {
            case caseEvidence = "case_evidence"
            case operationResponse = "operation_response"
            case readbackResponse = "readback_response"
            case rawTranscript = "raw_transcript"
            case publicTranscript = "public_transcript"
            case mutationRestoreCompensation = "mutation_restore_compensation"
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
        let operationCatalogPath: String
        let operationCatalogSHA256: String
        let waiversSHA256: String
        let files: [Entry]

        enum CodingKeys: String, CodingKey {
            case schema
            case binarySHA256 = "binary_sha256"
            case caseManifestPath = "case_manifest_path"
            case caseManifestSHA256 = "case_manifest_sha256"
            case operationCatalogPath = "operation_catalog_path"
            case operationCatalogSHA256 = "operation_catalog_sha256"
            case waiversSHA256 = "waivers_sha256"
            case files
        }
    }

    // #394: despite the "raw" name (kept to avoid rippling the schema/contract
    // checks), this transcript is ID-NORMALIZED wire — session-random target /
    // trace IDs are replaced with stable `<prefix>_<NORM:N>` placeholders for
    // cross-run comparison. It is NOT forensic, byte-unmodified stdio.
    private struct RawTranscriptArtifact: Codable {
        let schema: String
        let frames: [QualificationWireFrame]
    }

    private struct PublicTranscriptArtifact: Codable {
        struct Frame: Codable {
            let sequence: Int
            let direction: QualificationWireFrame.Direction
            let operationID: String
            let payloadSHA256: String

            enum CodingKeys: String, CodingKey {
                case sequence
                case direction
                case operationID = "operation_id"
                case payloadSHA256 = "payload_sha256"
            }
        }

        let schema: String
        let frames: [Frame]
    }

    private struct MutationRestoreCompensationArtifact: Codable {
        let schema: String
        let records: [QualificationMutationRestoreRecord]
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
                // A run that did not qualify exits non-zero. It used to write a `.failed`
                // attestation and return 0, so a caller that keyed on the exit code -- which is
                // every shell, every CI step -- read a failed qualification as a passing one.
                let attestation = try await qualify(options)
                // `failed == 0`, not `passed == total`. A DEFERRAL is a declared gap, not a
                // failure, and most operations defer today -- exiting non-zero for those would
                // make a zero exit impossible and the code meaningless. A FAILED case is a case
                // that ran and did not hold, and that is what a caller needs to see.
                return QualificationCommandResult(
                    exitCode: attestation.failed == 0 ? 0 : 1,
                    stdout: "",
                    stderr: attestation.failed == 0 ? "" :
                        "qualification: \(attestation.failed) of \(attestation.total) case(s) failed\n"
                )
            default:
                throw RunnerError.invalidArguments("Expected --qualify")
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

    private func qualify(_ options: QualifyOptions) async throws -> ReleaseQualificationAttestation {
        guard options.outputURL.lastPathComponent.caseInsensitiveCompare(Self.manifestFilename)
            != .orderedSame,
            options.outputURL.lastPathComponent.caseInsensitiveCompare(Self.caseManifestFilename)
            != .orderedSame,
            options.outputURL.lastPathComponent.caseInsensitiveCompare(Self.operationCatalogFilename)
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
        let driveEnvironment = environment
        let executableURL = try Self.snapshotExecutable(sourceExecutableURL)
        defer { try? FileManager.default.removeItem(at: executableURL.deletingLastPathComponent()) }
        let executableData = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        let binarySHA256 = SupportBundleBuilder.sha256(executableData)
        let outputDirectory = options.outputURL.deletingLastPathComponent()
        let evidenceDirectory = outputDirectory.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        let allSpecs = runtime.specs().sorted { $0.id.rawValue < $1.id.rawValue }
        // `--qualify` WRITES TO WHATEVER PROJECT IS OPEN unless it is told not to. The Phase-B and
        // Phase-C recipes rename track 0, create and delete markers, set the tempo and move
        // faders; this branch's own records document a track leaked into an operator's project
        // twice. That was never in `--help` and had no opt-in, so a shipped flag mutated a user's
        // work on the strength of its name.
        //
        // The gate is HERE, on the spec list, and not on each of the twelve recipe sites: a recipe
        // that is never handed its spec cannot run, which is provable by reading one line. Gating
        // each site is provable only by finding all of them, and the branch's own history says one
        // was written, compiled and silently never fired.
        let specs = options.mutateOpenProject
            ? allSpecs
            : allSpecs.filter { $0.mutability != .mutating }
        let driveResult = try await runtime.drive(QualificationDriveRequest(
            executableURL: executableURL,
            environment: driveEnvironment,
            // The REGISTRY's count, not the drive's. It is compared against the server's
            // whole catalog (`catalogCountMatch`), so narrowing it to the specs this run
            // happens to drive would make withholding the mutating half look like the
            // server had lost half its operations.
            expectedOperationCount: allSpecs.count,
            operations: specs,
            expectedExecutableSHA256: binarySHA256
        ))
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

        // The full list, deliberately. Only the DRIVE is filtered: a withheld mutating operation
        // must still get a CASE, so it lands on the existing `live_mutation_not_run` deferral
        // instead of vanishing. A missing case would shrink coverage silently, and
        // `requiredOperationIDs` is derived from the whole registry, so it would surface later as
        // a missing operation rather than as the withheld one it is.
        for spec in allSpecs {
            // `allSpecs`, not the driven list. This asks "is this operation IN THE REGISTRY,
            // exactly once" -- a question about the registry, which withholding the mutating half
            // does not change. Searching the driven list made every withheld operation report
            // `registry_spec_found: false`, which reads as a broken registry rather than as an
            // operation this run chose not to drive.
            let matchingSpecs = allSpecs.filter {
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
            let withheld = operationResult == nil && spec.mutability == .mutating && !options.mutateOpenProject
            let observedStatus = withheld ? QualificationStatus.notQualified : operationResult?.status ?? .failed
            let operationDeferral = operationResult?.deferral ?? (withheld ? QualificationDeferral(
                code: .liveMutationNotRun,
                detail: "live mutation was not run: --mutate-open-project was not supplied") : nil)
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
                deferral: operationDeferral,
                readback: operationResult?.readback,
                operationResponseSHA256: operationResult?.responseSHA256,
                operationRequestID: operationResult?.requestID,
                operationIsError: operationResult?.isError,
                operationState: operationResult?.state,
                operationError: operationResult?.error,
                operationWriteAttempted: operationResult?.writeAttempted,
                // Binds the case to the cycle it rests on. Without it
                // `mutation-restore-compensation.json` was a file shipped BESIDE the evidence:
                // checked for internal consistency and never compared to any case, so a passing
                // mutating case with no record at all -- or a record naming an operation no case
                // mentions -- went through.
                //
                // Read from `restore`, the value the case carries, so the two cannot name
                // different records: `evidence(_:binds:)` compares them.
                mutationRestoreRecordSHA256: operationResult?.restore?.recordSHA256
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
                    : operationDeferral?.detail
                        ?? operationResult?.failureReason
                        ?? driveResult.failureReason
                        ?? "operation-specific protocol evidence failed",
                binarySHA256: binarySHA256,
                axis: observedAxis,
                operationID: spec.id.rawValue,
                operationRequestID: operationResult?.requestID,
                verificationKind: verificationKind,
                deferral: operationDeferral,
                readback: operationResult?.readback,
                restore: operationResult?.restore
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
                    verified: isObservedAxis && passed,
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
            if isObservedAxis {
                // #394: rewrite session-random target refs (trk_/mix_/ins_/prj_)
                // and trace ids (lpmcp_) to appearance-order placeholders so the
                // transcript is CROSS-RUN ID-STABLE (the ID dimension only —
                // timestamp / live-DAW-state noise is not touched by this pass).
                // Emit-only: the semantic oracle still validates the raw,
                // un-normalized operation response/readback bytes (see
                // QualificationOperationResult), so target-faithfulness is intact.
                let normalizedFrames = QualificationTranscriptNormalizer.normalize(
                    driveResult.wireFrames
                )
                let requiredArtifacts: [(String, Data, EvidenceManifest.Kind)] = [
                    (
                        Self.rawTranscriptFilename,
                        try Self.encoded(RawTranscriptArtifact(
                            schema: "qualification-raw-transcript/v1",
                            frames: normalizedFrames
                        )),
                        .rawTranscript
                    ),
                    (
                        Self.publicTranscriptFilename,
                        try Self.encoded(PublicTranscriptArtifact(
                            schema: "qualification-public-transcript/v1",
                            frames: normalizedFrames.map { frame in
                                .init(
                                    sequence: frame.sequence,
                                    direction: frame.direction,
                                    operationID: frame.operationID,
                                    payloadSHA256: SupportBundleBuilder.sha256(
                                        Data(frame.payload.utf8)
                                    )
                                )
                            }
                        )),
                        .publicTranscript
                    ),
                    (
                        Self.mutationRestoreCompensationFilename,
                        try Self.encoded(MutationRestoreCompensationArtifact(
                            schema: "qualification-mutation-restore-compensation/v1",
                            records: driveResult.mutationRestoreRecords
                        )),
                        .mutationRestoreCompensation
                    ),
                ]
                for (path, data, kind) in requiredArtifacts {
                    try data.write(to: outputDirectory.appendingPathComponent(path), options: .atomic)
                    manifestEntries.append(.init(
                        path: path,
                        sha256: SupportBundleBuilder.sha256(data),
                        caseID: evidence.caseID,
                        binarySHA256: binarySHA256,
                        axis: axis,
                        kind: kind
                    ))
                    evidenceFiles.append(path)
                }
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
                if let comparison = externalEvidence.atlasComparison,
                   comparison.pairs.contains(where: { $0.current.logicVersion != driveResult.logicProVersion }) {
                    throw RunnerError.evidenceBindingMismatch("atlas current Logic version binding")
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

        // ADR-007: the atlas diff, as one more case rather than a new attestation field.
        //
        // `runtime.atlasPairs` is injected so this decision is testable without Logic — and so the
        // capture side, which needs a running application, cannot make the DECISION untestable.
        // Off unless `adr007SelectorAtlas` is set: only `ko` has a control-bar baseline today, and
        // arming it everywhere would refuse every run on a Logic speaking anything else.
        // The flag decides before anything is CAPTURED, not only before a case is emitted. Passing
        // `runtime.atlasPairs()` as an argument evaluated it eagerly, so a run with the flag off
        // still walked the AX tree — work nobody asked for, and a claim in the PR ("the flag is the
        // only thing arming it") that the code did not keep. Named by review, 2026-08-29.
        let atlasArmed = options.requireAtlas || FeatureFlags.adr007SelectorAtlas
        let atlasCaptured = atlasArmed ? runtime.atlasPairs() : (pairs: [], dropped: [])
        if atlasArmed,
           atlasCaptured.pairs.contains(where: { $0.current.logicVersion != driveResult.logicProVersion }) {
            throw RunnerError.evidenceBindingMismatch("atlas current Logic version binding")
        }
        if let atlas = AtlasQualification.evidenceCaseFor(
            armed: atlasArmed,
            pairs: atlasCaptured.pairs,
            dropped: atlasCaptured.dropped,
            axis: observedAxis,
            binarySHA256: binarySHA256,
            traceID: "atlas-drift-diff"
        ) {
            let atlasCase = atlas.qualificationCase
            // AFTER the external-manifest collision check at the top of this function, so this id
            // has to be checked here or not at all. An external manifest declaring
            // `atlas.drift_diff` would otherwise produce two cases with one id, and every consumer
            // that keys by id — a waiver or a reader counting a failure — would
            // see whichever it reached first. Found by review before merge, 2026-08-29.
            guard !cases.contains(where: { $0.id == atlasCase.id }) else {
                throw RunnerError.evidenceBindingMismatch(
                    "case id \(atlasCase.id) is already present; the ADR-007 step cannot add a "
                        + "second case under the same id")
            }
            let evidenceData = try Self.encoded(atlas.evidence)
            let evidencePath = atlasCase.evidenceFiles[0]
            // Reserve this path consistently on case-sensitive and case-insensitive volumes.
            guard !manifestEntries.contains(where: {
                $0.path.caseInsensitiveCompare(evidencePath) == .orderedSame
            }) else {
                throw RunnerError.evidenceBindingMismatch(
                    "evidence path \(evidencePath) is already present; the ADR-007 step cannot overwrite it")
            }
            try evidenceData.write(to: outputDirectory.appendingPathComponent(evidencePath), options: .atomic)
            manifestEntries.append(.init(path: evidencePath,
                sha256: SupportBundleBuilder.sha256(evidenceData), caseID: atlasCase.id,
                binarySHA256: binarySHA256, axis: observedAxis, kind: .caseEvidence))
            cases.append(atlasCase)
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
        let operationCatalogEntries = allSpecs
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map(Self.operationCatalogEntry)
        let operationCatalog = QualificationOperationCatalog(
            schema: "qualification-operation-catalog/v2",
            binarySHA256: binarySHA256,
            semanticPolicySHA256: try Self.operationCatalogPolicyDigest(
                operationCatalogEntries
            ),
            operations: operationCatalogEntries
        )
        let operationCatalogData = try Self.encoded(operationCatalog)
        try operationCatalogData.write(
            to: outputDirectory.appendingPathComponent(Self.operationCatalogFilename),
            options: .atomic
        )
        let operationCatalogSHA256 = SupportBundleBuilder.sha256(operationCatalogData)
        manifestEntries.sort { $0.path < $1.path }
        let manifest = EvidenceManifest(
            schema: "qualification-evidence-manifest/v4",
            binarySHA256: binarySHA256,
            caseManifestPath: Self.caseManifestFilename,
            caseManifestSHA256: SupportBundleBuilder.sha256(caseManifestData),
            operationCatalogPath: Self.operationCatalogFilename,
            operationCatalogSHA256: operationCatalogSHA256,
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
            schema: "qualification-provenance/v3",
            binarySHA256: binarySHA256,
            commitSHA: commitSHA,
            releaseVersion: options.releaseVersion,
            axis: observedAxis,
            runID: UUID().uuidString.lowercased(),
            startedAt: startedAt,
            completedAt: completedAt,
            evidenceManifestSHA256: manifestSHA256,
            operationCatalogSHA256: operationCatalogSHA256,
            logicVersion: driveResult.logicProVersion
        )
        let counts = QualificationSummaryCounts(cases: cases)
        let attestation = ReleaseQualificationAttestation(
            schema: "release-qualification-attestation/v3",
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
            total: counts.total,
            passed: counts.passed,
            failed: counts.failed,
            waived: counts.waived,
            cases: cases,
            waivers: waivers,
            evidenceManifestSHA256: manifestSHA256,
            operationCatalogSHA256: operationCatalogSHA256,
            provenance: provenance
        )
        try Self.encoded(attestation).write(
            to: options.outputURL,
            options: .atomic
        )
        return attestation
    }

    private func parseQualifyOptions(_ arguments: [String]) throws -> QualifyOptions {
        let values = try Self.optionValues(arguments, allowed: [
            "--out", "--cases", "--waivers", "--release-version", "--variant", "--locale", "--profile", "--cache",
            "--mutate-open-project",
            "--require-atlas",
        ], valueless: ["--mutate-open-project", "--require-atlas"])
        guard let output = values["--out"] else { throw RunnerError.missingOption("--out") }
        let environment = runtime.environment()
        let variant = try Self.parseVariant(values["--variant"] ?? "desktop")
        let locale = try Self.parseLocale(values["--locale"] ?? "en")
        let profile = try Self.parseEnum(SetupProfile.self, values["--profile"] ?? "core", option: "--profile")
        let cache = try Self.parseEnum(CacheState.self, values["--cache"] ?? "cold", option: "--cache")
        return QualifyOptions(
            outputURL: URL(fileURLWithPath: output),
            // Present at all -- with or without a value -- is consent. Absent, the mutating
            // specs never reach the drive.
            mutateOpenProject: values["--mutate-open-project"] != nil,
            requireAtlas: values["--require-atlas"] != nil,
            externalCasesURL: values["--cases"].map(URL.init(fileURLWithPath:)),
            waiversURL: values["--waivers"].map(URL.init(fileURLWithPath:)),
            releaseVersion: values["--release-version"] ?? environment["RELEASE_VERSION"] ?? "unknown",
            variant: variant,
            locale: locale,
            profile: profile,
            cache: cache
        )
    }

    /// Every option here takes a value unless it is named in `valueless`. A bare flag is not a
    /// special case of a valued one: read as a pair it swallows the NEXT option as its value, and
    /// the run then fails somewhere else entirely -- which is what `--mutate-open-project` did
    /// before this parameter existed, throwing before the attestation was written.
    private static func optionValues(
        _ arguments: [String],
        allowed: Set<String>,
        valueless: Set<String> = []
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else { throw RunnerError.invalidArguments("Unknown option: \(option)") }
            guard values[option] == nil else { throw RunnerError.invalidArguments("Duplicate option: \(option)") }
            if valueless.contains(option) {
                values[option] = ""
                index += 1
                continue
            }
            guard arguments.indices.contains(index + 1) else { throw RunnerError.missingOption(option) }
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
    private static let operationCatalogFilename = "operation-catalog.json"
    private static let rawTranscriptFilename = "raw-transcript.json"
    private static let publicTranscriptFilename = "public-transcript.json"
    private static let mutationRestoreCompensationFilename =
        "mutation-restore-compensation.json"

    private static func operationCatalogEntry(
        _ spec: OperationSpec
    ) -> QualificationOperationCatalog.Entry {
        let disposition: QualificationOperationCatalog.OracleDisposition
        let semanticPolicy: QualificationSemanticPolicy
        if spec.id == .systemHealth {
            disposition = .bespokeHealth
            semanticPolicy = QualificationSemanticPolicy(
                kind: .bespokeHealth,
                strength: nil,
                constraints: [],
                independentlyCreditable: true
            )
        } else if let oracle = SemanticOracleTable.byOperationID[spec.id] {
            disposition = .semanticOracle
            semanticPolicy = QualificationSemanticPolicy(
                kind: oracle.strength == .custom ? .localCustom : .declarative,
                strength: oracle.strength,
                constraints: oracle.constraints,
                independentlyCreditable:
                    QualificationSemanticReadbackValidator.canUseIndependentReadback(for: spec.id)
            )
        } else {
            disposition = .noSemanticOracle
            semanticPolicy = QualificationSemanticPolicy(
                kind: .none,
                strength: nil,
                constraints: [],
                independentlyCreditable: false
            )
        }
        return QualificationOperationCatalog.Entry(
            operationID: spec.id.rawValue,
            caseID: "in-process/\(spec.id.rawValue)",
            oracleDisposition: disposition,
            semanticPolicy: semanticPolicy,
            mutationRestorePolicy: QualificationTransport.mutationRestorePolicy(for: spec.id)
        )
    }

    static func operationCatalogPolicyDigest(
        _ entries: [QualificationOperationCatalog.Entry]
    ) throws -> String {
        SupportBundleBuilder.sha256(try encoded(entries))
    }

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

    static func evidence(
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
            // #984: the case's restore names the record the evidence binds. Without this the
            // attestation's `restore` -- which the credit rule reads -- was bound to nothing.
            && evidence.mutationRestoreRecordSHA256 == qualificationCase.restore?.recordSHA256
            && evidence.availabilityReason == qualificationCase.availabilityReason
            && evidence.availabilityObservation == qualificationCase.availabilityObservation
            && (evidence.verificationKind != .atlasComparison
                || evidence.failureReason == qualificationCase.reason)
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
              let payloadData = artifact.payload.data(using: .utf8)
        else {
            return false
        }
        if evidence.verificationKind == .semanticReadback {
            return true
        }
        let payload = try? JSONSerialization.jsonObject(
            with: payloadData,
            options: [.fragmentsAllowed]
        )
        guard let object = payload as? [String: Any] else {
            return evidence.operationState == nil
                && evidence.operationError == nil
                && evidence.operationWriteAttempted != true
        }
        return object["state"] as? String == evidence.operationState
            && object["error"] as? String == evidence.operationError
            && object["write_attempted"] as? Bool == evidence.operationWriteAttempted
    }

    /// The retained evidence shape rule, exposed so a test can ask it directly.
    ///
    /// `internal`, not `private`, and the reason is the defect this seam exists for: the runner
    /// produced evidence that its own reader rejected, and nothing compared the two directly.
    static func evidenceShapeIsValid(_ evidence: CaseEvidence) -> Bool {
        if evidence.verificationKind != .atlasComparison, evidence.atlasComparison != nil { return false }
        switch evidence.verificationKind {
        case .atlasComparison:
            return AtlasQualification.comparisonBinds(evidence)
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
        case .verifiedWriteCycle:
            // The mirror image of `.semanticReadback`, and every difference is load-bearing. The
            // probe must have been REFUSED fail-closed -- `isError == true`, State C, a typed
            // refusal, and no write attempted -- because a probe that wrote cannot vouch for the
            // cycle recorded beside it. `QualificationTransport` already refuses to promote
            // without that refusal; this rechecks the retained evidence bytes independently of
            // the producer branch that wrote them.
            return evidence.status == .passed
                && evidence.verified
                && !evidence.operationID.hasPrefix("qualification.")
                && evidence.operationResponseSHA256 != nil
                && evidence.operationRequestID != nil
                && evidence.operationIsError == true
                && evidence.operationState == "C"
                && evidence.operationWriteAttempted == false
                && ["consent_required", "invalid_params"].contains(evidence.operationError ?? "")
                && evidence.readback?.verified == true
                && evidence.mutationRestoreRecordSHA256 != nil
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
            // An axis passes on the observations the runner passed it on (`allChecksPass`), read
            // from this file, not on its own `status` and `verified`. The negative probe's
            // conjuncts are `QualificationNegativeResult.isFailClosedAndStable`'s, less the two it
            // does not record (`toolIsError`, `error`); `healthReadStable` stays out, as there,
            // because health warms during cache polling and MCU registration.
            return evidence.status == .passed
                && evidence.verified
                && evidence.operationID.hasPrefix("qualification.")
                && evidence.operationResponseSHA256 == nil
                && evidence.operationRequestID == nil
                && evidence.readback != nil
                && evidence.availabilityObservation != nil
                && evidence.handshakeOK
                && evidence.healthOK
                && evidence.catalogCountMatch
                && evidence.traceOK
                && evidence.negativeFailclosed
                && evidence.negativeState == "C"
                && evidence.negativeWriteAttempted == false
                && evidence.catalogReadStable
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
            // `deliberateZeroWriteProbe` sits with these two because it is the same OBSERVATION --
            // the operation returned a typed refusal. What differs is why the probe asked in a way
            // that would be refused, and that distinction is in the code, not in the evidence.
            case .some(.liveMutationNotRun), .some(.operationUnavailable),
                 .some(.deliberateZeroWriteProbe), .some(.notExposedInProductionContract):
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
              relativePath.caseInsensitiveCompare(caseManifestFilename) != .orderedSame,
              relativePath.caseInsensitiveCompare(operationCatalogFilename) != .orderedSame
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
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
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
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
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
        // O_NONBLOCK on every open: a blocking O_RDONLY open of a FIFO waits for a writer, so a
        // bundle or candidate planted as a FIFO hung the verifier before the fstat below could reject
        // it (#373 Q4). It changes nothing for the regular file that fstat then insists on.
        let fileFD = openat(
            directoryFD,
            filename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
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

    private static func commitSHA(from environment: [String: String]) throws -> String {
        guard let commitSHA = environment["GIT_COMMIT"],
              isCommitSHA(commitSHA) else {
            throw RunnerError.commitIdentityUnavailable
        }
        return commitSHA
    }

    private static func isCommitSHA(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }


    /// SHA-256 of a mutation-restore record's canonical encoding, so a case and a record can be
    /// compared without either one re-serialising the other's bytes by hand.
    static func recordDigest(_ record: QualificationMutationRestoreRecord) throws -> String {
        let data = try encoded(record)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
