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

@Test func doctorReleaseCommandFailuresTerminateWithTypedEvidence() {
    let cases: [(SetupDoctor.CommandResult, String, String)] = [
        (.timedOut, "timeout", "verification timed out"),
        (.spawnFailed("ENOENT"), "spawn_failed", "verification could not be started"),
        (.notAllowlisted, "allowlist_rejected", "blocked by the Doctor command allowlist"),
    ]

    for (result, failureReason, summaryFragment) in cases {
        let runtime = issue262Runtime(result)
        let checks = [
            SetupDoctor.releaseSignatureCheck(executablePath: "/tmp/LogicProMCP", runtime: runtime),
            SetupDoctor.releaseQuarantineCheck(executablePath: "/tmp/LogicProMCP", runtime: runtime),
        ]
        for check in checks {
            #expect(check.status == .fail)
            #expect(check.remediation.type == .none)
            #expect(check.remediation.value.isEmpty)
            #expect(check.evidence["command_failure_reason"] == failureReason)
            #expect(check.evidence["command_status"] == failureReason)
            #expect(check.evidence["terminal"] == "true")
            #expect(check.evidence["human_intervention_required"] == "false")
            #expect(check.evidence["human_intervention_requests"] == "0")
            #expect(check.summary.localizedCaseInsensitiveContains(summaryFragment))
            for staleRequest in ["Retry", "Verify the tool", "Use an allowlisted tool"] {
                #expect(!check.summary.contains(staleRequest))
            }
            if case .spawnFailed = result {
                #expect(check.evidence["spawn_error"] == "present")
            }
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

@Test func doctorCommandNonzeroExitTerminatesWithDistinctTypedEvidence() {
    let check = SetupDoctor.releaseSignatureCheck(
        executablePath: "/tmp/LogicProMCP",
        runtime: issue262Runtime(.completed(.init(exitCode: 7, stdout: "", stderr: "invalid signature")))
    )

    #expect(check.status == .fail)
    #expect(check.remediation.type == .none)
    #expect(check.remediation.value.isEmpty)
    #expect(check.evidence["command_failure_reason"] == "non_zero_exit")
    #expect(check.evidence["exit_code"] == "7")
    #expect(check.evidence["command_status"] == "non_zero_exit")
    #expect(check.evidence["terminal"] == "true")
    #expect(check.evidence["human_intervention_required"] == "false")
    #expect(check.evidence["human_intervention_requests"] == "0")
}

@Test func doctorRuntimeReportsAllowlistRejectionWithoutSpawning() {
    #expect(SetupDoctor.Runtime.production.runCommand("/bin/echo", ["harmless"]) == .notAllowlisted)
}
