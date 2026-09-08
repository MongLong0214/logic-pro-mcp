import Foundation
import Testing
@testable import LogicProMCP

/// #683 — a stalled stdout write stopped every reply, including the timeout envelopes.
///
/// Reproduced on the release binary: with a reader that stopped draining, 1539 of 1539 samples were
/// parked in `writeAll` -> `Darwin.write` on the serial write queue. The queue is serial, so replies
/// AND the 25s `operation_timeout` envelopes queued behind one write that had no deadline — which is
/// why "no response, ever, not even a timeout" was the signature rather than a puzzle.
///
/// These cases use a real pipe with a real full buffer, and a short injected deadline so a stall
/// under test does not stall the suite.
@Suite("Issue #683 — a bounded stdout write")
struct SerializedStdioTransportStallTests {

    /// A pipe whose read end is deliberately not drained, filled until the next write would block.
    private static func fullPipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        // Non-blocking only while FILLING, so the setup cannot hang; the transport's own write is
        // restored to blocking below, because blocking is the behaviour under test.
        let flags = fcntl(fds[1], F_GETFL, 0)
        _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK)
        let chunk = [UInt8](repeating: 0x41, count: 4096)
        while true {
            let n = chunk.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
            if n < 0 { break }
        }
        _ = fcntl(fds[1], F_SETFL, flags)
        return (fds[0], fds[1])
    }

    @Test("a reader that stopped draining is OutputStalled, and the suite does not hang")
    func aStalledReaderIsReportedRatherThanWaitedOnForever() {
        let p = Self.fullPipe()
        defer { close(p.read); close(p.write) }
        let transport = SerializedStdioTransport(input: p.read, output: p.write, writeDeadline: 0.2)

        // The send is raced against a bound. Without one, DELETING the deadline does not fail this
        // test — it HANGS it, and a hung test is not a red test: it is a suite that never finishes
        // and a mutation that cannot be shown to be caught. Found by review 2026-09-09.
        let outcome = Self.withBound(seconds: 5) {
            do {
                try await transport.send(Data(#"{"jsonrpc":"2.0"}"#.utf8))
                return "accepted"
            } catch let stalled as SerializedStdioTransport.OutputStalled {
                // 17 payload bytes plus the newline the transport appends. My first expectation said
                // 17 and the test said 18 — the frame IS the payload plus its delimiter.
                #expect(stalled.bytes == 18)
                #expect(stalled.description.contains("No part of the frame was written."))
                return "stalled"
            } catch {
                return "other: \(error)"
            }
        }
        #expect(outcome == "stalled")
    }

    /// Runs `body` and answers `"unbounded"` if it has not finished within `seconds`.
    ///
    /// A task group does NOT bound this. `cancelAll` only requests cooperative cancellation, and
    /// leaving the group's scope waits for every child — so a body suspended on a `send` whose
    /// dispatch queue is blocked inside `write` never lets the group return, and the "bound" hangs
    /// exactly where the defect does. Found by review 2026-09-09.
    ///
    /// A detached task plus a semaphore does bound the VERDICT: the blocked task is still there, but
    /// the test reports and fails instead of hanging, which is what a mutation needs in order to be
    /// caught rather than merely to stall the suite.
    private static func withBound(
        seconds: Double,
        _ body: @escaping @Sendable () async -> String
    ) -> String {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let value = await body()
            box.set(value)
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return "unbounded" }
        return box.value ?? "unbounded"
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// A closed descriptor is not a slow reader. A Bool return made these identical.
    @Test("a closed read end is a POSIX error, not a stall")
    func aClosedPeerIsAPosixErrorNotAStall() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        close(fds[0])                       // the peer is gone
        defer { close(fds[1]) }
        let transport = SerializedStdioTransport(input: fds[0], output: fds[1], writeDeadline: 0.2)

        do {
            try await transport.send(Data("x".utf8))
            Issue.record("a closed peer accepted a frame")
        } catch is SerializedStdioTransport.OutputStalled {
            Issue.record("a closed peer was reported as a stalled reader")
        } catch let posix as POSIXError {
            // EPIPE specifically. "Some POSIXError" passes for EBADF, EIO and every other cause,
            // so it does not distinguish a closed peer from any other failure — which is the whole
            // distinction this case is named for. Found by review 2026-09-09.
            #expect(posix.code == .EPIPE)
        } catch {
            Issue.record("a closed peer produced \(error), not a POSIXError")
        }
    }

    /// TWO invalid descriptors, because they take different routes and only one of them was
    /// covered. `-1` never reaches `poll` at all — it is refused by the guard above it, and
    /// `Darwin.write(-1, …)` would throw `EBADF` on its own, so that case passes with the whole
    /// deadline deleted and witnesses nothing. A CLOSED POSITIVE descriptor is the one that goes
    /// through `poll` and comes back `POLLNVAL`. Found by review 2026-09-09.
    @Test("a negative descriptor is a POSIX error, not a stall")
    func anInvalidDescriptorIsAPosixErrorNotAStall() async throws {
        let transport = SerializedStdioTransport(input: STDIN_FILENO, output: -1, writeDeadline: 0.2)
        do {
            try await transport.send(Data("x".utf8))
            Issue.record("an invalid descriptor accepted a frame")
        } catch is SerializedStdioTransport.OutputStalled {
            Issue.record("an invalid descriptor was reported as a stalled reader")
        } catch let posix as POSIXError {
            #expect(posix.code == .EBADF)
        } catch {
            Issue.record("an invalid descriptor produced \(error), not a POSIXError")
        }
    }

    /// The OTHER invalid descriptor, and the one `-1` never reaches. A negative fd is refused by the
    /// guard above `poll`; a descriptor that was real and has been closed goes THROUGH `poll` and
    /// comes back `POLLNVAL`. Measured on this host: `poll` on a closed fd returns 1 with
    /// `revents == POLLNVAL (32)`, not 0 — so the two really are different branches and the `-1`
    /// case witnesses only one of them.
    ///
    /// This calls `waitUntilWritable` directly rather than sending through a transport, because a
    /// closed descriptor number is immediately available for REUSE: routed through a transport, the
    /// first thing that opens a file takes the number back and the test then measures a live fd.
    /// That is how the first version of this case failed — it reported a stall on a descriptor that
    /// had already been recycled.
    @Test("a closed descriptor is EBADF through POLLNVAL, not a stall")
    func aClosedDescriptorIsEBADFThroughPOLLNVAL() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let closed = fds[1]
        close(fds[0])
        close(fds[1])
        let verdict = SerializedStdioTransport.waitUntilWritable(closed, deadline: 0.2)
        #expect(verdict == .failed(EBADF))
    }

    /// A signal must not extend the deadline.
    ///
    /// `poll` answers `-1`/`EINTR` for the first eight attempts and becomes writable on the ninth,
    /// while the clock advances 0.05s per reading against a 0.2s deadline. A deadline that is an
    /// INSTANT expires on the fourth reading and answers `timedOut` having polled three times. One
    /// that hands each attempt the full duration never expires, reaches the ninth attempt and
    /// answers `ready` — the wait extended by signals, which is the defect.
    ///
    /// The ninth attempt exists so the wrong implementation TERMINATES. Without it the mutant spins
    /// in a synchronous loop that no async timeout can interrupt, and the suite hangs instead of
    /// going red — a mutation that hangs has not been shown to be caught.
    @Test("a signal on every poll does not extend the deadline")
    func repeatedEINTRDoesNotExtendTheDeadline() {
        let clock = TickingClock(step: 0.05)
        let attempts = Counter()
        let verdict = SerializedStdioTransport.waitUntilWritable(
            STDOUT_FILENO,
            deadline: 0.2,
            poll: { pfd, _, _ in
                attempts.bump()
                if attempts.value <= 8 { errno = EINTR; return -1 }
                pfd.pointee.revents = Int16(POLLOUT)
                return 1
            },
            now: { clock.now() })

        #expect(verdict == .timedOut)
        #expect(attempts.value <= 8)
    }

    /// A monotonic clock that moves only when it is read, so the test does not sleep and does not
    /// flake. Nanoseconds, matching production: the deadline is measured against `DispatchTime`
    /// rather than `Date`, because a wall clock can be corrected backwards and lengthen the very
    /// wait the deadline exists to bound.
    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private let step: UInt64
        private var elapsed: UInt64 = 0
        init(step: TimeInterval) { self.step = UInt64(step * 1_000_000_000) }
        func now() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let value = elapsed
            elapsed &+= step
            return value
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A write that reports zero bytes for a non-empty request wrote nothing and will keep writing
    /// nothing. Treating it as "done" returned NORMALLY with the frame half sent, so the caller was
    /// told the frame was flushed and the next frame followed the partial bytes. A real pipe never
    /// produces this, which is why it needs a seam rather than a fixture.
    @Test("a zero-length write is an error, not a finished frame")
    func aZeroLengthWriteIsNotSuccess() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        var calls = 0
        #expect(throws: POSIXError.self) {
            try SerializedStdioTransport.writeAll(
                Data("abcdef".utf8),
                to: fds[1],
                write: { _, _, _ in calls += 1; return calls == 1 ? 2 : 0 })
        }
        // It wrote two bytes and then stalled at zero: the frame is incomplete, and the point is
        // that this is reported rather than returned as success.
        #expect(calls == 2)
    }



    /// The deadline must not fire on ordinary traffic, or the fix trades a hang for a broken server.
    ///
    /// It asserts BOTH halves of the criterion: 200 frames go out without throwing, AND the
    /// mid-frame stall report never fires. The name claimed the second half before any test checked
    /// it — found by review 2026-09-09 — so the report is routed through a replaceable sink and
    /// counted here rather than left as an unverified word in a test name.
    @Test("a drained pipe accepts many frames with no stall and no stall report")
    func ordinaryTrafficIsUnaffected() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        // Immutable copies: the closures below run concurrently and cannot capture the `var`.
        let readEnd = fds[0]
        let writeEnd = fds[1]
        let drained = Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
                if n <= 0 { return }
            }
        }
        drained.start()
        let reports = Counter()
        let original = SerializedStdioTransport.reportMidFrameStall
        SerializedStdioTransport.reportMidFrameStall = { _, _ in reports.bump() }
        defer { SerializedStdioTransport.reportMidFrameStall = original }

        let transport = SerializedStdioTransport(input: STDIN_FILENO, output: writeEnd, writeDeadline: 5)
        for i in 0..<200 {
            try await transport.send(Data(String(repeating: "\(i % 10)", count: 4096).utf8))
        }
        #expect(reports.value == 0)
    }

    /// The watchdog's own case: a write that is still going when the deadline passes reports WHILE
    /// it is stuck, not after it recovers. The reader here drains only after a pause, so the frame
    /// completes and the send succeeds — the report is the only observable difference, which is the
    /// point of arming it.
    @Test("a write still going at the deadline is reported while it is stuck")
    func theMidFrameWatchdogFiresDuringTheStall() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let readEnd = fds[0]

        // The report has to arrive WHILE the write is stuck. Counting it after `send` returns is
        // satisfied by an implementation that reports afterwards — which is the shape this replaced,
        // so the test would not have told the two apart. The sink signals, and the test waits for
        // that signal BEFORE the send completes. Found by review 2026-09-09.
        let reported = DispatchSemaphore(value: 0)
        let original = SerializedStdioTransport.reportMidFrameStall
        SerializedStdioTransport.reportMidFrameStall = { _, _ in reported.signal() }
        defer { SerializedStdioTransport.reportMidFrameStall = original }

        // A reader that sleeps first, so the write blocks mid-frame past the deadline and then
        // completes. 256KB is comfortably past a pipe buffer.
        let late = Thread {
            Thread.sleep(forTimeInterval: 3.0)
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
                if n <= 0 { return }
            }
        }
        late.start()

        let transport = SerializedStdioTransport(input: STDIN_FILENO, output: fds[1], writeDeadline: 0.3)
        let sent = DispatchSemaphore(value: 0)
        Task.detached {
            try? await transport.send(Data(String(repeating: "z", count: 262_144).utf8))
            sent.signal()
        }
        // The reader wakes at 3s; a report seen before then happened while the write was blocked.
        #expect(reported.wait(timeout: .now() + 2.0) == .success,
                "no stall report arrived while the write was still blocked")
        #expect(sent.wait(timeout: .now() + 10.0) == .success, "the frame never completed")
    }

    /// Criterion 3 of the ticket, which had no test. After a frame is refused, what reached the pipe
    /// must be WHOLE frames — the refusal happens before the first byte, so the stream ends on a
    /// newline and no partial JSON object trails it. Asserting the throw without asserting this
    /// leaves the property the change is built on (#220: a part-written frame lets the next one
    /// interleave) unchecked.
    ///
    /// The pipe is filled with real frames rather than filler, because filler cannot witness frame
    /// integrity: reading back 0x41 bytes says nothing about JSON boundaries.
    ///
    /// What this case does NOT do is catch a mutation that abandons a part-written frame, and the
    /// reason is worth stating rather than leaving as a gap. Measured: injecting an early return
    /// after a partial write left this test GREEN, because through a pipe the partial case never
    /// arises — with no reader draining, a blocking `write` fills what it can and then BLOCKS for
    /// the rest instead of returning a short count, so every frame here is either written whole or
    /// refused before its first byte. The property is structural, not luck. The one path that can
    /// produce a short count is a `write` that answers zero, and that has its own case through the
    /// seam below, which does catch it.
    @Test("after a refused frame the pipe holds only whole frames")
    func aRefusedFrameLeavesNoPartialJSON() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let transport = SerializedStdioTransport(input: fds[0], output: fds[1], writeDeadline: 0.2)

        let payload = String(repeating: "x", count: 8000)
        var refused = false
        for i in 0..<64 {
            do {
                try await transport.send(Data(#"{"jsonrpc":"2.0","id":\#(i),"p":"\#(payload)"}"#.utf8))
            } catch is SerializedStdioTransport.OutputStalled {
                refused = true
                break
            }
        }
        #expect(refused, "the pipe never filled, so nothing was refused")

        // Everything the pipe holds, without blocking once it is drained.
        let flags = fcntl(fds[0], F_GETFL, 0)
        _ = fcntl(fds[0], F_SETFL, flags | O_NONBLOCK)
        var drained = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fds[0], $0.baseAddress, $0.count) }
            if n <= 0 { break }
            drained.append(contentsOf: buf[0..<n])
        }

        #expect(drained.last == UInt8(ascii: "\n"), "the stream does not end on a frame boundary")
        let lines = drained.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Non-vacuity: a test that drained nothing would satisfy "every line parses" for free.
        #expect(lines.count >= 2, "only \(lines.count) frame(s) reached the pipe")
        #expect(drained.count > 16_000, "only \(drained.count) bytes reached the pipe")
        for line in lines {
            #expect(
                (try? JSONSerialization.jsonObject(with: Data(line))) != nil,
                "a partial object reached the pipe")
        }
    }

    /// #220's property, asserted directly rather than assumed to survive the change.
    @Test("frames still do not interleave under concurrency")
    func framesRemainWholeUnderConcurrency() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0]
        let writeEnd = fds[1]
        defer { close(writeEnd) }
        let transport = SerializedStdioTransport(input: STDIN_FILENO, output: writeEnd, writeDeadline: 5)

        let collected = Task<[String], Never> {
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while out.filter({ $0 == UInt8(ascii: "\n") }).count < 50 {
                let n = buf.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            return String(decoding: out, as: UTF8.self)
                .split(separator: "\n").map(String.init)
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let body = String(repeating: String(format: "%02d", i), count: 2048)
                    try? await transport.send(Data(body.utf8))
                }
            }
        }
        let lines = await collected.value
        close(readEnd)
        #expect(lines.count == 50)
        // Every line must be one frame repeated from a single sender, not a splice of two.
        for line in lines {
            let head = String(line.prefix(2))
            #expect(line == String(repeating: head, count: line.count / 2))
        }
    }
}
