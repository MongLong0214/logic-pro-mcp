import Testing
@testable import LogicProMCP

// WS5-AC2 / PRD §2.1 G6-a: the Logic Pro automation probe reports the honest
// tri-state. A probe that could NOT run (osascript timeout / spawn failure /
// unexpected output) surfaces as .notVerifiable — NOT a false "Automation NOT
// GRANTED" denial. grant (exit 0 + name) and deny (non-zero exit) are unchanged.

private func completedResult(exitCode: Int32, stdout: String) -> BoundedProcessRunner.Result {
    .completed(BoundedProcessRunner.Output(
        exitCode: exitCode,
        stdout: stdout,
        stderr: "",
        stdoutTruncated: false,
        stderrTruncated: false
    ))
}

private func triStateRuntime(
    running: Bool,
    automationState: PermissionChecker.CheckState
) -> PermissionChecker.Runtime {
    PermissionChecker.Runtime(
        checkAccessibility: { _ in true },
        isLogicProRunning: { running },
        runAutomationProbe: { true },  // legacy Bool seam — bypassed by the tri-state seam below
        runSystemEventsAutomationProbe: { .granted },
        runAutomationProbeState: { automationState }
    )
}

// MARK: - probeState mapping (the honesty core)

@Test func testProbeStateTimedOutIsNotVerifiableNotDenial() {
    #expect(PermissionChecker.probeState(from: .timedOut, expectedName: "Logic Pro") == .notVerifiable)
}

@Test func testProbeStateSpawnFailedIsNotVerifiableNotDenial() {
    #expect(PermissionChecker.probeState(from: .spawnFailed("posix_spawn ENOENT"), expectedName: "Logic Pro") == .notVerifiable)
}

@Test func testProbeStateExitZeroWithExpectedNameIsGranted() {
    let state = PermissionChecker.probeState(from: completedResult(exitCode: 0, stdout: "Logic Pro\n"), expectedName: "Logic Pro")
    #expect(state == .granted)
}

@Test func testProbeStateNonZeroExitIsRealDenial() {
    // errAEEventNotPermitted (-1743) surfaces as a non-zero osascript exit — a
    // genuine denial, correctly reported as .notGranted (unchanged behaviour).
    let state = PermissionChecker.probeState(from: completedResult(exitCode: 1, stdout: ""), expectedName: "Logic Pro")
    #expect(state == .notGranted)
}

@Test func testProbeStateExitZeroWithUnexpectedOutputIsNotVerifiable() {
    // Ran but produced no verifiable grant answer → .notVerifiable, not a denial.
    let state = PermissionChecker.probeState(from: completedResult(exitCode: 0, stdout: "SomethingElse"), expectedName: "Logic Pro")
    #expect(state == .notVerifiable)
}

// MARK: - checkAutomationState carries the tri-state (does not collapse to a denial)

@Test func testCheckAutomationStateReportsNotVerifiableForProbeFailure() {
    // The intended observable G6-a change: a probe that could not run surfaces
    // as .notVerifiable in --check-permissions / health / doctor, not a denial.
    let state = PermissionChecker.checkAutomationState(runtime: triStateRuntime(running: true, automationState: .notVerifiable))
    #expect(state == .notVerifiable)
    // And it must NOT be advertised as granted (would poison allGranted).
    // Force/negation form (not `== false`) — the reliable Bool assertion here.
    #expect(!PermissionChecker.checkAutomation(runtime: triStateRuntime(running: true, automationState: .notVerifiable)))
}

@Test func testCheckAutomationStateGrantUnchanged() {
    #expect(PermissionChecker.checkAutomationState(runtime: triStateRuntime(running: true, automationState: .granted)) == .granted)
    #expect(PermissionChecker.checkAutomation(runtime: triStateRuntime(running: true, automationState: .granted)))
}

@Test func testCheckAutomationStateDenyUnchanged() {
    #expect(PermissionChecker.checkAutomationState(runtime: triStateRuntime(running: true, automationState: .notGranted)) == .notGranted)
    #expect(!PermissionChecker.checkAutomation(runtime: triStateRuntime(running: true, automationState: .notGranted)))
}

@Test func testCheckAutomationStateNotVerifiableWhenLogicProNotRunning() {
    // Unchanged: the probe is skipped entirely when Logic Pro is not running.
    let state = PermissionChecker.checkAutomationState(runtime: triStateRuntime(running: false, automationState: .granted))
    #expect(state == .notVerifiable)
}

// MARK: - Backward-compat: a Runtime built WITHOUT the tri-state seam lifts the Bool probe

@Test func testLegacyBoolProbeLiftsToGrantedWhenTrue() {
    let granted = PermissionChecker.Runtime(
        checkAccessibility: { _ in true },
        isLogicProRunning: { true },
        runAutomationProbe: { true },
        runSystemEventsAutomationProbe: { .granted }
    )
    #expect(PermissionChecker.checkAutomationState(runtime: granted) == .granted)
}

@Test func testLegacyBoolProbeLiftsToNotGrantedWhenFalse() {
    let denied = PermissionChecker.Runtime(
        checkAccessibility: { _ in true },
        isLogicProRunning: { true },
        runAutomationProbe: { false },
        runSystemEventsAutomationProbe: { .granted }
    )
    #expect(PermissionChecker.checkAutomationState(runtime: denied) == .notGranted)
}
