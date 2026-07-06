import Foundation
import Testing
@testable import LogicProMCP

private func doctorV3Permissions() -> PermissionChecker.PermissionStatus {
    .init(
        accessibilityState: .granted,
        automationState: .granted,
        systemEventsAutomationState: .granted,
        postEventAccessState: .granted
    )
}

private func doctorV3Approvals() -> [ManualValidationChannel: ManualValidationApproval] {
    Dictionary(uniqueKeysWithValues: ManualValidationChannel.allCases.map {
        ($0, ManualValidationApproval(approvedAt: Date(timeIntervalSince1970: 0), note: "test"))
    })
}

private func doctorV3Runtime(
    resolvedExecutablePath: String? = "/opt/homebrew/bin/LogicProMCP",
    registration: SetupDoctor.ClaudeRegistration = .registered(command: "/opt/homebrew/bin/LogicProMCP"),
    readClaudeRegistration: (() -> SetupDoctor.ClaudeRegistration)? = nil,
    exists: @escaping (String) -> Bool = { _ in true },
    executable: @escaping (String) -> Bool = { _ in true },
    regular: @escaping (String) -> Bool = { _ in true },
    directory: @escaping (String) -> Bool = { _ in true },
    logicApps: @escaping () -> [SetupDoctor.LogicAppInfo] = {
        [SetupDoctor.LogicAppInfo(path: "/Applications/Logic Pro.app", version: LogicProSupport.latestValidatedLogicVersion, bundleID: ServerConfig.logicProBundleID, readable: true)]
    },
    commandHandler: @escaping (String, [String]) -> SetupDoctor.CommandOutput? = { executable, arguments in
        if executable == "/usr/bin/codesign" { return .init(exitCode: 0, stdout: "", stderr: "") }
        if executable == "/usr/bin/xattr" { return .init(exitCode: 1, stdout: "", stderr: "No such xattr") }
        if executable == "/usr/bin/lipo" { return .init(exitCode: 0, stdout: "arm64\n", stderr: "") }
        if executable == "/usr/bin/strings", arguments.count == 2 {
            return .init(exitCode: 0, stdout: "\(ServerConfig.serverVersion)\n", stderr: "")
        }
        if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew" {
            return .init(exitCode: 0, stdout: "logic-pro-mcp \(ServerConfig.serverVersion)\n", stderr: "")
        }
        return nil
    }
) -> SetupDoctor.Runtime {
    var runtime = SetupDoctor.Runtime(
        resolveExecutablePath: { _ in resolvedExecutablePath },
        fileExists: exists,
        isExecutableFile: executable,
        logicProRunning: { true },
        logicProHasVisibleWindow: { true },
        runCommand: commandHandler,
        readClaudeRegistration: readClaudeRegistration ?? { registration }
    )
    runtime.logicApps = logicApps
    runtime.shareDirProbe = { .complete(path: "/opt/homebrew/share/logic-pro-mcp", source: "brew_pkgshare") }
    runtime.readClaudeDesktopRegistration = { .registered(command: "/Applications/Claude.app/Contents/MacOS/Claude") }
    runtime.keyCommandsPresetStaged = { true }
    runtime.mcuPortReferenceFound = { true }
    runtime.launchContext = { SetupDoctor.LaunchContextInfo(context: "terminal", responsibleHint: "Terminal") }
    runtime.tccCrossContextProbe = { .granted("service=accessibility;principal_hint=Terminal;state=granted") }
    runtime.blockingDialogInfo = { nil }
    runtime.fileExistsAtPath = exists
    runtime.isRegularFile = regular
    runtime.isDirectory = directory
    return runtime
}

private func doctorV3Report(_ runtime: SetupDoctor.Runtime) -> SetupDoctor.Report {
    SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: doctorV3Permissions(),
        approvals: doctorV3Approvals(),
        runtime: runtime
    )
}

private func doctorV3Check(_ report: SetupDoctor.Report, _ id: String) throws -> SetupDoctor.Check {
    try #require(report.checks.first { $0.id == id })
}

