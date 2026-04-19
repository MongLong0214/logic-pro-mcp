import Foundation
import Testing
@testable import LogicProMCP

// Logger is a global singleton; serialize tests so sink swaps don't race.
@Suite("Logger", .serialized)
struct LoggerTests {

    /// Install a capture sink, run the body, then restore stderr + reset rate limiter.
    private func capture(_ body: () -> Void) -> [String] {
        let box = LogCaptureBox()
        let previous = Log.output
        Log.output = { msg in box.append(msg) }
        defer {
            Log.output = previous
            Log.resetForTests()
        }
        Log.resetForTests()
        body()
        return box.snapshot()
    }

    @Test("text format emits timestamp + level + subsystem + message + filename:line")
    func textFormatShape() {
        Log.setFormatForTests(.text)
        let lines = capture {
            Log.info("hello world", subsystem: "router")
        }
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.contains("[INFO]"))
        #expect(line.contains("[router]"))
        #expect(line.contains("hello world"))
        #expect(line.contains("LoggerTests.swift:"))
        #expect(line.hasSuffix("\n"))
    }

    @Test("JSON format produces one JSON object per line with required keys")
    func jsonFormatShape() throws {
        Log.setFormatForTests(.json)
        defer { Log.setFormatForTests(.text) }

        let lines = capture {
            Log.warn("disk filling up", subsystem: Log.Subsystem.poller)
        }
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.hasSuffix("\n"))
        let data = Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["level"] as? String == "WARN")
        #expect(obj["subsystem"] as? String == "poller")
        #expect(obj["message"] as? String == "disk filling up")
        #expect(obj["ts"] is String)
        #expect(obj["file"] is String)
        #expect(obj["line"] is Int)
    }

    @Test("JSON format escapes embedded quotes and control chars")
    func jsonEscaping() throws {
        Log.setFormatForTests(.json)
        defer { Log.setFormatForTests(.text) }

        let lines = capture {
            Log.error("oops \"quoted\"\nnewline\ttab", subsystem: "validation")
        }
        let data = Data(lines[0].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["message"] as? String == "oops \"quoted\"\nnewline\ttab")
    }

    @Test("setLevel filters messages below threshold at runtime")
    func runtimeLevelFiltering() {
        let original = Log.minLevel
        defer { Log.setLevel(original) }

        Log.setLevel(.warn)
        let lines = capture {
            Log.debug("d", subsystem: "main")
            Log.info("i", subsystem: "main")
            Log.warn("w", subsystem: "main")
            Log.error("e", subsystem: "main")
        }
        #expect(lines.count == 2)
        #expect(lines[0].contains("[WARN]"))
        #expect(lines[1].contains("[ERROR]"))
    }

    @Test("Subsystem enum overload matches raw string equivalent")
    func subsystemEnumOverload() {
        let lines = capture {
            Log.info("msg", subsystem: Log.Subsystem.midi)
        }
        #expect(lines.count == 1)
        #expect(lines[0].contains("[midi]"))
    }

    @Test("rate limit suppresses repeated identical messages within window")
    func rateLimitSuppression() {
        let lines = capture {
            for _ in 0..<50 {
                Log.info("tight loop", subsystem: "poller")
            }
        }
        // Threshold is 10/window; the 51 calls should emit ~10 identical lines,
        // never all 50. Different messages are counted separately.
        #expect(lines.count < 50)
        #expect(lines.count >= 1)
        #expect(lines.allSatisfy { $0.contains("tight loop") })
    }

    @Test("rate limit does not affect distinct messages")
    func rateLimitDistinctMessages() {
        let lines = capture {
            for i in 0..<30 {
                Log.info("unique #\(i)", subsystem: "poller")
            }
        }
        #expect(lines.count == 30)
    }

    @Test("output sink is swappable (DI)")
    func outputInjection() {
        let box = LogCaptureBox()
        let prev = Log.output
        Log.output = { msg in box.append(msg) }
        defer { Log.output = prev; Log.resetForTests() }
        Log.resetForTests()

        Log.error("from DI sink", subsystem: "main")
        #expect(box.snapshot().count == 1)
        #expect(box.snapshot()[0].contains("from DI sink"))
    }

    @Test("all 14 legacy subsystem string values are representable via enum")
    func legacySubsystemsCovered() {
        let legacyStrings = ["main", "server", "router", "poller", "midi", "mcu", "scripter",
                             "ax", "appleScript", "cgEvent", "keycmd", "project", "library", "validation"]
        let enumRawValues = Set(Log.Subsystem.allCases.map(\.rawValue))
        for s in legacyStrings {
            #expect(enumRawValues.contains(s), "Missing enum case for \(s)")
        }
    }
}

/// Small lock-guarded sink for capturing emitted log lines across threads.
final class LogCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(s)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
