import Foundation

/// Read-only PLANNER for the install / update / uninstall lifecycle.
///
/// Mirrors `SetupDoctor`'s Runtime-injection seam so it is fully testable
/// without touching the real filesystem, the real Claude config, or the real
/// install location. A plan DESCRIBES the ordered steps a live execution would
/// take — it NEVER mutates anything. The `Runtime` exposes only read accessors;
/// there is deliberately no write/delete/register hook on it, so a dry-run plan
/// is structurally incapable of changing state (the test asserts this by handing
/// in a runtime that records any unexpected access).
///
/// Honest Contract: a plan is not a claim of success. It reports the CURRENT
/// observed state and the PLANNED state for each artifact, plus whether the step
/// is reversible and whether it needs sudo. Live execution is delegated to
/// `Scripts/install.sh` / `Scripts/uninstall.sh`; the planner does not pretend
/// to perform it.
enum SetupLifecycle {
    enum Command: String, Codable, Sendable, CaseIterable {
        case install
        case update
        case uninstall
    }

    enum Action: String, Codable, Sendable {
        case create
        case update
        case delete
        case register
        case unregister
        case skip
    }

    /// Shared with SetupDoctor — see `SetupRemediationType`. Was a hand-mirrored
    /// copy kept in sync by comment; now aliased to the single source of truth.
    /// The lifecycle planner still only emits command/docs/manual/none.
    typealias RemediationType = SetupRemediationType

    /// Shared with SetupDoctor — see `SetupRemediation`.
    typealias Remediation = SetupRemediation

    struct Step: Codable, Equatable, Sendable {
        let id: String
        let action: Action
        let target: String
        let currentState: String
        let plannedState: String
        let reversible: Bool
        let requiresSudo: Bool
        let remediation: Remediation

        enum CodingKeys: String, CodingKey {
            case id
            case action
            case target
            case currentState = "current_state"
            case plannedState = "planned_state"
            case reversible
            case requiresSudo = "requires_sudo"
            case remediation
        }
    }

    struct Plan: Codable, Equatable, Sendable {
        let schema: String
        let command: Command
        let executionMode: String
        let installedVersion: String?
        let targetVersion: String
        let installDir: String
        let steps: [Step]
        let nextSafeAction: String

        enum CodingKeys: String, CodingKey {
            case schema
            case command
            case executionMode = "execution_mode"
            case installedVersion = "installed_version"
            case targetVersion = "target_version"
            case installDir = "install_dir"
            case steps
            case nextSafeAction = "next_safe_action"
        }
    }

    /// Read-only inspection seam. Every closure READS observed state; there is no
    /// mutation hook by construction, so a dry-run plan cannot change anything.
    /// Production wires these to the same primitives `Scripts/install.sh` and
    /// `Scripts/uninstall.sh` touch.
    struct Runtime: @unchecked Sendable {
        /// Default install directory (`/usr/local/bin` unless overridden by env).
        let installDir: () -> String
        /// Does a file/package exist at the absolute path?
        let fileExists: (String) -> Bool
        /// Is the directory at `path` writable without elevation? Used to decide
        /// `requires_sudo` for binary placement/removal under `INSTALL_DIR`.
        let directoryWritable: (String) -> Bool
        /// Claude Code MCP registration state (reuses the doctor's read-only reader).
        let claudeRegistration: () -> SetupDoctor.ClaudeRegistration
        /// Is the `claude` CLI resolvable on PATH? Drives whether registration is a
        /// command step or a manual one.
        let claudeCLIAvailable: () -> Bool
        /// Version string of the binary already installed at `INSTALL_DIR`, if it
        /// can be read; nil when nothing is installed or the version cannot be read.
        let installedBinaryVersion: () -> String?
        /// Home directory for resolving per-user artifacts (Key Commands, plist,
        /// approval store). Injected so tests never read the real home dir.
        let homeDirectory: () -> URL

        static let production = Runtime(
            installDir: {
                resolveInstallDir()
            },
            fileExists: { path in
                FileManager.default.fileExists(atPath: path)
            },
            directoryWritable: { path in
                FileManager.default.isWritableFile(atPath: path)
            },
            claudeRegistration: {
                SetupDoctor.readProductionClaudeRegistration()
            },
            claudeCLIAvailable: {
                productionClaudeCLIAvailable()
            },
            installedBinaryVersion: {
                productionInstalledBinaryVersion()
            },
            homeDirectory: {
                FileManager.default.homeDirectoryForCurrentUser
            }
        )
    }

