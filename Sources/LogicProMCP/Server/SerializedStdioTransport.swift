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

    /// Seconds to wait for stdout to ACCEPT a frame before declaring the output stalled. Injectable
    /// so a test can stall a real descriptor without stalling the suite.
    ///
    /// 30, not 5: a large `tools/list` to a slow client is normal traffic and must not be mistaken
    /// for a stall. The value this defends against is infinity — measured 2026-09-08 on the release
    /// binary with a reader that stopped draining, 1539 of 1539 samples parked in `write` with no
    /// deadline above it, and every reply AND every 25s timeout envelope queued behind that one
    /// write on this serial queue (#683).
    private let writeDeadline: TimeInterval

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, logger: Logger? = nil,
         writeDeadline: TimeInterval = 30) {
        self.inputFD = input
        self.outputFD = output
        self.writeDeadline = writeDeadline
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

    /// The output stopped accepting bytes. Distinct from a POSIX error because nothing FAILED — the
    /// reader stopped reading, and a caller that cannot tell those apart reports the wrong thing.
    struct OutputStalled: Swift.Error, CustomStringConvertible {
        let bytes: Int
        let seconds: TimeInterval
        var description: String {
            "stdout did not accept a \(bytes)-byte frame within \(seconds)s: the reader has stopped "
                + "draining. No part of the frame was written."
        }
    }

    /// Whether `fd` accepted a writer within `deadline`, and if not, WHY.
    ///
    /// A CASE and not a Bool. A Bool collapses "the deadline passed" with "the descriptor is
    /// invalid" and "the peer hung up", and `send` would then report every one of them as
    /// `OutputStalled` — a closed descriptor described as a slow reader, which is the confusion this
    /// whole change exists to remove one layer down.
    enum Writability: Equatable { case ready; case timedOut; case failed(Int32) }

    /// The `poll` and clock seams exist so the two paths a real pipe cannot produce are testable:
    /// a `poll` interrupted by a signal, and time passing between attempts. Without them the
    /// EINTR branch is unreachable from a test and its rule — that the deadline is an instant and
    /// not a fresh duration per attempt — can only be asserted, never checked.
    static func waitUntilWritable(
        _ fd: Int32,
        deadline: TimeInterval,
        poll pollFn: (UnsafeMutablePointer<pollfd>, nfds_t, Int32) -> Int32 = { Darwin.poll($0, $1, $2) },
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> Writability {
        // A NEGATIVE descriptor before anything else. POSIX `poll` IGNORES an entry whose fd is
        // negative and then returns 0 when the timeout expires — which is byte-for-byte the answer
        // it gives for a healthy-but-full pipe. Without this guard an invalid descriptor is
        // reported as a stalled reader, which is precisely the confusion this function was split
        // into three cases to prevent. Caught by the test that exists to keep the causes distinct.
        guard fd >= 0 else { return .failed(EBADF) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        // The deadline is an INSTANT, not a duration handed to each `poll`. Restarting the full
        // timeout after every `EINTR` was the earlier shape, and under repeated signals it extends
        // the wait without bound — a deadline that any signal can reset is not a deadline, and the
        // whole change exists to stop an unbounded wait. Found by review 2026-09-09.
        // MONOTONIC, not the wall clock. `Date` moves when the system clock is corrected: a
        // rollback lengthens the wait this function exists to bound and a forward jump shortens it,
        // so an elapsed-time deadline measured against it is not bounded by anything the process
        // controls. Found by review 2026-09-09, after the first fix here used `Date`.
        let expiry = now() &+ UInt64(max(0, deadline) * 1_000_000_000)
        while true {
            let current = now()
            if current >= expiry { return .timedOut }
            let remainingMS = Double(expiry - current) / 1_000_000
            let milliseconds = Int32(max(0, min(remainingMS, Double(Int32.max))))
            let n = withUnsafeMutablePointer(to: &pfd) { pollFn($0, 1, milliseconds) }
            if n < 0 {
                if errno == EINTR { continue }
                return .failed(errno)
            }
            if n == 0 { return .timedOut }
            if (pfd.revents & Int16(POLLNVAL)) != 0 { return .failed(EBADF) }
            // POLLERR is tested BEFORE POLLHUP, so a descriptor reporting both answers `EIO` rather
            // than `EPIPE`. That is deliberate — an error and a hangup together is an error — and
            // it is stated here because the two are easy to describe as one rule and are not.
            if (pfd.revents & Int16(POLLERR)) != 0 { return .failed(EIO) }
            // EPIPE on purpose: the reader is gone, which is the ordinary end of a session and must
            // surface as the POSIX error a caller already handles, not as a novel stall type.
            if (pfd.revents & Int16(POLLHUP)) != 0 { return .failed(EPIPE) }
            return (pfd.revents & Int16(POLLOUT)) != 0 ? .ready : .failed(EIO)
        }
    }

    /// Where the mid-frame stall report goes. Replaceable so a test can observe it without
    /// redirecting the process's stderr — a test that dup2s over `STDERR_FILENO` changes it for
    /// every other test running beside it, and the claim being checked ("ordinary traffic writes no
    /// stall line") is about whether the report HAPPENED, not about which file it landed in.
    /// Guarded, because the watchdog reads it from a global queue while a test may be replacing it.
    /// An unsynchronised `nonisolated(unsafe) var` raced on both sides: a report could be charged to
    /// whichever sink happened to be installed. Found by review 2026-09-09.
    private static let stallReportLock = NSLock()
    nonisolated(unsafe) private static var stallReporter: @Sendable (Int, TimeInterval) -> Void = {
        bytes, seconds in
        let line = "[stdio] a \(bytes)-byte frame has been writing for more than "
            + "\(String(format: "%.1f", seconds))s; the reader is stalling mid-frame\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static var reportMidFrameStall: @Sendable (Int, TimeInterval) -> Void {
        get { stallReportLock.lock(); defer { stallReportLock.unlock() }; return stallReporter }
        set { stallReportLock.lock(); stallReporter = newValue; stallReportLock.unlock() }
    }

    func send(_ data: Data) async throws {
        var mutableFrame = data
        mutableFrame.append(UInt8(ascii: "\n"))
        let frame = mutableFrame  // immutable snapshot ⇒ compiler-provable Sendable capture
        let fd = outputFD
        let deadline = writeDeadline
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            // Serial queue + blocking write ⇒ each frame is flushed atomically,
            // start-to-finish, before the next send's bytes touch the fd.
            // The wait for writability is BEFORE the first byte; the write after it is still
            // blocking. A deadline cannot be applied MID-frame: #220 exists because a frame written
            // in pieces lets a second frame interleave, and abandoning a part-written frame is that
            // same corruption by another route. So the residual — a reader that stalls after the
            // frame begins — is made LOUD rather than fixed.
            writeQueue.async {
                switch SerializedStdioTransport.waitUntilWritable(fd, deadline: deadline) {
                case .ready:
                    break
                case .timedOut:
                    cont.resume(throwing: OutputStalled(bytes: frame.count, seconds: deadline))
                    return
                case let .failed(code):
                    cont.resume(throwing: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
                    return
                }
                // A ONE-SHOT WATCHDOG, armed before the first byte and disarmed when the frame is
                // out. Reporting the overrun AFTER `writeAll` returned was the earlier shape, and it
                // says nothing while the stall is happening — the operator learns about a wedged
                // write only once it has stopped being wedged, which is exactly when the report is
                // no longer useful. It cannot abandon the frame: a part-written frame lets the next
                // one interleave, which is #220's corruption by another route.
                // CANCELLED when the frame is out, not merely flagged. The first shape scheduled an
                // uncancellable block per frame that stayed queued for the whole deadline — thirty
                // seconds of retained work items and captured frames on a busy server, growing with
                // throughput. A `DispatchWorkItem` is cancelled the moment the write returns.
                let watchdog = DispatchWorkItem {
                    SerializedStdioTransport.reportMidFrameStall(frame.count, deadline)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline,
                                                               execute: watchdog)
                do {
                    try SerializedStdioTransport.writeAll(frame, to: fd)
                    watchdog.cancel()
                    cont.resume()
                } catch {
                    watchdog.cancel()
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
    ///
    /// It returns normally only when every byte went out. Any other outcome throws, because the
    /// caller's contract is "the frame was written or it was not" — a partial frame reported as
    /// success is the interleaved stream #220 exists to prevent, arriving by the success path.
    static func writeAll(
        _ data: Data,
        to fd: Int32,
        write writeFn: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let written = writeFn(fd, base.advanced(by: offset), total - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                // A zero-byte result for a non-empty request wrote nothing and will keep writing
                // nothing. Breaking out of the loop RETURNED NORMALLY with the frame half sent, so
                // the caller was told the frame was flushed and the next frame followed the partial
                // bytes — the newline framing #220 protects, broken by the success path rather than
                // by an error. Found by review 2026-09-09.
                if written == 0 { throw POSIXError(.EIO) }
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
