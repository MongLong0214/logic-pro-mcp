import Foundation
import Testing
@testable import LogicProMCP

private actor LifecycleMockMainServer: ServerStarting {
    func start() async throws {}
}

/// Records every read the planner makes against the injected runtime AND records
/// any path the planner would mutate. The lifecycle Runtime has no write hook by
/// construction, so a non-empty `writes` array can only happen if a future change
/// adds one — the dry-run zero-mutation test asserts it stays empty.
private final class LifecycleRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var fileExistsQueries: [String] = []
    private(set) var directoryWritableQueries: [String] = []
    private(set) var writes: [String] = []

    func recordFileExists(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        fileExistsQueries.append(path)
    }

    func recordDirectoryWritable(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        directoryWritableQueries.append(path)
    }

    func recordWrite(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        writes.append(path)
    }

    func snapshotWrites() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
}

private let lifecycleTestHome = URL(fileURLWithPath: "/Users/tester")

private func lifecycleRuntime(
    installDir: String = "/usr/local/bin",
    presentPaths: Set<String> = [],
    installDirWritable: Bool = false,
    registration: SetupDoctor.ClaudeRegistration = .notRegistered,
    claudeCLIAvailable: Bool = true,
    installedVersion: String? = nil,
    home: URL = lifecycleTestHome,
    recorder: LifecycleRuntimeRecorder? = nil
) -> SetupLifecycle.Runtime {
    SetupLifecycle.Runtime(
        installDir: { installDir },
        fileExists: { path in
            recorder?.recordFileExists(path)
            return presentPaths.contains(path)
        },
        directoryWritable: { path in
            recorder?.recordDirectoryWritable(path)
            return installDirWritable
        },
        claudeRegistration: { registration },
        claudeCLIAvailable: { claudeCLIAvailable },
        installedBinaryVersion: { installedVersion },
        homeDirectory: { home }
    )
}

private func step(_ plan: SetupLifecycle.Plan, _ id: String) -> SetupLifecycle.Step? {
    plan.steps.first { $0.id == id }
}

private func binaryPath(_ installDir: String = "/usr/local/bin") -> String {
    installDir + "/LogicProMCP"
}

private func keyCommandsPath(_ home: URL = lifecycleTestHome) -> String {
    home.appendingPathComponent("Music/Audio Music Apps/Key Commands/LogicProMCP-KeyCommands.plist").path
}

private func approvalStorePath(_ home: URL = lifecycleTestHome) -> String {
    home.appendingPathComponent("Library/Application Support/LogicProMCP/operator-approvals.json").path
}

private func approvalLockPath(_ home: URL = lifecycleTestHome) -> String {
    approvalStorePath(home) + ".lock"
}

private func launchAgentPath(_ home: URL = lifecycleTestHome) -> String {
    home.appendingPathComponent("Library/LaunchAgents/com.logicpro.mcp.plist").path
}

// MARK: - Install plan (nothing installed)

@Test func testInstallPlanWhenNothingInstalledIsAllCreateOrRegister() throws {
    let plan = SetupLifecycle.plan(
        command: .install,
        runtime: lifecycleRuntime(registration: .notRegistered)
    )

    #expect(plan.schema == "logic_pro_mcp_lifecycle_plan.v1")
    #expect(plan.command == .install)
    #expect(plan.executionMode == "dry_run_only")
    #expect(plan.targetVersion == ServerConfig.serverVersion)
    #expect(plan.installedVersion == nil)

    let binary = try #require(step(plan, "binary.install"))
    #expect(binary.action == .create)
    #expect(binary.currentState == "absent")
    #expect(binary.plannedState == "present")
    #expect(binary.target == binaryPath())
    // /usr/local/bin not writable by the fake -> sudo required.
    #expect(binary.requiresSudo)

    let register = try #require(step(plan, "mcp.register"))
    #expect(register.action == .register)
    #expect(register.currentState == "not_registered")
    #expect(!register.requiresSudo)

    let keycmds = try #require(step(plan, "keycmds.stage"))
    #expect(keycmds.action == .create)

    // Scripter is a manual Logic-side step with no FS artifact -> always skip.
    let scripter = try #require(step(plan, "scripter.insert"))
    #expect(scripter.action == .skip)
    #expect(scripter.remediation.type == .manual)

    // No delete/unregister actions in a fresh install plan.
    let actions = Set(plan.steps.map(\.action))
    #expect(!actions.contains(.delete))
    #expect(!actions.contains(.unregister))
}

