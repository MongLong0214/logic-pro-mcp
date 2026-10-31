import Foundation

extension SetupDoctor {
    private static func terminalBinaryEvidence(
        _ evidence: [String: String]
    ) -> [String: String] {
        var result = evidence
        result["terminal"] = "true"
        result["human_intervention_required"] = "false"
        result["human_intervention_requests"] = "0"
        return result
    }

    private static func observedBinaryPathBlock(
        for id: String,
        checks: [Check]
    ) -> String? {
        guard status(of: "binary.path", in: checks) != nil else { return nil }
        return blockingCause(for: id, checks: checks)
    }

    static func requireBinary(_ executablePath: String?, runtime: Runtime) -> String? {
        guard let executablePath, runtime.fileExists(executablePath) else { return nil }
        return executablePath
    }


    static func binaryPathCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath = requireBinary(executablePath, runtime: runtime) else {
            return check(
                id: "binary.path",
                domain: "binary",
                status: .fail,
                summary: "LogicProMCP binary could not be resolved from argv0 or PATH.",
                evidence: terminalBinaryEvidence(["argv0_resolved": executablePath ?? "<nil>"]),
                remediationType: .none
            )
        }
        return check(
            id: "binary.path",
            domain: "binary",
            status: .pass,
            summary: "LogicProMCP binary path resolved.",
            evidence: ["path": executablePath],
            remediationType: .none
        )
    }


    static func binaryExecutableCheck(
        executablePath: String?,
        runtime: Runtime,
        checks: [Check] = []
    ) -> Check {
        if let cause = observedBinaryPathBlock(for: "binary.executable", checks: checks) {
            return check(
                id: "binary.executable",
                domain: "binary",
                status: .skipped,
                summary: "Executable bit could not be checked because the binary path is missing.",
                evidence: [:],
                remediationType: .none,
                blockedBy: cause,
                skipReason: .binaryPathMissing
            )
        }
        guard let executablePath = requireBinary(executablePath, runtime: runtime) else {
            return check(
                id: "binary.executable",
                domain: "binary",
                status: .fail,
                summary: "Binary path became unavailable before executable permission could be checked.",
                evidence: terminalBinaryEvidence(["path_state": "unavailable_at_check"]),
                remediationType: .none,
                skipReason: nil
            )
        }
        let executable = runtime.isExecutableFile(executablePath)
        let evidence = ["path": executablePath, "executable": String(executable)]
        return check(
            id: "binary.executable",
            domain: "binary",
            status: executable ? .pass : .fail,
            summary: executable ? "Binary has executable permission." : "Binary is not executable.",
            evidence: executable ? evidence : terminalBinaryEvidence(evidence),
            remediationType: .none
        )
    }


    static func binaryVersionCheck() -> Check {
        // Honest reporting: this echoes the version compiled into the running
        // doctor process, not the version of the binary at binary.path. It cannot
        // detect a stale/mismatched install, so it never fails — the summary states
        // exactly what it reports and the remediation is unconditionally .none
        // rather than carrying a dead .fail branch + unreachable docs anchor.
        check(
            id: "binary.version",
            domain: "binary",
            status: .pass,
            summary: "Running server version: \(ServerConfig.serverVersion).",
            evidence: ["version": ServerConfig.serverVersion],
            remediationType: .none
        )
    }


    static func releaseSignatureCheck(
        executablePath: String?,
        runtime: Runtime,
        checks: [Check] = []
    ) -> Check {
        if let cause = observedBinaryPathBlock(for: "release.signature", checks: checks) {
            return check(
                id: "release.signature",
                domain: "release",
                status: .skipped,
                summary: "Signature verification skipped because the binary path is missing.",
                evidence: [:],
                remediationType: .none,
                blockedBy: cause,
                skipReason: .binaryPathMissing
            )
        }
        guard let executablePath = requireBinary(executablePath, runtime: runtime) else {
            return check(
                id: "release.signature",
                domain: "release",
                status: .fail,
                summary: "Binary path became unavailable before signature verification.",
                evidence: terminalBinaryEvidence(["path_state": "unavailable_at_check"]),
                remediationType: .none,
                skipReason: nil
            )
        }
        let result = runtime.runCommand("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", executablePath])
        guard let output = result.output else {
            return check(
                id: "release.signature",
                domain: "release",
                status: .fail,
                summary: commandFailureSummary(command: "codesign", result: result),
                evidence: terminalBinaryEvidence(commandFailureEvidence(path: executablePath, result: result)),
                remediationType: .none
            )
        }
        return check(
            id: "release.signature",
            domain: "release",
            status: output.exitCode == 0 ? .pass : .warn,
            summary: output.exitCode == 0 ? "Binary signature verifies." : "Binary signature did not verify.",
            evidence: commandEvidence(path: executablePath, output: output),
            remediationType: output.exitCode == 0 ? .none : .docs
        )
    }


    static func releaseQuarantineCheck(
        executablePath: String?,
        runtime: Runtime,
        checks: [Check] = []
    ) -> Check {
        if let cause = observedBinaryPathBlock(for: "release.quarantine", checks: checks) {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .skipped,
                summary: "Quarantine check skipped because the binary path is missing.",
                evidence: [:],
                remediationType: .none,
                blockedBy: cause,
                skipReason: .binaryPathMissing
            )
        }
        guard let executablePath = requireBinary(executablePath, runtime: runtime) else {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .fail,
                summary: "Binary path became unavailable before quarantine inspection.",
                evidence: terminalBinaryEvidence(["path_state": "unavailable_at_check"]),
                remediationType: .none,
                skipReason: nil
            )
        }
        let result = runtime.runCommand("/usr/bin/xattr", ["-p", "com.apple.quarantine", executablePath])
        guard let output = result.output else {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .fail,
                summary: commandFailureSummary(command: "xattr quarantine", result: result),
                evidence: terminalBinaryEvidence(commandFailureEvidence(path: executablePath, result: result)),
                remediationType: .none
            )
        }
        // Distinguish three outcomes instead of folding everything but exit 0 into
        // .pass. xattr exits non-zero both when the attribute is absent (exit 1,
        // "No such xattr") AND on permission-denied or other errors; collapsing all
        // of those to "not quarantined" would let the doctor affirm a clean state it
        // never verified.
        let trimmedStderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = commandEvidence(path: executablePath, output: output)
        if output.exitCode == 0 {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .fail,
                summary: "Binary has a macOS quarantine attribute.",
                evidence: terminalBinaryEvidence(evidence),
                remediationType: .none
            )
        }
        let attributeAbsent = output.exitCode == 1
            && trimmedStdout.isEmpty
            && trimmedStderr.localizedCaseInsensitiveContains("No such xattr")
        if attributeAbsent {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .pass,
                summary: "Binary is not quarantined.",
                evidence: evidence,
                remediationType: .none
            )
        }
        return check(
            id: "release.quarantine",
            domain: "release",
            status: .warn,
            summary: "Quarantine state could not be determined.",
            evidence: evidence,
            remediationType: .docs
        )
    }


}
