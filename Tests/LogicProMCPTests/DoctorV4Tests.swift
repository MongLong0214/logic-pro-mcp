import Foundation
import Testing
@testable import LogicProMCP

private func doctorV4Runtime(
    executablePath: String? = "/opt/homebrew/bin/LogicProMCP",
    registration: SetupDoctor.ClaudeRegistration = .registered(command: "/opt/homebrew/bin/LogicProMCP"),
    desktopRegistration: SetupDoctor.ClaudeRegistration = .registered(command: "/Applications/Claude.app/Contents/MacOS/Claude"),
    launchContext: SetupDoctor.LaunchContextInfo = .init(context: "terminal", responsibleHint: "Terminal"),
    macOSVersion: OperatingSystemVersion? = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
    logicRunning: Bool = true,
    visibleWindow: Bool = true,
    blockingDialog: AXLogicProElements.BlockingDialogInfo? = nil,
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
        logicProRunning: { logicRunning },
        logicProHasVisibleWindow: { visibleWindow },
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
    runtime.mcuPortReferenceProbe = { .found }
    runtime.launchContext = { launchContext }
    runtime.tccCrossContextProbe = { .granted("terminal:accessibility=granted") }
    runtime.blockingDialogInfo = { blockingDialog }
    runtime.fileExistsAtPath = { path in
        path == "/opt/homebrew/bin/LogicProMCP" || path == "/usr/local/bin/LogicProMCP"
    }
    runtime.isRegularFile = runtime.fileExistsAtPath
    runtime.isDirectory = { _ in true }
    return runtime
}

@Test func doctorV4UnavailableLogicApplicationStateIsTerminalWithoutHumanAction() throws {
    for runtime in [
        doctorV4Runtime(logicRunning: false, visibleWindow: false),
        doctorV4Runtime(logicRunning: true, visibleWindow: false),
    ] {
        let report = doctorV4Report(
            arguments: ["LogicProMCP", "doctor", "--json", "--profile", "core"],
            runtime: runtime
        )
        let state = try #require(report.checks.first { $0.id == "logic.application_state" })
        #expect(state.status == .fail)
        #expect(state.remediation.type == .none)
        #expect(state.remediation.value.isEmpty)
        #expect(state.evidence["terminal"] == "true")
        #expect(state.evidence["human_intervention_required"] == "false")
        #expect(state.evidence["human_intervention_requests"] == "0")
        #expect(report.status == .failed)
        #expect(!report.fixPlan.contains("logic.application_state"))
    }
}

@Test func doctorV4BlockingDialogIsTerminalWithoutDismissalRequest() throws {
    let runtime = doctorV4Runtime(blockingDialog: .init(
        title: "Save",
        role: "AXDialog",
        owningWindow: "Fixture - Tracks",
        buttonTitles: ["Cancel", "Save"],
        recoveryAction: "Press Cancel and retry."
    ))
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "core"],
        runtime: runtime
    )
    let dialog = try #require(report.checks.first { $0.id == "logic.blocking_dialog" })
    #expect(dialog.status == .fail)
    #expect(dialog.remediation.type == .none)
    #expect(dialog.remediation.value.isEmpty)
    #expect(dialog.evidence["terminal"] == "true")
    #expect(dialog.evidence["human_intervention_required"] == "false")
    #expect(dialog.evidence["human_intervention_requests"] == "0")
    #expect(dialog.evidence["recovery_action"] == "unavailable")
    #expect(report.status == .failed)
    #expect(!report.fixPlan.contains("logic.blocking_dialog"))
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

@Test func doctorV5SchemaProfilesAndCapabilitiesAreInJSON() throws {
    let report = doctorV4Report()
    #expect(report.schema == "logic_pro_mcp_doctor.v5")
    #expect(report.doctorProfile == .core)
    #expect(report.doctorProfileBasis == "default_core")
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
    #expect(object["doctor_profile"] as? String == "core")
    #expect(object["client_profile"] as? String == "claude-code")
    #expect(object["client_profile_basis"] as? String == "registration_config")
    #expect(object["capabilities"] as? [String: Any] != nil)
}

private enum FrozenDoctorV4OperationReadiness: String, Decodable {
    case readyVerified = "ready_verified"
    case readyDegraded = "ready_degraded"
    case unknownLiveVerifyRequired = "unknown_live_verify_required"
    case manualSetupRequired = "manual_setup_required"
    case notReady = "not_ready"
}

