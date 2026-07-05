import Dispatch
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #112: the server-side command deadline turns a wedged/occluded Logic session
/// (AX ops blocking past the client tools/call timeout, stalling the stdio loop)
/// into a typed `operation_timeout` State C instead of a bare hang.
@Suite("Issue112 command deadline")
struct Issue112CommandDeadlineTests {
    private final class BlockingWorkProbe: @unchecked Sendable {
        private let stateLock = NSLock()
        private var entered = false
        private var completed = false
        private let release = DispatchSemaphore(value: 0)

        func hasEntered() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return entered
        }

        func isCompleted() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return completed
        }

        func unblock() {
            release.signal()
        }

        func run() -> CallTool.Result {
            stateLock.lock()
            entered = true
            stateLock.unlock()
            release.wait()
            stateLock.lock()
            completed = true
            stateLock.unlock()
            return toolTextResult("{\"verified\":true}")
        }
    }

    private actor ResultProbe {
        private var result: CallTool.Result?

        func store(_ result: CallTool.Result) {
            self.result = result
        }

        func hasResult() -> Bool {
            result != nil
        }

        func load() -> CallTool.Result? {
            result
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }

    private func text(_ result: CallTool.Result) -> String {
        sharedToolText(result)
    }

    private func json(_ result: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(text(result))
    }

    @Test("fast work passes through unchanged")
    func fastWorkPassesThrough() async {
        let result = await LogicProServer.runWithDeadline(tool: "logic_transport", command: "stop", deadlineOverride: 5.0) {
            toolTextResult("{\"verified\":true,\"operation\":\"transport.stop\"}")
        }
        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
        #expect((json(result)?["verified"] as? Bool)!)
    }

    @Test("mutation gate reclaims a stale holder so a wedged op cannot lock out all mutations")
    func mutationGateReclaimsStaleHolder() {
        let gate = LogicMutationGate(staleHolderTTL: 10)
        let t0 = Date()
        let first = gate.tryAcquire(operation: "logic_tracks.rename", now: t0)
        #expect(first != nil)
        // Within the TTL the gate is genuinely held — a second op is refused.
        #expect(gate.tryAcquire(operation: "logic_tracks.mute", now: t0.addingTimeInterval(5)) == nil)
        // Past the TTL the stale (presumed-wedged) holder is reclaimed: recovery.
        let second = gate.tryAcquire(operation: "logic_tracks.mute", now: t0.addingTimeInterval(11))
        #expect(second != nil)
        #expect(gate.currentOperation() == "logic_tracks.mute")
        // The orphaned original holder's late release must NOT free the reclaimed
        // gate (epoch guard) — otherwise a concurrent mutation could slip in.
        if let first { gate.release(first) }
        #expect(gate.currentOperation() == "logic_tracks.mute")
        if let second { gate.release(second) }
        #expect(gate.currentOperation() == nil)
    }

    @Test("mutation gate same-name reclaim is release-safe via epoch")
    func mutationGateSameNameReclaimReleaseSafe() {
        let gate = LogicMutationGate(staleHolderTTL: 1)
        let t0 = Date()
        let a = gate.tryAcquire(operation: "logic_project.export_run", now: t0)
        // Same operation name, reclaimed after the TTL.
        let b = gate.tryAcquire(operation: "logic_project.export_run", now: t0.addingTimeInterval(2))
        #expect(a != nil)
        #expect(b != nil)
        // Releasing the orphaned first claim must not free the successor that
        // happens to share the operation name.
        if let a { gate.release(a) }
        #expect(gate.currentOperation() == "logic_project.export_run")
        if let b { gate.release(b) }
        #expect(gate.currentOperation() == nil)
    }

    @Test("work that exceeds the deadline returns typed operation_timeout")
    func slowWorkTimesOut() async {
        let result = await LogicProServer.runWithDeadline(tool: "logic_tracks", command: "rename", deadlineOverride: 0.15) {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s — far past the 0.15s deadline
            return toolTextResult("{\"verified\":true}") // must NOT win
        }
        #expect(result.isError!)
        let obj = json(result)
        #expect(obj?["error"] as? String == "operation_timeout")
        #expect(obj?["operation"] as? String == "logic_tracks.rename")
        #expect(obj?["timeout_sec"] as? Double == 0.15)
        #expect(!(((obj?["hint"] as? String)?.isEmpty)!))
    }

    @Test("non-cooperative blocking work does not hold the deadline scope open")
    func blockingWorkDoesNotDelayTimeoutReturn() async throws {
        let blocker = BlockingWorkProbe()
        let resultProbe = ResultProbe()
        let gate = LogicMutationGate(staleHolderTTL: 3_600, timedOutReclaimGrace: 3_600)

        let runner = Task {
            let result = await LogicProServer.runWithDeadline(
                tool: "logic_project",
                command: "export_run",
                deadlineOverride: 0.05,
                mutationGate: gate
            ) {
                blocker.run()
            }
            await resultProbe.store(result)
        }

        #expect(try await waitUntil(timeoutNanoseconds: 5_000_000_000) { blocker.hasEntered() })
        #expect(try await waitUntil(timeoutNanoseconds: 10_000_000_000) { await resultProbe.hasResult() })
        #expect(!(blocker.isCompleted()))

        let refused = await LogicProServer.runWithDeadline(
            tool: "logic_tracks",
            command: "rename",
            deadlineOverride: 1,
            mutationGate: gate
        ) {
            toolTextResult("{\"unexpected\":true}")
        }
        #expect(refused.isError!)
        #expect(json(refused)?["error"] as? String == "mutating_operation_in_progress")
        #expect(json(refused)?["active_operation"] as? String == "logic_project.export_run")
        // No write was attempted — the gate refused before dispatch — so the
        // refusal is retryable once the in-flight op releases the gate.
        #expect((json(refused)?["safe_to_retry"] as? Bool)!)

        blocker.unblock()
        await runner.value

        let result = await resultProbe.load()!
        #expect(result.isError!)
        #expect(json(result)?["error"] as? String == "operation_timeout")
        // Timeout abandons (does not stop) a possibly-partial mutation, so this
        // result is intentionally NOT safe to retry and the op is not stopped.
        #expect(!((json(result)?["safe_to_retry"] as? Bool)!))
        #expect(!((json(result)?["underlying_operation_stopped"] as? Bool)!))
        #expect(try await waitUntil(timeoutNanoseconds: 1_000_000_000) { blocker.isCompleted() })

        let afterDrain = await LogicProServer.runWithDeadline(
            tool: "logic_tracks",
            command: "rename",
            deadlineOverride: 1,
            mutationGate: gate
        ) {
            toolTextResult("{\"verified\":true}")
        }
        let afterDrainIsError = afterDrain.isError ?? false
        #expect(!afterDrainIsError)
    }

    @Test("operation_timeout is a terminal error code")
    func timeoutIsTerminal() {
        #expect(HonestContract.terminalErrorCodes.contains(HonestContract.FailureError.operationTimeout.rawValue))
        #expect(HonestContract.FailureError.operationTimeout.rawValue == "operation_timeout")
        #expect(HonestContract.terminalErrorCodes.contains(HonestContract.FailureError.mutatingOperationInProgress.rawValue))
        #expect(HonestContract.FailureError.mutatingOperationInProgress.rawValue == "mutating_operation_in_progress")
    }

    @Test("deadline tiers: fast commands short, long/medium commands generous")
    func deadlineTiers() {
        // Fast tier — far above the sub-second healthy completion time.
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_transport", command: "stop") == 25)
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: "set_volume") == 25)
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_tracks", command: "mute") == 25)
        // Long tier — full Library walks / SMF import / guarded export.
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_tracks", command: "scan_library") == 300)
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: "import_file") == 300)
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: "bounce") == 300)
        // Medium tier — multi-step menu/library navigation.
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_tracks", command: "set_instrument") == 90)
        #expect(AccessibilityChannel.setInstrumentLibraryNavigationDeadlineSeconds == 30)
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_plugins", command: "insert_verified") == 90)
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: "play_sequence") == 90)
    }

    @Test("all mutating transport commands hold the timeout mutation gate")
    func mutatingTransportCommandsAreGated() {
        let mutatingTransportCommands = [
            "play", "stop", "record", "pause", "rewind", "fast_forward", "toggle_cycle",
            "toggle_metronome", "set_tempo", "goto_position", "set_cycle_range", "toggle_count_in",
        ]

        for command in mutatingTransportCommands {
            #expect(
                LogicProServer.isMutatingCommand(tool: "logic_transport", command: command),
                "logic_transport \(command) must hold the mutation gate on timeout"
            )
        }
    }

    @Test("the deadline timeout result is shaped like a State C envelope")
    func timeoutResultShape() {
        let result = LogicProServer.deadlineTimeoutResult(tool: "logic_navigate", command: "create_marker", seconds: 25)
        #expect(result.isError!)
        let obj = json(result)
        #expect(!((obj?["success"] as? Bool)!))
        #expect(obj?["error"] as? String == "operation_timeout")
        #expect(obj?["operation"] as? String == "logic_navigate.create_marker")
    }

    // MARK: - #201 bounded post-timeout gate reclaim

    @Test("a timed-out holder is reclaimed after the short grace, not the full stale TTL")
    func timedOutHolderReclaimsAfterGrace() {
        let gate = LogicMutationGate(staleHolderTTL: 360, timedOutReclaimGrace: 15)
        let t0 = Date()
        let first = gate.tryAcquire(operation: "logic_transport.play", now: t0)
        #expect(first != nil)
        // The command deadline abandons logic_transport.play at its 25s deadline.
        gate.markTimedOut(first!, now: t0.addingTimeInterval(25))
        // Within the grace after the timeout, the gate is still genuinely held —
        // a successor mutation is refused (the abandoned work may still be unwinding).
        #expect(gate.tryAcquire(operation: "logic_transport.stop", now: t0.addingTimeInterval(25 + 14)) == nil)
        // Past the grace, a successor reclaims it — recovery happens ~40s after the
        // op started, NOT after the 360s blanket stale-holder TTL (#201).
        let second = gate.tryAcquire(operation: "logic_transport.stop", now: t0.addingTimeInterval(25 + 16))
        #expect(second != nil)
        #expect(gate.currentOperation() == "logic_transport.stop")
        // The abandoned op's late release must NOT free the reclaimed gate (epoch).
        gate.release(first!)
        #expect(gate.currentOperation() == "logic_transport.stop")
        gate.release(second!)
        #expect(gate.currentOperation() == nil)
    }

    @Test("markTimedOut is epoch-guarded against an already-reclaimed successor")
    func markTimedOutIsEpochGuarded() {
        let gate = LogicMutationGate(staleHolderTTL: 5, timedOutReclaimGrace: 15)
        let t0 = Date()
        let first = gate.tryAcquire(operation: "logic_tracks.rename", now: t0)
        #expect(first != nil)
        // A successor reclaims via the stale TTL before any timeout mark.
        let second = gate.tryAcquire(operation: "logic_tracks.mute", now: t0.addingTimeInterval(6))
        #expect(second != nil)
        // A late timeout mark from the abandoned first op must not mark the
        // successor — the successor is healthy and still owns the gate.
        gate.markTimedOut(first!, now: t0.addingTimeInterval(7))
        // Within the successor's own grace/TTL a third op is still refused.
        #expect(gate.tryAcquire(operation: "logic_tracks.solo", now: t0.addingTimeInterval(8)) == nil)
        gate.release(second!)
        #expect(gate.currentOperation() == nil)
    }

    @Test("a healthy (non-timed-out) holder still requires the full stale TTL")
    func nonTimedOutHolderUsesStaleTTL() {
        let gate = LogicMutationGate(staleHolderTTL: 360, timedOutReclaimGrace: 15)
        let t0 = Date()
        let first = gate.tryAcquire(operation: "logic_project.bounce", now: t0)
        #expect(first != nil)
        // No timeout mark → the short grace must NOT apply to a healthy long-running
        // op; it is still held well past the grace window.
        #expect(gate.tryAcquire(operation: "logic_tracks.mute", now: t0.addingTimeInterval(16)) == nil)
        // Only the full stale TTL reclaims a healthy long-running holder.
        #expect(gate.tryAcquire(operation: "logic_tracks.mute", now: t0.addingTimeInterval(361)) != nil)
    }

    @Test("a timed-out mutating deadline result advertises bounded gate reclaim")
    func timeoutResultAdvertisesBoundedReclaim() {
        let result = LogicProServer.deadlineTimeoutResult(
            tool: "logic_transport", command: "play", seconds: 25, mutationMayStillBeRunning: true
        )
        #expect(result.isError!)
        let obj = json(result)
        #expect(obj?["error"] as? String == "operation_timeout")
        #expect(obj?["mutation_gate"] as? String == "reclaimable_after_grace")
        #expect((obj?["gate_reclaim_after_sec"] as? Double) == LogicProServer.mutationGateReclaimGraceSeconds)
        // The abandoned op's own effect is unknown → still not safe to retry, and
        // it was not stopped (only abandoned).
        #expect(!((obj?["safe_to_retry"] as? Bool)!))
        #expect(!((obj?["underlying_operation_stopped"] as? Bool)!))
    }

    @Test("a timed-out mutating op frees the gate after the reclaim grace, end-to-end")
    func timedOutMutationRecoversGateEndToEnd() async throws {
        // The wedged op never returns (held by the semaphore for the whole test),
        // so recovery can ONLY come from the #201 bounded reclaim, not from the
        // work's own release. Grace is injected short so the test stays fast.
        let blocker = BlockingWorkProbe()
        let gate = LogicMutationGate(staleHolderTTL: 360, timedOutReclaimGrace: 0.3)
        let resultProbe = ResultProbe()

        let runner = Task {
            let result = await LogicProServer.runWithDeadline(
                tool: "logic_transport",
                command: "play",
                deadlineOverride: 0.05,
                mutationGate: gate
            ) {
                blocker.run()
            }
            await resultProbe.store(result)
        }

        #expect(try await waitUntil(timeoutNanoseconds: 5_000_000_000) { blocker.hasEntered() })
        #expect(try await waitUntil(timeoutNanoseconds: 10_000_000_000) { await resultProbe.hasResult() })
        #expect(json(await resultProbe.load()!)?["error"] as? String == "operation_timeout")

        #expect(gate.currentOperation() == "logic_transport.play")

        // Once the reclaim grace elapses, the gate auto-recovers WITHOUT the wedged
        // play ever returning, so a follow-up mutation proceeds (#201).
        try await Task.sleep(nanoseconds: 500_000_000) // > the 0.3s injected grace
        let recovered = await LogicProServer.runWithDeadline(
            tool: "logic_transport",
            command: "stop",
            deadlineOverride: 1,
            mutationGate: gate
        ) {
            toolTextResult("{\"verified\":true}")
        }
        let recoveredIsError = recovered.isError ?? false
        #expect(!recoveredIsError)
        #expect((json(recovered)?["verified"] as? Bool)!)

        blocker.unblock()
        await runner.value
    }
}
