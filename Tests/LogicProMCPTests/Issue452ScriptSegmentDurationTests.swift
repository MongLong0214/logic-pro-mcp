import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #452 — the AppleScript segment must be externally measurable
//
// `midi.import_file` spans three time budgets, and only the outermost one — the
// operation deadline — crossed the process boundary. The middle budget, the one
// `midiImportAppleScriptTimeout` governs and the one #449 is about, could be
// argued from summed `delay` statements but never measured: those sums exclude
// every AX query and file operation between the delays, so they cannot establish
// real headroom.
//
// The fix records a monotonic interval around the script call and emits it as a
// `script_segment.completed` trace attribute. Two properties make it evidence
// rather than decoration:
//
//  1. It is measured with `ContinuousClock`, so an NTP step cannot invent it.
//  2. It survives the trace store's attribute filter. Undeclared keys are
//     silently dropped, so an emission whose key is missing from
//     `attributePrivacyClasses` records nothing and exposes nothing while the
//     source still reads as though it emits. Asserting only "the code calls
//     record" would pass in exactly that broken state.
//
// This file covers the declaration and the clock in isolation. The end-to-end
// assertion — a real import run producing a readable duration on a stored trace
// — is in `OperationTraceTests`, which is serialized against the shared store
// that test has to drive.

@Suite("Issue #452 — AppleScript segment duration")
struct Issue452ScriptSegmentDurationTests {
    /// The key must be declared, or the emission is dropped before storage.
    @Test("the duration attribute is declared and publicly classified")
    func durationKeyIsDeclared() {
        #expect(OperationTraceStore.attributePrivacyClasses["applescript_duration_ms"] == .publicDiagnostic)
    }

    /// The formatter is the instrument; prove it can distinguish intervals and
    /// clamps rather than emitting a negative duration.
    @Test("elapsed milliseconds are non-negative and grow with real elapsed time")
    func elapsedMillisecondsIsMonotonicAndClamped() async throws {
        let start = ContinuousClock.now
        let immediate = try #require(Int(elapsedMilliseconds(since: start)))
        #expect(immediate >= 0)

        try await Task.sleep(nanoseconds: 40_000_000)
        let later = try #require(Int(elapsedMilliseconds(since: start)))
        #expect(later >= immediate)
        #expect(later >= 30, "a 40ms sleep must be visible, or the reading is not measuring anything")

        // A future instant clamps to zero instead of reporting a negative span.
        #expect(elapsedMilliseconds(since: ContinuousClock.now.advanced(by: .seconds(5))) == "0")
    }
}
