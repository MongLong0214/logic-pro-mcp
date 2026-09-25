import Darwin
import Foundation
import Testing
@testable import LogicProMCP

/// #947. The qualification session's shutdown has to stop a pipe reader that will never see end of
/// file: the server exited, but a process it started still holds the write end. Until #947 it did
/// that by closing the reader's `FileHandle` from the shutdown thread. A reader blocked in `read(2)`
/// survived that. A reader between two reads did not: its next `handle.fileDescriptor` raised an
/// Objective-C exception on the closed handle, which no Swift `catch` sees, and the test process
/// died with signal 6 and no result line.
///
/// The issue named the ordering as the whole defect. A test that only stops a BLOCKED reader passes
/// against the broken code, so each stream is also driven by a process that floods it. A reader
/// that always has data waiting is never blocked, and the stop has to land between reads.
@Suite(.serialized)
struct QualificationReaderShutdownTests {
    enum Held: String, CaseIterable, Sendable {
        /// Holds the pipe open and writes nothing, so the reader waits.
        case silentStdout, silentStderr
        /// Writes without pause, so the reader is between reads when the stop lands.
        case floodedStdout, floodedStderr

        /// A background command the script leaves running after it exits. Its descriptors are the
        /// script's, so it holds the session's pipes open.
        var command: String {
            switch self {
            case .silentStdout: "sleep 30 2>/dev/null"
            case .silentStderr: "sleep 30 >&2"
            // A frame the stdout reader accepts: JSON-RPC 2.0 without an id is a notification,
            // so the reader keeps reading instead of failing on the first line.
            case .floodedStdout: "yes '{\"jsonrpc\":\"2.0\"}' 2>/dev/null"
            case .floodedStderr: "yes >&2"
            }
        }
    }

    @Test(arguments: Held.allCases)
    func shutdownStopsAReaderThatNeverReachesEndOfFile(_ held: Held) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qualification-947-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("held.pid")
        let script = directory.appendingPathComponent("server.sh")
        try """
        #!/bin/sh
        \(held.command) &
        echo $! > '\(pidFile.path)'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let session = QualificationSubprocessSession(
            request: .init(executableURL: script, environment: [:], expectedOperationCount: 0),
            requestTimeout: 1,
            // Generous, because every case waits it out once before the stop: the holder never
            // closes the pipe. At 0.5 s all four cases timed out during a full suite run at a load
            // average near 50.
            shutdownGrace: 3
        )
        try session.start()
        // The script has to have started its holder before shutdown begins timing it. The first
        // exec of a freshly written script took longer than the grace on this host, and the case
        // then measured a forced exit instead of a reader.
        let started = Date()
        while !FileManager.default.fileExists(atPath: pidFile.path), Date().timeIntervalSince(started) < 10 {
            usleep(10_000)
        }
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Darwin.kill(pid, SIGKILL)
            }
        }

        let outcome = try session.shutdown()
        #expect(outcome.status == 0)
        #expect(!outcome.forced)
        // The holder is still running, so the pipe never reached end of file. That the stop was
        // needed at all is what makes this case about #947, and it is checked, not assumed.
        let holder = try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Darwin.kill(holder, 0) == 0)
        if held == .silentStderr || held == .floodedStderr {
            #expect(session.stderrTail.contains("stderr capture ended early"))
        }
    }
}
