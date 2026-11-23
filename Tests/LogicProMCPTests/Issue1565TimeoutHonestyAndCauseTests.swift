import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #1565: a timeout after a write is an unknown outcome, not a clean failure, and a timeout names
/// the likely cause (window off this Space, Logic's main thread saturated).
@Suite("Issue1565 timeout honesty and cause")
struct Issue1565TimeoutHonestyAndCauseTests {
    private let offSpaceAndSaturated = LogicLiveness(windowOnScreen: false, cpuPercent: 97.4)

    private func json(_ result: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(sharedToolText(result))
    }

    @Test("a timeout after a write boundary is State B with an unknown effect, never State C")
    func timeoutAfterWriteIsUnknownOutcome() async throws {
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project",
            command: "new",
            deadlineOverride: 0.05,
            mutationGate: LogicMutationGate()
        ) {
            _ = OperationTraceContext.claimDeadlineEffect("direct_write")
            try? await Task.sleep(nanoseconds: 400_000_000)
            return toolTextResult("{\"success\":true,\"state\":\"A\"}")
        }

        let body = try #require(json(result))
        #expect(result.isError == true)
        #expect(body["state"] as? String == "B")
        #expect(body["state"] as? String != "C")
        #expect(body["reason"] as? String == "effect_unknown_after_timeout")
        #expect(body["error"] as? String == "operation_timeout")
        #expect(body["success"] as? Bool == false)
        #expect(body["verified"] as? Bool == false)
        #expect(body["write_attempted"] as? Bool == true)
        #expect(body["effect_unknown"] as? Bool == true)
        #expect(body["safe_to_retry"] as? Bool == false)
        #expect(body["terminal"] as? Bool == true)
        #expect((body["recovery_hint"] as? String)?.contains("Re-read") == true)
    }

    @Test("a timeout before any write stays a clean State C")
    func timeoutBeforeWriteStaysStateC() async throws {
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project",
            command: "new",
            deadlineOverride: 0.05,
            mutationGate: LogicMutationGate()
        ) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return toolTextResult("late")
        }

        let body = try #require(json(result))
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "operation_timeout")
        #expect(body["write_attempted"] as? Bool == false)
        #expect(body["effect_unknown"] as? Bool == false)
    }

    @Test("a timeout on a read is unchanged: State C with no write fields")
    func timeoutOnReadIsUnchanged() async throws {
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_system",
            command: "health",
            deadlineOverride: 0.05
        ) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return toolTextResult("late")
        }

        let body = try #require(json(result))
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "operation_timeout")
        #expect(body["write_attempted"] == nil)
        #expect(body["effect_unknown"] == nil)
        #expect(body["likely_causes"] == nil)
    }

    @Test("a tool timeout names the off-Space and saturated causes with their fixes")
    func toolTimeoutNamesCauses() async throws {
        let probe = offSpaceAndSaturated
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_system",
            command: "health",
            deadlineOverride: 0.05,
            livenessProbe: { probe }
        ) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return toolTextResult("late")
        }

        let body = try #require(json(result))
        #expect(body["state"] as? String == "C")
        #expect(body["logic_window_on_screen"] as? Bool == false)
        #expect(body["logic_cpu_percent"] as? Double == 97.4)
        let causes = try #require(body["likely_causes"] as? [String])
        #expect(causes == [LogicLivenessProbe.windowOffSpaceMessage, LogicLivenessProbe.saturatedMessage])
    }

    @Test("an unknown-outcome timeout still carries the cause fields")
    func unknownOutcomeTimeoutCarriesCauses() async throws {
        let probe = offSpaceAndSaturated
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_project",
            command: "new",
            deadlineOverride: 0.05,
            mutationGate: LogicMutationGate(),
            livenessProbe: { probe }
        ) {
            _ = OperationTraceContext.claimDeadlineEffect("direct_write")
            try? await Task.sleep(nanoseconds: 400_000_000)
            return toolTextResult("late")
        }

        let body = try #require(json(result))
        #expect(body["state"] as? String == "B")
        #expect((body["likely_causes"] as? [String])?.count == 2)
    }

    @Test("a resource read timeout names the cause")
    func resourceTimeoutNamesCause() async throws {
        let result = try await LogicProServer.runResourceReadWithDeadline(
            uri: "logic://transport/state",
            deadlineOverride: 0.05,
            livenessProbe: { LogicLiveness(windowOnScreen: true, cpuPercent: 91) }
        ) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return ReadResource.Result(contents: [])
        }

        let text = try #require(result.contents.first?.text)
        let body = try #require(sharedJSONObject(text))
        #expect(body["error"] as? String == "operation_timeout")
        #expect(body["likely_causes"] as? [String] == [LogicLivenessProbe.saturatedMessage])
        #expect(body["logic_window_on_screen"] as? Bool == true)
    }

    @Test("a healthy Logic names no cause")
    func healthyLogicHasNoCause() {
        let healthy = LogicLiveness(windowOnScreen: true, cpuPercent: 12)
        #expect(healthy.likelyCauses.isEmpty)
        #expect(healthy.fields["likely_causes"] == nil)
        #expect(LogicLiveness.unavailable.fields.isEmpty)
    }

    @Test("window on screen is read from the window list for the pid only")
    func windowOnScreenFromList() {
        func window(pid: Int, width: Double, layer: Int = 0) -> [String: Any] {
            ["kCGWindowOwnerPID": pid, "kCGWindowLayer": layer,
             "kCGWindowBounds": ["Width": width, "Height": 600.0]]
        }
        #expect(LogicLivenessProbe.hasOnScreenWindow(pid: 42, in: [window(pid: 42, width: 900)]))
        #expect(!LogicLivenessProbe.hasOnScreenWindow(pid: 42, in: [window(pid: 7, width: 900)]))
        #expect(!LogicLivenessProbe.hasOnScreenWindow(pid: 42, in: [window(pid: 42, width: 0)]))
        #expect(!LogicLivenessProbe.hasOnScreenWindow(pid: 42, in: [window(pid: 42, width: 900, layer: 25)]))
        #expect(!LogicLivenessProbe.hasOnScreenWindow(pid: 42, in: []))
    }

    @Test("CPU percent is the CPU time delta over the wall time, and saturation starts above 85")
    func cpuPercentAndThreshold() {
        let percent = LogicLivenessProbe.cpuPercent(cpuSecondsBefore: 10, cpuSecondsAfter: 10.19, elapsedSeconds: 0.2)
        #expect(abs((percent ?? 0) - 95) < 0.001)
        #expect(LogicLivenessProbe.cpuPercent(cpuSecondsBefore: 10, cpuSecondsAfter: 9, elapsedSeconds: 0.2) == nil)
        #expect(LogicLivenessProbe.cpuPercent(cpuSecondsBefore: 1, cpuSecondsAfter: 2, elapsedSeconds: 0) == nil)
        #expect(LogicLiveness(windowOnScreen: true, cpuPercent: 85.1).mainThreadSaturated)
        #expect(!LogicLiveness(windowOnScreen: true, cpuPercent: 84.9).mainThreadSaturated)
    }

    @Test("the live probe stays under 300 ms")
    func liveProbeIsBounded() {
        let start = ContinuousClock.now
        _ = LogicLivenessProbe.live()
        #expect(start.duration(to: .now) < .milliseconds(300))
    }

    @Test("the poll delay backs off when idle and after a slow cycle, and is otherwise the base")
    func pollDelayBacksOff() {
        let base: UInt64 = 3_000_000_000
        // Busy client, fast cycle: unchanged.
        #expect(StatePoller.nextPollDelayNs(base: base, idleSeconds: 1, lastCycleNs: 200_000_000) == base)
        // Idle: backs off.
        #expect(StatePoller.nextPollDelayNs(base: base, idleSeconds: 60, lastCycleNs: 200_000_000)
            == StatePoller.idleIntervalNs)
        // A 6 s cycle waits at least 12 s, so Logic is idle two thirds of the time.
        #expect(StatePoller.nextPollDelayNs(base: base, idleSeconds: 1, lastCycleNs: 6_000_000_000) == 12_000_000_000)
        // Never more than the cap.
        #expect(StatePoller.nextPollDelayNs(base: base, idleSeconds: 60, lastCycleNs: 100_000_000_000)
            == StatePoller.maxIntervalNs)
    }
}
