import Foundation

extension SetupDoctor {
    enum DoctorCheckID: String, Codable, CaseIterable, Sendable {
        case binaryPath = "binary.path"
        case binaryExecutable = "binary.executable"
        case binaryVersion = "binary.version"
        case installSource = "install.source"
        case installBinaryInventory = "install.binary_inventory"
        case installShareDir = "install.share_dir"
        case releaseSignature = "release.signature"
        case releaseQuarantine = "release.quarantine"
        case mcpClaudeCodeRegistration = "mcp.claude_code_registration"
        case mcpRegistrationTarget = "mcp.registration_target"
        case mcpClaudeDesktopRegistration = "mcp.claude_desktop_registration"
        case permissionsAccessibility = "permissions.accessibility"
        case permissionsAutomationLogicPro = "permissions.automation_logic_pro"
        case permissionsAutomationSystemEvents = "permissions.automation_system_events"
        case permissionsPostEventAccess = "permissions.post_event_access"
        case permissionsLaunchContext = "permissions.launch_context"
        case permissionsTCCCrossContext = "permissions.tcc_cross_context"
        case systemMacOSVersion = "system.macos_version"
        case logicInstallation = "logic.installation"
        case logicVersionSupport = "logic.version_support"
        case logicApplicationState = "logic.application_state"
        case logicBlockingDialog = "logic.blocking_dialog"
        case channelsManualValidation = "channels.manual_validation"
        case channelsKeycmdReference = "channels.keycmd_reference"
        case channelsMCUWiringHint = "channels.mcu_wiring_hint"
        case dependenciesClickFallback = "dependencies.click_fallback"
        case updatesLatestRelease = "updates.latest_release"
    }

    enum DoctorCheckInclusionRule: Equatable, Sendable {
        case always
        case latestReleaseLookupAvailable
    }

    struct DoctorCheckDefinition: Equatable, Sendable {
        let id: DoctorCheckID
        let dependencies: [DoctorCheckID]
        let inclusionRule: DoctorCheckInclusionRule
        let optionalByDefault: Bool
        let capabilityGroups: [String]
        let remediationAnchor: String?
        let profileRule: String?
        let clientRule: String?

        init(
            _ id: DoctorCheckID,
            dependencies: [DoctorCheckID] = [],
            inclusionRule: DoctorCheckInclusionRule = .always,
            optionalByDefault: Bool = false,
            capabilityGroups: [String] = [],
            remediationAnchor: String? = nil,
            profileRule: String? = nil,
            clientRule: String? = nil
        ) {
            self.id = id
            self.dependencies = dependencies
            self.inclusionRule = inclusionRule
            self.optionalByDefault = optionalByDefault
            self.capabilityGroups = capabilityGroups
            self.remediationAnchor = remediationAnchor
            self.profileRule = profileRule
            self.clientRule = clientRule
        }
    }

    struct DoctorCapabilityDefinition: Equatable, Sendable {
        let id: String
        let profiles: Set<DoctorProfile>
        let liveVerification: String?

        init(_ id: String, profiles: Set<DoctorProfile>, liveVerification: String? = nil) {
            self.id = id
            self.profiles = profiles
            self.liveVerification = liveVerification
        }
    }

    private static let allCapabilityGroups = [
        "core_transport",
        "track_management",
        "midi_import",
        "mixer_ax",
        "mixer_mcu",
        "project_lifecycle",
        "keycmd_only_ops",
        "legacy_scripter",
        "verified_plugin_applyback",
    ]