@Test func testDoctorV3BinaryInventoryRejectsLeadingDotNoiseAndWarnsOnStaleCandidate() throws {
    let runtime = doctorV3Runtime(
        resolvedExecutablePath: "/tmp/build/LogicProMCP",
        regular: { $0 == "/opt/homebrew/bin/LogicProMCP" },
        commandHandler: { executable, arguments in
            if executable == "/usr/bin/codesign" { return .init(exitCode: 0, stdout: "", stderr: "") }
            if executable == "/usr/bin/xattr" { return .init(exitCode: 1, stdout: "No such xattr", stderr: "") }
            if executable == "/usr/bin/lipo" { return .init(exitCode: 0, stdout: "x86_64 arm64\n", stderr: "") }
            if executable == "/usr/bin/strings", arguments == ["-a", "/opt/homebrew/bin/LogicProMCP"] {
                return .init(exitCode: 0, stdout: ".1.1.1\n3.5.0\n", stderr: "")
            }
            return nil
        }
    )
    let check = try doctorV3Check(doctorV3Report(runtime), "install.binary_inventory")
    #expect(check.status == .warn)
    #expect(check.evidence["stale"] == "true")
    let candidates = try #require(check.evidence["candidates"])
    #expect(candidates.contains(":3.5.0"))
    #expect(check.evidence["indeterminate"] == nil)
    #expect(check.summary == "A canonical LogicProMCP binary has a different static version than the running doctor.")
}

@Test func testDoctorV3BinaryInventoryWarnsWhenCanonicalVersionIsIndeterminate() throws {
    let runtime = doctorV3Runtime(
        resolvedExecutablePath: "/tmp/build/LogicProMCP",
        regular: { $0 == "/opt/homebrew/bin/LogicProMCP" },
        commandHandler: { executable, arguments in
            if executable == "/usr/bin/codesign" { return .init(exitCode: 0, stdout: "", stderr: "") }
            if executable == "/usr/bin/xattr" { return .init(exitCode: 1, stdout: "No such xattr", stderr: "") }
            if executable == "/usr/bin/lipo" { return .init(exitCode: 0, stdout: "arm64\n", stderr: "") }
            if executable == "/usr/bin/strings", arguments == ["-a", "/opt/homebrew/bin/LogicProMCP"] {
                return .init(exitCode: 0, stdout: "\(ServerConfig.serverVersion)\n3.40.1\n", stderr: "")
            }
            return nil
        }
    )
    let check = try doctorV3Check(doctorV3Report(runtime), "install.binary_inventory")
    #expect(check.status == .warn)
    #expect(check.evidence["stale"] == nil)
    let indeterminate = try #require(check.evidence["indeterminate"])
    #expect(indeterminate.contains("/opt/homebrew/bin/LogicProMCP"))
    #expect(indeterminate.contains("3.40.1"))
    #expect(check.summary.contains("staleness cannot be ruled out"))
}

@Test func testDoctorV3BinaryInventoryAllowsIndeterminateRunningExecutable() throws {
    let runtime = doctorV3Runtime(
        resolvedExecutablePath: "/opt/homebrew/bin/LogicProMCP",
        regular: { $0 == "/opt/homebrew/bin/LogicProMCP" },
        commandHandler: { executable, arguments in
            if executable == "/usr/bin/codesign" { return .init(exitCode: 0, stdout: "", stderr: "") }
            if executable == "/usr/bin/xattr" { return .init(exitCode: 1, stdout: "No such xattr", stderr: "") }
            if executable == "/usr/bin/lipo" { return .init(exitCode: 0, stdout: "arm64\n", stderr: "") }
            if executable == "/usr/bin/strings", arguments == ["-a", "/opt/homebrew/bin/LogicProMCP"] {
                return .init(exitCode: 0, stdout: "\(ServerConfig.serverVersion)\n3.40.1\n", stderr: "")
            }
            return nil
        }
    )
    let check = try doctorV3Check(doctorV3Report(runtime), "install.binary_inventory")
    #expect(check.status == .pass)
    #expect(check.evidence["stale"] == nil)
    let indeterminate = try #require(check.evidence["indeterminate"])
    #expect(indeterminate.contains("/opt/homebrew/bin/LogicProMCP"))
    #expect(check.summary == "Canonical LogicProMCP binary inventory found no stale installed binary.")
}

@Test func testDoctorV3RelativeRegisteredCommandIsSkippedNotWarn() throws {
    let report = doctorV3Report(doctorV3Runtime(registration: .registered(command: "LogicProMCP")))
    let check = try doctorV3Check(report, "mcp.registration_target")
    #expect(check.status == .skipped)
    #expect(check.evidence["reason"] == "relative_command")
    #expect(check.summary.contains("install.binary_inventory"))
}

