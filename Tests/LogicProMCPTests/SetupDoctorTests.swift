import Foundation
import Testing
@testable import LogicProMCP

private actor DoctorMockMainServer: ServerStarting {
    func start() async throws {}
}

private func doctorRuntime(
    executablePath: String? = "/usr/local/bin/LogicProMCP",
    exists: Bool = true,
    executable: Bool = true,
    logicRunning: Bool = true,
    visibleWindow: Bool = true,
    registration: SetupDoctor.ClaudeRegistration = .registered(command: "/usr/local/bin/LogicProMCP"),
    // v2 seams — hermetic defaults (all-good) so the new checks pass by default and
    // existing tests keep their `.ok` aggregate. Tests override per-case.
    macOSVersion: OperatingSystemVersion? = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
    monotonicNowMs: @escaping () -> Double = { 0 },
    latestReleaseLookup: (() -> SetupDoctor.UpdateOutcome)? = nil,
    commandHandler: @escaping (String, [String]) -> SetupDoctor.CommandOutput? = { executable, arguments in
        if executable == "/usr/bin/codesign" {
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        if executable == "/usr/bin/xattr" {
            return .init(exitCode: 1, stdout: "", stderr: "No such xattr")
        }
        if executable == "/usr/bin/lipo" {
            return .init(exitCode: 0, stdout: "arm64\n", stderr: "")
        }
        if executable == "/usr/bin/strings", arguments.count == 2 {
            return .init(exitCode: 0, stdout: "\(ServerConfig.serverVersion)\n", stderr: "")
        }
        if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew",
           arguments == ["list", "--versions", "logic-pro-mcp"] {
            return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
        }
        return nil
    }
) -> SetupDoctor.Runtime {
    var runtime = SetupDoctor.Runtime(
        resolveExecutablePath: { _ in executablePath },
        fileExists: { _ in exists },
        isExecutableFile: { _ in executable },
        logicProRunning: { logicRunning },
        logicProHasVisibleWindow: { visibleWindow },
        runCommand: { executable, arguments in
            commandHandler(executable, arguments).map(SetupDoctor.CommandResult.completed)
                ?? .spawnFailed("test_command_unavailable")
        },
        readClaudeRegistration: { registration }
    )
    runtime.macOSVersion = { macOSVersion }
    runtime.monotonicNowMs = monotonicNowMs
    runtime.latestReleaseLookup = latestReleaseLookup
    runtime.logicApps = {
        [SetupDoctor.LogicAppInfo(path: "/Applications/Logic Pro.app", version: LogicProSupport.latestValidatedLogicVersion, bundleID: ServerConfig.logicProBundleID, readable: true)]
    }
    runtime.shareDirProbe = { .complete(path: "/opt/homebrew/share/logic-pro-mcp", source: "brew_pkgshare") }
    runtime.readClaudeDesktopRegistration = { .registered(command: "/Applications/Claude.app/Contents/MacOS/Claude") }
    runtime.keyCommandsPresetStaged = { true }
    runtime.mcuPortReferenceFound = { true }
    runtime.launchContext = { SetupDoctor.LaunchContextInfo(context: "terminal", responsibleHint: "Terminal") }
    runtime.tccCrossContextProbe = { .granted("terminal:accessibility=granted") }
    runtime.blockingDialogInfo = { nil }
    runtime.fileExistsAtPath = { _ in exists }
    runtime.isRegularFile = { _ in exists }
    return runtime
}

/// All-permissions-granted status (incl. System Events) — the v2 default for tests
/// that expect a healthy `.ok` aggregate. The 2-arg PermissionStatus init defaults
/// systemEvents to `.notVerifiable`, which (correctly) makes the report non-ok.
private func grantedPermissionStatus() -> PermissionChecker.PermissionStatus {
    .init(accessibility: true, automationLogicPro: true, systemEventsAutomation: .granted, postEventAccess: true)
}

private func allApprovals() -> [ManualValidationChannel: ManualValidationApproval] {
    Dictionary(uniqueKeysWithValues: ManualValidationChannel.allCases.map {
        ($0, ManualValidationApproval(approvedAt: Date(timeIntervalSince1970: 0), note: "test"))
    })
}

private func issue26RepositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Test func testSetupDoctorJSONContractStableCheckIDsAndOKAggregation() throws {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime()
    )

    #expect(report.schema == "logic_pro_mcp_doctor.v4")
    #expect(report.status == .ok)
    #expect(report.installSource == .homebrew)

    let ids = report.checks.map(\.id)
    #expect(ids == [
        "binary.path",
        "binary.executable",
        "binary.version",
        "install.source",
        "install.binary_inventory",
        "install.share_dir",
        "release.signature",
        "release.quarantine",
        "mcp.claude_code_registration",
        "mcp.registration_target",
        "mcp.claude_desktop_registration",
        "permissions.accessibility",
        "permissions.automation_logic_pro",
        "permissions.automation_system_events",
        "permissions.post_event_access",
        "permissions.launch_context",
        "permissions.tcc_cross_context",
        "system.macos_version",
        "logic.installation",
        "logic.version_support",
        "logic.application_state",
        "logic.blocking_dialog",
        // #457: keycmd_reference now precedes manual_validation because the approval
        // check declares it as a dependency, and a dependency has to have run before
        // blockingCause can see its status. The order is part of the JSON contract, so
        // this move is deliberate and recorded rather than absorbed silently.
        "channels.keycmd_reference",
        "channels.manual_validation",
        "channels.mcu_wiring_hint",
        "dependencies.click_fallback",
    ])

    let json = encodeJSON(report)
    let object = try #require(sharedJSONObject(json))
    #expect(object["schema"] as? String == "logic_pro_mcp_doctor.v4")
    #expect(object["status"] as? String == "ok")
    #expect(object["install_source"] as? String == "homebrew")
    #expect(object["version"] as? String == ServerConfig.serverVersion)
    #expect((object["checks"] as? [[String: Any]])?.count == ids.count)

    // Lock the per-check wire shape so a Codable key typo on a nested field cannot
    // ship green. All assertions are live (force-unwrap / != nil), never dead forms.
    let firstCheck = try #require((object["checks"] as? [[String: Any]])?.first)
    #expect(firstCheck["id"] as? String == "binary.path")
    #expect(firstCheck["domain"] as? String == "binary")
    let firstStatus = try #require(firstCheck["status"] as? String)
    #expect(firstStatus == "pass")
    let firstSummary = try #require(firstCheck["summary"] as? String)
    #expect(!firstSummary.isEmpty)
    #expect(firstCheck["evidence"] as? [String: Any] != nil)
    let remediation = try #require(firstCheck["remediation"] as? [String: Any])
    let remediationType = try #require(remediation["type"] as? String)
    #expect(remediationType == "none")
    #expect(remediation["value"] as? String != nil)
}