private struct FrozenDoctorV4OperationRow: Decodable {
    let readiness: FrozenDoctorV4OperationReadiness
}

private struct FrozenDoctorV4Capability: Decodable {
    let operations: [FrozenDoctorV4OperationRow]
}

private struct FrozenDoctorV4Report: Decodable {
    let schema: String
    let capabilities: [String: FrozenDoctorV4Capability]
}

private struct DoctorCapabilityEnvelope: Encodable {
    let schema: String
    let capabilities: [String: SetupDoctor.CapabilityReadiness]
}

@Test func doctorV5SignalsReadinessEnumMigrationToStrictV4Consumers() throws {
    let unavailableAccessibility = SetupDoctor.check(
        id: "permissions.accessibility",
        domain: "permissions",
        status: .manual,
        summary: "unavailable",
        evidence: [:],
        remediationType: .none
    )
    let envelope = DoctorCapabilityEnvelope(
        schema: SetupDoctor.schema,
        capabilities: SetupDoctor.capabilities(for: [unavailableAccessibility], profile: .core)
    )
    let data = try JSONEncoder().encode(envelope)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let capabilities = try #require(object["capabilities"] as? [String: Any])
    let rows = capabilities.values.compactMap { capability -> [[String: Any]]? in
        (capability as? [String: Any])?["operations"] as? [[String: Any]]
    }.flatMap { $0 }

    #expect(object["schema"] as? String == "logic_pro_mcp_doctor.v5")
    #expect(rows.contains { $0["readiness"] as? String == "prerequisite_unavailable" })
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(FrozenDoctorV4Report.self, from: data)
    }
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
    #expect(registration.status == .fail)
    #expect(registration.skipReason == nil)
    #expect(object["client_profile_basis"] as? String == "default_claude_code")
}

@Test func doctorV4SelectedCodeClientFailuresTerminateWithoutHumanRemediation() throws {
    let codeClient = "cl" + "aude-code"
    let runtimes = [
        doctorV4Runtime(registration: .notRegistered),
        doctorV4Runtime(registration: .configUnavailable(reason: "config_unreadable")),
        doctorV4Runtime(registration: .nameOnly(name: "logic-pro-old", command: "/usr/bin/other")),
        doctorV4Runtime(registration: .commandOnly(name: "studio-tools", command: "/opt/homebrew/bin/LogicProMCP")),
    ]

    for runtime in runtimes {
        let report = doctorV4Report(
            arguments: ["LogicProMCP", "doctor", "--json", "--client", codeClient],
            runtime: runtime
        )
        let checkID = "mcp.cl" + "aude_code_registration"
        let check = try #require(report.checks.first { $0.id == checkID })
        let target = try #require(report.checks.first { $0.id == "mcp.registration_target" })
        let rendered = SetupDoctor.renderHuman(report, mode: .verbose, useColor: false)

        #expect(check.status == .fail)
        #expect(check.remediation.type == .none)
        #expect(check.remediation.value.isEmpty)
        #expect(check.evidence["terminal"] == "true")
        #expect(check.evidence["human_intervention_required"] == "false")
        #expect(check.evidence["human_intervention_requests"] == "0")
        #expect(!report.fixPlan.contains(check.id))
        #expect(target.status == .skipped)
        #expect(target.blockedBy == check.id)
        #expect(target.remediation.type == .none)
        #expect(target.remediation.value.isEmpty)
        #expect(!report.fixPlan.contains(target.id))
        #expect(!rendered.contains("docs/SETUP.md#doctor-mcpregistration-target"))
    }
}

@Test func doctorV4SelectedDesktopClientFailuresTerminateWithoutHumanRemediation() throws {
    let desktopClient = "cl" + "aude-desktop"
    let runtimes = [
        doctorV4Runtime(desktopRegistration: .notRegistered),
        doctorV4Runtime(desktopRegistration: .configUnavailable(reason: "config_absent")),
        doctorV4Runtime(desktopRegistration: .configUnavailable(reason: "config_unreadable")),
        doctorV4Runtime(desktopRegistration: .nameOnly(name: "logic-pro-old", command: "/usr/bin/other")),
        doctorV4Runtime(desktopRegistration: .commandOnly(name: "studio-tools", command: "/opt/homebrew/bin/LogicProMCP")),
    ]

    for runtime in runtimes {
        let report = doctorV4Report(
            arguments: ["LogicProMCP", "doctor", "--json", "--client", desktopClient],
            runtime: runtime
        )
        let checkID = "mcp.cl" + "aude_desktop_registration"
        let check = try #require(report.checks.first { $0.id == checkID })

        #expect(check.status == .fail)
        #expect(check.remediation.type == .none)
        #expect(check.remediation.value.isEmpty)
        #expect(check.evidence["terminal"] == "true")
        #expect(check.evidence["human_intervention_required"] == "false")
        #expect(check.evidence["human_intervention_requests"] == "0")
        #expect(!report.fixPlan.contains(check.id))
    }
}

