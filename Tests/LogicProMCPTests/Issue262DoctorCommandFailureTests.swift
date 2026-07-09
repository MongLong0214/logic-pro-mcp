import Foundation
import Testing
@testable import LogicProMCP

private func issue262Runtime(_ commandResult: SetupDoctor.CommandResult) -> SetupDoctor.Runtime {
    SetupDoctor.Runtime(
        resolveExecutablePath: { _ in "/tmp/LogicProMCP" },
        fileExists: { _ in true },
        isExecutableFile: { _ in true },
        logicProRunning: { true },
        logicProHasVisibleWindow: { true },
        runCommand: { _, _ in commandResult },
        readClaudeRegistration: { .notRegistered }
    )
}

@Test func doctorCommandFailuresKeepTypedEvidenceAndActionableSummary() {
    let cases: [(SetupDoctor.CommandResult, String, String)] = [
        (.timedOut, "timeout", "Retry"),
        (.spawnFailed("ENOENT"), "spawn_failed", "Verify the tool exists"),
        (.notAllowlisted, "allowlist_rejected", "Use an allowlisted tool"),
    ]

    for (result, failureReason, summaryFragment) in cases {
        let check = SetupDoctor.releaseSignatureCheck(
            executablePath: "/tmp/LogicProMCP",
            runtime: issue262Runtime(result)
        )

        #expect(check.status == .warn)
        #expect(check.evidence["command_failure_reason"] == failureReason)
        #expect(check.evidence["command_status"] == failureReason)
        #expect(check.summary.localizedCaseInsensitiveContains(summaryFragment))
        if case .spawnFailed = result {
            #expect(check.evidence["spawn_error"] == "present")
        }
    }
}

@Test func doctorCommandSuccessKeepsTypedEvidence() {
    let check = SetupDoctor.releaseSignatureCheck(
        executablePath: "/tmp/LogicProMCP",
        runtime: issue262Runtime(.completed(.init(exitCode: 0, stdout: "", stderr: "")))
    )

    #expect(check.status == .pass)
    #expect(check.evidence["command_status"] == "success")
    #expect(check.evidence["command_failure_reason"] == nil)
}

@Test func doctorCommandNonzeroExitRemainsDistinctFromExecutionFailures() {
    let check = SetupDoctor.releaseSignatureCheck(
        executablePath: "/tmp/LogicProMCP",
        runtime: issue262Runtime(.completed(.init(exitCode: 7, stdout: "", stderr: "invalid signature")))
    )

    #expect(check.status == .warn)
    #expect(check.evidence["command_failure_reason"] == "non_zero_exit")
    #expect(check.evidence["exit_code"] == "7")
    #expect(check.evidence["command_status"] == "non_zero_exit")
}

@Test func doctorRuntimeReportsAllowlistRejectionWithoutSpawning() {
    #expect(SetupDoctor.Runtime.production.runCommand("/bin/echo", ["harmless"]) == .notAllowlisted)
}