@Test func testSetupDoctorReportsActionableRemediationForNonPassStates() {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "full", "--client", "claude-code"],
        permissionStatus: .init(accessibilityState: .notGranted, automationState: .notVerifiable),
        approvals: [:],
        runtime: doctorRuntime(
            executablePath: nil,
            exists: false,
            executable: false,
            logicRunning: false,
            visibleWindow: false,
            commandHandler: { _, _ in nil }
        )
    )

    #expect(report.status == .failed)
    for check in report.checks where check.status != .pass && !check.optional {
        #expect(check.remediation.type != .none, "\(check.id) has no remediation type")
        #expect(!check.remediation.value.isEmpty, "\(check.id) has no remediation value")
    }
}

@Test func testMainEntrypointDoctorJSONDoesNotStartServerAndWritesStdout() async throws {
    let store = ManualValidationStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-cli-\(UUID().uuidString)")
            .appendingPathExtension("json")
    )
    try await store.approve(.midiKeyCommands, note: "test")
    try await store.approve(.scripter, note: "test")

    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionCheck: { grantedPermissionStatus() },
        serverFactory: {
            Issue.record("Server should not start for doctor")
            return DoctorMockMainServer()
        },
        approvalStoreFactory: { store },
        doctorRuntime: doctorRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 0)
    #expect(stderr.isEmpty)
    let json = try #require(sharedJSONObject(stdout))
    #expect(json["schema"] as? String == "logic_pro_mcp_doctor.v4")
    #expect(json["status"] as? String == "ok")
}

