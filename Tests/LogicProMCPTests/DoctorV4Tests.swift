import Foundation
import Testing
@testable import LogicProMCP

private func doctorV4Runtime(
    executablePath: String? = "/opt/homebrew/bin/LogicProMCP",
    registration: SetupDoctor.ClaudeRegistration = .registered(command: "/opt/homebrew/bin/LogicProMCP"),
    desktopRegistration: SetupDoctor.ClaudeRegistration = .registered(command: "/Applications/Claude.app/Contents/MacOS/Claude"),
    launchContext: SetupDoctor.LaunchContextInfo = .init(context: "terminal", responsibleHint: "Terminal"),
    macOSVersion: OperatingSystemVersion? = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
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
            return .init(exitCode: 0, stdout: "\(ServerConfig.versionMarker)\n", stderr: "")
        }
        if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew",
           arguments == ["list", "--versions", "logic-pro-mcp"] {
            return .init(exitCode: 0, stdout: "logic-pro-mcp \(ServerConfig.serverVersion)\n", stderr: "")
        }
        return nil
    }
) -> SetupDoctor.Runtime {
    var runtime = SetupDoctor.Runtime(
        resolveExecutablePath: { _ in executablePath },
        fileExists: { _ in true },
        isExecutableFile: { _ in true },
        logicProRunning: { true },
        logicProHasVisibleWindow: { true },
        runCommand: { executable, arguments in
            commandHandler(executable, arguments).map(SetupDoctor.CommandResult.completed)
                ?? .spawnFailed("test_command_unavailable")
        },
        readClaudeRegistration: { registration }
    )
    runtime.macOSVersion = { macOSVersion }
    runtime.logicApps = {
        [SetupDoctor.LogicAppInfo(path: "/Applications/Logic Pro.app", version: LogicProSupport.latestValidatedLogicVersion, bundleID: ServerConfig.logicProBundleID, readable: true)]
    }
    runtime.shareDirProbe = { .complete(path: "/opt/homebrew/share/logic-pro-mcp", source: "brew_pkgshare") }
    runtime.readClaudeDesktopRegistration = { desktopRegistration }
    runtime.keyCommandsPresetStaged = { true }
    runtime.mcuPortReferenceFound = { true }
    runtime.launchContext = { launchContext }
    runtime.tccCrossContextProbe = { .granted("terminal:accessibility=granted") }
    runtime.blockingDialogInfo = { nil }
    runtime.fileExistsAtPath = { path in
        path == "/opt/homebrew/bin/LogicProMCP" || path == "/usr/local/bin/LogicProMCP"
    }
    runtime.isRegularFile = runtime.fileExistsAtPath
    runtime.isDirectory = { _ in true }
    return runtime
}

private func doctorV4Permissions() -> PermissionChecker.PermissionStatus {
    .init(accessibility: true, automationLogicPro: true, systemEventsAutomation: .granted, postEventAccess: true)
}

private func doctorV4Approvals() -> [ManualValidationChannel: ManualValidationApproval] {
    Dictionary(uniqueKeysWithValues: ManualValidationChannel.allCases.map {
        ($0, ManualValidationApproval(approvedAt: Date(timeIntervalSince1970: 0), note: "test"))
    })
}

private func doctorV4Report(
    arguments: [String] = ["LogicProMCP", "doctor", "--json"],
    runtime: SetupDoctor.Runtime = doctorV4Runtime(),
    approvals: [ManualValidationChannel: ManualValidationApproval] = doctorV4Approvals(),
    storeHealth: ManualValidationStoreHealth = .ok
) -> SetupDoctor.Report {
    SetupDoctor.generate(
        arguments: arguments,
        permissionStatus: doctorV4Permissions(),
        approvals: approvals,
        runtime: runtime,
        manualStoreHealth: storeHealth
    )
}

@Test func doctorV4SkipReasonRawValuesAreStable() {
    let expected = Set([
        "binary_path_missing",
        "bundle_unreadable",
        "client_not_selected",
        "full_disk_access_unavailable",
        "http_error",
        "intentionally_skipped",
        "offline",
        "parse_error",
        "path_dependent_unresolved",
        "principal_not_found",
        "profile_not_required",
        "share_dir_invalid",
        "source_build_no_share_dir",
        "source_unavailable",
        "tcc_query_unavailable",
        "tcc_schema_mismatch",
        "timeout",
        "version_unreadable",
    ])

    #expect(Set(SetupDoctor.DoctorSkipReason.allCases.map(\.rawValue)) == expected)
}

