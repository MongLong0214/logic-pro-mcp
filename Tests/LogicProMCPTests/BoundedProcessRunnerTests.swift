import Foundation
import Testing
@testable import LogicProMCP

// WS8b (AC5) — BoundedProcessRunner is the only safe subprocess pattern in the
// server (hard timeout + concurrent pipe drain). These tests exercise its four
// real outcomes against live child processes: a clean completion, a non-zero
// exit, the timeout → SIGTERM → SIGKILL escalation on a TERM-ignoring child, a
// >64KB stdout that would deadlock a read-after-wait implementation, the
// output-limit truncation flag, and a spawn failure. `run` is synchronous, so
// these are non-async tests.
@Suite("BoundedProcessRunner")
struct BoundedProcessRunnerTests {
    @Test func normalCompletionCapturesStdoutAndExitCode() {
        let result = BoundedProcessRunner.run(executable: "/bin/echo", arguments: ["hello world"], timeout: 5)
        guard case .completed(let out) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(out.exitCode == 0)
        #expect(out.stdout == "hello world\n")
        #expect(!out.stdoutTruncated)
    }

    @Test func nonZeroExitStillCompletes() {
        let result = BoundedProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "exit 3"], timeout: 5)
        guard case .completed(let out) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(out.exitCode == 3)
    }

    @Test func slowChildTimesOut() {
        let result = BoundedProcessRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3)
        #expect(result == .timedOut)
    }

    @Test func sigtermIgnoringChildIsEscalatedToSIGKILL() {
        // The child ignores SIGTERM and would sleep well past the timeout, then
        // touch a marker. Only the SIGKILL escalation can stop it — so if the
        // marker never appears, SIGKILL fired.
        let marker = NSTemporaryDirectory() + "bpr-sigkill-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let script = "trap '' TERM; sleep 3; : > '\(marker)'"

        let result = BoundedProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], timeout: 0.3)
        #expect(result == .timedOut)

        // Wait past the child's would-be completion; a surviving (un-killed)
        // child would have created the marker by now.
        Thread.sleep(forTimeInterval: 3.3)
        #expect(!FileManager.default.fileExists(atPath: marker), "TERM-ignoring child survived the timeout → SIGKILL did not fire")
    }

    @Test func largeStdoutDoesNotDeadlock() {
        // ~180 KB of stdout — well past the ~64 KB OS pipe buffer that would
        // deadlock a read-after-waitUntilExit implementation. The concurrent
        // drain must complete it.
        let result = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes AAAAAAAA | head -n 20000"],
            timeout: 20
        )
        guard case .completed(let out) = result else {
            Issue.record("large-stdout run must complete, not deadlock or time out; got \(result)")
            return
        }
        #expect(out.stdout.utf8.count > 65_536, "expected more than one pipe buffer of stdout")
        #expect(!out.stdoutTruncated)
    }

    @Test func stdoutIsTruncatedAtOutputLimit() {
        let result = BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes AAAAAAAA | head -n 20000"],
            timeout: 20,
            outputLimitBytes: 1000
        )
        guard case .completed(let out) = result else {
            Issue.record("expected .completed, got \(result)")
            return
        }
        #expect(out.stdoutTruncated)
        #expect(out.stdout.utf8.count <= 1000)
    }

    @Test func missingExecutableFailsToSpawn() {
        let result = BoundedProcessRunner.run(
            executable: "/nonexistent/definitely-not-a-real-binary",
            arguments: [],
            timeout: 5
        )
        guard case .spawnFailed = result else {
            Issue.record("expected .spawnFailed for a missing executable, got \(result)")
            return
        }
    }
}