@Test func testMainEntrypointDoctorHumanOutputIncludesStableIDs() async {
    var stdout = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "doctor"],
        permissionCheck: { grantedPermissionStatus() },
        serverFactory: {
            Issue.record("Server should not start for doctor")
            return DoctorMockMainServer()
        },
        approvalStoreFactory: {
            ManualValidationStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("doctor-human-\(UUID().uuidString)")
                    .appendingPathExtension("json")
            )
        },
        doctorRuntime: doctorRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { _ in }
    )

    #expect(exitCode == 0)
    #expect(stdout.contains("Logic Pro MCP doctor"))
    #expect(stdout.contains("binary.path"))
    #expect(stdout.contains("mcp.claude_code_registration"))
}

@Test func testSetupDocsContainEveryDoctorRemediationAnchor() throws {
    let setup = try String(
        contentsOf: issue26RepositoryRootURL().appendingPathComponent("docs/SETUP.md"),
        encoding: .utf8
    )

    for anchor in SetupDoctor.remediationAnchorsByCheckID.values.sorted() {
        let id = anchor.replacingOccurrences(of: "docs/SETUP.md#", with: "")
        #expect(setup.contains("id=\"\(id)\""), "Missing remediation anchor \(anchor)")
    }
}

// MARK: - Install-source classification

@Test func testDoctorUpdateAndShareDirRemediationUsesInstallSource() throws {
    let cases: [(
        source: SetupDoctor.InstallSource,
        executablePath: String,
        updateType: SetupDoctor.RemediationType,
        updateValue: String,
        shareType: SetupDoctor.RemediationType,
        shareValue: String
    )] = [
        (
            .homebrew,
            "/opt/homebrew/bin/LogicProMCP",
            .command,
            "brew upgrade logic-pro-mcp",
            .command,
            "brew reinstall logic-pro-mcp"
        ),
        (
            .sourceBuild,
            "/Users/x/logic-pro-mcp/.build/release/LogicProMCP",
            .command,
            "git pull && swift build -c release",
            .command,
            "git pull && swift build -c release"
        ),
        (
            .releaseBinary,
            "/usr/local/bin/LogicProMCP",
            .docs,
            "Download and replace the pinned LogicProMCP release binary.",
            .docs,
            "Reinstall from the pinned LogicProMCP release package to restore helper assets."
        ),
        (
            .unknown,
            "/Users/x/bin/LogicProMCP",
            .docs,
            "docs/SETUP.md#doctor-updateslatest-release",
            .docs,
            "docs/SETUP.md#doctor-installshare-dir"
        ),
    ]

    for testCase in cases {
        var runtime = doctorRuntime(
            executablePath: testCase.executablePath,
            latestReleaseLookup: { .found(version: "v99.0.0") },
            commandHandler: { executable, arguments in
                if testCase.source == .homebrew,
                   (executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew"),
                   arguments == ["list", "--versions", "logic-pro-mcp"] {
                    return .init(exitCode: 0, stdout: "logic-pro-mcp \(ServerConfig.serverVersion)\n", stderr: "")
                }
                return nil
            }
        )
        runtime.shareDirProbe = {
            .missing(path: "/tmp/logic-pro-mcp-share", source: "registered_env", files: ["logic_bounce.py"])
        }
        let report = SetupDoctor.generate(
            arguments: ["LogicProMCP", "doctor", "--json", "--check-updates", "--client", "claude-code"],
            permissionStatus: grantedPermissionStatus(),
            approvals: allApprovals(),
            runtime: runtime
        )
        let update = try #require(report.checks.first { $0.id == "updates.latest_release" })
        let share = try #require(report.checks.first { $0.id == "install.share_dir" })
        let json = encodeJSON(report)
        let object = try #require(sharedJSONObject(json))
        let encodedChecks = try #require(object["checks"] as? [[String: Any]])
        let encodedUpdate = try #require(encodedChecks.first { $0["id"] as? String == "updates.latest_release" })
        let encodedShare = try #require(encodedChecks.first { $0["id"] as? String == "install.share_dir" })
        let encodedUpdateRemediation = try #require(encodedUpdate["remediation"] as? [String: Any])
        let encodedShareRemediation = try #require(encodedShare["remediation"] as? [String: Any])
        let human = SetupDoctor.renderHuman(report, useColor: false)

        #expect(report.installSource == testCase.source)
        #expect(update.remediation.type == testCase.updateType)
        #expect(update.remediation.value == testCase.updateValue)
        #expect(share.remediation.type == testCase.shareType)
        #expect(share.remediation.value == testCase.shareValue)
        #expect(report.fixPlan.contains("updates.latest_release"))
        #expect(report.fixPlan.contains("install.share_dir"))
        #expect(encodedUpdateRemediation["value"] as? String == testCase.updateValue)
        #expect(encodedShareRemediation["value"] as? String == testCase.shareValue)
        #expect(human.contains(testCase.updateValue))
        #expect(human.contains(testCase.shareValue))
        if testCase.source != .homebrew {
            #expect(!update.remediation.value.contains("brew "))
            #expect(!share.remediation.value.contains("brew "))
        }
    }
}

@Test func testSetupDoctorClassifiesSourceBuildEvenWhenBrewProbeSucceeds() throws {
    // .build path component must win over a succeeding brew probe (precedence pin).
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(executablePath: "/Users/x/proj/.build/release/LogicProMCP")
    )
    let src = report.installSource
    #expect(src == .sourceBuild)
    let object = try #require(sharedJSONObject(encodeJSON(report)))
    #expect(object["install_source"] as? String == "source_build")
}

