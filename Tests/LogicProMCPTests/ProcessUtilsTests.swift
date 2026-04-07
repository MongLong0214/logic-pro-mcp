import Darwin
import Foundation
import Testing
@testable import LogicProMCP

private final class ProcessRuntimeHarness: @unchecked Sendable {
    var pid: pid_t?
    var fallbackPID: pid_t?
    var running = false
    var activateCalls = 0
    var activateResult = true
    var bundleURL: URL?

    func runtime() -> ProcessUtils.Runtime {
        ProcessUtils.Runtime(
            logicProPID: { self.pid },
            fallbackLogicProPID: { self.fallbackPID },
            logicProRunning: { self.running },
            activateLogicPro: {
                self.activateCalls += 1
                return self.activateResult
            },
            logicProBundleURL: { self.bundleURL }
        )
    }
}

private func makeBundleURL(version: String) throws -> URL {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("app")
    let contentsURL = bundleURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    let plistURL = contentsURL.appendingPathComponent("Info.plist")
    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.apple.logic10",
        "CFBundleName": "Logic Pro",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: plistURL)
    return bundleURL
}

@Test func testProcessUtilsRunAppKitExecutesOnMainThreadWhenCalledOffMain() async {
    let executedOnMainThread: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let isMainThread = ProcessUtils.runAppKit { Thread.isMainThread }
            continuation.resume(returning: isMainThread)
        }
    }

    #expect(executedOnMainThread == true)
}

@Test func testProcessUtilsCurrentProcessMetricsAreNonNegative() {
    let metrics = ProcessUtils.currentProcessMetrics()

    #expect(metrics.memoryMB >= 0)
    #expect(metrics.cpuPercent >= 0)
    #expect(metrics.uptimeSec >= 0)
}

@Test func testProcessUtilsRuntimeControlsPIDAndRunningState() {
    let harness = ProcessRuntimeHarness()

    #expect(ProcessUtils.logicProPID(runtime: harness.runtime()) == nil)
    #expect(ProcessUtils.isLogicProRunning(runtime: harness.runtime()) == false)

    harness.pid = 4242

    #expect(ProcessUtils.logicProPID(runtime: harness.runtime()) == 4242)
    #expect(ProcessUtils.isLogicProRunning(runtime: harness.runtime()) == true)
}

@Test func testProcessUtilsFallsBackToSecondaryPIDSource() {
    let harness = ProcessRuntimeHarness()
    harness.fallbackPID = 63416

    #expect(ProcessUtils.logicProPID(runtime: harness.runtime()) == 63416)
    #expect(ProcessUtils.isLogicProRunning(runtime: harness.runtime()) == true)
}

@Test func testProcessUtilsParsesLogicProPIDFromProcessListOutput() {
    let output = """
      101 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
    63416 /Applications/Logic Pro.app/Contents/MacOS/Logic Pro
      303 /Applications/WebStorm.app/Contents/MacOS/webstorm
    """

    #expect(ProcessUtils.parseLogicProPID(fromProcessList: output) == 63416)
}

@Test func testProcessUtilsIgnoresUnrelatedProcessListRows() {
    let output = """
      101 /Applications/Logicly.app/Contents/MacOS/Logicly
      303 /Applications/WebStorm.app/Contents/MacOS/webstorm
    """

    #expect(ProcessUtils.parseLogicProPID(fromProcessList: output) == nil)
}

@Test func testProcessUtilsActivateLogicProUsesInjectedRuntime() {
    let harness = ProcessRuntimeHarness()
    harness.activateResult = false

    let activated = ProcessUtils.activateLogicPro(runtime: harness.runtime())

    #expect(activated == false)
    #expect(harness.activateCalls == 1)
}

@Test func testProcessUtilsProductionActivateWrapperReturnsWithoutCrash() {
    let activated = ProcessUtils.activateLogicPro()

    #expect(activated == true || activated == false)
}

@Test func testProcessUtilsLogicProVersionUsesInjectedBundleURL() throws {
    let harness = ProcessRuntimeHarness()
    harness.bundleURL = try makeBundleURL(version: "10.9.1")

    let version = ProcessUtils.logicProVersion(runtime: harness.runtime())

    #expect(version == "10.9.1")
}

@Test func testProcessUtilsLogicProVersionReturnsNilWithoutBundleURL() {
    let harness = ProcessRuntimeHarness()

    let version = ProcessUtils.logicProVersion(runtime: harness.runtime())

    #expect(version == nil)
}

@Test func testPermissionStatusAllGrantedSummaryOmitsRemediation() {
    let status = PermissionChecker.PermissionStatus(accessibility: true, automationLogicPro: true)

    #expect(status.allGranted == true)
    #expect(status.summary.contains("Accessibility: granted"))
    #expect(status.summary.contains("Automation (Logic Pro): granted"))
    #expect(status.summary.contains("System Settings") == false)
}

@Test func testPermissionStatusSummaryOnlyMentionsMissingAutomationGuidance() {
    let status = PermissionChecker.PermissionStatus(accessibility: true, automationLogicPro: false)

    #expect(status.allGranted == false)
    #expect(status.summary.contains("Accessibility: granted"))
    #expect(status.summary.contains("Automation (Logic Pro): NOT GRANTED"))
    #expect(status.summary.contains("Accessibility → add your terminal app") == false)
    #expect(status.summary.contains("Automation → allow control of Logic Pro"))
}
