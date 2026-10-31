import Foundation
import Testing
@testable import LogicProMCP

private actor Issue1403LifecycleMockServer: ServerStarting {
    func start() async throws {}
}

@Test func issue1403LiveInstallRefusalIsMachineReadableAndRequestsNoHumanContinuation() async throws {
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "install", "--json"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server must not start for a terminal lifecycle refusal")
            return Issue1403LifecycleMockServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stdout.isEmpty)
    let data = try #require(stderr.data(using: .utf8))
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["schema"] as? String == "logic_pro_mcp_lifecycle_terminal.v1")
    #expect(object["command"] as? String == "install")
    #expect(object["state"] as? String == "C")
    let terminal = try #require(object["terminal"] as? Bool)
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    let humanInterventionRequired = try #require(
        object["human_intervention_required"] as? Bool
    )
    #expect(terminal)
    #expect(!writeAttempted)
    #expect(!humanInterventionRequired)
    #expect(object["human_intervention_requests"] as? Int == 0)
    #expect(object["human_dependent_transitions"] as? Int == 0)
    #expect(!stderr.contains("--dry-run"))
    #expect(!stderr.contains("Scripts/"))
}

@Test func issue1403LiveUninstallRefusalHumanOutputIsTerminalWithoutAnotherCommand() async {
    var stdout = ""
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "uninstall"],
        permissionCheck: { .init(accessibility: true, automationLogicPro: true) },
        serverFactory: {
            Issue.record("Server must not start for a terminal lifecycle refusal")
            return Issue1403LifecycleMockServer()
        },
        approvalStoreFactory: { ManualValidationStore() },
        writeStdout: { stdout += $0 },
        writeStderr: { stderr += $0 }
    )

    #expect(exitCode == 1)
    #expect(stdout.isEmpty)
    #expect(stderr.contains("terminal outcome"))
    #expect(stderr.contains("write attempted: false"))
    #expect(stderr.contains("human-dependent transitions: 0"))
    #expect(stderr.contains("human-intervention requests: 0"))
    #expect(!stderr.contains("--dry-run"))
    #expect(!stderr.contains("Scripts/"))
    #expect(!stderr.contains("Re-run"))
}