@Test func testDoctorSourceBuildDoesNotSuggestBrewUpgrade() throws {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(
            executablePath: "/Users/x/logic-pro-mcp/.build/release/LogicProMCP",
            commandHandler: { executable, arguments in
                if executable == "/usr/bin/codesign" {
                    return .init(exitCode: 0, stdout: "", stderr: "")
                }
                if executable == "/usr/bin/xattr" {
                    return .init(exitCode: 1, stdout: "", stderr: "No such xattr")
                }
                if executable == "/usr/bin/lipo" {
                    return .init(exitCode: 0, stdout: "arm64\n", stderr: "")
                }
                if executable == "/usr/bin/strings", arguments.count == 2 {
                    return .init(exitCode: 0, stdout: "0.0.1\n", stderr: "")
                }
                if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew",
                   arguments == ["list", "--versions", "logic-pro-mcp"] {
                    return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
                }
                return nil
            }
        )
    )
    let inventory = try #require(report.checks.first { $0.id == "install.binary_inventory" })
    #expect(report.installSource == .sourceBuild)
    #expect(inventory.status == .warn)
    #expect(inventory.remediation.type == .command)
    #expect(inventory.remediation.value.contains("swift build -c release"))
    #expect(!inventory.remediation.value.contains("brew upgrade"))
}

@Test func testSetupDoctorClassifiesReleaseBinaryWhenBrewProbeFails() {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(
            executablePath: "/opt/homebrew/bin/LogicProMCP",
            commandHandler: { _, _ in nil }
        )
    )
    let src = report.installSource
    #expect(src == .releaseBinary)
    let installCheck = try? #require(report.checks.first { $0.id == "install.source" })
    let status = installCheck?.status
    #expect(status == .pass)
}

@Test func testSetupDoctorClassifiesUnknownWhenNoSignalMatches() throws {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "full"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(
            executablePath: "/Users/x/bin/LogicProMCP",
            commandHandler: { _, _ in nil }
        )
    )
    let src = report.installSource
    #expect(src == .unknown)
    let installCheck = try #require(report.checks.first { $0.id == "install.source" })
    #expect(installCheck.status == .warn)
    #expect(installCheck.remediation.type == .docs)
}

@Test func testSetupDoctorDoesNotMisclassifyDotBuildSuffixDirectoryAsSourceBuild() {
    // A directory whose component merely ENDS in .build (not the SwiftPM `.build`
    // component) must NOT be classified as source_build.
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(
            executablePath: "/Users/x/my.build/release/LogicProMCP",
            commandHandler: { _, _ in nil }
        )
    )
    let src = report.installSource
    #expect(src == .unknown)
    #expect(src != .sourceBuild)
}