@Test func doctorV4SchemaProfilesAndCapabilitiesAreInJSON() throws {
    let report = doctorV4Report()
    #expect(report.schema == "logic_pro_mcp_doctor.v4")
    #expect(report.doctorProfile == .full)
    #expect(report.clientProfile == .claudeCode)
    #expect(Set(report.capabilities.keys) == Set([
        "core_transport",
        "track_management",
        "midi_import",
        "mixer_ax",
        "mixer_mcu",
        "project_lifecycle",
        "keycmd_only_ops",
        "legacy_scripter",
        "verified_plugin_applyback",
    ]))

    let object = try #require(sharedJSONObject(encodeJSON(report)))
    #expect(object["doctor_profile"] as? String == "full")
    #expect(object["client_profile"] as? String == "claude-code")
    #expect(object["client_profile_basis"] as? String == "registration_config")
    #expect(object["capabilities"] as? [String: Any] != nil)
}

@Test func doctorV4TerminalInfersClaudeCodeFromRegistrationConfig() throws {
    let report = doctorV4Report(
        runtime: doctorV4Runtime(
            registration: .registered(command: "/opt/homebrew/bin/LogicProMCP"),
            desktopRegistration: .notRegistered
        )
    )
    let registration = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })

    #expect(report.clientProfile == .claudeCode)
    #expect(report.clientProfileBasis == "registration_config")
    #expect(registration.status == .pass)
    #expect(registration.skipReason == nil)
}

@Test func doctorV4TerminalDefaultsToClaudeCodeWhenRegistrationIsMissing() throws {
    let report = doctorV4Report(
        runtime: doctorV4Runtime(
            registration: .notRegistered,
            desktopRegistration: .notRegistered
        )
    )
    let registration = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })
    let object = try #require(sharedJSONObject(encodeJSON(report)))

    #expect(report.clientProfile == .claudeCode)
    #expect(report.clientProfileBasis == "default_claude_code")
    #expect(registration.status == .warn)
    #expect(registration.skipReason == nil)
    #expect(object["client_profile_basis"] as? String == "default_claude_code")
}

@Test func doctorV4PartialClaudeRegistrationsExposeTargetedGuidance() throws {
    let cases: [(
        registration: SetupDoctor.ClaudeRegistration,
        matchKind: String,
        summaryFragment: String,
        remediationFragment: String
    )] = [
        (
            .nameOnly(name: "logic-pro-old", command: "/usr/bin/other"),
            "name_only",
            "name matches, but its command does not target LogicProMCP",
            "remove 'logic-pro-old'"
        ),
        (
            .commandOnly(name: "studio-tools", command: "/opt/homebrew/bin/LogicProMCP"),
            "command_only",
            "targets LogicProMCP, but its server name does not match logic-pro",
            "remove 'studio-tools'"
        ),
    ]

    for item in cases {
        let report = doctorV4Report(
            runtime: doctorV4Runtime(registration: item.registration)
        )
        let check = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })
        let object = try #require(sharedJSONObject(encodeJSON(report)))
        let checks = try #require(object["checks"] as? [[String: Any]])
        let encoded = try #require(checks.first { $0["id"] as? String == check.id })
        let output = SetupDoctor.renderHuman(report, mode: .verbose, useColor: false)

        #expect(check.status == .warn)
        #expect(report.clientProfile == .claudeCode)
        #expect(report.clientProfileBasis == "registration_config")
        let evidence = try #require(encoded["evidence"] as? [String: Any])
        #expect(evidence["match_kind"] as? String == item.matchKind)
        #expect(check.evidence["match_kind"] == item.matchKind)
        #expect(check.summary.contains(item.summaryFragment))
        #expect(check.remediation.value.contains(item.remediationFragment))
        #expect(output.contains(item.summaryFragment))
    }
}

@Test func doctorV4UnknownContextDefaultsToClaudeCodeWhenRegistrationIsMissing() throws {
    let report = doctorV4Report(
        runtime: doctorV4Runtime(
            registration: .notRegistered,
            desktopRegistration: .notRegistered,
            launchContext: .init(context: "unknown", responsibleHint: "unknown")
        )
    )
    let registration = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })

    #expect(report.clientProfile == .claudeCode)
    #expect(report.clientProfileBasis == "default_claude_code")
    #expect(registration.status == .warn)
    #expect(registration.skipReason == nil)
}