@Test func testInstallPlanSkipsBinaryWhenAlreadyPresent() throws {
    let plan = SetupLifecycle.plan(
        command: .install,
        runtime: lifecycleRuntime(
            presentPaths: [binaryPath()],
            installDirWritable: true,
            registration: .registered(command: binaryPath())
        )
    )
    let binary = try #require(step(plan, "binary.install"))
    #expect(binary.action == .skip)
    #expect(binary.currentState == "present")
    // Already writable dir -> no sudo even though it's a skip.
    #expect(!binary.requiresSudo)

    let register = try #require(step(plan, "mcp.register"))
    #expect(register.action == .skip)
    #expect(register.currentState == "registered")
}

@Test func testInstallPlanRequiresSudoOnlyWhenInstallDirNotWritable() throws {
    let writable = SetupLifecycle.plan(
        command: .install,
        runtime: lifecycleRuntime(installDirWritable: true)
    )
    let notWritable = SetupLifecycle.plan(
        command: .install,
        runtime: lifecycleRuntime(installDirWritable: false)
    )
    #expect(try #require(step(writable, "binary.install")).requiresSudo == false)
    #expect(try #require(step(notWritable, "binary.install")).requiresSudo == true)
}

// MARK: - Uninstall plan (fully installed)

@Test func testUninstallPlanWhenFullyInstalledIsAllDeleteOrUnregister() throws {
    let present: Set<String> = [
        binaryPath(),
        keyCommandsPath(),
        approvalStorePath(),
        approvalLockPath(),
        launchAgentPath(),
    ]
    let plan = SetupLifecycle.plan(
        command: .uninstall,
        runtime: lifecycleRuntime(
            presentPaths: present,
            installDirWritable: false,
            registration: .registered(command: binaryPath()),
            claudeCLIAvailable: true
        )
    )

    #expect(plan.command == .uninstall)

    let approvals = try #require(step(plan, "approvals.remove"))
    #expect(approvals.action == .delete)
    #expect(approvals.reversible)
    #expect(!approvals.requiresSudo)

    let binary = try #require(step(plan, "binary.remove"))
    #expect(binary.action == .delete)
    #expect(binary.reversible)
    // Install dir not writable -> sudo required to remove the binary.
    #expect(binary.requiresSudo)

    let keycmds = try #require(step(plan, "keycmds.remove"))
    #expect(keycmds.action == .delete)
    #expect(keycmds.reversible)

    let unregister = try #require(step(plan, "mcp.unregister"))
    #expect(unregister.action == .unregister)
    #expect(unregister.currentState == "registered")
    #expect(unregister.remediation.type == .command)
    #expect(unregister.remediation.value == "claude mcp remove logic-pro")

    let launch = try #require(step(plan, "launch_agent.remove"))
    #expect(launch.action == .delete)

    // Every reachable artifact step is reversible (re-installable / re-approvable).
    for s in plan.steps where s.action == .delete || s.action == .unregister {
        #expect(s.reversible, "\(s.id) should be reversible")
    }
    // No create/register in an uninstall plan.
    let actions = Set(plan.steps.map(\.action))
    #expect(!actions.contains(.create))
    #expect(!actions.contains(.register))
}

@Test func testUninstallPlanSkipsAbsentArtifacts() throws {
    // Nothing present at all -> every removable step is skip, scripter stays manual.
    let plan = SetupLifecycle.plan(
        command: .uninstall,
        runtime: lifecycleRuntime(presentPaths: [], registration: .notRegistered)
    )
    #expect(try #require(step(plan, "approvals.remove")).action == .skip)
    #expect(try #require(step(plan, "binary.remove")).action == .skip)
    #expect(try #require(step(plan, "keycmds.remove")).action == .skip)
    #expect(try #require(step(plan, "mcp.unregister")).action == .skip)
    #expect(try #require(step(plan, "launch_agent.remove")).action == .skip)

    // A skipped binary removal needs no sudo regardless of dir writability.
    #expect(try #require(step(plan, "binary.remove")).requiresSudo == false)
}

