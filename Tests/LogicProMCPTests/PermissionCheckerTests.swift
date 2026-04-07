import Testing
@testable import LogicProMCP

private final class PermissionRuntimeHarness: @unchecked Sendable {
    var prompts: [Bool] = []
    var probeCalls = 0
    var accessibility = true
    var running = true
    var probeResult = true

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
            }
        )
    }
}

@Test func testPermissionCheckerCheckAccessibilityUsesInjectedRuntimeAndPrompt() {
    let harness = PermissionRuntimeHarness()
    harness.accessibility = false

    let granted = PermissionChecker.checkAccessibility(prompt: true, runtime: harness.runtime())

    #expect(granted == false)
    #expect(harness.prompts == [true])
}

@Test func testPermissionCheckerCheckAutomationSkipsProbeWhenLogicProIsNotRunning() {
    let harness = PermissionRuntimeHarness()
    harness.running = false

    let granted = PermissionChecker.checkAutomation(runtime: harness.runtime())
    let state = PermissionChecker.checkAutomationState(runtime: harness.runtime())

    #expect(granted == false)
    #expect(state == .notVerifiable)
    #expect(harness.probeCalls == 0)
}

@Test func testPermissionCheckerCheckAutomationUsesProbeResultWhenRunning() {
    let harness = PermissionRuntimeHarness()
    harness.running = true
    harness.probeResult = false

    let granted = PermissionChecker.checkAutomation(runtime: harness.runtime())

    #expect(granted == false)
    #expect(harness.probeCalls == 1)
}

@Test func testPermissionCheckerCheckAggregatesInjectedRuntime() {
    let harness = PermissionRuntimeHarness()
    harness.accessibility = false
    harness.running = false

    let status = PermissionChecker.check(runtime: harness.runtime())

    #expect(status.accessibility == false)
    #expect(status.accessibilityState == .notGranted)
    #expect(status.automationLogicPro == false)
    #expect(status.automationState == .notVerifiable)
    #expect(status.automationVerifiable == false)
    #expect(status.allGranted == false)
    #expect(status.summary.contains("NOT VERIFIABLE"))
}

@Test func testPermissionCheckerProductionWrapperFunctionsReturnStatuses() {
    let accessibility = PermissionChecker.checkAccessibility(prompt: false)
    let automation = PermissionChecker.checkAutomation()
    let status = PermissionChecker.check()

    #expect(accessibility == true || accessibility == false)
    #expect(automation == true || automation == false)
    #expect(status.accessibility == true || status.accessibility == false)
    #expect(status.automationLogicPro == true || status.automationLogicPro == false)
}