@Test func doctorV4ExplicitTerminalClientStillOverridesInference() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "terminal"],
        runtime: doctorV4Runtime(registration: .registered(command: "/opt/homebrew/bin/LogicProMCP"))
    )
    let registration = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })

    #expect(report.clientProfile == .terminal)
    #expect(report.clientProfileBasis == "explicit_flag")
    #expect(registration.status == .skipped)
    #expect(registration.skipReason == .clientNotSelected)
}

@Test func doctorV4SkippedChecksRequireBlockedByOrSkipReason() {
    let report = doctorV4Report(
        runtime: doctorV4Runtime(macOSVersion: nil),
        approvals: [:]
    )
    for check in report.checks where check.status == .skipped {
        #expect(
            check.blockedBy != nil || check.skipReason != nil,
            "\(check.id) skipped without blocked_by or skip_reason"
        )
    }
}

@Test func doctorV4VerboseRendererShowsSkipReason() {
    let report = doctorV4Report(
        runtime: doctorV4Runtime(macOSVersion: nil)
    )
    let output = SetupDoctor.renderHuman(report, mode: .verbose, useColor: false)
    #expect(output.contains("skip_reason: version_unreadable"))
}

@Test func doctorV4CoreProfileDoesNotRequireManualChannels() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "core"],
        approvals: [:]
    )
    let manual = try #require(report.checks.first { $0.id == "channels.manual_validation" })
    let object = try #require(sharedJSONObject(encodeJSON(report)))
    let checks = try #require(object["checks"] as? [[String: Any]])
    let encodedManual = try #require(checks.first { $0["id"] as? String == "channels.manual_validation" })
    #expect(manual.status == .skipped)
    #expect(manual.optional)
    #expect(manual.skipReason == .profileNotRequired)
    #expect(encodedManual["skip_reason"] as? String == "profile_not_required")
    #expect(report.status == .ok)
}

@Test func doctorV4FullProfileRequiresManualChannels() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "full"],
        approvals: [:]
    )
    let manual = try #require(report.checks.first { $0.id == "channels.manual_validation" })
    #expect(manual.status == .manual)
    #expect(manual.skipReason == nil)
    #expect(report.status == .manualActionRequired)
}

@Test func doctorV4IntentionalSkipDoesNotClaimCapabilityReady() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "keycmd"],
        approvals: [
            .midiKeyCommands: ManualValidationApproval(
                approvedAt: Date(timeIntervalSince1970: 0),
                note: "operator does not use key commands",
                kind: .intentionallySkipped
            ),
        ]
    )

    let manual = try #require(report.checks.first { $0.id == "channels.manual_validation" })
    #expect(manual.status == .skipped)
    #expect(manual.skipReason == .intentionallySkipped)
    #expect(!manual.optional)
    #expect(report.status == .degraded)
    #expect(report.capabilities["keycmd_only_ops"]?.status == .unknownLiveVerifyRequired)
}

@Test func doctorV4CursorClientDoesNotRequireClaudeRegistration() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "cursor"],
        runtime: doctorV4Runtime(registration: .notRegistered, desktopRegistration: .notRegistered)
    )
    let claude = try #require(report.checks.first { $0.id == "mcp.claude_code_registration" })
    #expect(claude.status == .skipped)
    #expect(claude.optional)
    #expect(claude.skipReason == .clientNotSelected)
    #expect(report.clientProfile == .cursor)
}

@Test func doctorV4ExplicitClaudeDesktopAbsentConfigIsRequiredAndNotOk() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--client", "claude-desktop"],
        runtime: doctorV4Runtime(
            registration: .notRegistered,
            desktopRegistration: .configUnavailable(reason: "config_absent")
        )
    )

    let desktop = try #require(report.checks.first { $0.id == "mcp.claude_desktop_registration" })
    let isOptional = desktop.optional
    #expect(desktop.status == .warn || desktop.status == .manual)
    #expect(isOptional == false)
    #expect(desktop.skipReason != .clientNotSelected)
    #expect(report.status != .ok)
}