@Test func testDoctorV3RegisteredCommandMustBeRegularFile() throws {
    let command = "/opt/homebrew/bin/LogicProMCP"
    let runtime = doctorV3Runtime(
        registration: .registered(command: command),
        regular: { $0 != command }
    )
    let check = try doctorV3Check(doctorV3Report(runtime), "mcp.registration_target")
    #expect(check.status == .warn)
    #expect(check.evidence["regular_file"] == "false")
}

@Test func testDoctorV3RegisteredShareDirEnvMissingWarns() throws {
    let runtime = doctorV3Runtime(
        registration: .registered(
            command: "/opt/homebrew/bin/LogicProMCP",
            environment: ["LOGIC_PRO_MCP_SHARE_DIR": "/missing/share"]
        ),
        directory: { $0 != "/missing/share" }
    )
    let check = try doctorV3Check(doctorV3Report(runtime), "mcp.registration_target")
    #expect(check.status == .warn)
    #expect(check.evidence["share_dir"] == "missing")
}

@Test func testDoctorV3InstallShareDirEvidenceDoesNotExposeEnvPath() throws {
    let secretShareDir = "/tmp/private-share-\(UUID().uuidString)"
    var runtime = doctorV3Runtime()
    runtime.shareDirProbe = {
        .missing(path: secretShareDir, source: "registered_env", files: ["logic_bounce.py"])
    }
    let check = try doctorV3Check(doctorV3Report(runtime), "install.share_dir")
    #expect(check.status == .warn)
    #expect(check.evidence["source"] == "registered_env")
    #expect(check.evidence["resolved_dir"] != secretShareDir)
    #expect(check.evidence.values.allSatisfy { !$0.contains(secretShareDir) })
}

@Test func testDoctorV3LogicInstallationUsesReadableCopy() throws {
    let runtime = doctorV3Runtime(logicApps: {
        [
            SetupDoctor.LogicAppInfo(path: "/Applications/Logic Pro.app", version: nil, bundleID: nil, readable: false),
            SetupDoctor.LogicAppInfo(path: "/Users/example/Applications/Logic Pro.app", version: LogicProSupport.latestValidatedLogicVersion, bundleID: ServerConfig.logicProBundleID, readable: true),
        ]
    })
    let report = doctorV3Report(runtime)
    let installation = try doctorV3Check(report, "logic.installation")
    let version = try doctorV3Check(report, "logic.version_support")
    #expect(installation.status == .pass)
    #expect(version.status == .pass)
}

@Test func testDoctorV3LaunchClassifierPrecedence() {
    let result = SetupDoctor.classifyLaunchContext(
        ancestryBundleIDs: ["com.anthropic.claudefordesktop"],
        cfBundleIdentifier: "com.apple.Terminal",
        termProgram: "Apple_Terminal"
    )
    #expect(result.context == "claude_desktop")

    let fallback = SetupDoctor.classifyLaunchContext(
        ancestryBundleIDs: [],
        cfBundleIdentifier: nil,
        termProgram: "iTerm.app"
    )
    #expect(fallback.context == "terminal")
}

@Test func testDoctorV3TCCDeniedWarnsAndRedacts() {
    let rows = [
        SetupDoctor.TCCRow(
            service: "kTCCServiceAppleEvents",
            client: "/Users/example/Claude.app",
            authValue: 0,
            indirectObjectIdentifier: "com.apple.logic10"
        )
    ]
    let result = SetupDoctor.mapTCCQueryOutcome(.rows(rows))
    #expect(result == .denied("service=appleevents:logic10;principal_hint=Claude.app;state=denied"))
}

@Test func testDoctorV3TCCNoGrantDoesNotPass() {
    let unknown = SetupDoctor.TCCRow(
        service: "kTCCServicePostEvent",
        client: "com.apple.Terminal",
        authValue: 1,
        indirectObjectIdentifier: ""
    )
    #expect(SetupDoctor.mapTCCQueryOutcome(.rows([unknown])) == .skipped(reason: "principal_not_found"))
    #expect(SetupDoctor.mapTCCQueryOutcome(.rows([])) == .skipped(reason: "principal_not_found"))
    #expect(SetupDoctor.mapTCCQueryOutcome(.queryUnavailable) == .skipped(reason: "tcc_query_unavailable"))
    #expect(SetupDoctor.mapTCCQueryOutcome(.schemaMismatch) == .skipped(reason: "tcc_schema_mismatch"))
    #expect(SetupDoctor.mapTCCQueryOutcome(.fullDiskAccessUnavailable) == .skipped(reason: "full_disk_access_unavailable"))
}

