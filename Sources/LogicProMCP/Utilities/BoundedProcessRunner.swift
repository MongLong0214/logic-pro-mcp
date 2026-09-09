import Foundation

/// Runs child processes with a hard timeout and concurrent stdout/stderr drain.
///
/// This is the only safe pattern for production subprocesses in the server:
/// reading pipes after `waitUntilExit()` can deadlock once a child fills an OS
/// pipe buffer, and cooperative Swift task cancellation cannot kill a blocked
/// external process.
enum BoundedProcessRunner {
    static let defaultOutputLimitBytes = 1_048_576

    struct Output: Equatable, Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
    }

    enum Result: Equatable, Sendable {
        case completed(Output)
        case timedOut
        case spawnFailed(String)

        var output: Output? {
            if case let .completed(value) = self { return value }
            return nil
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLimitBytes: Int = defaultOutputLimitBytes
    ) -> Result {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        stdin.fileHandleForWriting.closeFile()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let maxBytes = max(0, outputLimitBytes)
        let stdoutBuffer = PipeDrainBuffer(maxBytes: maxBytes)
        let stderrBuffer = PipeDrainBuffer(maxBytes: maxBytes)
        let group = DispatchGroup()

        // #843: `availableData` raises an Objective-C `NSFileHandleOperationException` when the pipe
        // goes bad, and a Swift `catch` cannot see one. Inside a `readabilityHandler` that is worse
        // than a crash in a plain loop: the exception unwinds past `group.leave()`, so a process
        // that survived it would wait on this group forever. `read(upToCount:)` reports the same
        // condition as a Swift `Error`, and a failed read is treated exactly as end of file —
        // whatever was buffered is what the caller gets, and the group is always released.
        func drain(_ pipe: Pipe, into buffer: PipeDrainBuffer) {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let chunk = (try? fileHandle.read(upToCount: 64 * 1024)) ?? nil
                guard let chunk, !chunk.isEmpty else {
                    fileHandle.readabilityHandler = nil
                    group.leave()
                    return
                }
                buffer.append(chunk)
            }
        }
        drain(stdout, into: stdoutBuffer)
        drain(stderr, into: stderrBuffer)

        group.enter()
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            group.leave()
            group.leave()
            group.leave()
            return .spawnFailed(String(describing: error))
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            let pid = process.processIdentifier
            if process.isRunning {
                Log.warn(
                    "'\(executable)' exceeded \(timeout)s timeout (pid \(pid)); sending SIGTERM",
                    subsystem: "process"
                )
                process.terminate()
            }
            if group.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                Log.error(
                    "'\(executable)' (pid \(pid)) ignored SIGTERM after 0.2s; escalating to SIGKILL",
                    subsystem: "process"
                )
                kill(pid, SIGKILL)
                _ = group.wait(timeout: .now() + 0.5)
            }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return .timedOut
        }

        let stdoutSnapshot = stdoutBuffer.snapshot()
        let stderrSnapshot = stderrBuffer.snapshot()
        return .completed(
            Output(
                exitCode: process.terminationStatus,
                // Lenient decode: String(data:encoding:) returns nil when the
                // output-limit cut a multibyte sequence mid-scalar, nilling the
                // WHOLE buffer (dropped Korean/UTF-8 tails). String(decoding:as:)
                // substitutes U+FFFD for the truncated tail and keeps the valid
                // prefix. Valid UTF-8 is byte-identical.
                stdout: String(decoding: stdoutSnapshot.data, as: UTF8.self),
                stderr: String(decoding: stderrSnapshot.data, as: UTF8.self),
                stdoutTruncated: stdoutSnapshot.truncated,
                stderrTruncated: stderrSnapshot.truncated
            )
        )
    }

    private struct PipeDrainSnapshot {
        let data: Data
        let truncated: Bool
    }

    private final class PipeDrainBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let maxBytes: Int
        private var data = Data()
        private var truncated = false

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }

            let remaining = maxBytes - data.count
            if remaining > 0 {
                data.append(contentsOf: chunk.prefix(remaining))
            }
            if chunk.count > max(remaining, 0) {
                truncated = true
            }
        }

        func snapshot() -> PipeDrainSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return PipeDrainSnapshot(data: data, truncated: truncated)
        }
    }
}