@Test func doctorV4BareRegisteredCommandCanResolveThroughDoctorPath() throws {
    var runtime = doctorV4Runtime(
        registration: .registered(command: "logic-pro-mcp-dev"),
        launchContext: .init(context: "claude_code", responsibleHint: "claude")
    ) { executable, arguments in
        if executable == "/usr/bin/which", arguments == ["logic-pro-mcp-dev"] {
            return .init(exitCode: 0, stdout: "/tmp/LogicProMCP-dev\n", stderr: "")
        }
        if executable == "/usr/bin/strings", arguments.count == 2 {
            return .init(exitCode: 0, stdout: "\(ServerConfig.versionMarker)\n", stderr: "")
        }
        if executable == "/usr/bin/codesign" || executable == "/usr/bin/xattr" || executable == "/usr/bin/lipo" {
            return .init(exitCode: executable == "/usr/bin/xattr" ? 1 : 0, stdout: executable == "/usr/bin/lipo" ? "arm64\n" : "", stderr: executable == "/usr/bin/xattr" ? "No such xattr" : "")
        }
        if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew" {
            return .init(exitCode: 0, stdout: "logic-pro-mcp \(ServerConfig.serverVersion)\n", stderr: "")
        }
        return nil
    }
    runtime.fileExistsAtPath = { path in path == "/tmp/LogicProMCP-dev" }
    runtime.isRegularFile = runtime.fileExistsAtPath

    let report = doctorV4Report(runtime: runtime)
    let target = try #require(report.checks.first { $0.id == "mcp.registration_target" })
    #expect(target.status == .pass)
    #expect(target.evidence["resolution_basis"] == "doctor_path")
    #expect(target.evidence["resolved_path"] == "/tmp/LogicProMCP-dev")
}

@Test func doctorV4ManualStorePersistsIntentionalSkip() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("manual-skip-\(UUID().uuidString)")
        .appendingPathExtension("json")
    let store = ManualValidationStore(fileURL: fileURL)
    try await store.skip(.scripter, note: "not using legacy scripter")
    let decisions = await store.list()
    let scripter = try #require(decisions[.scripter])
    #expect(scripter.kind == .intentionallySkipped)
    #expect(!(await store.isApproved(.scripter)))
}

@Test func doctorV4ManualStoreCorruptionWarnsDoctor() {
    let report = doctorV4Report(storeHealth: .corrupt("json_decode_failed"))
    let manual = report.checks.first { $0.id == "channels.manual_validation" }
    #expect(manual?.status == .warn)
    #expect(manual?.evidence["store_health"] == "corrupt")
}

@Test func doctorV4SemanticVersionAndMarkerSniff() throws {
    let parsed = try #require(SetupDoctor.SemanticVersion("3.9.0"))
    #expect(parsed.major == 3)
    #expect(SetupDoctor.SemanticVersion("v") == nil)
    #expect(SetupDoctor.staticVersion(fromStringsOutput: "3.40.1\n\(ServerConfig.versionMarker)\n") == .version(ServerConfig.serverVersion))
    #expect(SetupDoctor.staticVersion(fromStringsOutput: "3.40.1\n3.9.0\n") == .indeterminate(["3.40.1", "3.9.0"]))
}

@Test func doctorV4CheckRegistryIDsAreUniqueAndAnchored() {
    let ids = SetupDoctor.checkDefinitions.map(\.id.rawValue)
    #expect(Set(ids).count == ids.count)
    #expect(Set(ids) == Set(SetupDoctor.DoctorCheckID.allCases.map(\.rawValue)))
    #expect(Set(SetupDoctor.remediationAnchorsByCheckID.keys).isSubset(of: Set(ids)))
    #expect(SetupDoctor.checkDefinitionByID["updates.latest_release"]?.optionalByDefault == true)
}

@Test func doctorV4CheckRegistryCoversRenderedChecksAndOrder() {
    var runtime = doctorV4Runtime()
    runtime.latestReleaseLookup = { .found(version: ServerConfig.serverVersion) }

    let report = doctorV4Report(runtime: runtime)
    let reportIDs = report.checks.map(\.id)
    let registryIDs = Set(SetupDoctor.orderedCheckIDs)
    let orderedRenderedIDs = SetupDoctor.orderedCheckIDs.filter { Set(reportIDs).contains($0) }

    #expect(Set(reportIDs).isSubset(of: registryIDs))
    #expect(reportIDs == orderedRenderedIDs)
}

