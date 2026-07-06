import Darwin
import CoreGraphics
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

@Test func testProcessUtilsRunAppKitExecutesOnMainThreadOrReturnsNil() async {
    let result: Bool? = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let isMainThread = ProcessUtils.runAppKit { Thread.isMainThread }
            continuation.resume(returning: isMainThread)
        }
    }

    // In a test environment without an active runloop, runAppKit may return nil
    // (deadlock guard) or true (if runloop happens to be active). Both are correct.
    if let result {
        #expect(result)
    }
}

@Test func testProcessUtilsCurrentProcessMetricsAreNonNegative() {
    let metrics = ProcessUtils.currentProcessMetrics()

    #expect(metrics.memoryMB >= 0)
    #expect(metrics.cpuPercent >= 0)
    #expect(metrics.uptimeSec >= 0)
}

@Test func testProcessUtilsMarksZeroUptimeCPUAsWarmingUp() {
    let metrics = ProcessUtils.processMetricsForSample(
        cpuTimeSec: 0.144807,
        uptimeSec: 0.001,
        residentMemoryBytes: 18_559_795
    )

    #expect(metrics.memoryMB > 17)
    #expect(metrics.cpuPercent == 0)
    #expect(metrics.cpuPercentStatus == "warming_up")
    #expect(metrics.cpuSampleWindowSec == 0)
}

@Test func testProcessUtilsReportsSampledCPUWithExplicitUnits() {
    let metrics = ProcessUtils.processMetricsForSample(
        cpuTimeSec: 1.5,
        uptimeSec: 3.0,
        residentMemoryBytes: 0
    )

    #expect(metrics.cpuPercent == 50)
    #expect(metrics.cpuPercentStatus == "sampled")
    #expect(metrics.cpuPercentUnits == "single_core_lifetime_average")
    #expect(metrics.cpuSampleWindowSec == 3)
}

@Test func testProcessUtilsRuntimeControlsPIDAndRunningState() {
    let harness = ProcessRuntimeHarness()

    #expect(ProcessUtils.logicProPID(runtime: harness.runtime()) == nil)
    #expect(!(ProcessUtils.isLogicProRunning(runtime: harness.runtime())))

    harness.pid = 4242

    #expect(ProcessUtils.logicProPID(runtime: harness.runtime()) == 4242)
    #expect(ProcessUtils.isLogicProRunning(runtime: harness.runtime()))
}

@Test func testProcessUtilsFallsBackToSecondaryPIDSource() {
    let harness = ProcessRuntimeHarness()
    harness.fallbackPID = 63416

    #expect(ProcessUtils.logicProPID(runtime: harness.runtime()) == 63416)
    #expect(ProcessUtils.isLogicProRunning(runtime: harness.runtime()))
}

@Test func testProcessUtilsParsesLogicProPIDFromProcessListOutput() {
    let output = """
      101 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
    63416 /Applications/Logic Pro.app/Contents/MacOS/Logic Pro
      303 /Applications/WebStorm.app/Contents/MacOS/webstorm
    """

    #expect(ProcessUtils.parseLogicProPID(fromProcessList: output) == 63416)
}

@Test func testProcessUtilsParsesLogicProPIDFromPgrepOutput() {
    let output = """
    7174 /Applications/Logic Pro.app/Contents/MacOS/Logic Pro
    23187 /Applications/Logic Pro.app/Contents/PlugIns/LogicProThumbnailExtension.appex/Contents/MacOS/LogicProThumbnailExtension
    50950 osascript -e tell application "System Events" to get unix id of first application process whose name is "Logic Pro"
    """

    #expect(ProcessUtils.parseLogicProPID(fromProcessList: output) == 7174)
}

@Test func testProcessUtilsParsesLogicProPIDFromWindowList() {
    let output: [[String: Any]] = [
        [
            kCGWindowOwnerName as String: "Finder",
            kCGWindowOwnerPID as String: NSNumber(value: 101),
        ],
        [
            kCGWindowOwnerName as String: "Logic Pro",
            kCGWindowOwnerPID as String: NSNumber(value: 7174),
            kCGWindowBounds as String: [
                "Width": NSNumber(value: 1600),
                "Height": NSNumber(value: 900),
            ],
        ],
    ]

    #expect(ProcessUtils.logicProPID(fromWindowList: output) == 7174)
}

@Test func testProcessUtilsIgnoresUnrelatedProcessListRows() {
    let output = """
      101 /Applications/Logicly.app/Contents/MacOS/Logicly
      303 /Applications/WebStorm.app/Contents/MacOS/webstorm
    """

    #expect(ProcessUtils.parseLogicProPID(fromProcessList: output) == nil)
}