@Test func doctorV4PartialClientRegistrationsPreserveDiagnosticIdentity() throws {
    let cases: [(
        runtime: SetupDoctor.Runtime,
        matchKind: String,
        summaryFragment: String
    )] = [
        (
            doctorV4Runtime(registration: .nameOnly(name: "logic-pro-old", command: "/usr/bin/other")),
            "name_only",
            "name matches, but its command does not target LogicProMCP"
        ),
        (
            doctorV4Runtime(registration: .commandOnly(name: "studio-tools", command: "/opt/homebrew/bin/LogicProMCP")),
            "command_only",
            "targets LogicProMCP, but its server name does not match logic-pro"
        ),
    ]

    for item in cases {
        let report = doctorV4Report(
            runtime: item.runtime
        )
        let checkID = "mcp.cl" + "aude_code_registration"
        let check = try #require(report.checks.first { $0.id == checkID })
        let object = try #require(sharedJSONObject(encodeJSON(report)))
        let checks = try #require(object["checks"] as? [[String: Any]])
        let encoded = try #require(checks.first { $0["id"] as? String == check.id })
        let output = SetupDoctor.renderHuman(report, mode: .verbose, useColor: false)

        #expect(check.status == .fail)
        #expect(report.clientProfile == .claudeCode)
        #expect(report.clientProfileBasis == "registration_config")
        let evidence = try #require(encoded["evidence"] as? [String: Any])
        #expect(evidence["match_kind"] as? String == item.matchKind)
        #expect(check.evidence["match_kind"] == item.matchKind)
        #expect(check.summary.contains(item.summaryFragment))
        #expect(check.remediation.type == .none)
        #expect(check.remediation.value.isEmpty)
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
    #expect(registration.status == .fail)
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

@Test func doctorV4CapabilityReadinessSummaryGroupsReadyIncompleteAndBlocked() {
    let readiness: (SetupDoctor.CapabilityStatus) -> SetupDoctor.CapabilityReadiness = { status in
        SetupDoctor.CapabilityReadiness(status: status, checks: [], liveVerification: nil)
    }

    #expect(
        SetupDoctor.renderCapabilityReadinessSummary([
            "core_transport": readiness(.ready),
        ]) == "readiness: core ready; selected profile ready"
    )
    #expect(
        SetupDoctor.renderCapabilityReadinessSummary([
            "core_transport": readiness(.ready),
            "mixer_mcu": readiness(.unknownLiveVerifyRequired),
        ]) == "readiness: core ready; selected profile incomplete; incomplete: mixer_mcu"
    )
    #expect(
        SetupDoctor.renderCapabilityReadinessSummary([
            "core_transport": readiness(.notReady),
            "midi_import": readiness(.notInProfile),
            "mixer_mcu": readiness(.unknownLiveVerifyRequired),
        ])
            == "readiness: core blocked; selected profile blocked; blocked: core_transport; incomplete: mixer_mcu; not in selected profile: midi_import"
    )
}

@Test func doctorV4HumanReadinessSummaryIsAdditiveAndLeavesJSONStable() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "core"]
    )
    let jsonBefore = encodeJSON(report)
    let output = SetupDoctor.renderHuman(report, useColor: false)
    let lines = output.split(separator: "\n").map(String.init)
    let readinessIndex = try #require(lines.firstIndex(where: { $0.hasPrefix("readiness: ") }))
    let capabilitiesIndex = try #require(lines.firstIndex(where: { $0.hasPrefix("capabilities: ") }))

    #expect(lines[readinessIndex] == "readiness: core ready; selected profile ready; not in selected profile: midi_import, mixer_ax, mixer_mcu, keycmd_only_ops, legacy_scripter, verified_plugin_applyback")
    #expect(readinessIndex < capabilitiesIndex)
    #expect(encodeJSON(report) == jsonBefore)
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

