import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #221: a parallel mutation probe reported a likely false positive — after
/// `logic_navigate.rename_marker` failed quickly, a later `logic_edit.quantize`
/// was rejected with `mutating_operation_in_progress(active=rename_marker)`.
///
/// Root cause analysis: the MCP swift-sdk dispatches each request in its own
/// Task (Server.swift), so two mutations fired in parallel genuinely overlap
/// and the gate CORRECTLY serializes them (one is refused, `safe_to_retry`).
/// The only way this could be a real defect is if the gate failed to release
/// when a mutating op FAILED (as opposed to succeeded) — leaving a stuck gate
/// that blocks all later mutations even under serial use. These tests lock in
/// the guarantee that a completed mutating op — success OR failure — always
/// frees the gate, and that a genuinely-overlapping refusal is honest and
/// transient (`safe_to_retry: true`, resolves once the in-flight op finishes).
@Suite("Issue221 mutation gate release")
struct Issue221MutationGateReleaseTests {
    private func json(_ result: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(sharedToolText(result))
    }

    @Test("a fast-FAILING mutating op releases the gate so the next mutation is not blocked")
    func failingMutationReleasesGateForNextMutation() async {
        let gate = LogicMutationGate()

        // rename_marker fails fast with a terminal State C — the #221 trigger.
        let first = await LogicProServer.runWithDeadline(
            tool: "logic_navigate",
            command: "rename_marker",
            deadlineOverride: 5,
            mutationGate: gate
        ) {
            toolTextResult(
                HonestContract.encodeStateC(error: .notImplemented, hint: "rename_marker not implemented"),
                isError: true
            )
        }
        #expect(first.isError!)
        #expect(json(first)?["error"] as? String == "not_implemented")
        // The gate MUST be free the instant the failed op returns.
        #expect(gate.currentOperation() == nil, "a failed mutating op must release the gate")

        // The follow-up quantize must NOT be refused by the already-finished
        // rename_marker — this was the reported false block.
        let second = await LogicProServer.runWithDeadline(
            tool: "logic_edit",
            command: "quantize",
            deadlineOverride: 5,
            mutationGate: gate
        ) {
            toolTextResult(HonestContract.encodeStateC(error: .channelsExhausted), isError: true)
        }
        #expect(json(second)?["error"] as? String != "mutating_operation_in_progress",
                "quantize must not be blocked by the already-completed rename_marker")
        #expect(gate.currentOperation() == nil)
    }

    @Test("a fast-succeeding mutating op releases the gate")
    func succeedingMutationReleasesGate() async {
        let gate = LogicMutationGate()
        _ = await LogicProServer.runWithDeadline(
            tool: "logic_tracks", command: "mute", deadlineOverride: 5, mutationGate: gate
        ) {
            toolTextResult(HonestContract.encodeStateA(extras: ["index": 0]))
        }
        #expect(gate.currentOperation() == nil)

        let next = await LogicProServer.runWithDeadline(
            tool: "logic_tracks", command: "solo", deadlineOverride: 5, mutationGate: gate
        ) {
            toolTextResult(HonestContract.encodeStateA(extras: ["index": 0]))
        }
        #expect(json(next)?["error"] as? String != "mutating_operation_in_progress")
    }

    @Test("LogicMutationGate.release frees the gate regardless of op outcome")
    func gateReleaseIsOutcomeIndependent() {
        let gate = LogicMutationGate()
        // Simulate a failed op: acquire then release (the outcome the op
        // reported is irrelevant to the gate — release always frees it).
        let claim = gate.tryAcquire(operation: "logic_navigate.rename_marker")
        #expect(claim != nil)
        #expect(gate.currentOperation() == "logic_navigate.rename_marker")
        if let claim { gate.release(claim) }
        #expect(gate.currentOperation() == nil)
        // A different mutation can now acquire immediately.
        let next = gate.tryAcquire(operation: "logic_edit.quantize")
        #expect(next != nil)
    }

    @Test("a genuinely-overlapping mutation is refused honestly and the refusal is transient")
    func concurrentOverlapRefusalIsHonestAndTransient() async {
        let gate = LogicMutationGate()
        let blocker = OverlapBlocker()
        let firstResult = ResultBox()

        // Op A enters work() and blocks — it holds the gate for the duration.
        let runnerA = Task {
            let r = await LogicProServer.runWithDeadline(
                tool: "logic_navigate", command: "rename_marker", deadlineOverride: 30, mutationGate: gate
            ) {
                blocker.enterAndWait()
                return toolTextResult(HonestContract.encodeStateC(error: .notImplemented), isError: true)
            }
            firstResult.store(r)
        }

        // Wait until A is genuinely inside work() holding the gate.
        while !blocker.hasEntered() { await Task.yield() }

        // Op B overlaps A → correctly refused, safe_to_retry, names A.
        let refused = await LogicProServer.runWithDeadline(
            tool: "logic_edit", command: "quantize", deadlineOverride: 5, mutationGate: gate
        ) {
            toolTextResult(HonestContract.encodeStateA())
        }
        #expect(json(refused)?["error"] as? String == "mutating_operation_in_progress")
        #expect(json(refused)?["active_operation"] as? String == "logic_navigate.rename_marker")
        #expect((json(refused)?["safe_to_retry"] as? Bool) == true)
        #expect((json(refused)?["write_attempted"] as? Bool) == false)

        // A completes → gate frees → B's retry now succeeds (transient refusal).
        blocker.unblock()
        await runnerA.value
        #expect(gate.currentOperation() == nil)

        let retried = await LogicProServer.runWithDeadline(
            tool: "logic_edit", command: "quantize", deadlineOverride: 5, mutationGate: gate
        ) {
            toolTextResult(HonestContract.encodeStateA())
        }
        #expect(json(retried)?["error"] as? String != "mutating_operation_in_progress")
    }

    // MARK: - Test doubles

    private final class OverlapBlocker: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let gate = DispatchSemaphore(value: 0)

        func enterAndWait() {
            lock.lock(); entered = true; lock.unlock()
            gate.wait()
        }
        func hasEntered() -> Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func unblock() { gate.signal() }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CallTool.Result?
        func store(_ r: CallTool.Result) { lock.lock(); value = r; lock.unlock() }
    }
}
