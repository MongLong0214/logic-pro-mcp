import ApplicationServices
import Foundation
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

private final class BlockingAutomationPermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let workerReturned = DispatchSemaphore(value: 0)
    private var callCountStorage = 0
    private var statesStorage: [PermissionChecker.CheckState] = []

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    var states: [PermissionChecker.CheckState] {
        lock.lock()
        defer { lock.unlock() }
        return statesStorage
    }

    func determine(bundleID: String, askUserIfNeeded: Bool) -> Int32 {
        #expect(bundleID == "com.example.blocked")
        #expect(!askUserIfNeeded)
        lock.lock()
        callCountStorage += 1
        lock.unlock()
        release.wait()
        workerReturned.signal()
        return Int32(noErr)
    }

    func append(_ state: PermissionChecker.CheckState) {
        lock.lock()
        statesStorage.append(state)
        lock.unlock()
    }

    func unblock(maximumWorkers: Int) {
        for _ in 0..<maximumWorkers {
            release.signal()
        }
    }

    func waitForWorkerReturn(timeout: TimeInterval) -> Bool {
        workerReturned.wait(timeout: .now() + timeout) == .success
    }
}

// MARK: - probeState mapping (the honesty core)

@Test func testAutomationPermissionProbeNeverAsksForConsent() {
    final class Observation: @unchecked Sendable {
        var bundleID: String?
        var askUserIfNeeded: Bool?
    }
    let observation = Observation()

    let state = PermissionChecker.nonPromptingAutomationState(
        bundleID: "com.apple.systemevents",
        determinePermission: { bundleID, askUserIfNeeded in
            observation.bundleID = bundleID
            observation.askUserIfNeeded = askUserIfNeeded
            return Int32(errAEEventWouldRequireUserConsent)
        }
    )

    #expect(observation.bundleID == "com.apple.systemevents")
    let askedForConsent = observation.askUserIfNeeded ?? true
    #expect(!askedForConsent)
    #expect(state == .notGranted)
}

@Test func testBlockedAutomationPermissionQueryIsBoundedAndCoalesced() {
    let probe = BlockingAutomationPermissionProbe()
    let coordinator = AutomationPermissionQueryCoordinator()
    let callers = DispatchGroup()

    for _ in 0..<2 {
        callers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let state = PermissionChecker.nonPromptingAutomationState(
                bundleID: "com.example.blocked",
                coordinator: coordinator,
                determinePermission: probe.determine
            )
            probe.append(state)
            callers.leave()
        }
    }

    let terminatedBeforeCleanup = callers.wait(timeout: .now() + 1.5) == .success
    let callsBeforeCleanup = probe.callCount
    let statesBeforeCleanup = probe.states

    // The pre-fix direct calls are released after the bounded assertion so a
    // RED run does not strand test threads. The corrected path has only one
    // shared worker; the extra signal is harmless.
    probe.unblock(maximumWorkers: 2)
    _ = callers.wait(timeout: .now() + 1.0)
    _ = probe.waitForWorkerReturn(timeout: 1.0)

    #expect(terminatedBeforeCleanup)
    #expect(callsBeforeCleanup == 1)
    #expect(statesBeforeCleanup == [.notVerifiable, .notVerifiable])
}

@Test(arguments: [
    (Int32(noErr), PermissionChecker.CheckState.granted),
    (Int32(errAEEventNotPermitted), PermissionChecker.CheckState.notGranted),
    (Int32(errAEEventWouldRequireUserConsent), PermissionChecker.CheckState.notGranted),
    (Int32(procNotFound), PermissionChecker.CheckState.notVerifiable),
    (Int32(paramErr), PermissionChecker.CheckState.notVerifiable),
])
func testAutomationPermissionStatusMapping(status: Int32, expected: PermissionChecker.CheckState) {
    let state = PermissionChecker.nonPromptingAutomationState(
        bundleID: "com.example.target",
        determinePermission: { _, _ in status }
    )
    #expect(state == expected)
}

@Test func testSystemEventsPermissionProbeLaunchesWithoutActivationThenRetriesNonprompting() {
    final class Observation: @unchecked Sendable {
        var statuses = [Int32(procNotFound), Int32(noErr)]
        var asks: [Bool] = []
        var launchedBundleIDs: [String] = []
    }
    let observation = Observation()

    let state = PermissionChecker.nonPromptingSystemEventsAutomationState(
        determinePermission: { bundleID, askUserIfNeeded in
            #expect(bundleID == "com.apple.systemevents")
            observation.asks.append(askUserIfNeeded)
            return observation.statuses.removeFirst()
        },
        launchWithoutActivation: { bundleID in
            observation.launchedBundleIDs.append(bundleID)
            return true
        }
    )

    #expect(state == .granted)
    #expect(observation.asks == [false, false])
    #expect(observation.launchedBundleIDs == ["com.apple.systemevents"])
}

@Test func testSystemEventsPermissionProbeDoesNotLaunchForConsentOrDenial() {
    for status in [Int32(errAEEventWouldRequireUserConsent), Int32(errAEEventNotPermitted)] {
        var launchCount = 0
        let state = PermissionChecker.nonPromptingSystemEventsAutomationState(
            determinePermission: { _, askUserIfNeeded in
                #expect(!askUserIfNeeded)
                return status
            },
            launchWithoutActivation: { _ in
                launchCount += 1
                return true
            }
        )

        #expect(state == .notGranted)
        #expect(launchCount == 0)
    }
}

@Test func testSystemEventsPermissionProbeFailsClosedWhenBackgroundLaunchFails() {
    var queryCount = 0
    let state = PermissionChecker.nonPromptingSystemEventsAutomationState(
        determinePermission: { _, askUserIfNeeded in
            queryCount += 1
            #expect(!askUserIfNeeded)
            return Int32(procNotFound)
        },
        launchWithoutActivation: { _ in false }
    )

    #expect(state == .notVerifiable)
    #expect(queryCount == 1)
}

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