@Test func testSetupDoctorDetectsHomebrewViaCanonicalBrewPathWithStrippedEnvPath() {
    // brew is NOT resolvable via /usr/bin/env (stripped PATH), only at its canonical
    // absolute path — doctor must still classify .homebrew.
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(
            executablePath: "/opt/homebrew/bin/LogicProMCP",
            commandHandler: { executable, arguments in
                if executable == "/opt/homebrew/bin/brew",
                   arguments == ["list", "--versions", "logic-pro-mcp"] {
                    return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
                }
                return nil
            }
        )
    )
    let src = report.installSource
    #expect(src == .homebrew)
}

// MARK: - Quarantine outcome distinction

@Test func testReleaseQuarantineReportsPassOnlyWhenAttributeAbsent() throws {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(commandHandler: { executable, arguments in
            if executable == "/usr/bin/codesign" {
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/xattr" {
                return .init(exitCode: 1, stdout: "", stderr: "No such xattr")
            }
            if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew" {
                return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
            }
            return nil
        })
    )
    let quarantine = try #require(report.checks.first { $0.id == "release.quarantine" })
    #expect(quarantine.status == .pass)
    #expect(quarantine.summary == "Binary is not quarantined.")
}

@Test func testReleaseQuarantineReportsWarnWhenAttributePresent() throws {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(commandHandler: { executable, _ in
            if executable == "/usr/bin/codesign" {
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/xattr" {
                return .init(exitCode: 0, stdout: "0081;...;Safari;\n", stderr: "")
            }
            if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew" {
                return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
            }
            return nil
        })
    )
    let quarantine = try #require(report.checks.first { $0.id == "release.quarantine" })
    #expect(quarantine.status == .warn)
    #expect(quarantine.summary == "Binary has a macOS quarantine attribute.")
    #expect(quarantine.remediation.type == .command)
}

@Test func testDoctorRemediationShellQuotesPaths() throws {
    let path = "/Users/x/My Build/LogicProMCP"
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(
            executablePath: path,
            executable: false,
            commandHandler: { executable, _ in
                if executable == "/usr/bin/codesign" {
                    return .init(exitCode: 0, stdout: "", stderr: "")
                }
                if executable == "/usr/bin/xattr" {
                    return .init(exitCode: 0, stdout: "0081;Safari;\n", stderr: "")
                }
                return nil
            }
        )
    )
    let executable = try #require(report.checks.first { $0.id == "binary.executable" })
    let quarantine = try #require(report.checks.first { $0.id == "release.quarantine" })
    #expect(executable.remediation.value == "chmod +x '\(path)'")
    #expect(quarantine.remediation.value == "xattr -d com.apple.quarantine '\(path)'")
}

@Test func testDoctorXattrEvidenceKeepsStdoutStderrSummary() throws {
    let longError = String(repeating: "permission denied ", count: 400)
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(commandHandler: { executable, _ in
            if executable == "/usr/bin/codesign" {
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/xattr" {
                return .init(exitCode: 0, stdout: "0081;Safari;\n", stderr: longError)
            }
            return nil
        })
    )
    let quarantine = try #require(report.checks.first { $0.id == "release.quarantine" })
    #expect(quarantine.evidence["exit_code"] == "0")
    #expect(quarantine.evidence["stdout"] == "present")
    #expect(quarantine.evidence["stdout_truncated"] == "false")
    #expect(quarantine.evidence["stderr"] == "present")
    #expect(quarantine.evidence["stderr_truncated"] == "true")
}

@Test func testDoctorCodesignEvidenceKeepsStdoutStderrSummary() throws {
    let longOutput = String(repeating: "authority ", count: 600)
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(commandHandler: { executable, _ in
            if executable == "/usr/bin/codesign" {
                return .init(exitCode: 1, stdout: longOutput, stderr: "invalid signature\n")
            }
            if executable == "/usr/bin/xattr" {
                return .init(exitCode: 1, stdout: "", stderr: "No such xattr")
            }
            return nil
        })
    )
    let signature = try #require(report.checks.first { $0.id == "release.signature" })
    #expect(signature.status == .warn)
    #expect(signature.evidence["exit_code"] == "1")
    #expect(signature.evidence["stdout"] == "present")
    #expect(signature.evidence["stdout_truncated"] == "true")
    #expect(signature.evidence["stderr"] == "present")
    #expect(signature.evidence["stderr_truncated"] == "false")
}