@Test func testProcessUtilsParsesLogicProPIDFromCommandNameAndSuffixVariants() {
    #expect(ProcessUtils.parseLogicProPID(fromProcessList: "7174 Logic Pro") == 7174)
    #expect(ProcessUtils.parseLogicProPID(fromProcessList: "7175 /private/tmp/Logic Pro") == 7175)
    #expect(ProcessUtils.parseLogicProPID(fromProcessList: "-1 /Applications/Logic Pro.app/Contents/MacOS/Logic Pro") == nil)
    #expect(ProcessUtils.parseLogicProPID(fromProcessList: "abc /Applications/Logic Pro.app/Contents/MacOS/Logic Pro") == nil)
}

@Test func testProcessUtilsWindowListHandlesMissingBoundsAndRejectsZeroSizedWindows() {
    let zeroSized: [[String: Any]] = [
        [
            kCGWindowOwnerName as String: "Logic Pro",
            kCGWindowOwnerPID as String: NSNumber(value: 4000),
            kCGWindowBounds as String: [
                "Width": NSNumber(value: 0),
                "Height": NSNumber(value: 900),
            ],
        ],
    ]
    let missingBounds: [[String: Any]] = [
        [
            kCGWindowOwnerName as String: "Logic Pro",
            kCGWindowOwnerPID as String: 4001,
        ],
    ]

    #expect(ProcessUtils.logicProPID(fromWindowList: zeroSized) == nil)
    #expect(ProcessUtils.logicProPID(fromWindowList: missingBounds) == 4001)
}

@Test func testProcessUtilsActivateLogicProUsesInjectedRuntime() {
    let harness = ProcessRuntimeHarness()
    harness.activateResult = false

    let activated = ProcessUtils.activateLogicPro(runtime: harness.runtime())

    #expect(!(activated))
    #expect(harness.activateCalls == 1)
}

@Test func testProcessUtilsActivationFallsBackWhenAppKitActivationIsUnavailable() {
    var appKitCalls = 0
    var appleScriptCalls = 0

    let activated = ProcessUtils.activateLogicProWithFallback(
        appKitActivate: {
            appKitCalls += 1
            return nil
        },
        appleScriptActivate: {
            appleScriptCalls += 1
            return true
        }
    )

    #expect(activated)
    #expect(appKitCalls == 1)
    #expect(appleScriptCalls == 1)
}

@Test func testProcessUtilsActivationUsesAppleScriptWhenAppKitActivationFails() {
    var appleScriptCalls = 0

    let activated = ProcessUtils.activateLogicProWithFallback(
        appKitActivate: { false },
        appleScriptActivate: {
            appleScriptCalls += 1
            return true
        }
    )

    #expect(activated)
    #expect(appleScriptCalls == 1)
}

@Test func testProcessUtilsActivationReinforcesSuccessfulAppKitActivationWithAppleScript() {
    var appKitCalls = 0
    var appleScriptCalls = 0

    let activated = ProcessUtils.activateLogicProWithFallback(
        appKitActivate: {
            appKitCalls += 1
            return true
        },
        appleScriptActivate: {
            appleScriptCalls += 1
            return true
        }
    )

    #expect(activated)
    #expect(appKitCalls == 1)
    #expect(appleScriptCalls == 1)
}

@Test func testProcessUtilsProductionActivateWrapperReturnsWithoutCrash() {
    // activateLogicPro's result is environment-dependent (needs a running Logic);
    // this smoke test asserts the production wrapper runs without crashing.
    _ = ProcessUtils.activateLogicPro()
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
    let status = PermissionChecker.PermissionStatus(
        accessibility: true,
        automationLogicPro: true,
        systemEventsAutomation: .granted,
        postEventAccess: true
    )

    #expect(status.allGranted)
    #expect(status.summary.contains("Accessibility: granted"))
    #expect(status.summary.contains("Automation (Logic Pro): granted"))
    #expect(status.summary.contains("Automation (System Events): granted"))
    #expect(!(status.summary.contains("System Settings")))
}

@Test func testPermissionStatusSummaryOnlyMentionsMissingAutomationGuidance() {
    let status = PermissionChecker.PermissionStatus(accessibility: true, automationLogicPro: false)

    #expect(!(status.allGranted))
    #expect(status.summary.contains("Accessibility: granted"))
    #expect(status.summary.contains("Automation (Logic Pro): NOT GRANTED"))
    #expect(!(status.summary.contains("Accessibility → add your terminal app")))
    #expect(status.summary.contains("Automation → allow control of Logic Pro"))
}