    static let schema = "logic_pro_mcp_lifecycle_plan.v1"

    /// Stable doc anchors, sharing `docs/SETUP.md` with the doctor so remediation
    /// language and links stay consistent across both surfaces.
    static let remediationAnchorsByStepID: [String: String] = [
        "binary.install": "docs/SETUP.md#lifecycle-binaryinstall",
        "binary.update": "docs/SETUP.md#lifecycle-binaryupdate",
        "binary.remove": "docs/SETUP.md#lifecycle-binaryremove",
        "mcp.register": "docs/SETUP.md#lifecycle-mcpregister",
        "mcp.unregister": "docs/SETUP.md#lifecycle-mcpunregister",
        "keycmds.stage": "docs/SETUP.md#lifecycle-keycmdsstage",
        "keycmds.remove": "docs/SETUP.md#lifecycle-keycmdsremove",
        "scripter.insert": "docs/SETUP.md#lifecycle-scripterinsert",
        "scripter.remove": "docs/SETUP.md#lifecycle-scripterremove",
        "launch_agent.install": "docs/SETUP.md#lifecycle-launchagentinstall",
        "launch_agent.remove": "docs/SETUP.md#lifecycle-launchagentremove",
        "approvals.remove": "docs/SETUP.md#lifecycle-approvalsremove",
    ]

    /// Build a read-only plan for `command`. Never mutates; `execution_mode` is
    /// always `dry_run_only` so the wire contract states the plan does nothing.
    static func plan(command: Command, runtime: Runtime = .production) -> Plan {
        let installDir = runtime.installDir()
        let binaryPath = installDir + "/LogicProMCP"
        let binaryInstalled = runtime.fileExists(binaryPath)
        let installDirWritable = runtime.directoryWritable(installDir)
        let installedVersion = binaryInstalled ? runtime.installedBinaryVersion() : nil
        let targetVersion = ServerConfig.serverVersion

        let steps: [Step]
        switch command {
        case .install:
            steps = installSteps(
                runtime: runtime,
                binaryPath: binaryPath,
                binaryInstalled: binaryInstalled,
                installDirWritable: installDirWritable
            )
        case .update:
            steps = updateSteps(
                runtime: runtime,
                binaryPath: binaryPath,
                binaryInstalled: binaryInstalled,
                installDirWritable: installDirWritable,
                installedVersion: installedVersion,
                targetVersion: targetVersion
            )
        case .uninstall:
            steps = uninstallSteps(
                runtime: runtime,
                binaryPath: binaryPath,
                binaryInstalled: binaryInstalled,
                installDirWritable: installDirWritable
            )
        }

        return Plan(
            schema: schema,
            command: command,
            executionMode: "dry_run_only",
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            installDir: installDir,
            steps: steps,
            nextSafeAction: nextSafeAction(for: command)
        )
    }

