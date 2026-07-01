import Darwin
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #220: the swift-sdk StdioTransport corrupts the stdout stream under
/// concurrent large writes (reentrant `send` interleaves partial frames).
/// `SerializedStdioTransport` writes each frame atomically. These tests drive
/// the transport over real OS pipes to prove frames never interleave and that
/// the read path frames correctly.
@Suite("SerializedStdioTransport")
struct SerializedStdioTransportTests {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var done = false
        func append(_ bytes: ArraySlice<UInt8>) { lock.lock(); data.append(contentsOf: bytes); lock.unlock() }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        func finish() { lock.lock(); done = true; lock.unlock() }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    @Test("concurrent large sends never interleave frames on the wire")
    func concurrentSendsAreAtomic() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0]
        let writeEnd = fds[1]

        // Drain the pipe concurrently so blocking writes never deadlock on a
        // full pipe buffer.
        let collected = DataBox()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let r = buf.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
                if r <= 0 { break }
                collected.append(buf[0..<r])
            }
            collected.finish()
        }

        let transport = SerializedStdioTransport(output: writeEnd)
        let n = 40
        // Each frame is large (~8 KB) and self-identifying: id must equal marker,
        // so any byte-level interleaving of two frames is detectable.
        let payloads = (0..<n).map { i in
            "{\"id\":\(i),\"marker\":\(i),\"pad\":\"" + String(repeating: "x", count: 8000) + "\"}"
        }
        await withTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask { try? await transport.send(Data(payload.utf8)) }
            }
        }
        close(writeEnd)
        // Wait for the reader to hit EOF (async-safe poll — no semaphore.wait).
        for _ in 0..<600 where !collected.isDone { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(collected.isDone)
        close(readEnd)

        let all = collected.snapshot()
        let lines = all.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
        #expect(lines.count == n, "expected \(n) intact frames, got \(lines.count)")
        var seen = Set<Int>()
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                Issue.record("a frame was not complete valid JSON — frames interleaved")
                continue
            }
            let id = obj["id"] as? Int
            let marker = obj["marker"] as? Int
            #expect(id != nil && id == marker, "frame fields must all belong to the same response")
            if let id { seen.insert(id) }
        }
        #expect(seen.count == n, "every distinct frame must arrive exactly once and intact")
    }

    @Test("receive() frames newline-delimited input and finishes on EOF")
    func receiveFramesInput() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0]
        let writeEnd = fds[1]

        let transport = SerializedStdioTransport(input: readEnd)
        try await transport.connect()

        let frames = ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"]
        // Write two frames in one chunk and one split across writes to exercise
        // buffering across reads.
        let blob = (frames[0] + "\n" + frames[1] + "\n" + frames[2]).data(using: .utf8)!
        _ = blob.withUnsafeBytes { Darwin.write(writeEnd, $0.baseAddress, $0.count) }
        _ = "\n".data(using: .utf8)!.withUnsafeBytes { Darwin.write(writeEnd, $0.baseAddress, $0.count) }
        close(writeEnd) // EOF → stream finishes

        var received: [String] = []
        for try await frame in transport.receive() {
            received.append(String(decoding: frame, as: UTF8.self))
        }
        await transport.disconnect()
        close(readEnd)

        #expect(received == frames)
    }
}
