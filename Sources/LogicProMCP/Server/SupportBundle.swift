import CryptoKit
import Darwin
import Foundation

struct SupportBundleBuilder: Sendable {
    private static let blockingQueue = DispatchQueue(
        label: "logic-pro-mcp.support-bundle.blocking",
        qos: .utility,
        attributes: .concurrent
    )
    static let jsonFileNames = [
        "doctor.json",
        "manifest.json",
        "metadata.json",
        "redaction_report.json",
        "traces.json",
    ]
    static let fileNames = jsonFileNames + ["SHA256SUMS"]

    struct LogicMetadata: Codable, Sendable {
        let version: String
        let variant: String
        let locale: String
    }

    struct ProcessMetadata: Codable, Sendable {
        let uptimeSec: Int
        let memoryMb: Double

        enum CodingKeys: String, CodingKey {
            case uptimeSec = "uptime_sec"
            case memoryMb = "memory_mb"
        }
    }

    struct ChannelMetadata: Codable, Sendable {
        let id: String
        let available: Bool
        let ready: Bool
        let verificationStatus: String

        enum CodingKeys: String, CodingKey {
            case id
            case available
            case ready
            case verificationStatus = "verification_status"
        }
    }

    struct Metadata: Codable, Sendable {
        let process: ProcessMetadata
        let channels: [ChannelMetadata]
    }

    struct Input: Sendable {
        let createdAt: Date
        let serverVersion: String
        let serverCommit: String
        let logic: LogicMetadata
        let qualificationReference: String
        let traces: [OperationTrace]
        let doctorReport: SetupDoctor.Report
        let metadata: Metadata
    }

    struct FileDigest: Codable, Sendable, Equatable {
        let name: String
        let sha256: String
    }

    struct Result: Sendable, Equatable {
        let directory: URL
        let files: [FileDigest]
    }

    struct Assembly: Sendable {
        let files: [String: Data]
    }

    func build(
        _ input: Input,
        at directory: URL,
        onFirstWrite: @Sendable () async -> Void = {}
    ) async throws -> Result {
        try await write(assemble(input), to: directory, onFirstWrite: onFirstWrite)
    }

    func assemble(_ input: Input) throws -> Assembly {
        let traceOutput = exportTraces(input.traces)
        let doctorOutput = exportDoctor(input.doctorReport)
        let manifest = Manifest(
            schema: "logic_pro_mcp_support_bundle.v1",
            createdAt: input.createdAt,
            serverVersion: safeDiagnostic(input.serverVersion),
            serverCommit: safeDiagnostic(input.serverCommit),
            logic: .init(
                version: safeDiagnostic(input.logic.version),
                variant: safeDiagnostic(input.logic.variant),
                locale: safeDiagnostic(input.logic.locale)
            ),
            qualificationReference: safeDiagnostic(input.qualificationReference),
            files: Self.fileNames.sorted()
        )
        let summaries = [
            RedactionSummary(file: "manifest.json", privacyClasses: [.publicDiagnostic], droppedKeyCount: 0),
            RedactionSummary(file: "traces.json", privacyClasses: traceOutput.privacyClasses, droppedKeyCount: traceOutput.droppedKeyCount),
            RedactionSummary(
                file: "doctor.json",
                privacyClasses: doctorOutput.privacyClasses,
                droppedKeyCount: doctorOutput.droppedKeyCount
            ),
            RedactionSummary(file: "metadata.json", privacyClasses: [.publicDiagnostic], droppedKeyCount: 0),
            RedactionSummary(file: "redaction_report.json", privacyClasses: [.publicDiagnostic], droppedKeyCount: 0),
            RedactionSummary(file: "SHA256SUMS", privacyClasses: [.publicDiagnostic], droppedKeyCount: 0),
        ]

        var files: [String: Data] = [
            "manifest.json": try jsonData(manifest),
            "traces.json": try jsonData(TraceFile(schema: "logic_pro_mcp_operation_traces.v1", traces: traceOutput.traces)),
            "doctor.json": try jsonData(doctorOutput.report),
            "metadata.json": try jsonData(input.metadata),
            "redaction_report.json": try jsonData(RedactionReport(
                schema: "logic_pro_mcp_support_bundle_redaction.v1",
                files: summaries
            )),
        ]
        let sums = try Self.jsonFileNames.map { name in
            guard let data = files[name] else { throw CocoaError(.fileNoSuchFile) }
            return "\(Self.sha256(data))  \(name)"
        }
            .joined(separator: "\n") + "\n"
        files["SHA256SUMS"] = Data(sums.utf8)
        return Assembly(files: files)
    }