    static let checkDefinitions: [DoctorCheckDefinition] = [
        .init(.binaryPath, capabilityGroups: allCapabilityGroups, remediationAnchor: "docs/SETUP.md#doctor-binarypath"),
        .init(.binaryExecutable, capabilityGroups: allCapabilityGroups, remediationAnchor: "docs/SETUP.md#doctor-binaryexecutable"),
        .init(.binaryVersion),
        .init(.installSource, remediationAnchor: "docs/SETUP.md#doctor-installsource"),
        .init(.installBinaryInventory, remediationAnchor: "docs/SETUP.md#doctor-installbinary-inventory"),
        .init(.installShareDir, remediationAnchor: "docs/SETUP.md#doctor-installshare-dir"),
        .init(.releaseSignature, remediationAnchor: "docs/SETUP.md#doctor-releasesignature"),
        .init(.releaseQuarantine, remediationAnchor: "docs/SETUP.md#doctor-releasequarantine"),
        .init(.mcpClaudeCodeRegistration, remediationAnchor: "docs/SETUP.md#doctor-mcpclaude-code-registration", clientRule: "claude-code"),
        .init(.mcpRegistrationTarget, dependencies: [.mcpClaudeCodeRegistration], remediationAnchor: "docs/SETUP.md#doctor-mcpregistration-target", clientRule: "claude-code"),
        .init(.mcpClaudeDesktopRegistration, remediationAnchor: "docs/SETUP.md#doctor-mcpclaude-desktop-registration", clientRule: "claude-desktop"),
        .init(.permissionsAccessibility, capabilityGroups: allCapabilityGroups, remediationAnchor: "docs/SETUP.md#doctor-permissionsaccessibility"),
        .init(.permissionsAutomationLogicPro, capabilityGroups: ["track_management", "project_lifecycle", "mixer_ax", "verified_plugin_applyback"], remediationAnchor: "docs/SETUP.md#doctor-permissionsautomation-logic-pro"),
        .init(.permissionsAutomationSystemEvents, capabilityGroups: ["midi_import", "project_lifecycle"], remediationAnchor: "docs/SETUP.md#doctor-permissionsautomation-system-events"),
        .init(.permissionsPostEventAccess, capabilityGroups: allCapabilityGroups, remediationAnchor: "docs/SETUP.md#doctor-permissionspost-event-access"),
        .init(.permissionsLaunchContext, remediationAnchor: "docs/SETUP.md#doctor-permissionslaunch-context"),
        .init(.permissionsTCCCrossContext, remediationAnchor: "docs/SETUP.md#doctor-permissionstcc-cross-context"),
        .init(.systemMacOSVersion, remediationAnchor: "docs/SETUP.md#doctor-systemmacos-version"),
        .init(.logicInstallation, capabilityGroups: allCapabilityGroups, remediationAnchor: "docs/SETUP.md#doctor-logicinstallation"),
        .init(.logicVersionSupport, dependencies: [.logicInstallation], capabilityGroups: allCapabilityGroups, remediationAnchor: "docs/SETUP.md#doctor-logicversion-support"),
        .init(.logicApplicationState, capabilityGroups: allCapabilityGroups, remediationAnchor: "docs/SETUP.md#doctor-logicapplication-state"),
        .init(.logicBlockingDialog, dependencies: [.logicApplicationState, .permissionsAccessibility], capabilityGroups: ["track_management", "mixer_ax", "verified_plugin_applyback"], remediationAnchor: "docs/SETUP.md#doctor-logicblocking-dialog"),
        .init(.channelsManualValidation, capabilityGroups: ["keycmd_only_ops", "legacy_scripter"], remediationAnchor: "docs/SETUP.md#doctor-channelsmanual-validation", profileRule: "keycmd|legacy-scripter|full"),
        .init(.channelsKeycmdReference, capabilityGroups: ["keycmd_only_ops"], remediationAnchor: "docs/SETUP.md#doctor-channelskeycmd-reference", profileRule: "keycmd|full"),
        .init(.channelsMCUWiringHint, capabilityGroups: ["mixer_mcu"], remediationAnchor: "docs/SETUP.md#doctor-channelsmcu-wiring-hint", profileRule: "full"),
        .init(.dependenciesClickFallback, remediationAnchor: "docs/SETUP.md#doctor-dependenciesclick-fallback"),
        .init(
            .updatesLatestRelease,
            inclusionRule: .latestReleaseLookupAvailable,
            optionalByDefault: true,
            remediationAnchor: "docs/SETUP.md#doctor-updateslatest-release"
        ),
    ]

    static let checkDefinitionByID: [String: DoctorCheckDefinition] = Dictionary(
        uniqueKeysWithValues: checkDefinitions.map { ($0.id.rawValue, $0) }
    )

    static let orderedCheckIDs: [String] = checkDefinitions.map(\.id.rawValue)

    static let capabilityDefinitions: [DoctorCapabilityDefinition] = [
        .init("core_transport", profiles: [.core, .mixer, .keycmd, .legacyScripter, .full]),
        .init("track_management", profiles: [.core, .mixer, .full]),
        .init("midi_import", profiles: [.full]),
        .init("mixer_ax", profiles: [.mixer, .full]),
        .init("mixer_mcu", profiles: [.full], liveVerification: "logic://system/health mcu.connected"),
        .init("project_lifecycle", profiles: [.core, .mixer, .full]),
        .init("keycmd_only_ops", profiles: [.keycmd, .full]),
        .init("legacy_scripter", profiles: [.legacyScripter, .full]),
        .init("verified_plugin_applyback", profiles: [.mixer, .full]),
    ]

    static func capabilityCheckIDs(for capabilityID: String) -> [String] {
        checkDefinitions.compactMap { definition in
            definition.capabilityGroups.contains(capabilityID) ? definition.id.rawValue : nil
        }
    }
}
