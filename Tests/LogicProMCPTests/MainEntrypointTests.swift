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

@Test func testMainEntrypointReturnsSuccessForGrantedPermissions() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--check-permissions"],
        permissionCheck: {
            .init(accessibility: true, automationLogicPro: true)
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
