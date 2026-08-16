import Testing
@testable import LogicProMCP

private final class PermissionRuntimeHarness: @unchecked Sendable {
    var prompts: [Bool] = []
    var probeCalls = 0
    var accessibility = true
    var running = true
    var probeResult = true
    var systemEventsProbeCalls = 0
    // Tri-state now (was Bool): the seam returns a CheckState so a could-not-run
    // probe can be modelled as .notVerifiable, distinct from a denial (.notGranted).
    var systemEventsProbeState: PermissionChecker.CheckState = .granted

    func runtime() -> PermissionChecker.Runtime {
        PermissionChecker.Runtime(
            checkAccessibility: { prompt in
                self.prompts.append(prompt)
                return self.accessibility
            },
            isLogicProRunning: { self.running },
            runAutomationProbe: {
                self.probeCalls += 1
                return self.probeResult
            },
            runSystemEventsAutomationProbe: {
                self.systemEventsProbeCalls += 1
                return self.systemEventsProbeState
            }
        )
    }
}

@Test func testPermissionCheckerSystemEventsAutomationProbeReflectsGrant() {
    let harness = PermissionRuntimeHarness()
    harness.systemEventsProbeState = .granted

    let state = PermissionChecker.checkSystemEventsAutomationState(runtime: harness.runtime())

    #expect(state == .granted)
    #expect(PermissionChecker.checkSystemEventsAutomation(runtime: harness.runtime()))
    #expect(harness.systemEventsProbeCalls == 2)
}

@Test func testPermissionCheckerSystemEventsAutomationProbeRunsEvenWhenLogicProNotRunning() {
    // System Events is always running; its probe is NOT gated on Logic Pro
    // (unlike the Logic Pro automation probe), so a denied System Events target
    // is reported as not_granted, not not_verifiable.
    let harness = PermissionRuntimeHarness()
    harness.running = false
    harness.systemEventsProbeState = .notGranted

    let state = PermissionChecker.checkSystemEventsAutomationState(runtime: harness.runtime())

    #expect(state == .notGranted)
    #expect(harness.systemEventsProbeCalls == 1)
}

@Test func testPermissionCheckerSystemEventsProbeCouldNotRunIsNotVerifiable() {
    // A probe that could not run (osascript timeout / spawn failure) maps to
    // .notVerifiable, NOT .notGranted — an infrastructure failure is not a denial.
    let harness = PermissionRuntimeHarness()
    harness.systemEventsProbeState = .notVerifiable

    let state = PermissionChecker.checkSystemEventsAutomationState(runtime: harness.runtime())

    #expect(state == .notVerifiable)
    // Force/negation form, NOT `== false`: `#expect(!(bool))` is a DEAD no-op
    // under this repo's pinned swift-testing (it passes even when flipped to `== true`).
    // `!expr` is the only reliable Bool form. This guards the honesty invariant that a
    // could-not-run probe is NOT advertised as granted (would poison allGranted / #188).
    #expect(!PermissionChecker.checkSystemEventsAutomation(runtime: harness.runtime()))
}

@Test func testPermissionCheckerCheckAccessibilityUsesInjectedRuntimeAndPrompt() {
    let harness = PermissionRuntimeHarness()
    harness.accessibility = false

    let granted = PermissionChecker.checkAccessibility(prompt: true, runtime: harness.runtime())

    #expect(!granted)
    #expect(harness.prompts == [true])
}

@Test func testPermissionCheckerCheckAutomationSkipsProbeWhenLogicProIsNotRunning() {
    let harness = PermissionRuntimeHarness()
    harness.running = false

    let granted = PermissionChecker.checkAutomation(runtime: harness.runtime())
    let state = PermissionChecker.checkAutomationState(runtime: harness.runtime())

    #expect(!granted)
    #expect(state == .notVerifiable)
    #expect(harness.probeCalls == 0)
}

@Test func testPermissionCheckerCheckAutomationUsesProbeResultWhenRunning() {
    let harness = PermissionRuntimeHarness()
    harness.running = true
    harness.probeResult = false

    let granted = PermissionChecker.checkAutomation(runtime: harness.runtime())

    #expect(!granted)
    #expect(harness.probeCalls == 1)
}