@Test func testReleaseQuarantineReportsWarnWhenStateUndeterminable() throws {
    // Non-zero exit that is NOT the recognized "No such xattr" must NOT be reported
    // as a clean pass — it conflates "not quarantined" with "could not determine".
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(commandHandler: { executable, _ in
            if executable == "/usr/bin/codesign" {
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if executable == "/usr/bin/xattr" {
                return .init(exitCode: 13, stdout: "", stderr: "Operation not permitted")
            }
            if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew" {
                return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
            }
            return nil
        })
    )
    let quarantine = try #require(report.checks.first { $0.id == "release.quarantine" })
    #expect(quarantine.status == .warn)
    #expect(quarantine.summary == "Quarantine state could not be determined.")
    #expect(quarantine.evidence["exit_code"] == "13")
}

@Test func testDoctorUnknownLaunchContextIsExplainedButAggregateNeutral() throws {
    var runtime = doctorRuntime()
    runtime.launchContext = {
        SetupDoctor.LaunchContextInfo(context: "unknown", responsibleHint: "unknown")
    }
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: runtime
    )
    let launch = try #require(report.checks.first { $0.id == "permissions.launch_context" })
    #expect(report.status == .ok)
    #expect(launch.status == .pass)
    #expect(launch.summary.localizedCaseInsensitiveContains("unknown"))
    #expect(launch.summary.localizedCaseInsensitiveContains("responsible process"))
    #expect(launch.summary.localizedCaseInsensitiveContains("Terminal"))
    #expect(SetupDoctor.renderHuman(report, useColor: false).contains("Launch context is unknown"))
}

// MARK: - Claude registration (config-based, read-only)

@Test func testClaudeRegistrationPassWhenConfigHasMatchingEntry() throws {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(registration: .registered(command: "/usr/local/bin/some-wrapper/LogicProMCP"))
    )
    let registration = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })
    #expect(registration.status == .pass)
    #expect(registration.evidence["command"] == "/usr/local/bin/some-wrapper/LogicProMCP")
    #expect(registration.evidence["match_kind"] == "name_and_command")
}

@Test func testClaudeRegistrationWarnWhenConfigHasNoMatchingEntry() throws {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(registration: .notRegistered)
    )
    let registration = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })
    #expect(registration.status == .warn)
    #expect(registration.evidence["match_kind"] == "none")
    #expect(registration.remediation.type == .command)
    #expect(!registration.remediation.value.isEmpty)
}

@Test func testClaudeRegistrationManualWithConfigReasonWhenUnreadable() throws {
    // The config-unavailable path must say the CONFIG could not be read — NOT that
    // the Claude CLI was unavailable.
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-code"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(registration: .configUnavailable(reason: "config file not found at /x/.claude.json"))
    )
    let registration = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })
    #expect(registration.status == .manual)
    #expect(registration.summary.localizedCaseInsensitiveContains("config"))
    #expect(!registration.summary.localizedCaseInsensitiveContains("CLI"))
    #expect(registration.evidence["reason"] == "config file not found at /x/.claude.json")
}

@Test func testProductionClaudeRegistrationParsesTopLevelEntry() {
    let json = """
    {"mcpServers":{"logic-pro":{"type":"stdio","command":"/Users/x/bin/LogicProMCP","args":[]}}}
    """
    let result = registrationFromTemporaryConfig(json)
    #expect(result == .registered(command: "/Users/x/bin/LogicProMCP"))
}

@Test func testProductionClaudeRegistrationParsesProjectScopedEntry() {
    let json = """
    {"projects":{"/p":{"mcpServers":{"logic-pro-mcp":{"command":"/opt/homebrew/bin/LogicProMCP"}}}}}
    """
    let result = registrationFromTemporaryConfig(json)
    #expect(result == .registered(command: "/opt/homebrew/bin/LogicProMCP"))
}

