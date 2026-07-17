import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("ADR-005 support bundle", .serialized)
struct SupportBundleTests {
    @Test("bundle is complete, readback-verifiable, and privacy safe")
    func completePrivacySafeBundle() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-support-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }

        let privatePath = "/Users/private/Library/secret.logicx"
        let envValue = "ULW_ENV_VALUE_7d2c2b09"
        let doctorValue = "ULW_DOCTOR_VALUE_081c0e7a"
        let trace = OperationTrace(
            traceID: TraceID(rawValue: "lpmcp_00000000-0000-0000-0000-000000000001"),
            operationID: OperationID.transportPlay.rawValue,
            startedAt: .now,
            events: [
                TraceEvent(
                    phase: .requestReceived,
                    timestamp: .now,
                    attributes: [
                        "operation_id": OperationID.transportPlay.rawValue,
                        "command": "play",
                        "project_path_hash": privatePath,
                        "prompt": "sk-private-prompt",
                        "token": "ghp_private-token",
                        "environment": envValue,
                        "private_path": "Bearer private-token \(privatePath)",
                    ],
                    privacyClasses: [
                        "operation_id": .publicDiagnostic,
                        "command": .publicDiagnostic,
                        "project_path_hash": .hashed,
                        "prompt": .secret,
                        "token": .secret,
                        "environment": .secret,
                        "private_path": .publicDiagnostic,
                    ]
                ),
            ],
            completedAt: .now
        )
        let input = SupportBundleBuilder.Input(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            serverVersion: "3.11.0",
            serverCommit: "unknown",
            logic: .init(version: "12.3", variant: "desktop", locale: "en_US"),
            qualificationReference: "not_available",
            traces: [trace],
            doctorReport: Self.hostileDoctorReport(privateValue: doctorValue),
            metadata: .init(
                process: .init(uptimeSec: 42, memoryMb: 64.5),
                channels: [
                    .init(
                        id: "accessibility",
                        available: true,
                        ready: true,
                        verificationStatus: "verified"
                    ),
                ]
            )
        )

        let result = try await SupportBundleBuilder().build(input, at: output)
        let expectedFiles = Set([
            "manifest.json", "traces.json", "doctor.json", "metadata.json",
            "redaction_report.json", "SHA256SUMS",
        ])
        let actualFiles = Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
        #expect(actualFiles == expectedFiles)
        #expect(Set(result.files.map(\.name)) == expectedFiles)

        let manifest = try Self.jsonObject(output.appendingPathComponent("manifest.json"))
        #expect(manifest["schema"] as? String == "logic_pro_mcp_support_bundle.v1")
        #expect(manifest["created_at"] as? String == "2023-11-14T22:13:20.000Z")
        #expect(Set(manifest["files"] as? [String] ?? []) == expectedFiles)
        #expect(manifest["server_commit"] as? String == "unknown")
        #expect(manifest["qualification_reference"] as? String == "not_available")

        let checksumLines = try String(
            contentsOf: output.appendingPathComponent("SHA256SUMS"),
            encoding: .utf8
        ).split(separator: "\n").map(String.init)
        #expect(checksumLines.count == expectedFiles.count - 1)
        for line in checksumLines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            #expect(parts.count == 2)
            guard parts.count == 2 else { continue }
            let expectedDigest = String(parts[0])
            let name = String(parts[1])
            let data = try Data(contentsOf: output.appendingPathComponent(name))
            #expect(expectedDigest == Self.sha256(data))
        }
        for file in result.files {
            let data = try Data(contentsOf: output.appendingPathComponent(file.name))
            #expect(file.sha256 == Self.sha256(data))
        }

        let allText = try expectedFiles.sorted().map {
            try String(contentsOf: output.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        for forbidden in ["/Users/", "sk-", "ghp_", "Bearer ", envValue, doctorValue] {
            #expect(!allText.contains(forbidden), "bundle leaked forbidden marker: \(forbidden)")
        }

        let traces = try Self.jsonObject(output.appendingPathComponent("traces.json"))
        let exportedTraces = try #require(traces["traces"] as? [[String: Any]])
        let events = try #require(exportedTraces.first?["events"] as? [[String: Any]])
        let attributes = try #require(events.first?["attributes"] as? [String: String])
        #expect(Set(attributes.keys) == ["operation_id", "command", "project_path_hash"])
        #expect(attributes["project_path_hash"] == Self.sha256(Data(privatePath.utf8)))

        let report = try Self.jsonObject(output.appendingPathComponent("redaction_report.json"))
        let summaries = try #require(report["files"] as? [[String: Any]])
        let traceSummary = try #require(summaries.first { $0["file"] as? String == "traces.json" })
        #expect((traceSummary["dropped_key_count"] as? Int ?? 0) == 4)
        #expect(Set(traceSummary["privacy_classes"] as? [String] ?? []) == [
            TracePrivacyClass.publicDiagnostic.rawValue,
            TracePrivacyClass.hashed.rawValue,
            TracePrivacyClass.secret.rawValue,
        ])
        let doctorSummary = try #require(summaries.first { $0["file"] as? String == "doctor.json" })
        #expect((doctorSummary["dropped_key_count"] as? Int ?? 0) == 1)

        let doctor = try Self.jsonObject(output.appendingPathComponent("doctor.json"))
        let doctorChecks = try #require(doctor["checks"] as? [[String: Any]])
        let doctorEvidence = try #require(doctorChecks.first?["evidence"] as? [String: String])
        #expect(doctorEvidence["dialog_title"] == "present")
        #expect(doctorEvidence["path"] == "present")
        #expect(doctorEvidence["token"] == nil)
    }

    @Test("existing output directories are refused without changing caller files")
    func refusesExistingOutputDirectory() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-existing-support-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-linked-support-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let marker = output.appendingPathComponent("keep.me")
        try Data("caller-owned".utf8).write(to: marker)
        let assembly = SupportBundleBuilder.Assembly(files: Dictionary(
            uniqueKeysWithValues: SupportBundleBuilder.fileNames.map { ($0, Data($0.utf8)) }
        ))

        await #expect(throws: Error.self) {
            try await SupportBundleBuilder().write(assembly, to: output)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "caller-owned")
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["keep.me"])

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        await #expect(throws: Error.self) {
            try await SupportBundleBuilder().write(assembly, to: link)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["keep.me"])
    }

    @Test("concurrent publishers cannot replace an already published bundle")
    func concurrentPublishIsExclusive() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-racing-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let assembly = SupportBundleBuilder.Assembly(files: Dictionary(
            uniqueKeysWithValues: SupportBundleBuilder.fileNames.map { ($0, Data($0.utf8)) }
        ))

        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await SupportBundleBuilder().write(assembly, to: output)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(successes.filter { $0 }.count == 1)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
            == Set(SupportBundleBuilder.fileNames))
    }

    @Test("PRD-011: bundle directory containment defeats absolute, dot-dot, and symlink escapes")
    func bundleDirectoryContainment() throws {
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv(rootKey, root.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
            try? FileManager.default.removeItem(at: root)
        }
        // Relative subpath resolves strictly inside (suffix-checked; the
        // canonical prefix form is the resolver's own realpath output).
        let relative = SystemDispatcher.resolvedSupportBundleDirectory(requested: "session-a/bundle-1")
        #expect(relative != nil)
        #expect(relative?.path.hasSuffix("/session-a/bundle-1") == true)
        // Absolute path already under the root is accepted.
        #expect(SystemDispatcher.resolvedSupportBundleDirectory(
            requested: root.appendingPathComponent("abs-child").path
        ) != nil)
        // Absolute path outside the root is rejected.
        #expect(SystemDispatcher.resolvedSupportBundleDirectory(
            requested: "/tmp/pr011-outside-\(UUID().uuidString)"
        ) == nil)
        // Dot-dot traversal is rejected.
        #expect(SystemDispatcher.resolvedSupportBundleDirectory(requested: "a/../../escape") == nil)
        // The root itself is not a valid bundle directory (strictly inside).
        #expect(SystemDispatcher.resolvedSupportBundleDirectory(requested: root.path) == nil)
        // A symlink planted under the root that points outside is resolved
        // before the containment check and rejected.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr011-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(SystemDispatcher.resolvedSupportBundleDirectory(requested: "link/bundle") == nil)
    }

    @Test("system command returns typed State A/C and records the write boundary")
    func systemCommandContractAndTrace() async throws {
        let flag = "LOGIC_MCP_ADR005_OPERATION_TRACE"
        let previous = getenv(flag).map { String(cString: $0) }
        setenv(flag, "1", 1)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        // PRD-011: contain test bundles under a temp root override.
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        setenv(rootKey, FileManager.default.temporaryDirectory.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
        }
        await OperationTraceStore.shared.clear()

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-support-command-\(UUID().uuidString)")
        let success = await SystemDispatcher.handle(
            command: "export_support_bundle",
            params: ["dir": .string(output.path)],
            router: ChannelRouter(),
            cache: StateCache(),
            supportBundleExporter: { directory, onFirstWrite in
                await onFirstWrite()
                return .init(
                    directory: directory,
                    files: [.init(name: "manifest.json", sha256: String(repeating: "a", count: 64))]
                )
            }
        )
        let successObject = try #require(sharedJSONObject(sharedToolText(success)))
        #expect(successObject["state"] as? String == "A")
        #expect(
            (successObject["bundle_path"] as? String)?
                .hasSuffix("/" + output.lastPathComponent) == true
        )
        let files = try #require(successObject["files"] as? [[String: String]])
        #expect(files == [["name": "manifest.json", "sha256": String(repeating: "a", count: 64)]])
        let traceID = try #require(successObject["trace_id"] as? String)
        let trace = try #require(await OperationTraceStore.shared.trace(.init(rawValue: traceID)))
        #expect(trace.events.map(\.phase) == [
            .requestReceived, .inputValidated, .writeBoundaryCrossed,
            .verificationCompleted, .resultEmitted,
        ])

        let failure = await SystemDispatcher.handle(
            command: "export_support_bundle",
            params: ["dir": .string(output.path)],
            router: ChannelRouter(),
            cache: StateCache(),
            supportBundleExporter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let failureObject = try #require(sharedJSONObject(sharedToolText(failure)))
        #expect(failure.isError == true)
        #expect(failureObject["state"] as? String == "C")
        #expect(failureObject["error"] as? String == "support_bundle_export_failed")

        let defaultPath = await SystemDispatcher.handle(
            command: "export_support_bundle",
            params: [:],
            router: ChannelRouter(),
            cache: StateCache(),
            supportBundleExporter: { directory, onFirstWrite in
                await onFirstWrite()
                return .init(directory: directory, files: [])
            }
        )
        let defaultObject = try #require(sharedJSONObject(sharedToolText(defaultPath)))
        #expect((defaultObject["bundle_path"] as? String)?.contains(
            "/Library/Logs/LogicProMCP/support-bundles/"
        ) == true)
    }

    @Test("public MCP handler exports locally without starting Logic")
    func publicHandlerExport() async throws {
        // PRD-011: contain the test bundle under a temp root override.
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        setenv(rootKey, FileManager.default.temporaryDirectory.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-public-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let input = SupportBundleBuilder.Input(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            serverVersion: ServerConfig.serverVersion,
            serverCommit: "unknown",
            logic: .init(version: "unknown", variant: "unknown", locale: "en_US"),
            qualificationReference: "not_available",
            traces: [],
            doctorReport: Self.doctorReport,
            metadata: .init(process: .init(uptimeSec: 1, memoryMb: 1), channels: [])
        )
        let server = LogicProServer()
        let handlers = await server.makeHandlers(supportBundleExporter: { directory, onFirstWrite in
            try await SupportBundleBuilder().build(input, at: directory, onFirstWrite: onFirstWrite)
        })
        let result = await handlers.callTool(CallTool.Parameters(
            name: "logic_system",
            arguments: [
                "command": .string("export_support_bundle"),
                "params": .object(["dir": .string(output.path)]),
            ]
        ))
        let object = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(object["state"] as? String == "A")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
            == Set(SupportBundleBuilder.fileNames))

        let invalid = await handlers.callTool(CallTool.Parameters(
            name: "logic_system",
            arguments: [
                "command": .string("export_support_bundle"),
                "params": .object(["dir": .string("/pr011-outside-root-\(UUID().uuidString)")]),
            ]
        ))
        #expect(invalid.isError == true)
        #expect(sharedJSONObject(sharedToolText(invalid))?["error"] as? String == "invalid_params")
    }

    private static let doctorReport = SetupDoctor.Report(
        schema: SetupDoctor.schema,
        status: .ok,
        version: "3.11.0",
        installSource: .sourceBuild,
        checks: [],
        summary: .init(
            total: 0,
            passed: 0,
            failed: 0,
            warnings: 0,
            manual: 0,
            skipped: 0,
            durationMs: 0
        ),
        headline: "Ready",
        fixPlan: [],
        doctorProfile: .core,
        doctorProfileBasis: "test",
        clientProfile: .terminal,
        clientProfileBasis: "test",
        capabilities: [:]
    )

    private static func hostileDoctorReport(privateValue: String) -> SetupDoctor.Report {
        SetupDoctor.Report(
            schema: SetupDoctor.schema,
            status: .degraded,
            version: "3.11.0",
            installSource: .sourceBuild,
            checks: [
                .init(
                    id: "logic.blocking_dialog",
                    domain: "logic",
                    status: .warn,
                    summary: "Bearer \(privateValue)",
                    evidence: [
                        "dialog_title": privateValue,
                        "path": "/Users/private/\(privateValue)",
                        "token": "sk-doctor-secret",
                    ],
                    remediation: .init(
                        type: .command,
                        value: "chmod /Users/private/\(privateValue) ghp_doctor"
                    ),
                    category: .runtime,
                    severity: .warning,
                    durationMs: 1,
                    blockedBy: nil,
                    skipReason: nil,
                    optional: false
                ),
            ],
            summary: .init(
                total: 1,
                passed: 0,
                failed: 0,
                warnings: 1,
                manual: 0,
                skipped: 0,
                durationMs: 1
            ),
            headline: "Bearer \(privateValue)",
            fixPlan: ["logic.blocking_dialog"],
            doctorProfile: .core,
            doctorProfileBasis: privateValue,
            clientProfile: .terminal,
            clientProfileBasis: privateValue,
            capabilities: [:]
        )
    }

    private static func jsonObject(_ url: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