@Test func doctorV4DroppedRequiredCheckIsSynthesizedAsFailure() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "core", "--client", "claude-code"],
        approvals: [:]
    )
    let dropped = report.checks.filter { $0.id != "binary.executable" }
    let closed = SetupDoctor.checksClosingRequiredGaps(
        dropped,
        profile: report.doctorProfile,
        clientProfile: report.clientProfile
    )
    let synthesized = try #require(closed.first { $0.id == "binary.executable" })
    let isOptional = synthesized.optional
    #expect(synthesized.status == .fail)
    #expect(isOptional == false)
    #expect(synthesized.evidence["reason"] == "required_check_missing")

    let requiredIDs = SetupDoctor.requiredCheckIDs(
        for: report.doctorProfile,
        clientProfile: report.clientProfile
    )
    let scoped = closed.filter { requiredIDs.contains($0.id) && !$0.optional }
    #expect(SetupDoctor.aggregateStatus(scoped) != .ok)
}

@Test func doctorV4CapabilityChecksAreConsistentWithRegistryGroups() throws {
    let report = doctorV4Report()
    let grouped = Dictionary(grouping: SetupDoctor.checkDefinitions.flatMap { definition in
        definition.capabilityGroups.map { ($0, definition.id.rawValue) }
    }) { pair in
        pair.0
    }
    let registryCapabilityIDs = Set(grouped.keys)

    #expect(Set(report.capabilities.keys) == registryCapabilityIDs)
    for capabilityID in report.capabilities.keys.sorted() {
        let rendered = try #require(report.capabilities[capabilityID])
        let registryCheckIDs = (grouped[capabilityID] ?? []).map { $0.1 }
        #expect(rendered.checks == registryCheckIDs, "\(capabilityID) drifted from checkDefinitions.capabilityGroups")
    }
}

@Test func doctorV4BlockedByTableIsDerivedFromCheckRegistry() {
    #expect(
        SetupDoctor.blockedByDependencies["mcp.registration_target"] == ["mcp.claude_code_registration"]
    )
    #expect(SetupDoctor.checkDefinitionByID["mcp.registration_target"]?.dependencies.map(\.rawValue) == [
        "mcp.claude_code_registration",
    ])
}

@Test func doctorV4EvidenceBuilderAppliesPrivacyPolicies() {
    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("secret-project")
        .path
    let typed = SetupDoctor.buildEvidence([
        "hidden": .path(homePath, .hidden),
        "basename": .path(homePath, .basenameOnly),
        "relative": .path(homePath, .homeRelative),
        "secret": .sensitive,
    ])

    #expect(typed["hidden"] == "hidden")
    #expect(typed["basename"] == "secret-project")
    #expect(typed["relative"] == "~/secret-project")
    #expect(typed["secret"] == "redacted")

    let sanitized = SetupDoctor.sanitizedEvidence([
        "api_key": "abc123",
        "stderr": "token=abc123",
        "path": homePath,
    ])
    #expect(sanitized["api_key"] == "redacted")
    #expect(sanitized["stderr"] == "present")
    #expect(sanitized["path"] == "~/secret-project")
}

@Test func doctorV4ReportPrivacyScanRejectsHomePathsAndSecrets() throws {
    let homePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("private-bin/LogicProMCP")
        .path
    let runtime = doctorV4Runtime(
        executablePath: homePath,
        registration: .registered(command: homePath, environment: [
            "LOGIC_PRO_MCP_SHARE_DIR": homePath,
            "API_TOKEN": "token=super-secret",
        ])
    ) { executable, arguments in
        if executable == "/usr/bin/strings", arguments.count == 2 {
            return .init(exitCode: 0, stdout: "token=super-secret\n\(ServerConfig.versionMarker)\n", stderr: "token=super-secret")
        }
        if executable == "/usr/bin/codesign" || executable == "/usr/bin/xattr" || executable == "/usr/bin/lipo" {
            return .init(exitCode: executable == "/usr/bin/xattr" ? 1 : 0, stdout: executable == "/usr/bin/lipo" ? "arm64\n" : "", stderr: executable == "/usr/bin/xattr" ? "No such xattr" : "")
        }
        return nil
    }

    let encoded = encodeJSON(doctorV4Report(runtime: runtime))
    #expect(!encoded.contains(homePath))
    #expect(!encoded.contains("token=super-secret"))
}