@Test func testProductionClaudeRegistrationReportsNameOnlyWhenCommandDoesNotMatch() {
    let json = """
    {"mcpServers":{"logic-pro":{"command":"/usr/bin/other-tool"},"context7":{"command":"npx"}}}
    """
    let result = registrationFromTemporaryConfig(json)
    #expect(result == .nameOnly(name: "logic-pro", command: "/usr/bin/other-tool"))
}

@Test func testProductionClaudeRegistrationConfigUnavailableOnGarbage() {
    let result = registrationFromTemporaryConfig("not json at all {{{")
    guard case .configUnavailable = result else {
        Issue.record("Expected configUnavailable, got \(result)")
        return
    }
}

// MARK: - runProductionCommand (production path) — pipe drain + spawn distinction

@Test func testProductionCommandReturnsFullStdoutBeyondPipeBuffer() throws {
    // >64KB output would deadlock a read-after-exit implementation; the concurrent
    // drain must return the full payload non-nil.
    let byteCount = 256 * 1024
    let result = SetupDoctor.runProductionCommandForTesting(
        executable: "/bin/sh",
        arguments: ["-c", "head -c \(byteCount) /dev/zero | tr '\\0' 'a'"],
        timeout: 10.0
    )
    let output = try #require(result.output)
    #expect(output.stdout.count == byteCount)
    #expect(output.exitCode == 0)
}

@Test func testProductionCommandReportsSpawnFailureForMissingExecutable() throws {
    let result = SetupDoctor.runProductionCommandForTesting(
        executable: "/nonexistent/definitely/not/here",
        arguments: [],
        timeout: 2.0
    )
    guard case .spawnFailed = result else {
        Issue.record("Expected spawnFailed, got \(result)")
        return
    }
    #expect(result.output == nil)
}

@Test func testProductionCommandReportsTimeoutForSlowChild() throws {
    let result = SetupDoctor.runProductionCommandForTesting(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 5"],
        timeout: 0.3
    )
    #expect(result == .timedOut)
    #expect(result.output == nil)
}

// MARK: - Entrypoint exit-code contract

@Test func testMainEntrypointDoctorExitsOneAndReportsFailedStatus() async throws {
    var stdout = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "full"],
        permissionCheck: { .init(accessibilityState: .notGranted, automationState: .notVerifiable) },
        serverFactory: {
            Issue.record("Server should not start for doctor")
            return DoctorMockMainServer()
        },
        approvalStoreFactory: {
            ManualValidationStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("doctor-failed-\(UUID().uuidString)")
                    .appendingPathExtension("json")
            )
        },
        doctorRuntime: doctorRuntime(
            executablePath: nil,
            exists: false,
            executable: false,
            logicRunning: false,
            visibleWindow: false,
            registration: .notRegistered,
            commandHandler: { _, _ in nil }
        ),
        writeStdout: { stdout += $0 },
        writeStderr: { _ in }
    )

    #expect(exitCode == 1)
    let json = try #require(sharedJSONObject(stdout))
    #expect(json["status"] as? String == "failed")
}

@Test func testMainEntrypointDoctorExitsZeroOnManualActionRequired() async throws {
    // Manual channels unapproved -> manual_action_required -> exit 0 (do not fail CI
    // just because operator approvals are outstanding).
    var stdout = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "full"],
        permissionCheck: { grantedPermissionStatus() },
        serverFactory: {
            Issue.record("Server should not start for doctor")
            return DoctorMockMainServer()
        },
        approvalStoreFactory: {
            ManualValidationStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("doctor-manual-\(UUID().uuidString)")
                    .appendingPathExtension("json")
            )
        },
        doctorRuntime: doctorRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { _ in }
    )

    #expect(exitCode == 0)
    let json = try #require(sharedJSONObject(stdout))
    #expect(json["status"] as? String == "manual_action_required")
}