@Test func testPermissionCheckerCheckAggregatesInjectedRuntime() {
    let harness = PermissionRuntimeHarness()
    harness.accessibility = false
    harness.running = false

    let status = PermissionChecker.check(runtime: harness.runtime())

    #expect(!status.accessibility)
    #expect(status.accessibilityState == .notGranted)
    #expect(!status.automationLogicPro)
    #expect(status.automationState == .notVerifiable)
    #expect(!status.automationVerifiable)
    #expect(!status.allGranted)
    #expect(status.summary.contains("NOT VERIFIABLE"))
}

// MARK: - #544 review MAJOR — `aggregateState` must not conflate "undetermined"
// with "denied". `PermissionStatus.allGranted` is a plain Bool that
// intentionally collapses both into `false` for fail-closed callers
// (`--check-permissions`, `SetupDoctor`); `aggregateState` is the tri-state a
// caller that must NOT make that collapse (the `system.permissions` JSON
// field) reads instead. All constructed directly via the existing
// state-based `PermissionStatus` initializer — no live TCC call, no seam
// needed, so the mapping is pinned as pure data-in/data-out.

@Test func testAggregateStateIsGrantedOnlyWhenEveryCheckIsGranted() {
    let status = PermissionChecker.PermissionStatus(
        accessibilityState: .granted,
        automationState: .granted,
        systemEventsAutomationState: .granted,
        postEventAccessState: .granted
    )
    #expect(status.aggregateState == .granted)
}

@Test func testAggregateStateReportsNotVerifiableWhenNothingIsDeniedButSomethingIsUndetermined() {
    // Exact reproduction from the #544 adversarial review: Logic Pro
    // automation is granted, but the SEPARATE System Events automation
    // target could not be verified (e.g. an osascript timeout). Pre-fix,
    // `SystemDispatcher` only special-cased `automationState == .notVerifiable`,
    // so this exact combination fell through to `.bool(status.allGranted)` ==
    // `.bool(false)` — indistinguishable from a real denial.
    let status = PermissionChecker.PermissionStatus(
        accessibilityState: .granted,
        automationState: .granted,
        systemEventsAutomationState: .notVerifiable,
        postEventAccessState: .granted
    )
    #expect(status.aggregateState == .notVerifiable)
}

@Test func testAggregateStateReportsNotVerifiableWhenLogicProAutomationItselfIsUndetermined() {
    // The ORIGINAL pre-fix special case (Logic Pro not running) must still
    // resolve to undetermined, not a denial — this direction must not
    // regress while fixing the MAJOR above.
    let status = PermissionChecker.PermissionStatus(
        accessibilityState: .granted,
        automationState: .notVerifiable,
        systemEventsAutomationState: .granted,
        postEventAccessState: .granted
    )
    #expect(status.aggregateState == .notVerifiable)
}

@Test func testAggregateStateReportsNotGrantedWhenAnythingIsMeasuredDenied() {
    // A REAL denial must still win over "granted" — the fix must not soften
    // `aggregateState` into optimism. Accessibility denied, everything else
    // granted.
    let status = PermissionChecker.PermissionStatus(
        accessibilityState: .notGranted,
        automationState: .granted,
        systemEventsAutomationState: .granted,
        postEventAccessState: .granted
    )
    #expect(status.aggregateState == .notGranted)
}

@Test func testAggregateStatePrefersDeniedOverUndeterminedWhenBothArePresent() {
    // A measured denial must win over an undetermined sibling, not average
    // out to "undetermined" — a real refusal is never softened by an
    // unrelated check that simply never ran.
    let status = PermissionChecker.PermissionStatus(
        accessibilityState: .notGranted,
        automationState: .notVerifiable,
        systemEventsAutomationState: .granted,
        postEventAccessState: .granted
    )
    #expect(status.aggregateState == .notGranted)
}

@Test(processInspectionUnavailableInSandbox)
func testPermissionCheckerProductionWrapperFunctionsReturnStatuses() {
    // The Bool returns are environment-dependent (real TCC state), so no value
    // assertion is possible; the deterministic invariant is that check() always
    // returns a populated status summary. The wrapper calls are smoke coverage.
    _ = PermissionChecker.checkAccessibility(prompt: false)
    _ = PermissionChecker.checkAutomation()
    let status = PermissionChecker.check()

    #expect(!status.summary.isEmpty)
}