    static func renderHuman(_ plan: Plan) -> String {
        var lines: [String] = [
            "Logic Pro MCP lifecycle plan",
            "schema: \(plan.schema)",
            "command: \(plan.command.rawValue)",
            "execution_mode: \(plan.executionMode)",
            "install_dir: \(plan.installDir)",
            "installed_version: \(plan.installedVersion ?? "<none>")",
            "target_version: \(plan.targetVersion)",
            "",
        ]
        for step in plan.steps {
            lines.append("[\(step.action.rawValue)] \(step.id) -> \(step.target)")
            lines.append("  current: \(step.currentState) | planned: \(step.plannedState)")
            lines.append("  reversible: \(step.reversible) | requires_sudo: \(step.requiresSudo)")
            if step.remediation.type != .none {
                lines.append("  remediation: \(step.remediation.value)")
            }
        }
        lines.append("")
        lines.append("next_safe_action: \(plan.nextSafeAction)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Step builders

    private static func installSteps(
        runtime: Runtime,
        binaryPath: String,
        binaryInstalled: Bool,
        installDirWritable: Bool
    ) -> [Step] {
        var steps: [Step] = []

        steps.append(step(
            id: "binary.install",
            action: binaryInstalled ? .skip : .create,
            target: binaryPath,
            currentState: binaryInstalled ? "present" : "absent",
            plannedState: "present",
            // A create is reversible (uninstall removes it); a skip is a no-op so
            // it leaves nothing to roll back.
            reversible: true,
            requiresSudo: !installDirWritable,
            remediationType: .command,
            remediationValueOverride: binaryInstalled
                ? "Already installed at \(binaryPath); use the update command to refresh."
                : "Run Scripts/install.sh (pins LOGIC_PRO_MCP_VERSION + provenance)."
        ))

        steps.append(registrationStep(runtime: runtime, binaryPath: binaryPath, removing: false))
        steps.append(keyCommandsStep(runtime: runtime, removing: false))
        steps.append(scripterStep(removing: false))

        return steps
    }

    private static func updateSteps(
        runtime: Runtime,
        binaryPath: String,
        binaryInstalled: Bool,
        installDirWritable: Bool,
        installedVersion: String?,
        targetVersion: String
    ) -> [Step] {
        var steps: [Step] = []

        // No binary installed -> update is really an install of the binary.
        let action: Action
        let plannedState: String
        let current: String
        if !binaryInstalled {
            action = .create
            current = "absent"
            plannedState = "present (\(targetVersion))"
        } else if let installedVersion, installedVersion == targetVersion {
            action = .skip
            current = "present (\(installedVersion))"
            plannedState = "present (\(targetVersion))"
        } else {
            action = .update
            current = "present (\(installedVersion ?? "unknown"))"
            plannedState = "present (\(targetVersion))"
        }

        steps.append(step(
            id: "binary.update",
            action: action,
            target: binaryPath,
            currentState: current,
            plannedState: plannedState,
            reversible: true,
            requiresSudo: !installDirWritable,
            remediationType: .command,
            remediationValueOverride: action == .skip
                ? "Installed version already matches \(targetVersion); nothing to update."
                : "Run Scripts/install.sh with LOGIC_PRO_MCP_VERSION=v\(targetVersion)."
        ))

        // Re-point the Claude registration at the (possibly refreshed) binary.
        steps.append(registrationStep(runtime: runtime, binaryPath: binaryPath, removing: false))

        return steps
    }

    private static func uninstallSteps(
        runtime: Runtime,
        binaryPath: String,
        binaryInstalled: Bool,
        installDirWritable: Bool
    ) -> [Step] {
        var steps: [Step] = []
        let home = runtime.homeDirectory()

        // Order mirrors Scripts/uninstall.sh: approvals, binary, key commands,
        // registration, then manual Logic-side reminders.
        let approvalStore = approvalStorePath(home: home)
        let approvalLock = approvalLockPath(home: home)
        let approvalsPresent = approvalStoreArtifacts(home: home).contains { runtime.fileExists($0) }
        steps.append(step(
            id: "approvals.remove",
            action: approvalsPresent ? .delete : .skip,
            target: approvalStore,
            currentState: approvalsPresent ? "present" : "absent",
            plannedState: "absent",
            // Operator approvals are re-creatable via --approve-channel, so this
            // delete is reversible by re-approving.
            reversible: true,
            requiresSudo: false,
            remediationType: approvalsPresent ? .command : .none,
            remediationValueOverride: approvalsPresent
                ? "Scripts/uninstall.sh removes \(approvalStore) and \(approvalLock) when present; re-approve later with --approve-channel."
                : nil
        ))

        steps.append(step(
            id: "binary.remove",
            action: binaryInstalled ? .delete : .skip,
            target: binaryPath,
            currentState: binaryInstalled ? "present" : "absent",
            plannedState: "absent",
            // The binary can be reinstalled, so removal is reversible.
            reversible: true,
            requiresSudo: binaryInstalled && !installDirWritable,
            remediationType: binaryInstalled ? .command : .none,
            remediationValueOverride: binaryInstalled
                ? "Scripts/uninstall.sh removes \(binaryPath)."
                : nil
        ))

        steps.append(keyCommandsStep(runtime: runtime, removing: true))
        steps.append(registrationStep(runtime: runtime, binaryPath: binaryPath, removing: true))
        steps.append(scripterStep(removing: true))

        let launchAgent = launchAgentPath(home: home)
        let launchAgentPresent = runtime.fileExists(launchAgent)
        steps.append(step(
            id: "launch_agent.remove",
            action: launchAgentPresent ? .delete : .skip,
            target: launchAgent,
            currentState: launchAgentPresent ? "present" : "absent",
            plannedState: "absent",
            reversible: true,
            requiresSudo: false,
            remediationType: launchAgentPresent ? .manual : .none,
            remediationValueOverride: launchAgentPresent
                ? "launchctl unload \(launchAgent) && rm \(launchAgent)"
                : nil
        ))

        return steps
    }

    // MARK: - Shared step constructors

    private static func registrationStep(runtime: Runtime, binaryPath: String, removing: Bool) -> Step {
        let registered: Bool
        switch runtime.claudeRegistration() {
        case .registered:
            registered = true
        case .notRegistered, .configUnavailable:
            registered = false
        }
        let cliAvailable = runtime.claudeCLIAvailable()

        if removing {
            return step(
                id: "mcp.unregister",
                action: registered ? .unregister : .skip,
                target: "claude://mcp/logic-pro",
                currentState: registered ? "registered" : "not_registered",
                plannedState: "not_registered",
                reversible: true,
                requiresSudo: false,
                remediationType: registered ? (cliAvailable ? .command : .manual) : .none,
                remediationValueOverride: registered
                    ? "claude mcp remove logic-pro"
                    : nil
            )
        }

        return step(
            id: "mcp.register",
            action: registered ? .skip : .register,
            target: "claude://mcp/logic-pro",
            currentState: registered ? "registered" : "not_registered",
            plannedState: "registered",
            reversible: true,
            requiresSudo: false,
            remediationType: cliAvailable ? .command : .manual,
            remediationValueOverride: registered
                ? "Already registered with Claude Code."
                : "claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\(shareDirPath(binaryPath: binaryPath)) -- \(binaryPath)"
        )
    }

    private static func shareDirPath(binaryPath: String) -> String {
        let binaryURL = URL(fileURLWithPath: binaryPath).standardizedFileURL
        let installDir = binaryURL.deletingLastPathComponent()
        if installDir.lastPathComponent == "bin" {
            return installDir
                .deletingLastPathComponent()
                .appendingPathComponent("share/logic-pro-mcp")
                .path
        }
        return installDir
            .appendingPathComponent("share/logic-pro-mcp")
            .path
    }

    private static func keyCommandsStep(runtime: Runtime, removing: Bool) -> Step {
        let home = runtime.homeDirectory()
        let preset = keyCommandsPresetPath(home: home)
        let present = runtime.fileExists(preset)

        if removing {
            return step(
                id: "keycmds.remove",
                action: present ? .delete : .skip,
                target: preset,
                currentState: present ? "present" : "absent",
                plannedState: "absent",
                // uninstall-keycmds.sh can restore a pre-install backup, so this
                // delete is reversible.
                reversible: true,
                requiresSudo: false,
                remediationType: present ? .command : .none,
                remediationValueOverride: present
                    ? "Scripts/uninstall-keycmds.sh (restores any pre-install backup)."
                    : nil
            )
        }

        // Staging the mapping reference only copies a reference plist; the live
        // bindings still require manual MIDI Learn on Logic 12.2+, so the planned
        // state is honest about that.
        return step(
            id: "keycmds.stage",
            action: present ? .skip : .create,
            target: preset,
            currentState: present ? "present" : "absent",
            plannedState: "staged (manual MIDI Learn still required on Logic 12.2+)",
            reversible: true,
            requiresSudo: false,
            remediationType: .command,
            remediationValueOverride: present
                ? "Mapping reference already staged at \(preset)."
                : "Scripts/install-keycmds.sh stages the CC->Command mapping reference."
        )
    }

    private static func scripterStep(removing: Bool) -> Step {
        // Scripter insertion is a manual Logic-side step (insert the MIDI FX +
        // paste Scripts/LogicProMCP-Scripter.js); it leaves no filesystem artifact
        // the planner can inspect, so current/planned state are reported as manual
        // rather than fabricated.
        if removing {
            return step(
                id: "scripter.remove",
                action: .skip,
                target: "logic://midi-fx/LogicProMCP-Scripter",
                currentState: "manual",
                plannedState: "manual",
                reversible: true,
                requiresSudo: false,
                remediationType: .manual,
                remediationValueOverride:
                    "In Logic Pro, remove the LogicProMCP Scripter MIDI FX from each channel strip."
            )
        }
        return step(
            id: "scripter.insert",
            action: .skip,
            target: "logic://midi-fx/LogicProMCP-Scripter",
            currentState: "manual",
            plannedState: "manual",
            reversible: true,
            requiresSudo: false,
            remediationType: .manual,
            remediationValueOverride:
                "Optional legacy path: insert Scripter and load Scripts/LogicProMCP-Scripter.js, then --approve-channel Scripter."
        )
    }

    // MARK: - Artifact paths (injected home so tests stay off the real FS)

    private static func keyCommandsPresetPath(home: URL) -> String {
        home
            .appendingPathComponent("Music/Audio Music Apps/Key Commands/LogicProMCP-KeyCommands.plist")
            .path
    }

    private static func launchAgentPath(home: URL) -> String {
        home
            .appendingPathComponent("Library/LaunchAgents/com.logicpro.mcp.plist")
            .path
    }

    private static func approvalStorePath(home: URL) -> String {
        home
            .appendingPathComponent("Library/Application Support/LogicProMCP/operator-approvals.json")
            .path
    }

    private static func approvalLockPath(home: URL) -> String {
        approvalStorePath(home: home) + ".lock"
    }

    private static func approvalStoreArtifacts(home: URL) -> [String] {
        [approvalStorePath(home: home), approvalLockPath(home: home)]
    }

    private static func nextSafeAction(for command: Command) -> String {
        switch command {
        case .install:
            return "review_install_plan"
        case .update:
            return "review_update_plan"
        case .uninstall:
            return "review_uninstall_plan"
        }
    }

    private static func step(
        id: String,
        action: Action,
        target: String,
        currentState: String,
        plannedState: String,
        reversible: Bool,
        requiresSudo: Bool,
        remediationType: RemediationType,
        remediationValueOverride: String? = nil
    ) -> Step {
        let value = remediationValueOverride ?? defaultRemediationValue(for: id, type: remediationType)
        return Step(
            id: id,
            action: action,
            target: target,
            currentState: currentState,
            plannedState: plannedState,
            reversible: reversible,
            requiresSudo: requiresSudo,
            remediation: Remediation(type: remediationType, value: value)
        )
    }

    private static func defaultRemediationValue(for id: String, type: RemediationType) -> String {
        switch type {
        case .none:
            return ""
        // `.systemSettings` is part of the shared type but never emitted by the
        // lifecycle planner; handled here for exhaustiveness with the doc anchor.
        case .command, .docs, .manual, .systemSettings:
            return remediationAnchorsByStepID[id] ?? "docs/SETUP.md#lifecycle"
        }
    }

    // MARK: - Production read helpers

    /// The default binary install location used when no valid override is set.
    static let defaultInstallDir = "/usr/local/bin"

    /// Resolve `LOGIC_PRO_MCP_INSTALL_DIR` behind an L1 ownership + location
    /// allowlist. `productionInstalledBinaryVersion` EXECUTES the binary at this
    /// path (`--version`), so an unvalidated operator env value is an
    /// arbitrary-code-execution vector. Mirroring the library-inventory
    /// allowlist, an override is honored only when it standardizes to a path
    /// that is (1) a known binary root or under the user's home (location) AND
    /// (2) not world-writable (ownership); otherwise the safe default is used.
    /// Missing / empty env → default (no override).
    static func resolveInstallDir(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String {
        guard let raw = environment["LOGIC_PRO_MCP_INSTALL_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return defaultInstallDir
        }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path

        let allowedRoots: Set<String> = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]
        let homePath = homeDirectory.standardizedFileURL.path
        let locationAllowed = allowedRoots.contains(path)
            || path == homePath
            || path.hasPrefix(homePath + "/")
        guard locationAllowed else {
            Log.warn(
                "LOGIC_PRO_MCP_INSTALL_DIR '\(raw)' resolves outside the allowlisted install locations; using \(defaultInstallDir)",
                subsystem: "lifecycle"
            )
            return defaultInstallDir
        }

        // Ownership: refuse a world-writable directory — any local user could
        // swap the binary the version probe then executes. A not-yet-created
        // dir is fine (nothing installed); group-writable (e.g. Homebrew's
        // admin group) is allowed.
        if let perms = (try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber,
           (perms.uint16Value & 0o002) != 0 {
            Log.warn(
                "LOGIC_PRO_MCP_INSTALL_DIR '\(path)' is world-writable; using \(defaultInstallDir)",
                subsystem: "lifecycle"
            )
            return defaultInstallDir
        }
        return path
    }

    private static func productionClaudeCLIAvailable() -> Bool {
        guard let result = SetupDoctor.runProductionCommandForTesting(
            executable: "/usr/bin/which",
            arguments: ["claude"],
            timeout: 1.0
        ), let output = result.output else {
            return false
        }
        return output.exitCode == 0
            && !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func productionInstalledBinaryVersion() -> String? {
        let installDir = resolveInstallDir()
        let binaryPath = installDir + "/LogicProMCP"
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return nil }
        guard let result = SetupDoctor.runProductionCommandForTesting(
            executable: binaryPath,
            arguments: ["--version"],
            timeout: 1.5
        ), let output = result.output, output.exitCode == 0 else {
            return nil
        }
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
