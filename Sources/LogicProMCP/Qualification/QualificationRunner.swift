import Foundation

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
        struct Entry: Codable {
            let path: String
            let sha256: String
        }

        let schema: String
        let files: [Entry]
    }

    private enum RunnerError: Error, CustomStringConvertible {
        case invalidArguments(String)
        case missingOption(String)
        case invalidOption(String, String)
        case malformedWaiver(caseID: String, field: String)
        case duplicateWaiver(caseID: String)
        case releaseVersionMismatch(expected: String, actual: String)
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
        let waivers = try Self.loadWaivers(from: options.waiversURL)
        let startedAt = runtime.now()
        let executableURL = try runtime.executableURL()
        let environment = runtime.environment()
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
                environment: environment,
                expectedOperationCount: specs.count
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
        let traceStore = OperationTraceStore(
            maximumTraceCount: max(OperationTraceStore.defaultMaximumTraceCount, specs.count + 4),
            maximumBytes: OperationTraceStore.defaultMaximumBytes
        )
        var cases: [QualificationCase] = []
        var manifestEntries: [EvidenceManifest.Entry] = []
        var registryEvidencePassed = true
        var handlerEvidencePassed = true

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
            let traceID = await traceStore.start(operationID: spec.id.rawValue)
            let traceStarted = await traceStore.trace(traceID) != nil
            await traceStore.complete(traceID)
            let traceCompleted = await traceStore.trace(traceID)?.completedAt != nil
            let passed = driveResult.allChecksPass
            let relativePath = "evidence/operation-\(spec.id.rawValue).json"
            let evidence = CaseEvidence(
                schema: "qualification-case-evidence/v2",
                caseID: "in-process/\(spec.id.rawValue)",
                operationID: spec.id.rawValue,
                tool: spec.tool.rawValue,
                command: spec.command,
                registrySpecFound: registrySpecFound,
                handlerBound: handlerBound,
                traceStarted: traceStarted,
                traceCompleted: traceCompleted,
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
                failureReason: driveResult.failureReason
            )
            let evidenceData = try Self.encoded(evidence)
            try evidenceData.write(
                to: outputDirectory.appendingPathComponent(relativePath),
                options: .atomic
            )
            manifestEntries.append(.init(
                path: relativePath,
                sha256: SupportBundleBuilder.sha256(evidenceData)
            ))
            cases.append(QualificationCase(
                id: evidence.caseID,
                status: passed ? .passed : .failed,
                tool: spec.tool.rawValue,
                command: spec.command,
                traceID: traceID.rawValue,
                verified: passed,
                evidenceFiles: [relativePath],
                reason: passed
                    ? nil
                    : driveResult.failureReason ?? "live protocol checks failed"
            ))
        }

        let waiversByCaseID = Dictionary(uniqueKeysWithValues: waivers.map { ($0.caseID, $0) })
        for axis in QualificationAxis.requiredCombinations {
            let axisKey = "\(axis.variant.rawValue)/\(axis.locale.rawValue)/\(options.profile.rawValue)/\(options.cache.rawValue)"
            let caseID = "\(axisKey)/empty"
            let isObservedAxis = axis.variant.rawValue == driveResult.observedVariant
                && axis.locale.rawValue == driveResult.observedLocale
            let status: QualificationStatus
            let reason: String?
            if let failureReason = driveResult.failureReason {
                status = .failed
                reason = failureReason
            } else if isObservedAxis {
                status = driveResult.allChecksPass ? .passed : .failed
                reason = driveResult.allChecksPass ? nil : "live protocol checks failed"
            } else if waiversByCaseID[caseID]?.governsHostAxisAvailability == true {
                status = .waived
                reason = "required axis unavailable on this qualification host; governed by ADR-001-a waiver"
            } else {
                status = .skipped
                reason = "required axis unavailable on this qualification host"
            }
            let passed = status == .passed
            let traceID = await traceStore.start(operationID: "qualification.\(axisKey)")
            let traceStarted = await traceStore.trace(traceID) != nil
            await traceStore.complete(traceID)
            let traceCompleted = await traceStore.trace(traceID)?.completedAt != nil
            let relativePath = "evidence/axis-\(axisKey.replacingOccurrences(of: "/", with: "-")).json"
            let evidence = CaseEvidence(
                schema: "qualification-case-evidence/v2",
                caseID: caseID,
                operationID: "qualification.\(axisKey)",
                tool: "qualification",
                command: "stdio_jsonrpc_drive",
                registrySpecFound: registryEvidencePassed,
                handlerBound: handlerEvidencePassed,
                traceStarted: traceStarted,
                traceCompleted: traceCompleted,
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
                failureReason: driveResult.failureReason
            )
            let evidenceData = try Self.encoded(evidence)
            try evidenceData.write(
                to: outputDirectory.appendingPathComponent(relativePath),
                options: .atomic
            )
            manifestEntries.append(.init(
                path: relativePath,
                sha256: SupportBundleBuilder.sha256(evidenceData)
            ))
            cases.append(QualificationCase(
                id: caseID,
                status: status,
                tool: evidence.tool,
                command: evidence.command,
                traceID: traceID.rawValue,
                verified: passed,
                evidenceFiles: [relativePath],
                reason: reason
            ))
        }

        if let externalCasesURL = options.externalCasesURL {
            let externalCases = try JSONDecoder().decode(
                [QualificationCase].self,
                from: Data(contentsOf: externalCasesURL)
            )
            let internalEvidencePaths = Set(manifestEntries.map(\.path))
            let externalEvidencePaths = Set(externalCases.flatMap(\.evidenceFiles))
                .subtracting(internalEvidencePaths)
            for relativePath in externalEvidencePaths.sorted() {
                let evidenceData = try Self.validatedEvidenceData(
                    relativePath: relativePath,
                    outputDirectory: outputDirectory
                )
                manifestEntries.append(.init(
                    path: relativePath,
                    sha256: SupportBundleBuilder.sha256(evidenceData)
                ))
            }
            cases.append(contentsOf: externalCases)
        }

        manifestEntries.sort { $0.path < $1.path }
        let manifest = EvidenceManifest(
            schema: "qualification-evidence-manifest/v1",
            files: manifestEntries
        )
        let manifestData = try Self.encoded(manifest)
        try manifestData.write(
            to: outputDirectory.appendingPathComponent(Self.manifestFilename),
            options: .atomic
        )
        let attestedVariant = LogicVariant(rawValue: driveResult.observedVariant) ?? options.variant
        let attestedLocale = QualificationLocale(rawValue: driveResult.observedLocale) ?? options.locale

        let attestation = ReleaseQualificationAttestation(
            schema: "release-qualification-attestation/v1",
            serverVersion: options.releaseVersion,
            commitSHA: environment["GIT_COMMIT"] ?? "unknown",
            binarySHA256: binarySHA256,
            logicVariant: attestedVariant,
            logicVersion: driveResult.logicProVersion,
            locale: attestedLocale,
            profile: options.profile,
            startedAt: startedAt,
            completedAt: runtime.now(),
            total: cases.count,
            passed: cases.filter { $0.status == .passed }.count,
            failed: cases.filter { $0.status == .failed }.count,
            waived: cases.filter { $0.status == .waived }.count,
            cases: cases,
            waivers: waivers,
            evidenceManifestSHA256: SupportBundleBuilder.sha256(manifestData)
        )
        try Self.attestationData(attestation, cache: options.cache).write(
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
        let attestation = try JSONDecoder().decode(
            ReleaseQualificationAttestation.self,
            from: Data(contentsOf: options.attestationURL)
        )
        let directory = options.attestationURL.deletingLastPathComponent()
        let manifestArtifact = Self.manifestFilename
        let requiredArtifacts = options.requiredArtifacts.union([manifestArtifact])
        var presentArtifacts = Set(requiredArtifacts.filter { artifact in
            let url = artifact.hasPrefix("/")
                ? URL(fileURLWithPath: artifact)
                : directory.appendingPathComponent(artifact)
            return Self.isReadableRegularFile(url)
        })
        if !Self.evidenceIsIntact(attestation: attestation, directory: directory) {
            presentArtifacts.remove(manifestArtifact)
        }
        let decision = PromotionGate().evaluate(
            attestation: attestation,
            releaseVersion: options.releaseVersion,
            expectedBinarySHA256: options.expectedBinarySHA256,
            presentArtifacts: presentArtifacts,
            requiredArtifacts: requiredArtifacts
        )
        let currentExecutableData = try Data(
            contentsOf: runtime.executableURL(),
            options: .mappedIfSafe
        )
        let currentExecutableSHA256 = SupportBundleBuilder.sha256(currentExecutableData)
        var rejections = decision.rejections
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

    private static func loadWaivers(from url: URL?) throws -> [QualificationWaiver] {
        guard let url else { return [] }
        let waivers = try JSONDecoder().decode(
            [QualificationWaiver].self,
            from: Data(contentsOf: url)
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

    private static func validatedEvidenceData(
        relativePath: String,
        outputDirectory: URL
    ) throws -> Data {
        guard let url = safeEvidenceURL(relativePath: relativePath, outputDirectory: outputDirectory),
              isReadableRegularFile(url)
        else {
            throw RunnerError.invalidArguments("Invalid or unreadable evidence file: \(relativePath)")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func evidenceIsIntact(
        attestation: ReleaseQualificationAttestation,
        directory: URL
    ) -> Bool {
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        guard isReadableRegularFile(manifestURL),
              let manifestData = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
              SupportBundleBuilder.sha256(manifestData) == attestation.evidenceManifestSHA256,
              let manifest = try? JSONDecoder().decode(EvidenceManifest.self, from: manifestData),
              manifest.schema == "qualification-evidence-manifest/v1"
        else {
            return false
        }

        let expectedPaths = Set(attestation.cases.flatMap(\.evidenceFiles))
        let manifestPaths = manifest.files.map(\.path)
        guard Set(manifestPaths).count == manifestPaths.count,
              Set(manifestPaths) == expectedPaths
        else {
            return false
        }

        for entry in manifest.files {
            guard let evidenceData = try? validatedEvidenceData(
                relativePath: entry.path,
                outputDirectory: directory
            ), SupportBundleBuilder.sha256(evidenceData) == entry.sha256 else {
                return false
            }
        }
        return true
    }

    private static func safeEvidenceURL(
        relativePath: String,
        outputDirectory: URL
    ) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              relativePath.caseInsensitiveCompare(manifestFilename) != .orderedSame
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

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func attestationData(
        _ attestation: ReleaseQualificationAttestation,
        cache: CacheState
    ) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: encoded(attestation)) as? [String: Any] ?? [:]
        object["cache"] = cache.rawValue
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func failure(_ detail: String) -> QualificationCommandResult {
        QualificationCommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "Qualification failed: \(detail)\n"
        )
    }
}