@Test func testUninstallPlanDeletesApprovalsWhenOnlyLockSidecarExists() throws {
    let plan = SetupLifecycle.plan(
        command: .uninstall,
        runtime: lifecycleRuntime(
            presentPaths: [approvalLockPath()],
            registration: .notRegistered
        )
    )

    let approvals = try #require(step(plan, "approvals.remove"))
    #expect(approvals.action == .delete)
    #expect(approvals.target == approvalStorePath())
    #expect(approvals.remediation.value.contains("operator-approvals.json.lock"))
}

@Test func testUninstallUnregisterIsManualWhenClaudeCLIMissing() throws {
    let plan = SetupLifecycle.plan(
        command: .uninstall,
        runtime: lifecycleRuntime(
            registration: .registered(command: binaryPath()),
            claudeCLIAvailable: false
        )
    )
    let unregister = try #require(step(plan, "mcp.unregister"))
    #expect(unregister.action == .unregister)
    #expect(unregister.remediation.type == .manual)
}

// MARK: - Update plan (version delta)

@Test func testUpdatePlanWithVersionDeltaIsUpdate() throws {
    let plan = SetupLifecycle.plan(
        command: .update,
        runtime: lifecycleRuntime(
            presentPaths: [binaryPath()],
            installDirWritable: true,
            registration: .registered(command: binaryPath()),
            installedVersion: "3.0.0"
        )
    )

    #expect(plan.command == .update)
    #expect(plan.installedVersion == "3.0.0")
    #expect(plan.targetVersion == ServerConfig.serverVersion)
    #expect(plan.installedVersion != plan.targetVersion)

    let binary = try #require(step(plan, "binary.update"))
    #expect(binary.action == .update)
    #expect(binary.currentState == "present (3.0.0)")
    #expect(binary.plannedState == "present (\(ServerConfig.serverVersion))")
    #expect(!binary.requiresSudo)
}

@Test func testUpdatePlanSkipsWhenAlreadyAtTargetVersion() throws {
    let plan = SetupLifecycle.plan(
        command: .update,
        runtime: lifecycleRuntime(
            presentPaths: [binaryPath()],
            installDirWritable: true,
            registration: .registered(command: binaryPath()),
            installedVersion: ServerConfig.serverVersion
        )
    )
    let binary = try #require(step(plan, "binary.update"))
    #expect(binary.action == .skip)
    #expect(binary.currentState == "present (\(ServerConfig.serverVersion))")
}

@Test func testUpdatePlanFallsBackToCreateWhenNothingInstalled() throws {
    let plan = SetupLifecycle.plan(
        command: .update,
        runtime: lifecycleRuntime(presentPaths: [], installDirWritable: false)
    )
    #expect(plan.installedVersion == nil)
    let binary = try #require(step(plan, "binary.update"))
    #expect(binary.action == .create)
    #expect(binary.currentState == "absent")
    #expect(binary.requiresSudo)
}

// MARK: - JSON schema contract

@Test func testLifecyclePlanJSONValidatesAgainstSchema() throws {
    let plan = SetupLifecycle.plan(
        command: .uninstall,
        runtime: lifecycleRuntime(
            presentPaths: [binaryPath(), keyCommandsPath(), approvalStorePath()],
            registration: .registered(command: binaryPath())
        )
    )
    let json = encodeJSON(plan)
    let object = try #require(sharedJSONObject(json))

    #expect(object["schema"] as? String == "logic_pro_mcp_lifecycle_plan.v1")
    #expect(object["command"] as? String == "uninstall")
    #expect(object["execution_mode"] as? String == "dry_run_only")
    #expect(object["target_version"] as? String == ServerConfig.serverVersion)
    #expect(object["install_dir"] as? String == "/usr/local/bin")
    #expect(object["next_safe_action"] as? String == "review_uninstall_plan")

    let steps = try #require(object["steps"] as? [[String: Any]])
    #expect(steps.count == plan.steps.count)

    // Lock the per-step wire shape with snake_case keys so a CodingKeys typo on a
    // nested field cannot ship green. All force-unwrap / != nil — never dead forms.
    let first = try #require(steps.first)
    #expect(first["id"] as? String == "approvals.remove")
    let action = try #require(first["action"] as? String)
    #expect(action == "delete")
    #expect(first["target"] as? String != nil)
    #expect(first["current_state"] as? String != nil)
    #expect(first["planned_state"] as? String != nil)
    #expect(first["reversible"] as? Bool != nil)
    #expect(first["requires_sudo"] as? Bool != nil)
    let remediation = try #require(first["remediation"] as? [String: Any])
    #expect(remediation["type"] as? String != nil)
    #expect(remediation["value"] as? String != nil)
}

