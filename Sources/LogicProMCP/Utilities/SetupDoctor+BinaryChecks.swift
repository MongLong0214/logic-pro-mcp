import Foundation

extension SetupDoctor {
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
                evidence: ["argv0_resolved": executablePath ?? "<nil>"],
                remediationType: .docs
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


    static func binaryExecutableCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath = requireBinary(executablePath, runtime: runtime) else {
            return check(
                id: "binary.executable",
                domain: "binary",
                status: .skipped,
                summary: "Executable bit could not be checked because the binary path is missing.",
                evidence: [:],
                remediationType: .docs
            )
        }
        let executable = runtime.isExecutableFile(executablePath)
        return check(
            id: "binary.executable",
            domain: "binary",
            status: executable ? .pass : .fail,
            summary: executable ? "Binary has executable permission." : "Binary is not executable.",
            evidence: ["path": executablePath, "executable": String(executable)],
            remediationType: executable ? .none : .command,
            remediationValueOverride: executable ? nil : "chmod +x \(executablePath)"
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


    static func releaseSignatureCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath = requireBinary(executablePath, runtime: runtime) else {
            return check(
                id: "release.signature",
                domain: "release",
                status: .skipped,
                summary: "Signature verification skipped because the binary path is missing.",
                evidence: [:],
                remediationType: .docs
            )
        }
        guard let output = runtime.runCommand("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", executablePath]) else {
            return check(
                id: "release.signature",
                domain: "release",
                status: .warn,
                summary: "codesign verification could not be executed.",
                evidence: ["path": executablePath],
                remediationType: .docs
            )
        }
        return check(
            id: "release.signature",
            domain: "release",
            status: output.exitCode == 0 ? .pass : .warn,
            summary: output.exitCode == 0 ? "Binary signature verifies." : "Binary signature did not verify.",
            evidence: [
                "path": executablePath,
                "exit_code": String(output.exitCode),
                "stderr": output.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            ],
            remediationType: output.exitCode == 0 ? .none : .docs
        )
    }


    static func releaseQuarantineCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath = requireBinary(executablePath, runtime: runtime) else {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .skipped,
                summary: "Quarantine check skipped because the binary path is missing.",
                evidence: [:],
                remediationType: .docs
            )
        }
        guard let output = runtime.runCommand("/usr/bin/xattr", ["-p", "com.apple.quarantine", executablePath]) else {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .warn,
                summary: "xattr quarantine check could not be executed.",
                evidence: ["path": executablePath],
                remediationType: .docs
            )
        }
        // Distinguish three outcomes instead of folding everything but exit 0 into
        // .pass. xattr exits non-zero both when the attribute is absent (exit 1,
        // "No such xattr") AND on permission-denied or other errors; collapsing all
        // of those to "not quarantined" would let the doctor affirm a clean state it
        // never verified.
        let trimmedStderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence: [String: String] = [
            "path": executablePath,
            "exit_code": String(output.exitCode),
            "stderr": trimmedStderr,
        ]
        if output.exitCode == 0 {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .warn,
                summary: "Binary has a macOS quarantine attribute.",
                evidence: evidence,
                remediationType: .command,
                remediationValueOverride: "xattr -d com.apple.quarantine \(executablePath)"
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
