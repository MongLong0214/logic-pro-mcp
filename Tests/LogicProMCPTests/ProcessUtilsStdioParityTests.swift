import AppKit
import Foundation
import Testing
@testable import LogicProMCP

// RB-2 (2026-05-08 enterprise review) closed in v3.4.0: pre-fix
// `ProcessUtils.logicProApp()` and the `logicProBundleURL` runtime
// closure wrapped their `NSRunningApplication` / `NSWorkspace` calls
// in `runAppKit`, which forces a nil return whenever the server runs
// as an MCP-client stdio subprocess (no AppKit runloop). The live
// e2e harness reported `logic_pro_running:false` even when System
// Events on the same host could see Logic — exactly that bug.
//
// These tests pin the post-fix behaviour: when Logic Pro is installed
// on the host, the production `Runtime` MUST be able to look up its
// bundle URL without depending on the AppKit runloop. The tests skip
// gracefully on CI hosts where Logic isn't installed (the production
// release pipeline runs on macos-15 GitHub runners which don't have
// Logic Pro), so this guard is most useful on developer machines and
// any future macOS runner with Logic available.

private func logicProInstalled() -> Bool {
    return FileManager.default.fileExists(atPath: "/Applications/Logic Pro.app")
}

@Test func testProcessUtilsBundleURLResolvesWithoutAppKitRunloop() async {
    guard logicProInstalled() else {
        // CI without Logic Pro — the assertion below would fail on
        // missing bundle, not on the bug under test. Skip cleanly.
        return
    }

    // Run the lookup on a detached cooperative-pool task — no main
    // runloop, no AppKit context. Pre-fix this returned nil because
    // `runAppKit`'s `CFRunLoopIsWaiting` check failed and the closure
    // was never executed. Post-fix the launch-services query runs
    // directly and resolves the bundle URL.
    let url: URL? = await Task.detached(priority: .userInitiated) {
        ProcessUtils.Runtime.production.logicProBundleURL()
    }.value

    #expect(url != nil, "Logic Pro bundle URL must resolve from a non-main task without AppKit runloop")
    #expect(url?.lastPathComponent == "Logic Pro.app")
}

@Test func testProcessUtilsLogicProVersionResolvesOffMain() async {
    guard logicProInstalled() else { return }

    let version: String? = await Task.detached(priority: .userInitiated) {
        ProcessUtils.logicProVersion(runtime: .production)
    }.value

    #expect(version != nil, "Logic Pro version must resolve off-main when bundle lookup no longer requires AppKit runloop")
    if let version {
        // Logic Pro 12.x is the supported minimum; a successful
        // lookup should return a string starting with a digit.
        #expect((version.first?.isNumber)!, "version '\(version ?? "")' should start with a digit")
    }
}

@Test func testProcessUtilsIsLogicProRunningWorksOffMain() async {
    // Even without Logic running, the *call* must return a valid Bool
    // (not deadlock, not crash) when invoked off-main with no AppKit
    // runloop. The assertion is intentionally weak — we only check
    // that the function returns within a reasonable budget.
    let result: Bool = await Task.detached(priority: .userInitiated) {
        ProcessUtils.isLogicProRunning(runtime: .production)
    }.value

    // Either true or false is fine — we only care that it returned.
    _ = result
}