@Test func testLifecyclePlanActionVocabularyIsClosed() {
    // Every emitted action must be one of the documented enum cases across all
    // three commands and both present/absent states.
    let allowed: Set<String> = ["create", "update", "delete", "register", "unregister", "skip"]
    for command in SetupLifecycle.Command.allCases {
        let installed = SetupLifecycle.plan(
            command: command,
            runtime: lifecycleRuntime(
                presentPaths: [binaryPath(), keyCommandsPath(), approvalStorePath(), launchAgentPath()],
                registration: .registered(command: binaryPath()),
                installedVersion: "1.0.0"
            )
        )
        let empty = SetupLifecycle.plan(
            command: command,
            runtime: lifecycleRuntime(presentPaths: [], registration: .notRegistered)
        )
        for s in installed.steps + empty.steps {
            #expect(allowed.contains(s.action.rawValue), "unexpected action \(s.action.rawValue)")
        }
    }
}

// MARK: - Dry-run is read-only (zero mutations)

@Test func testDryRunPlanPerformsZeroMutations() {
    let recorder = LifecycleRuntimeRecorder()
    for command in SetupLifecycle.Command.allCases {
        _ = SetupLifecycle.plan(
            command: command,
            runtime: lifecycleRuntime(
                presentPaths: [binaryPath(), keyCommandsPath(), approvalStorePath(), launchAgentPath()],
                installDirWritable: false,
                registration: .registered(command: binaryPath()),
                installedVersion: "1.0.0",
                recorder: recorder
            )
        )
    }
    // The runtime exposes only read accessors; no write was ever recorded.
    #expect(recorder.snapshotWrites().isEmpty)
    // And the planner DID inspect real artifact paths (proves it read, not guessed).
    #expect(recorder.fileExistsQueries.contains(binaryPath()))
    #expect(recorder.fileExistsQueries.contains(keyCommandsPath()))
}

@Test func testDryRunDoesNotTouchRealFilesystemArtifacts() {
    // Drive the planner with the PRODUCTION fileExists against a path we control
    // in a temp dir, then assert the path was never created by the read-only plan.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lifecycle-readonly-\(UUID().uuidString)", isDirectory: true)
    let fakeBinary = tmp.appendingPathComponent("LogicProMCP").path

    let runtime = SetupLifecycle.Runtime(
        installDir: { tmp.path },
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        directoryWritable: { FileManager.default.isWritableFile(atPath: $0) },
        claudeRegistration: { .notRegistered },
        claudeCLIAvailable: { false },
        installedBinaryVersion: { nil },
        homeDirectory: { tmp }
    )

    _ = SetupLifecycle.plan(command: .install, runtime: runtime)
    _ = SetupLifecycle.plan(command: .uninstall, runtime: runtime)

    #expect(!FileManager.default.fileExists(atPath: fakeBinary))
    #expect(!FileManager.default.fileExists(atPath: tmp.path))
}

// MARK: - Entrypoint exit-code contract (mirrors doctor entrypoint tests)

@Test func testMainEntrypointInstallDryRunJSONExitsZeroWithoutStartingServer() async throws {
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "install", "--dry-run", "--json"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a lifecycle plan")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 0)
    #expect(stderr.isEmpty)
    let json = try #require(sharedJSONObject(stdout))
    #expect(json["schema"] as? String == "logic_pro_mcp_lifecycle_plan.v1")
    #expect(json["command"] as? String == "install")
}