    func write(
        _ assembly: Assembly,
        to directory: URL,
        onFirstWrite: @Sendable () async -> Void = {}
    ) async throws -> Result {
        try Self.requireAbsent(directory)
        await onFirstWrite()
        return try await Self.runBlocking {
            try Self.requireAbsent(directory)
            // Materialize, publish, and read back strictly through SecureFD
            // (fd-relative, no-follow): a symlink planted for any component of the
            // caller-derived bundle path can no longer divert the staging
            // directory, the per-file writes, the publish, or the readback outside
            // the trusted base. Replaces the path-based createDirectory + Data.write
            // + Data(contentsOf:) and the post-create realpath containment recheck.
            // Trusted anchor = the deepest EXISTING ancestor of the target
            // (confined under the support-bundle root by the caller's
            // resolvedSupportBundleDirectory in production; a temp root under test),
            // opened by path like the home base. The not-yet-existing tail is then
            // created + walked strictly no-follow below. Deriving the base per call
            // (no global seam) keeps concurrent publishers independent.
            var anchor = directory.standardizedFileURL
            var tail: [String] = []
            while !FileManager.default.fileExists(atPath: anchor.path), anchor.pathComponents.count > 1 {
                tail.insert(anchor.lastPathComponent, at: 0)
                anchor = anchor.deletingLastPathComponent()
            }
            let baseFD = anchor.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            guard baseFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(baseFD) }
            // `requireAbsent` proved the target does not exist, so the tail is
            // non-empty (its last element is the bundle directory name).
            guard let bundleName = tail.last else { throw CocoaError(.fileWriteFileExists) }
            let parentFD = try SecureFD.ensureDirectory(
                baseFD: baseFD, components: Array(tail.dropLast()), mode: 0o755
            )
            defer { close(parentFD) }

            let stagingName = ".\(bundleName).tmp-\(UUID().uuidString)"
            let (stagingFD, _) = try SecureFD.makeEmptyDir(
                parentFD: parentFD, name: stagingName, mode: 0o700
            )
            var published = false
            defer {
                close(stagingFD)
                if !published { try? SecureFD.teardownTree(parentFD: parentFD, name: stagingName) }
            }

            for name in Self.fileNames.sorted() {
                guard let data = assembly.files[name] else { throw CocoaError(.fileNoSuchFile) }
                let fd = try SecureFD.createFile(parentFD: stagingFD, name: name, mode: 0o600)
                do {
                    try data.withUnsafeBytes { raw in
                        var off = 0
                        while off < raw.count {
                            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                            off += n
                        }
                    }
                    try SecureFD.fullfsync(fd)
                } catch { close(fd); throw error }
                close(fd)
            }

            // Publish atomically + exclusively RELATIVE to the parent dir fd, so no
            // path re-resolution can divert it; RENAME_EXCL refuses an existing target.
            let renamed = stagingName.withCString { s in
                bundleName.withCString { d in
                    renameatx_np(parentFD, s, parentFD, d, UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            published = true

            // Read back the PUBLISHED bundle fd-relative (no-follow, regular-file,
            // st_nlink==1) and verify every digest; tear it down on any mismatch.
            do {
                let bundleFD = try SecureFD.walkVerified(baseFD: parentFD, [bundleName]).fd
                defer { close(bundleFD) }
                var digests: [FileDigest] = []
                for name in Self.fileNames.sorted() {
                    guard let source = assembly.files[name] else { throw CocoaError(.fileNoSuchFile) }
                    let rfd = try SecureFD.openRead(parentFD: bundleFD, name: name)
                    let data: Data
                    do {
                        data = try FileHandle(fileDescriptor: rfd, closeOnDealloc: false).readToEnd() ?? Data()
                    } catch { close(rfd); throw error }
                    close(rfd)
                    let digest = Self.sha256(data)
                    guard digest == Self.sha256(source) else { throw CocoaError(.fileReadCorruptFile) }
                    digests.append(FileDigest(name: name, sha256: digest))
                }
                return Result(directory: directory, files: digests)
            } catch {
                try? SecureFD.teardownTree(parentFD: parentFD, name: bundleName)
                throw error
            }
        }
    }

    static func runBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func exportTraces(_ traces: [OperationTrace]) -> TraceOutput {
        var droppedKeyCount = 0
        var appliedClasses: Set<TracePrivacyClass> = []
        let exported = traces.map { trace in
            TraceRecord(
                traceID: trace.traceID.rawValue,
                operationID: safeDiagnostic(trace.operationID),
                events: trace.events.map { event in
                    var attributes: [String: String] = [:]
                    var classes: [String: String] = [:]
                    for (key, value) in event.attributes {
                        if let declared = event.privacyClasses[key] { appliedClasses.insert(declared) }
                        guard let declared = event.privacyClasses[key],
                              OperationTraceStore.attributePrivacyClasses[key] == declared else {
                            droppedKeyCount += 1
                            continue
                        }
                        switch declared {
                        case .publicDiagnostic:
                            attributes[key] = safeDiagnostic(value)
                        case .hashed:
                            attributes[key] = Self.sha256(Data(value.utf8))
                        case .presenceOnly:
                            attributes[key] = "present"
                        case .secret:
                            droppedKeyCount += 1
                            continue
                        }
                        classes[key] = declared.rawValue
                    }
                    return TraceEventRecord(
                        phase: event.phase.rawValue,
                        timestamp: ISO8601DateFormatter.cacheFormatter.string(from: event.wallClock),
                        attributes: attributes,
                        privacyClasses: classes
                    )
                }
            )
        }
        return TraceOutput(
            traces: exported,
            privacyClasses: appliedClasses.sorted { $0.rawValue < $1.rawValue },
            droppedKeyCount: droppedKeyCount
        )
    }

    private func exportDoctor(_ report: SetupDoctor.Report) -> DoctorOutput {
        var droppedKeyCount = 0
        let checks = report.checks.map { check in
            var evidence: [String: String] = [:]
            for (key, value) in check.evidence {
                guard !isSensitiveLabel(key), !containsSecretMarker(value) else {
                    droppedKeyCount += 1
                    continue
                }
                evidence[safeIdentifier(key)] = "present"
            }
            return DoctorCheck(
                id: safeIdentifier(check.id),
                domain: safeIdentifier(check.domain),
                status: check.status,
                summary: "Check \(safeIdentifier(check.id)): \(check.status.rawValue)",
                evidence: evidence,
                remediation: .init(
                    type: check.remediation.type,
                    value: check.remediation.value.isEmpty ? "" : "present"
                ),
                category: check.category,
                severity: check.severity,
                durationMs: check.durationMs,
                blockedBy: check.blockedBy.map(safeIdentifier),
                skipReason: check.skipReason,
                optional: check.optional
            )
        }
        var capabilities: [String: DoctorCapability] = [:]
        for (key, capability) in report.capabilities {
            capabilities[safeIdentifier(key)] = .init(
                status: capability.status,
                checks: capability.checks.map(safeIdentifier),
                liveVerification: capability.liveVerification == nil ? nil : "present"
            )
        }
        let privacyClasses: [TracePrivacyClass] = droppedKeyCount == 0
            ? [.publicDiagnostic, .presenceOnly]
            : [.publicDiagnostic, .presenceOnly, .secret]
        return DoctorOutput(
            report: .init(
                schema: safeIdentifier(report.schema),
                status: report.status,
                version: safeIdentifier(report.version),
                installSource: report.installSource,
                checks: checks,
                summary: report.summary,
                headline: "Doctor status: \(report.status.rawValue)",
                fixPlan: report.fixPlan.map(safeIdentifier),
                doctorProfile: report.doctorProfile,
                doctorProfileBasis: report.doctorProfileBasis.isEmpty ? "" : "present",
                clientProfile: report.clientProfile,
                clientProfileBasis: report.clientProfileBasis.isEmpty ? "" : "present",
                capabilities: capabilities
            ),
            privacyClasses: privacyClasses,
            droppedKeyCount: droppedKeyCount
        )
    }

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        Data(try encodeJSONStrict(value).utf8)
    }

    private func safeDiagnostic(_ value: String) -> String {
        if ["sk-", "ghp_", "Bearer "].contains(where: value.contains) { return "redacted" }
        return value.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    private func safeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy(allowed.contains),
              !isSensitive(value) else {
            return "redacted"
        }
        return value
    }

    private func isSensitive(_ value: String) -> Bool {
        isSensitiveLabel(value) || containsSecretMarker(value)
            || value.lowercased().contains("/users/")
    }

    private func isSensitiveLabel(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["token", "secret", "password", "api_key", "apikey", "authorization"].contains {
            lower.contains($0)
        }
    }

    private func containsSecretMarker(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["sk-", "ghp_", "bearer ", "api_key=", "apikey=", "password=", "secret=", "token="].contains {
            lower.contains($0)
        }
    }

    private static func requireAbsent(_ directory: URL) throws {
        var info = stat()
        let result = directory.path.withCString { lstat($0, &info) }
        if result == 0 { throw CocoaError(.fileWriteFileExists) }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

}

private extension SupportBundleBuilder {
    struct DoctorReport: Encodable {
        let schema: String
        let status: SetupDoctor.ReportStatus
        let version: String
        let installSource: SetupDoctor.InstallSource
        let checks: [DoctorCheck]
        let summary: SetupDoctor.Summary
        let headline: String
        let fixPlan: [String]
        let doctorProfile: SetupDoctor.DoctorProfile
        let doctorProfileBasis: String
        let clientProfile: SetupDoctor.ClientProfile
        let clientProfileBasis: String
        let capabilities: [String: DoctorCapability]

        enum CodingKeys: String, CodingKey {
            case schema
            case status
            case version
            case installSource = "install_source"
            case checks
            case summary
            case headline
            case fixPlan = "fix_plan"
            case doctorProfile = "doctor_profile"
            case doctorProfileBasis = "doctor_profile_basis"
            case clientProfile = "client_profile"
            case clientProfileBasis = "client_profile_basis"
            case capabilities
        }
    }

    struct DoctorCheck: Encodable {
        let id: String
        let domain: String
        let status: SetupDoctor.CheckStatus
        let summary: String
        let evidence: [String: String]
        let remediation: SetupRemediation
        let category: SetupDoctor.Category
        let severity: SetupDoctor.Severity
        let durationMs: Double
        let blockedBy: String?
        let skipReason: SetupDoctor.DoctorSkipReason?
        let optional: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case domain
            case status
            case summary
            case evidence
            case remediation
            case category
            case severity
            case durationMs = "duration_ms"
            case blockedBy = "blocked_by"
            case skipReason = "skip_reason"
            case optional
        }
    }

    struct DoctorCapability: Encodable {
        let status: SetupDoctor.CapabilityStatus
        let checks: [String]
        let liveVerification: String?

        enum CodingKeys: String, CodingKey {
            case status
            case checks
            case liveVerification = "live_verification"
        }
    }

    struct DoctorOutput {
        let report: DoctorReport
        let privacyClasses: [TracePrivacyClass]
        let droppedKeyCount: Int
    }

    struct Manifest: Encodable {
        let schema: String
        let createdAt: Date
        let serverVersion: String
        let serverCommit: String
        let logic: LogicMetadata
        let qualificationReference: String
        let files: [String]

        enum CodingKeys: String, CodingKey {
            case schema
            case createdAt = "created_at"
            case serverVersion = "server_version"
            case serverCommit = "server_commit"
            case logic
            case qualificationReference = "qualification_reference"
            case files
        }
    }

    struct TraceEventRecord: Encodable {
        let phase: String
        let timestamp: String
        let attributes: [String: String]
        let privacyClasses: [String: String]

        enum CodingKeys: String, CodingKey {
            case phase
            case timestamp
            case attributes
            case privacyClasses = "privacy_classes"
        }
    }

    struct TraceRecord: Encodable {
        let traceID: String
        let operationID: String
        let events: [TraceEventRecord]

        enum CodingKeys: String, CodingKey {
            case traceID = "trace_id"
            case operationID = "operation_id"
            case events
        }
    }

    struct TraceFile: Encodable {
        let schema: String
        let traces: [TraceRecord]
    }

    struct TraceOutput {
        let traces: [TraceRecord]
        let privacyClasses: [TracePrivacyClass]
        let droppedKeyCount: Int
    }

    struct RedactionSummary: Encodable {
        let file: String
        let privacyClasses: [TracePrivacyClass]
        let droppedKeyCount: Int

        enum CodingKeys: String, CodingKey {
            case file
            case privacyClasses = "privacy_classes"
            case droppedKeyCount = "dropped_key_count"
        }
    }

    struct RedactionReport: Encodable {
        let schema: String
        let files: [RedactionSummary]
    }
}
