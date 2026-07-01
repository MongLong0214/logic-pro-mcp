import Foundation
import Testing
@testable import LogicProMCP

private enum MainEntrypointHarnessError: Error {
    case startFailed
}

private actor MockMainServer: ServerStarting {
    private(set) var startCalls = 0
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func start() async throws {
        startCalls += 1
        if let failure {
            throw failure
        }
    }
}

@Test func testMainEntrypointVersionFlagPrintsBareVersionAndExitsWithoutServer() async {
    // #212: `--version` must print the version and exit 0 WITHOUT starting the
    // MCP server channels (pre-fix it started the server and timed out).
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--version"],
        permissionCheck: {
            Issue.record("Permission check should not run for --version")
            return .init(accessibility: false, automationLogicPro: false)
        },
        serverFactory: {
            Issue.record("Server must not be created for --version")
            return MockMainServer()
        },
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 0)
    // Bare version only — SetupLifecycle.productionInstalledBinaryVersion()
    // compares this stdout for equality against ServerConfig.serverVersion.
    #expect(stdout == ServerConfig.serverVersion + "\n")
    #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == ServerConfig.serverVersion)
    #expect(stderr.isEmpty)
}

@Test func testMainEntrypointVersionShortFlagPrintsVersion() async {
    var stdout = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "-V"],
        serverFactory: {
            Issue.record("Server must not be created for -V")
            return MockMainServer()
        },
        writeStdout: { stdout += $0 },
        writeStderr: { _ in }
    )

    #expect(exitCode == 0)
    #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == ServerConfig.serverVersion)
}

@Test func testMainEntrypointReturnsSuccessForGrantedPermissions() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--check-permissions"],
        permissionCheck: {
            .init(accessibility: true, automationLogicPro: true, systemEventsAutomation: .granted)
        },
        serverFactory: {
            Issue.record("Server should not be created when checking permissions")
            return MockMainServer()
        },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 0)
    #expect(stderr.contains("Accessibility: granted"))
    #expect(stderr.contains("Automation (Logic Pro): granted"))
    #expect(stderr.contains("Automation (System Events): granted"))
}

@Test func testMainEntrypointReturnsFailureWhenSystemEventsAutomationDenied() async {
    // #188 readiness honesty: Accessibility + Logic Pro automation can be
    // granted while Automation → System Events (a separate TCC target driving
    // MIDI import / tempo dialog / project-state probes) is denied. The
    // readiness gate must exit non-zero so an install guide or CI check never
    // reads exit 0 as "ready" and then fails mid-import.
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--check-permissions"],
        permissionCheck: {
            .init(
                accessibilityState: .granted,
                automationState: .granted,
                systemEventsAutomationState: .notGranted
            )
        },
        serverFactory: {
            Issue.record("Server should not be created when checking permissions")
            return MockMainServer()
        },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Automation (System Events): NOT GRANTED"))
    #expect(stderr.contains("allow control of System Events"))
}

@Test func testMainEntrypointReturnsFailureForMissingPermissions() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--check-permissions"],
        permissionCheck: {
            .init(accessibility: false, automationLogicPro: true)
        },
        serverFactory: {
            Issue.record("Server should not be created when checking permissions")
            return MockMainServer()
        },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("NOT GRANTED"))
    #expect(stderr.contains("Accessibility"))
}

@Test func testMainEntrypointStartsServerWithoutPermissionFlag() async {
    let server = MockMainServer()
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP"],
        permissionCheck: {
            Issue.record("Permission check should not run without the flag")
            return .init(accessibility: false, automationLogicPro: false)
        },
        serverFactory: { server },
        writeStderr: { _ in }
    )

    #expect(exitCode == 0)
    #expect(await server.startCalls == 1)
}

@Test func testMainEntrypointReturnsFailureWhenServerStartThrows() async {
    let server = MockMainServer(failure: MainEntrypointHarnessError.startFailed)
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP"],
        permissionCheck: {
            Issue.record("Permission check should not run without the flag")
            return .init(accessibility: false, automationLogicPro: false)
        },
        serverFactory: { server },
        writeStderr: { _ in }
    )

    #expect(exitCode == 1)
    #expect(await server.startCalls == 1)
}

@Test func testMainEntrypointDefaultDependenciesHandlePermissionCheckPath() async {
    let exitCode = await MainEntrypoint.run(arguments: ["LogicProMCP", "--check-permissions"])
    #expect(exitCode == 0 || exitCode == 1)
}

@Test func testLogicProMCPMainExitCodeWrapsMainEntrypoint() async {
    let exitCode = await LogicProMCPMain.exitCode(
        arguments: ["LogicProMCP", "--check-permissions"],
        runner: { arguments in
            #expect(arguments == ["LogicProMCP", "--check-permissions"])
            return 7
        }
    )
    #expect(exitCode == 7)
}

@Test func testLogicProMCPMainDefaultRunnerDelegatesToMainEntrypoint() async {
    var stderr = ""
    let exitCode = await LogicProMCPMain.defaultRunner(
        arguments: ["LogicProMCP", "--check-permissions"],
        permissionCheck: {
            .init(accessibility: true, automationLogicPro: false)
        },
        serverFactory: {
            Issue.record("Server should not be created when checking permissions")
            return MockMainServer()
        },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Accessibility: granted"))
    #expect(stderr.contains("Automation (Logic Pro): NOT GRANTED"))
}

@Test func testMainEntrypointApproveListAndRevokeManualValidationChannel() async throws {
    let store = ManualValidationStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-cli-\(UUID().uuidString)")
            .appendingPathExtension("json")
    )

    var approveOutput = ""
    let approveExitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--approve-channel", "MIDIKeyCommands", "--approval-note", "validated"],
        permissionCheck: { .init(accessibility: false, automationLogicPro: false) },
        serverFactory: { MockMainServer() },
        approvalStoreFactory: { store },
        writeStderr: { approveOutput += $0 }
    )
    #expect(approveExitCode == 0)
    #expect(approveOutput.contains("Approved MIDIKeyCommands"))

    var listOutput = ""
    let listExitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--list-approvals"],
        permissionCheck: { .init(accessibility: false, automationLogicPro: false) },
        serverFactory: { MockMainServer() },
        approvalStoreFactory: { store },
        writeStderr: { listOutput += $0 }
    )
    #expect(listExitCode == 0)
    #expect(listOutput.contains("MIDIKeyCommands"))
    #expect(listOutput.contains("validated"))

    var revokeOutput = ""
    let revokeExitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--revoke-channel", "MIDIKeyCommands"],
        permissionCheck: { .init(accessibility: false, automationLogicPro: false) },
        serverFactory: { MockMainServer() },
        approvalStoreFactory: { store },
        writeStderr: { revokeOutput += $0 }
    )
    #expect(revokeExitCode == 0)
    #expect(revokeOutput.contains("Revoked approval"))
}

@Test func testMainEntrypointRejectsUnknownApprovalChannel() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--approve-channel", "not-a-channel"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: { MockMainServer() },
        approvalStoreFactory: { ManualValidationStore() },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Unknown approval channel"))
}

@Test func testLogicProMCPMainDefaultPathsHandlePermissionCheckFlow() async {
    let runnerExitCode = await LogicProMCPMain.defaultRunner(
        arguments: ["LogicProMCP", "--check-permissions"]
    )
    let exitCode = await LogicProMCPMain.exitCode(
        arguments: ["LogicProMCP", "--check-permissions"]
    )

    #expect(runnerExitCode == 0 || runnerExitCode == 1)
    #expect(Int32(runnerExitCode) == exitCode)
}
