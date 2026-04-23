import Testing
@testable import LogicProMCP

/// v3.0.6 — verifies the `library.scan_all` mode dispatch. Ralph round 2
/// requires this test to exist so a future regression that silently flips
/// the default back to `disk` (or drops a mode entirely) is caught by the
/// test suite rather than by end-user reports.
///
/// We exercise `AccessibilityChannel.parseScanMode` directly — a pure,
/// isolated function that is the single source of truth for the
/// `params["mode"] → scanner-branch` decision. The three `runXxxScan`
/// methods (`runLiveScan`, `runDiskScan`, `runBothScan`) are already
/// individually covered by other suites; the only thing we haven't locked
/// down before this test existed was "which one runs for which mode
/// string, and what's the default?".
@Suite("v3.0.6 library.scan_all mode routing")
struct ScanLibraryModeRoutingTests {

    @Test("default (nil) → ax")
    func defaultIsAX() {
        #expect(AccessibilityChannel.parseScanMode(nil) == .ax)
    }

    @Test("empty string → ax")
    func emptyStringIsAX() {
        #expect(AccessibilityChannel.parseScanMode("") == .ax)
    }

    @Test("explicit ax → ax")
    func explicitAX() {
        #expect(AccessibilityChannel.parseScanMode("ax") == .ax)
    }

    @Test("explicit disk → disk")
    func explicitDisk() {
        #expect(AccessibilityChannel.parseScanMode("disk") == .disk)
    }

    @Test("explicit both → both")
    func explicitBoth() {
        #expect(AccessibilityChannel.parseScanMode("both") == .both)
    }

    @Test("mixed case (AX, Disk, Both) — normalized to lowercase variant")
    func caseInsensitive() {
        #expect(AccessibilityChannel.parseScanMode("AX") == .ax)
        #expect(AccessibilityChannel.parseScanMode("Disk") == .disk)
        #expect(AccessibilityChannel.parseScanMode("BOTH") == .both)
    }

    @Test("unknown mode falls back to ax (not disk — v3.0.6 regression guard)")
    func unknownFallsBackToAX() {
        #expect(AccessibilityChannel.parseScanMode("filesystem") == .ax)
        #expect(AccessibilityChannel.parseScanMode("legacy") == .ax)
        #expect(AccessibilityChannel.parseScanMode("xyz") == .ax)
    }

    /// Dedicated regression test for the v3.0.5 bug: the default MUST NOT
    /// be `.disk`. Anyone re-flipping it will trip this assertion loudly.
    @Test("regression: v3.0.5 default-to-disk bug does not recur")
    func regressionNoDefaultToDisk() {
        #expect(AccessibilityChannel.parseScanMode(nil) != .disk)
        #expect(AccessibilityChannel.parseScanMode("") != .disk)
    }
}
