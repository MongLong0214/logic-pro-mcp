import Darwin
import Foundation
import Logging
import MCP

/// stdio `Transport` that writes each JSON-RPC frame ATOMICALLY, fixing the
/// concurrent-large-read corruption in #220.
///
/// Root cause of #220: the swift-sdk `StdioTransport` is an actor whose `send`
/// sets stdout NON-blocking and, on a partial-write `EAGAIN`, `await`s
/// `Task.sleep` before writing the rest of the frame. Swift actor methods are
/// reentrant across `await`, and the MCP server dispatches every request in its
/// own Task — so while one `send` is suspended mid-frame, a SECOND `send` runs
/// on the same actor and writes its bytes into the middle of the first frame.
/// The newline-delimited stream is corrupted: under concurrent large reads the
/// client sees merged/split lines it cannot parse and drops the responses,
/// surfacing as "no response" (while each request succeeds when run alone).
///
/// This transport avoids the failure mode entirely:
/// * Writes run on a dedicated SERIAL queue with BLOCKING writes (stdout is
///   left in blocking mode). A frame is always written start-to-finish before
///   the next begins — there is no `EAGAIN` suspension and thus no reentrancy
///   window, so frames can never interleave.
/// * Reads run on a dedicated Thread with blocking reads, so they never occupy
///   the Swift cooperative thread pool (a blocking read there could starve
///   concurrent request handling).
///
/// It owns its own stream (created in `init`), so it needs no cross-actor
/// delegation. Frame semantics — newline-delimited, no trailing-newline in the
/// yielded frame — match the SDK transport, so the server behaves identically
/// for single-request traffic.
actor SerializedStdioTransport: Transport {
    nonisolated let logger: Logger

    private let inputFD: Int32
    private let outputFD: Int32
    private let writeQueue = DispatchQueue(label: "logic-pro-mcp.stdio.write")
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private let running = RunFlag()
    private var readThread: Thread?

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, logger: Logger? = nil) {
        self.inputFD = input
        self.outputFD = output
        self.logger = logger ?? Logger(label: "logic-pro-mcp.serialized-stdio") { _ in
            SwiftLogNoOpLogHandler()
        }
        var cont: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    func connect() async throws {
        guard !running.isRunning else { return }
        running.start()
        let fd = inputFD
        let cont = continuation
        let flag = running
        let thread = Thread {
            SerializedStdioTransport.readLoop(fd: fd, continuation: cont, running: flag)
        }
        thread.name = "logic-pro-mcp.stdio.read"
        thread.stackSize = 1 << 20
        readThread = thread
        thread.start()
    }

    func disconnect() async {
        running.stop()
        continuation.finish()
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }

    func send(_ data: Data) async throws {
        var mutableFrame = data
        mutableFrame.append(UInt8(ascii: "\n"))
        let frame = mutableFrame  // immutable snapshot ⇒ compiler-provable Sendable capture
        let fd = outputFD
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            // Serial queue + blocking write ⇒ each frame is flushed atomically,
            // start-to-finish, before the next send's bytes touch the fd.
            writeQueue.async {
                do {
                    try SerializedStdioTransport.writeAll(frame, to: fd)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking I/O (off the cooperative pool)

    /// Blocking read loop: accumulate bytes, split on newlines, yield each
    /// complete frame (without its trailing newline). Exits on EOF, hard error,
    /// or `disconnect()`.
    private static func readLoop(
        fd: Int32,
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation,
        running: RunFlag
    ) {
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pending = Data()
        while running.isRunning {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
            if n == 0 {
                continuation.finish() // EOF
                return
            }
            pending.append(contentsOf: buffer[0..<n])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let frame = pending[pending.startIndex..<newline]
                pending = pending[(newline + 1)...]
                if !frame.isEmpty {
                    continuation.yield(Data(frame))
                }
            }
        }
        continuation.finish()
    }

    /// Blocking full-frame write. Loops over partial writes and EINTR until the
    /// entire frame is flushed. On a blocking fd there is no `EAGAIN`, so this
    /// never suspends mid-frame.
    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let written = Darwin.write(fd, base.advanced(by: offset), total - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if written == 0 { break }
                offset += written
            }
        }
    }

    /// Thread-safe running flag shared with the off-actor read thread.
    private final class RunFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func start() { lock.lock(); value = true; lock.unlock() }
        func stop() { lock.lock(); value = false; lock.unlock() }
    }
}
