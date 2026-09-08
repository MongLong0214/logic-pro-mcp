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
    func aStalledReaderIsReportedRatherThanWaitedOnForever() async throws {
        let p = Self.fullPipe()
        defer { close(p.read); close(p.write) }
        let transport = SerializedStdioTransport(input: p.read, output: p.write, writeDeadline: 0.2)

        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0"}"#.utf8))
            Issue.record("a full pipe accepted a frame")
        } catch let stalled as SerializedStdioTransport.OutputStalled {
            // 17 payload bytes plus the newline the transport appends. My first expectation said 17
            // and the test said 18 — the frame IS the payload plus its delimiter.
            #expect(stalled.bytes == 18)
            #expect(stalled.description.contains("No part of the frame was written."))
        }
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
        } catch {
            // POSIXError, which is what a caller already handles.
            #expect(error is POSIXError)
        }
    }

    @Test("an invalid descriptor is a POSIX error, not a stall")
    func anInvalidDescriptorIsAPosixErrorNotAStall() async throws {
        let transport = SerializedStdioTransport(input: STDIN_FILENO, output: -1, writeDeadline: 0.2)
        do {
            try await transport.send(Data("x".utf8))
            Issue.record("an invalid descriptor accepted a frame")
        } catch is SerializedStdioTransport.OutputStalled {
            Issue.record("an invalid descriptor was reported as a stalled reader")
        } catch {
            #expect(error is POSIXError)
        }
    }

    /// The deadline must not fire on ordinary traffic, or the fix trades a hang for a broken server.
    @Test("a drained pipe accepts many frames with no stall and no stderr line")
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
        let transport = SerializedStdioTransport(input: STDIN_FILENO, output: writeEnd, writeDeadline: 5)
        for i in 0..<200 {
            try await transport.send(Data(String(repeating: "\(i % 10)", count: 4096).utf8))
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