@Test func testDoctorV3TCCSkippedEvidenceMatchesProbeReason() throws {
    let cases: [(reason: String, readable: String)] = [
        ("full_disk_access_unavailable", "false"),
        ("tcc_query_unavailable", "unknown"),
        ("tcc_schema_mismatch", "true"),
        ("principal_not_found", "true"),
    ]
    for item in cases {
        var runtime = doctorV3Runtime()
        runtime.tccCrossContextProbe = { .skipped(reason: item.reason) }
        let check = try doctorV3Check(doctorV3Report(runtime), "permissions.tcc_cross_context")
        #expect(check.status == .skipped)
        #expect(check.evidence["reason"] == item.reason)
        #expect(check.evidence["tcc_db_readable"] == item.readable)
        #expect(check.evidence["full_disk_access"] == item.readable)
    }
}

@Test func testDoctorV3EvidenceSanitizesStderrAndHomePath() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let check = SetupDoctor.check(
        id: "release.signature",
        domain: "release",
        status: .warn,
        summary: "x",
        evidence: ["stderr": "permission denied at \(home)/secret", "path": "\(home)/bin/LogicProMCP"],
        remediationType: .docs
    )
    #expect(check.evidence["stderr"] == "present")
    #expect(check.evidence["path"] == "~/bin/LogicProMCP")
}

@Test func testDoctorV3ClaudeRegistrationCapturesShareDirEnv() {
    let json = """
    {"mcpServers":{"logic-pro":{"command":"/opt/homebrew/bin/LogicProMCP","env":{"LOGIC_PRO_MCP_SHARE_DIR":"/tmp/share"}}}}
    """
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("doctor-v3-config-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let configURL = dir.appendingPathComponent(".claude.json")
    try? Data(json.utf8).write(to: configURL)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(
        SetupDoctor.readClaudeRegistrationForTesting(configURL: configURL)
            == .registered(command: "/opt/homebrew/bin/LogicProMCP", environment: ["LOGIC_PRO_MCP_SHARE_DIR": "/tmp/share"])
    )
}

@Test func testDoctorV3GenerateReusesClaudeRegistrationAndLogicApps() {
    var claudeReads = 0
    var logicReads = 0
    let runtime = doctorV3Runtime(
        readClaudeRegistration: {
            claudeReads += 1
            return .registered(command: "/opt/homebrew/bin/LogicProMCP")
        },
        logicApps: {
            logicReads += 1
            return [
                SetupDoctor.LogicAppInfo(
                    path: "/Applications/Logic Pro.app",
                    version: LogicProSupport.latestValidatedLogicVersion,
                    bundleID: ServerConfig.logicProBundleID,
                    readable: true
                ),
            ]
        }
    )
    _ = doctorV3Report(runtime)
    #expect(claudeReads == 1)
    #expect(logicReads == 1)
}

@Test func testDoctorV3GenerateReusesStaticVersionScanForRegisteredCandidate() {
    var stringsCalls: [String: Int] = [:]
    let runtime = doctorV3Runtime(commandHandler: { executable, arguments in
        if executable == "/usr/bin/codesign" { return .init(exitCode: 0, stdout: "", stderr: "") }
        if executable == "/usr/bin/xattr" { return .init(exitCode: 1, stdout: "No such xattr", stderr: "") }
        if executable == "/usr/bin/lipo" { return .init(exitCode: 0, stdout: "arm64\n", stderr: "") }
        if executable == "/usr/bin/strings", arguments.count == 2 {
            stringsCalls[arguments[1], default: 0] += 1
            return .init(exitCode: 0, stdout: "\(ServerConfig.serverVersion)\n", stderr: "")
        }
        if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew" {
            return .init(exitCode: 0, stdout: "logic-pro-mcp \(ServerConfig.serverVersion)\n", stderr: "")
        }
        return nil
    })
    _ = doctorV3Report(runtime)
    #expect(stringsCalls["/opt/homebrew/bin/LogicProMCP"] == 1)
}