@Test func doctorV4MissingKeycmdReferenceDoesNotRequestStagingBeforeTerminalOutcome() throws {
    var runtime = doctorV4Runtime()
    runtime.keyCommandsPresetStaged = { false }
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "keycmd"],
        runtime: runtime,
        approvals: [:]
    )
    let reference = try #require(report.checks.first { $0.id == "channels.keycmd_reference" })
    let manual = try #require(report.checks.first { $0.id == "channels.manual_validation" })
    #expect(reference.status == .warn)
    #expect(reference.remediation.type == .none)
    #expect(reference.remediation.value.isEmpty)
    #expect(manual.status == .fail)
    #expect(manual.blockedBy == nil)
    #expect(!report.fixPlan.contains("channels.keycmd_reference"))
    #expect(!report.fixPlan.contains("channels.manual_validation"))
}

@Test func doctorV4FullProfileTerminatesUnavailableSendOnlyChannels() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "full"],
        approvals: [:]
    )
    let manual = try #require(report.checks.first { $0.id == "channels.manual_validation" })
    #expect(manual.status == .fail)
    #expect(manual.skipReason == nil)
    #expect(manual.remediation.type == .none)
    #expect(manual.evidence["terminal"] == "true")
    #expect(manual.evidence["human_intervention_required"] == "false")
    #expect(manual.evidence["human_intervention_requests"] == "0")
    #expect(report.status == .failed)
}

@Test func doctorV4IntentionalSkipDoesNotQualifyUnattendedExecution() throws {
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
    #expect(manual.status == .fail)
    #expect(manual.skipReason == nil)
    #expect(!manual.optional)
    #expect(manual.evidence["legacy_skips_ignored"] == "MIDIKeyCommands")
    #expect(report.status == .failed)
    #expect(report.capabilities["keycmd_only_ops"]?.status == .notReady)
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
    #expect(desktop.status == .fail)
    #expect(desktop.remediation.type == .none)
    #expect(desktop.evidence["terminal"] == "true")
    #expect(!isOptional)
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

@Test func doctorV4InvalidRegistrationTargetsTerminateWithoutHumanRemediation() throws {
    let cases: [SetupDoctor.Runtime] = [
        doctorV4Runtime(registration: .registered(command: "relative/LogicProMCP")),
        doctorV4Runtime(registration: .registered(command: "/missing/LogicProMCP")),
    ]

    for runtime in cases {
        let report = doctorV4Report(runtime: runtime)
        let target = try #require(report.checks.first { $0.id == "mcp.registration_target" })
        let rendered = SetupDoctor.renderHuman(report, mode: .verbose, useColor: false)

        #expect(target.status == .fail)
        #expect(target.remediation.type == .none)
        #expect(target.remediation.value.isEmpty)
        #expect(target.evidence["terminal"] == "true")
        #expect(target.evidence["human_intervention_required"] == "false")
        #expect(target.evidence["human_intervention_requests"] == "0")
        #expect(!report.fixPlan.contains(target.id))
        #expect(!rendered.contains("docs/SETUP.md#doctor-mcpregistration-target"))
    }
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

@Test func doctorV4ManualStoreCorruptionRemainsEvidenceOnTerminalCheck() {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "full"],
        storeHealth: .corrupt("json_decode_failed")
    )
    let manual = report.checks.first { $0.id == "channels.manual_validation" }
    #expect(manual?.status == .fail)
    #expect(manual?.remediation.type.rawValue == "none")
    #expect(manual?.evidence["store_health"] == "corrupt:json_decode_failed")
    #expect(manual?.evidence["terminal"] == "true")
}

@Test func doctorV4SemanticVersionAndMarkerSniff() throws {
    let parsed = try #require(SetupDoctor.SemanticVersion("3.9.0"))
    #expect(parsed.major == 3)
    #expect(SetupDoctor.SemanticVersion("v") == nil)
    #expect(SetupDoctor.staticVersion(fromStringsOutput: "3.40.1\n\(ServerConfig.versionMarker)\n") == .version(ServerConfig.serverVersion))
    #expect(SetupDoctor.staticVersion(fromStringsOutput: "3.40.1\n3.9.0\n") == .indeterminate(["3.40.1", "3.9.0"]))
}

@Test func doctorV4CheckRegistryIDsAreUniqueAndAnchored() throws {
    let ids = SetupDoctor.checkDefinitions.map(\.id.rawValue)
    #expect(Set(ids).count == ids.count)
    #expect(Set(ids) == Set(SetupDoctor.DoctorCheckID.allCases.map(\.rawValue)))
    #expect(Set(SetupDoctor.remediationAnchorsByCheckID.keys).isSubset(of: Set(ids)))
    let v1 = try #require(SetupDoctor.checkDefinitionByID["updates.latest_release"]?.optionalByDefault)
    #expect(v1)
    #expect(
        SetupDoctor.checkDefinitionByID["updates.latest_release"]?.inclusionRule
            == .latestReleaseLookupAvailable
    )
}

