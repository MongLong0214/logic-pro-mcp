import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #449 — the import bound must outlast the import script's own polling
//
// `midi.import_file` returned `ax_write_failed` / `timedOut` while the region
// was actually landing in Logic. Cause: the script drives four polled stages —
// the File > Import > MIDI File sheet, the path-entry dialog, the import button
// and the tempo prompt — and the shared 5.0 s `appleScriptTimeout` killed
// osascript mid-import. Summing one `delay` per iteration across those loops
// gives a 17.2 s floor, so the outer bound fired first and the caller saw a
// timeout for work that had in fact succeeded.
//
// These tests lock the invariant that actually matters: the bound the import
// path runs under must exceed the budget the import script can spend. A test
// that only asserted `midiImportAppleScriptTimeout == 30.0` would pass while
// someone widened a polling loop past it, so the budget is DERIVED from the
// generated script rather than hard-coded.

/// Worst-case seconds a `repeat N times { ... delay D ... }` block can spend,
/// counting one delay per iteration. Nested loops are deliberately not summed:
/// this is a floor, and a floor is enough to prove the bound is too small.
private func pollingBudgetSeconds(of script: String) -> Double {
    let lines = script.components(separatedBy: "\n")
    var total = 0.0
    for (index, line) in lines.enumerated() {
        guard let iterations = firstInteger(in: line, after: "repeat ", before: " times") else { continue }
        // First delay inside this loop body, before its `end repeat`.
        for probe in lines.dropFirst(index + 1) {
            if probe.contains("end repeat") { break }
            if let delay = firstDouble(in: probe, after: "delay ") {
                total += Double(iterations) * delay
                break
            }
        }
    }
    return total
}

private func firstInteger(in line: String, after prefix: String, before suffix: String) -> Int? {
    guard let start = line.range(of: prefix), let end = line.range(of: suffix, range: start.upperBound..<line.endIndex)
    else { return nil }
    return Int(line[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces))
}

private func firstDouble(in line: String, after prefix: String) -> Double? {
    guard let start = line.range(of: prefix) else { return nil }
    let tail = line[start.upperBound...]
    let digits = tail.prefix { $0.isNumber || $0 == "." }
    return Double(digits)
}

@Suite("Issue #449 — midi.import_file timeout budget")
struct Issue449ImportTimeoutBudgetTests {
    /// The regression itself: the import path must not run under the shared bound.
    @Test("import path uses a bound distinct from the shared AppleScript bound")
    func importBoundIsSeparate() {
        #expect(ServerConfig.midiImportAppleScriptTimeout > ServerConfig.appleScriptTimeout)
    }

    /// The invariant that would have caught #449 before it shipped: whatever the
    /// import script can spend polling, the bound it runs under must exceed it.
    @Test("import bound exceeds the script's own derived polling floor")
    func importBoundExceedsScriptBudget() async throws {
        let box = ScriptBox()
        _ = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: try requireTemporaryMIDIFile(),
            executeScript: { script in
                box.store(script)
                return .error("stop after capture")
            }
        )

        let script = try #require(box.value, "import path must build a script to bound")
        let floor = pollingBudgetSeconds(of: script)

        // Guard the guard: if the parser stops seeing loops the test would pass
        // vacuously, so require the script to actually contain polling.
        #expect(floor > 0, "derived polling floor must be non-zero or this test proves nothing")
        #expect(
            ServerConfig.midiImportAppleScriptTimeout > floor,
            "import bound \(ServerConfig.midiImportAppleScriptTimeout)s must exceed derived polling floor \(floor)s"
        )
    }

    /// The parser is the instrument; prove it can fail before trusting it.
    @Test("polling-budget parser detects a loop it is aimed at")
    func parserDetectsKnownLoop() {
        let sample = """
        repeat 20 times
            delay 0.25
        end repeat
        """
        #expect(pollingBudgetSeconds(of: sample) == 5.0)
        #expect(pollingBudgetSeconds(of: "no loops here") == 0.0)
    }
}

/// The import path calls `executeScript` from a `@Sendable` context, so the
/// captured script has to cross a concurrency boundary rather than mutate a var.
private final class ScriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func store(_ script: String) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = script }
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func requireTemporaryMIDIFile() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("issue449-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: url)
    return url.path
}
