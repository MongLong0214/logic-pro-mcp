import Testing
@testable import LogicProMCP

private enum FailingApprovalStoreError: Error {
    case persistFailed
}

private actor NoopMainServer: ServerStarting {
    func start() async throws {}
}

private actor FailingApprovalStore: ManualValidationStoring {
    func isApproved(_ channel: ManualValidationChannel) async -> Bool { false }
    func approval(for channel: ManualValidationChannel) async -> ManualValidationApproval? { nil }
    func approve(_ channel: ManualValidationChannel, note: String?) async throws {
        throw FailingApprovalStoreError.persistFailed
    }
    func revoke(_ channel: ManualValidationChannel) async throws {
        throw FailingApprovalStoreError.persistFailed
    }
    func list() async -> [ManualValidationChannel : ManualValidationApproval] { [:] }
}

@Test func testMainEntrypointApproveChannelReportsPersistenceFailure() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--approve-channel", "scripter"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: { NoopMainServer() },
        approvalStoreFactory: { FailingApprovalStore() },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Failed to persist approval"))
}

@Test func testMainEntrypointRevokeRejectsUnknownApprovalChannel() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--revoke-channel", "not-a-channel"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: { NoopMainServer() },
        approvalStoreFactory: { ManualValidationStore() },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Unknown approval channel"))
}

@Test func testMainEntrypointRevokeReportsPersistenceFailure() async {
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--revoke-channel", "Scripter"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: { NoopMainServer() },
        approvalStoreFactory: { FailingApprovalStore() },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stderr.contains("Failed to revoke approval"))
}