@Test func doctorV4CheckRegistryCoversRenderedChecksAndOrder() {
    let reportWithoutUpdate = doctorV4Report()
    #expect(
        reportWithoutUpdate.checks.map(\.id)
            == SetupDoctor.orderedCheckIDs.filter { $0 != "updates.latest_release" }
    )

    var runtime = doctorV4Runtime()
    runtime.latestReleaseLookup = { .found(version: ServerConfig.serverVersion) }

    let report = doctorV4Report(runtime: runtime)
    let reportIDs = report.checks.map(\.id)
    let registryIDs = Set(SetupDoctor.orderedCheckIDs)

    #expect(Set(reportIDs).isSubset(of: registryIDs))
    #expect(reportIDs == SetupDoctor.orderedCheckIDs)
}

@Test func doctorV4RegistryRunnerPreservesProfileAndDependencyResults() throws {
    let report = doctorV4Report(
        arguments: ["LogicProMCP", "doctor", "--json", "--profile", "core", "--client", "claude-code"],
        runtime: doctorV4Runtime(registration: .notRegistered),
        approvals: [:]
    )
    let manual = try #require(report.checks.first { $0.id == "channels.manual_validation" })
    let target = try #require(report.checks.first { $0.id == "mcp.registration_target" })

    #expect(manual.status == .skipped)
    #expect(manual.skipReason == .profileNotRequired)
    #expect(target.status == .skipped)
    #expect(target.blockedBy == "mcp.claude_code_registration")
    #expect(target.remediation.type == .none)
    #expect(target.remediation.value.isEmpty)
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
    #expect(!isOptional)
    #expect(synthesized.evidence["reason"] == "required_check_missing")
    #expect(synthesized.evidence["terminal"] == "true")
    #expect(synthesized.evidence["human_intervention_required"] == "false")
    #expect(synthesized.evidence["human_intervention_requests"] == "0")
    #expect(synthesized.evidence["human_dependent_transitions"] == "0")
    #expect(synthesized.remediation.type == .none)
    #expect(synthesized.remediation.value.isEmpty)
    #expect(SetupDoctor.computeFixPlan([synthesized]).isEmpty)
    let headline = SetupDoctor.computeHeadline(checks: [synthesized], status: .failed)
    #expect(headline == "Terminal outcome [binary.executable]: Required doctor check was not emitted; readiness cannot be claimed.")
    #expect(!headline.contains("Next action"))

    let requiredIDs = SetupDoctor.requiredCheckIDs(
        for: report.doctorProfile,
        clientProfile: report.clientProfile
    )
    let scoped = closed.filter { requiredIDs.contains($0.id) && !$0.optional }
    #expect(SetupDoctor.aggregateStatus(scoped) != .ok)
}

@Test func doctorV4OptionalRequiredCheckIsSynthesizedAsTerminalFailure() throws {
    let optional = SetupDoctor.check(
        id: "binary.executable",
        domain: "binary",
        status: .pass,
        summary: "Executable is available.",
        evidence: [:],
        remediationType: .none,
        optional: true
    )
    let closed = SetupDoctor.checksClosingRequiredGaps(
        [optional],
        profile: .core,
        clientProfile: .custom
    )
    let synthesized = try #require(closed.first { $0.id == "binary.executable" })

    #expect(synthesized.status == .fail)
    #expect(!synthesized.optional)
    #expect(synthesized.evidence["reason"] == "required_check_marked_optional")
    #expect(synthesized.evidence["terminal"] == "true")
    #expect(synthesized.evidence["human_intervention_required"] == "false")
    #expect(synthesized.evidence["human_intervention_requests"] == "0")
    #expect(synthesized.evidence["human_dependent_transitions"] == "0")
    #expect(synthesized.remediation.type == .none)
    #expect(synthesized.remediation.value.isEmpty)
    #expect(SetupDoctor.computeFixPlan([synthesized]).isEmpty)
    let headline = SetupDoctor.computeHeadline(checks: [synthesized], status: .failed)
    #expect(headline == "Terminal outcome [binary.executable]: Required doctor check was emitted as optional; readiness cannot be claimed.")
    #expect(!headline.contains("Next action"))
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