@Test func testMainEntrypointDoctorExitsZeroOnDegraded() async throws {
    // A warn (codesign uncheckable) with all manual channels approved and no fail
    // -> degraded -> exit 0.
    var stdout = ""
    let store = ManualValidationStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-degraded-\(UUID().uuidString)")
            .appendingPathExtension("json")
    )
    try await store.approve(.midiKeyCommands, note: "test")
    try await store.approve(.scripter, note: "test")

    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionCheck: { grantedPermissionStatus() },
        serverFactory: {
            Issue.record("Server should not start for doctor")
            return DoctorMockMainServer()
        },
        approvalStoreFactory: { store },
        doctorRuntime: doctorRuntime(commandHandler: { executable, arguments in
            if executable == "/usr/bin/codesign" { return nil } // -> release.signature warn
            if executable == "/usr/bin/xattr" {
                return .init(exitCode: 1, stdout: "", stderr: "No such xattr")
            }
            if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew",
               arguments == ["list", "--versions", "logic-pro-mcp"] {
                return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
            }
            return nil
        }),
        writeStdout: { stdout += $0 },
        writeStderr: { _ in }
    )

    #expect(exitCode == 0)
    let json = try #require(sharedJSONObject(stdout))
    #expect(json["status"] as? String == "degraded")
}

// MARK: - aggregateStatus precedence

@Test func testAggregateStatusManualOutranksWarn() {
    // logic not running -> logic.application_state manual; codesign nil -> release
    // .signature warn. manual must win.
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(
            logicRunning: false,
            visibleWindow: false,
            commandHandler: { executable, arguments in
                if executable == "/usr/bin/codesign" { return nil }
                if executable == "/usr/bin/xattr" {
                    return .init(exitCode: 1, stdout: "", stderr: "No such xattr")
                }
                if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew",
                   arguments == ["list", "--versions", "logic-pro-mcp"] {
                    return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
                }
                return nil
            }
        )
    )
    #expect(report.status == .manualActionRequired)
}

@Test func testAggregateStatusWarnWithoutFailOrManualIsDegraded() {
    let report = SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: grantedPermissionStatus(),
        approvals: allApprovals(),
        runtime: doctorRuntime(commandHandler: { executable, arguments in
            if executable == "/usr/bin/codesign" { return nil } // -> warn
            if executable == "/usr/bin/xattr" {
                return .init(exitCode: 1, stdout: "", stderr: "No such xattr")
            }
            if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew",
               arguments == ["list", "--versions", "logic-pro-mcp"] {
                return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
            }
            return nil
        })
    )
    #expect(report.status == .degraded)
}

private func registrationFromTemporaryConfig(_ json: String) -> SetupDoctor.ClaudeRegistration {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("doctor-config-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let configURL = dir.appendingPathComponent(".claude.json")
    try? Data(json.utf8).write(to: configURL)
    defer { try? FileManager.default.removeItem(at: dir) }
    return SetupDoctor.readClaudeRegistrationForTesting(configURL: configURL)
}

// MARK: - dependencies.click_fallback — native-only semantics (coordinate-free campaign)

/// The external click-tool fallback was retired: a PRESENT external tool must
/// no longer mask a PostEvent denial as a passing click path (that was a
/// false-green about server capability). Warn is driven by PostEvent alone.
@Test func clickFallbackWarnsOnPostEventDenialEvenWithExternalToolPresent() {
    let runtime = doctorRuntime(executable: true)   // every path "is executable" → tool present
    let status = PermissionChecker.PermissionStatus(
        accessibility: true, automationLogicPro: true, postEventAccess: false
    )
    let check = SetupDoctor.clickFallbackCheck(runtime: runtime, permissionStatus: status)
    #expect(check.status == .warn)
    #expect(check.evidence["native_click"] == "denied")
}

@Test func clickFallbackPassesOnPostEventGrantWithoutExternalTool() {
    let runtime = doctorRuntime(executable: false)  // tool absent everywhere
    let status = PermissionChecker.PermissionStatus(
        accessibility: true, automationLogicPro: true, postEventAccess: true
    )
    let check = SetupDoctor.clickFallbackCheck(runtime: runtime, permissionStatus: status)
    #expect(check.status == .pass)
    #expect(check.evidence["native_click"] == "available")
}