@Test func testMainEntrypointUninstallDryRunHumanOutputIncludesStableIDs() async {
    var stdout = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "uninstall", "--dry-run"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a lifecycle plan")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(
            presentPaths: [binaryPath()],
            registration: .registered(command: binaryPath())
        ),
        writeStdout: { stdout += $0 },
        writeStderr: { _ in }
    )

    #expect(exitCode == 0)
    #expect(stdout.contains("Logic Pro MCP lifecycle plan"))
    #expect(stdout.contains("binary.remove"))
    #expect(stdout.contains("mcp.unregister"))
}

@Test func testMainEntrypointLifecycleWithoutDryRunRefusesAndExitsNonZero() async {
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "install"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a refused lifecycle command")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stdout.isEmpty)
    #expect(stderr.contains("--dry-run"))
    #expect(stderr.contains("Scripts/install.sh"))
}

@Test func testMainEntrypointUninstallWithoutDryRunPointsAtUninstallScript() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "uninstall"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a refused lifecycle command")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Scripts/uninstall.sh"))
}

@Test func testMainEntrypointLifecycleSubcommandJSONExitsZeroWithoutStartingServer() async throws {
    // #214: the documented `LogicProMCP lifecycle <action> --json` form must
    // print the read-only plan and exit 0 WITHOUT starting the server (pre-fix
    // it was unparsed and fell through to server startup → hang/timeout).
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "lifecycle", "install", "--json"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a lifecycle plan")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 0)
    #expect(stderr.isEmpty)
    let json = try #require(sharedJSONObject(stdout))
    #expect(json["schema"] as? String == "logic_pro_mcp_lifecycle_plan.v1")
    #expect(json["command"] as? String == "install")
    // Read-only: the wire contract must state the plan does nothing.
    #expect(json["execution_mode"] as? String == "dry_run_only")
}

@Test func testMainEntrypointLifecycleSubcommandHumanOutputMatchesDryRunForm() async {
    // `lifecycle uninstall` (no --dry-run) prints the human plan, exit 0.
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "lifecycle", "uninstall"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a lifecycle plan")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 0)
    #expect(stderr.isEmpty)
    #expect(stdout.contains("Logic Pro MCP lifecycle plan"))
    #expect(stdout.contains("command: uninstall"))
    #expect(stdout.contains("execution_mode: dry_run_only"))
}

@Test func testMainEntrypointLifecycleSubcommandMissingActionShowsUsage() async {
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "lifecycle"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a lifecycle usage error")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stdout.isEmpty)
    #expect(stderr.contains("Usage: LogicProMCP lifecycle"))
    #expect(stderr.contains("install|update|uninstall"))
}

@Test func testMainEntrypointLifecycleSubcommandUnknownActionShowsUsage() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "lifecycle", "frobnicate", "--json"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server should not start for a lifecycle usage error")
            return LifecycleMockMainServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Usage: LogicProMCP lifecycle"))
}

@Test func testMainEntrypointUnknownFirstArgStillStartsServer() async {
    // A non-lifecycle, non-doctor first arg must not be hijacked by the lifecycle
    // router — the server still starts.
    let server = LifecycleMockMainServer()
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP"],
        permissionCheck: {
            Issue.record("Permission check should not run on the server path")
            return .init(accessibility: false, automationLogicPro: false)
        },
        serverFactory: { server },
        approvalStoreFactory: { ManualValidationStore() },
        lifecycleRuntime: lifecycleRuntime(),
        writeStderr: { _ in }
    )
    #expect(exitCode == 0)
}

// MARK: - Docs anchor coverage (mirror doctor anchor doc-lint)

@Test func testSetupDocsContainEveryLifecycleRemediationAnchor() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let setup = try String(
        contentsOf: root.appendingPathComponent("docs/SETUP.md"),
        encoding: .utf8
    )
    for anchor in SetupLifecycle.remediationAnchorsByStepID.values.sorted() {
        let id = anchor.replacingOccurrences(of: "docs/SETUP.md#", with: "")
        #expect(setup.contains("id=\"\(id)\""), "Missing lifecycle remediation anchor \(anchor)")
    }
}
