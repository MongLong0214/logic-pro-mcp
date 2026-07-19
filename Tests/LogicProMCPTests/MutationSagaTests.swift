import Foundation
import MCP
import Testing
@testable import LogicProMCP

private enum MockSagaBehavior: Sendable {
    case applyStateA
    case failBeforeWrite
    case ambiguousApplied
    case ambiguousNotApplied
    case ambiguousUnknown
}

private actor MockSagaExecutor: SagaStepExecutor {
    private var states: [TargetReference: Value]
    private var behaviors: [MockSagaBehavior]
    private let beforeFirstRead: @Sendable () async -> Void
    private var unknownNextRead: Set<TargetReference> = []
    private var runs: [SagaStep] = []
    private var reads = 0

    init(
        states: [TargetReference: Value],
        behaviors: [MockSagaBehavior],
        beforeFirstRead: @escaping @Sendable () async -> Void = {}
    ) {
        self.states = states
        self.behaviors = behaviors
        self.beforeFirstRead = beforeFirstRead
    }

    func run(_ step: SagaStep) async -> StepResult {
        runs.append(step)
        let behavior = behaviors.isEmpty ? .applyStateA : behaviors.removeFirst()
        let target = step.targetRef
        let desired = step.params[step.expectedInverse.valueParameter]

        switch behavior {
        case .applyStateA:
            if let target, let desired { states[target] = desired }
            return StepResult(state: .stateA, writeBoundaryCrossed: true, detail: "synthetic A")
        case .failBeforeWrite:
            return StepResult(state: .stateC, writeBoundaryCrossed: false, detail: "synthetic C")
        case .ambiguousApplied:
            if let target, let desired { states[target] = desired }
            return StepResult(state: .stateB, writeBoundaryCrossed: true, detail: "synthetic B applied")
        case .ambiguousNotApplied:
            return StepResult(state: .stateB, writeBoundaryCrossed: true, detail: "synthetic B not applied")
        case .ambiguousUnknown:
            if let target { unknownNextRead.insert(target) }
            return StepResult(state: .stateB, writeBoundaryCrossed: true, detail: "synthetic B unknown")
        }
    }

    func readState(_ step: SagaStep) async -> ObservedState? {
        let isFirstRead = reads == 0
        reads += 1
        if isFirstRead { await beforeFirstRead() }
        guard let target = step.targetRef else { return nil }
        if unknownNextRead.remove(target) != nil { return nil }
        guard let value = states[target] else { return nil }
        return ObservedState(value: value, evidence: "synthetic readback")
    }

    func runCount() -> Int { runs.count }
    func readCount() -> Int { reads }
    func runOperations() -> [OperationID] { runs.map(\.operationID) }
    func state(for target: TargetReference) -> Value? { states[target] }
}

private actor BlockingSagaReadProbe {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func block() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func unblock() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor StepBoundaryCancellationProbe {
    private var checks = 0

    func shouldCancel() -> Bool {
        checks += 1
        return checks >= 3
    }
}

/// #412: a synchronous, counter-based deadline predicate — the saga-level stand
/// in for the injected `deadlineReached` / the dispatcher's folded deadline. It
/// flips true after `flipAfter` calls so a test can pin exactly when the budget
/// elapses, with no wall-clock sleep.
private final class DeadlineFlipProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let flipAfter: Int

    init(flipAfter: Int) { self.flipAfter = flipAfter }

    func reached() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks > flipAfter
    }
}

@Suite("Mutation saga", .serialized)
struct MutationSagaTests {
    private func bind(
        _ registry: TargetRegistry,
        index: Int,
        name: String
    ) async -> TargetReference {
        let descriptor = TargetDescriptor(trackIndex: index, trackName: name)
        return await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
    }

    /// A minimal step for journal-only tests (identity/finalize), where the
    /// step's contents are never executed — only hashed into the plan.
    private func journalStep() -> SagaStep {
        SagaStep(
            operationID: .tracksRename,
            targetRef: nil,
            params: ["name": .string("X")],
            expectedInverse: SagaExpectedInverse(
                operationID: .tracksRename,
                valueParameter: "name"
            )
        )
    }

    private func step(
        _ operationID: OperationID,
        target: TargetReference,
        value: Value
    ) -> SagaStep {
        let valueParameter: String
        switch operationID {
        case .tracksRename:
            valueParameter = "name"
        case .mixerSetVolume, .mixerSetPan:
            valueParameter = "value"
        case .tracksMute, .tracksSolo, .tracksArm:
            valueParameter = "enabled"
        default:
            valueParameter = "value"
        }
        return SagaStep(
            operationID: operationID,
            targetRef: target,
            params: [valueParameter: value],
            expectedInverse: SagaExpectedInverse(
                operationID: operationID,
                valueParameter: valueParameter
            )
        )
    }

    /// ADR-004: an unavailable route rejects the whole plan before step 1 —
    /// the executor is never called.
    @Test
    func preflightRejectsUnavailableRouteBeforeStepOne() async {
        let registry = TargetRegistry()
        let valid = await bind(registry, index: 0, name: "Valid")
        let executor = MockSagaExecutor(states: [valid: .string("Before")], behaviors: [])
        let saga = MutationSaga(
            targetRegistry: registry,
            enabled: true,
            routeAvailable: { _ in false }
        )
        let outcome = await saga.execute(
            SagaPlan(
                steps: [step(.tracksRename, target: valid, value: .string("After"))],
                idempotencyKey: "route-unavailable-plan"
            ),
            executor: executor
        )
        #expect(!outcome.complete)
        #expect(outcome.preflightIssues.contains(
            .routeUnavailable(stepIndex: 0, operationID: .tracksRename)
        ))
        #expect(await executor.runCount() == 0)
    }

    /// ADR-004: a plan whose modeled duration (2× per-step registry deadline —
    /// write + verification readback) reaches the saga-execute budget rejects
    /// before step 1, on >= (an exact fit has zero headroom for unmodeled
    /// work). The 6 allowlisted ops are DeadlineClass.short (25s → 50s
    /// modeled) and the budget is DeadlineClass.long (300s), so 6 steps
    /// (300s modeled) reject while 5 (250s) pass the budget check.
    @Test
    func preflightRejectsPlansExceedingDeadlineBudget() async {
        let registry = TargetRegistry()
        let valid = await bind(registry, index: 0, name: "Valid")
        let executor = MockSagaExecutor(states: [valid: .string("Before")], behaviors: [])
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let steps = (0..<6).map { index in
            step(.tracksRename, target: valid, value: .string("After-\(index)"))
        }
        let outcome = await saga.execute(
            SagaPlan(steps: steps, idempotencyKey: "budget-overflow-plan"),
            executor: executor
        )
        #expect(!outcome.complete)
        #expect(outcome.preflightIssues.contains(
            .deadlineBudgetExceeded(totalSeconds: 300, budgetSeconds: 300)
        ))
        #expect(await executor.runCount() == 0)
    }

    /// Boundary control: a 5-step plan (250s modeled < 300s budget) passes the
    /// budget check and executes — proving the gate discriminates rather than
    /// blanket-rejecting multi-step plans.
    @Test
    func preflightAllowsPlansWithinDeadlineBudget() async {
        let registry = TargetRegistry()
        let valid = await bind(registry, index: 0, name: "Valid")
        let executor = MockSagaExecutor(states: [valid: .string("Before")], behaviors: [])
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let steps = (0..<5).map { index in
            step(.tracksRename, target: valid, value: .string("After-\(index)"))
        }
        let outcome = await saga.execute(
            SagaPlan(steps: steps, idempotencyKey: "budget-within-plan"),
            executor: executor
        )
        #expect(outcome.preflightIssues.isEmpty)
        #expect(outcome.complete)
        #expect(await executor.runCount() == 5)
    }

    /// ADR-004: a step whose registry spec declares a confirmation policy is
    /// rejected — the saga wire carries no confirmation flow. project.open is
    /// l2, so the plan surfaces confirmationRequired alongside the
    /// not-reversible rejection.
    @Test
    func preflightRejectsConfirmationRequiringSteps() async {
        let registry = TargetRegistry()
        let valid = await bind(registry, index: 0, name: "Valid")
        let executor = MockSagaExecutor(states: [valid: .string("Before")], behaviors: [])
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let outcome = await saga.execute(
            SagaPlan(
                steps: [step(.projectOpen, target: valid, value: .string("/tmp/x.logicx"))],
                idempotencyKey: "confirmation-plan"
            ),
            executor: executor
        )
        #expect(!outcome.complete)
        #expect(outcome.preflightIssues.contains(
            .confirmationRequired(stepIndex: 0, operationID: .projectOpen)
        ))
        #expect(outcome.preflightIssues.contains(
            .operationNotReversible(stepIndex: 0, operationID: .projectOpen)
        ))
        #expect(await executor.runCount() == 0)
    }

    @Test
    func testPreflightRejectsInvalidPlansBeforeRun() async {
        let registry = TargetRegistry()
        let stale = await bind(registry, index: 0, name: "Stale")
        await registry.bumpTopologyGeneration()
        let valid = await bind(registry, index: 1, name: "Valid")
        let executor = MockSagaExecutor(states: [valid: .string("Before")], behaviors: [])
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })

        let staleOutcome = await saga.execute(
            SagaPlan(
                steps: [
                    step(.tracksRename, target: valid, value: .string("After")),
                    step(.mixerSetVolume, target: stale, value: .double(0.8)),
                ],
                idempotencyKey: "stale-plan"
            ),
            executor: executor
        )

        #expect(!staleOutcome.complete)
        #expect(staleOutcome.preflightIssues.contains(.staleTarget(stepIndex: 1)))
        #expect(await executor.runCount() == 0)
        #expect(await executor.readCount() == 0)

        let disallowedOutcome = await saga.execute(
            SagaPlan(
                steps: [
                    step(.tracksRename, target: valid, value: .string("After")),
                    step(.pluginsInsertVerified, target: valid, value: .string("Compressor")),
                ],
                idempotencyKey: "disallowed-plan"
            ),
            executor: executor
        )

        #expect(!disallowedOutcome.complete)
        #expect(disallowedOutcome.preflightIssues.contains(
            .operationNotReversible(stepIndex: 1, operationID: .pluginsInsertVerified)
        ))
        #expect(await executor.runCount() == 0)
        #expect(await executor.readCount() == 0)
    }

    @Test
    func testTwoStepPlanCompletesWithEvidence() async throws {
        let registry = TargetRegistry()
        let renameTarget = await bind(registry, index: 0, name: "Bass")
        let volumeTarget = await bind(registry, index: 1, name: "Keys")
        let executor = MockSagaExecutor(
            states: [renameTarget: .string("Bass"), volumeTarget: .double(0.25)],
            behaviors: [.applyStateA, .applyStateA]
        )
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let outcome = await saga.execute(
            SagaPlan(
                steps: [
                    step(.tracksRename, target: renameTarget, value: .string("Sub Bass")),
                    step(.mixerSetVolume, target: volumeTarget, value: .double(0.75)),
                ],
                idempotencyKey: "two-step-success"
            ),
            executor: executor
        )

        #expect(outcome.state == .completed)
        #expect(outcome.complete)
        #expect(outcome.stateHistory == [
            .draft, .validated, .awaitingConfirmation, .running, .completed,
        ])
        #expect(outcome.journal.count == 2)
        #expect(outcome.journal.allSatisfy {
            $0.beforeState != nil
                && $0.writeBoundaryCrossed
                && $0.executionResult != nil
                && $0.verificationEvidence?.disposition == .applied
                && $0.inverseOperation != nil
                && $0.compensationEvidence == nil
        })
        let renameRecord = try #require(outcome.journal.first)
        let volumeRecord = try #require(outcome.journal.last)
        #expect(renameRecord.inverseOperation?.params["name"] == .string("Bass"))
        #expect(volumeRecord.inverseOperation?.params["value"] == .double(0.25))
    }

    @Test
    func testFailureCompensatesAppliedPrefixInReverse() async throws {
        let registry = TargetRegistry()
        let renameTarget = await bind(registry, index: 0, name: "Lead")
        let volumeTarget = await bind(registry, index: 1, name: "Pad")
        let panTarget = await bind(registry, index: 2, name: "FX")
        let executor = MockSagaExecutor(
            states: [
                renameTarget: .string("Lead"),
                volumeTarget: .double(0.2),
                panTarget: .double(0),
            ],
            behaviors: [.applyStateA, .applyStateA, .failBeforeWrite, .applyStateA, .applyStateA]
        )
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let outcome = await saga.execute(
            SagaPlan(
                steps: [
                    step(.tracksRename, target: renameTarget, value: .string("Lead Vox")),
                    step(.mixerSetVolume, target: volumeTarget, value: .double(0.9)),
                    step(.mixerSetPan, target: panTarget, value: .double(-0.5)),
                ],
                idempotencyKey: "reverse-compensation"
            ),
            executor: executor
        )

        #expect(outcome.state == .fullyCompensated)
        #expect(!outcome.complete)
        #expect(await executor.runOperations() == [
            .tracksRename, .mixerSetVolume, .mixerSetPan, .mixerSetVolume, .tracksRename,
        ])
        #expect(await executor.state(for: renameTarget) == .string("Lead"))
        #expect(await executor.state(for: volumeTarget) == .double(0.2))
        #expect(outcome.journal[0].compensationEvidence?.disposition == .verified)
        #expect(outcome.journal[1].compensationEvidence?.disposition == .verified)
        #expect(outcome.journal[2].compensationEvidence?.disposition == .notNeeded)
        #expect(outcome.journal[0].compensationEvidence?.readback != nil)
        #expect(outcome.journal[1].compensationEvidence?.readback != nil)
    }

    @Test
    func testStepBoundaryCancellationCompensatesVerifiedWrite() async {
        let registry = TargetRegistry()
        let target = await bind(registry, index: 0, name: "Cancelable")
        let executor = MockSagaExecutor(
            states: [target: .string("Before")],
            behaviors: [.applyStateA, .applyStateA]
        )
        let cancellation = StepBoundaryCancellationProbe()
        let outcome = await MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true }).execute(
            SagaPlan(
                steps: [step(.tracksRename, target: target, value: .string("After"))],
                idempotencyKey: "cancel-after-verified-write"
            ),
            executor: executor,
            cancellationRequested: { await cancellation.shouldCancel() }
        )

        #expect(outcome.state == .fullyCompensated)
        #expect(!outcome.complete)
        #expect(outcome.journal.first?.verificationEvidence?.disposition == .applied)
        #expect(outcome.journal.first?.compensationEvidence?.disposition == .verified)
        #expect(await executor.runCount() == 2)
        #expect(await executor.state(for: target) == .string("Before"))
    }

    @Test
    func cancellationRequestedThroughDispatcherWhileReadBlockedPreventsWrite() async throws {
        let registry = TargetRegistry()
        let target = await bind(registry, index: 0, name: "Before")
        let plan = SagaPlan(
            steps: [step(.tracksRename, target: target, value: .string("After"))],
            idempotencyKey: "cancel-during-read"
        )
        let journal = SagaJournal()
        guard case .started = await journal.begin(plan) else {
            Issue.record("expected journal claim")
            return
        }
        let probe = BlockingSagaReadProbe()
        let executor = MockSagaExecutor(
            states: [target: .string("Before")],
            behaviors: [.applyStateA, .applyStateA],
            beforeFirstRead: { await probe.block() }
        )
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let execution = Task {
            await saga.execute(
                plan,
                executor: executor,
                cancellationRequested: {
                    await journal.record(for: plan.idempotencyKey) == .cancellationRequested
                }
            )
        }

        await probe.waitUntilEntered()
        let cancelResult = await SystemDispatcher.handle(
            command: "saga_cancel",
            params: ["idempotency_key": .string(plan.idempotencyKey)],
            router: ChannelRouter(),
            cache: StateCache(),
            sagaJournal: journal
        )
        await probe.unblock()
        let outcome = await execution.value
        guard case .text(let text, _, _) = cancelResult.content.first else {
            Issue.record("expected cancellation body")
            return
        }
        let body = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        #expect(body["state"] as? String == "B")
        #expect(!((body["verified"] as? Bool)!))
        #expect(body["status"] as? String == "cancellation_requested")
        #expect(await executor.runCount() == 0)
        #expect(await executor.state(for: target) == .string("Before"))
        let journalEntry = try #require(outcome.journal.first)
        #expect(!journalEntry.writeBoundaryCrossed)
    }

    // MARK: - #412 bounded saga lifecycle deadline (saga + journal level)

    /// #412: once the deadline trips (modeled here as the dispatcher's folded
    /// `cancellationRequested`), the forward loop issues NO additional dispatch
    /// — step 1 is never run; only step 0 and its inverse
    /// were dispatched. Asserts about NEW dispatch, not interruption.
    @Test
    func deadlineFlipStopsAdditionalForwardDispatch() async {
        let registry = TargetRegistry()
        let renameTarget = await bind(registry, index: 0, name: "Bass")
        let volumeTarget = await bind(registry, index: 1, name: "Keys")
        let executor = MockSagaExecutor(
            states: [renameTarget: .string("Bass"), volumeTarget: .double(0.25)],
            behaviors: [.applyStateA, .applyStateA]
        )
        // Flips true on the 3rd checkpoint — the post-applied check after step 0's
        // write, before step 1 is ever entered.
        let deadline = DeadlineFlipProbe(flipAfter: 2)
        let outcome = await MutationSaga(
            targetRegistry: registry,
            enabled: true,
            routeAvailable: { _ in true }
        ).execute(
            SagaPlan(
                steps: [
                    step(.tracksRename, target: renameTarget, value: .string("Sub Bass")),
                    step(.mixerSetVolume, target: volumeTarget, value: .double(0.75)),
                ],
                idempotencyKey: "deadline-forward-stop"
            ),
            executor: executor,
            cancellationRequested: { deadline.reached() }
        )

        // Only step 0 (forward) + step 0's inverse dispatched — no step 1.
        #expect(await executor.runCount() == 2)
        let ops = await executor.runOperations()
        #expect(!ops.contains(.mixerSetVolume))
        #expect(outcome.state == .fullyCompensated)
    }

    /// #412: a deadline that trips DURING compensation abandons the remaining
    /// inverses as `.uncertain` (never `.failed`, never dispatched) and
    /// terminates `rollbackUncertain`.
    @Test
    func deadlineFlipDuringCompensationAbandonsInversesAsUncertain() async throws {
        let registry = TargetRegistry()
        let renameTarget = await bind(registry, index: 0, name: "Lead")
        let volumeTarget = await bind(registry, index: 1, name: "Pad")
        let panTarget = await bind(registry, index: 2, name: "FX")
        let executor = MockSagaExecutor(
            states: [
                renameTarget: .string("Lead"),
                volumeTarget: .double(0.2),
                panTarget: .double(0),
            ],
            behaviors: [.applyStateA, .applyStateA, .failBeforeWrite]
        )
        let outcome = await MutationSaga(
            targetRegistry: registry,
            enabled: true,
            routeAvailable: { _ in true }
        ).execute(
            SagaPlan(
                steps: [
                    step(.tracksRename, target: renameTarget, value: .string("Lead Vox")),
                    step(.mixerSetVolume, target: volumeTarget, value: .double(0.9)),
                    step(.mixerSetPan, target: panTarget, value: .double(-0.5)),
                ],
                idempotencyKey: "deadline-compensation-flip"
            ),
            executor: executor,
            // The forward phase never trips; the deadline is already elapsed by
            // the time compensation begins, so the FIRST inverse is abandoned.
            deadlineReached: { true }
        )

        #expect(outcome.state == .rollbackUncertain)
        let c0 = try #require(outcome.journal[0].compensationEvidence)
        let c1 = try #require(outcome.journal[1].compensationEvidence)
        #expect(c0.disposition == .uncertain)
        #expect(c1.disposition == .uncertain)
        // Directly `.uncertain`, never through an inverse dispatch.
        #expect(c0.executionResult == nil)
        #expect(c1.executionResult == nil)
        // Only the 3 forward runs — no inverse dispatched after the flip.
        #expect(await executor.runCount() == 3)
    }

    /// #412: the loser of the first-writer race resumes with the WINNER's stored
    /// body, never a local body.
    @Test
    func finalizeReturningWinnerReturnsTheJournalWinnerBody() async throws {
        let journal = SagaJournal()
        let plan = SagaPlan(
            steps: [journalStep()],
            idempotencyKey: "ni3-winner-coupling"
        )
        guard case .started(let claim) = await journal.begin(plan) else {
            Issue.record("expected a new journal claim")
            return
        }
        // The winning finisher terminalizes first with body X — it DID finalize.
        let winnerBody = SagaJournal.StoredOutcome(body: "{\"winner\":true}", isError: false)
        let winning = await journal.completeOnTimeout(claim, outcome: winnerBody)
        #expect(winning.body.body == winnerBody.body)
        #expect(winning.didFinalize)

        // The losing finisher proposes a DIFFERENT local body and MUST read back
        // the winner — not its own local body — and reports didFinalize == false.
        let localBody = SagaJournal.StoredOutcome(body: "{\"local\":true}", isError: true)
        let losing = await journal.finalizeReturningWinner(claim, proposed: localBody)
        #expect(losing.body.body == winnerBody.body)
        #expect(losing.body.body != localBody.body)
        #expect(!losing.didFinalize)

        guard case .completed(let stored) = try #require(
            await journal.record(for: plan.idempotencyKey)
        ) else {
            Issue.record("expected a completed terminal record")
            return
        }
        #expect(stored.body == winnerBody.body)
    }

    /// #412: `completeOnTimeout` terminalizes BOTH live states, mapping
    /// `.inProgress → .completed` and `.cancellationRequested → .cancelled`
    /// (verified:false, because a timed-out outcome is never verified).
    @Test
    func completeOnTimeoutTerminalizesBothLiveStates() async throws {
        // inProgress → completed
        let journalA = SagaJournal()
        let planA = SagaPlan(steps: [journalStep()], idempotencyKey: "timeout-inprogress")
        guard case .started(let claimA) = await journalA.begin(planA) else {
            Issue.record("expected a claim"); return
        }
        let bodyA = SagaJournal.StoredOutcome(body: "{\"t\":\"ip\"}", isError: true)
        _ = await journalA.completeOnTimeout(claimA, outcome: bodyA)
        guard case .completed(let storedA) = try #require(
            await journalA.record(for: planA.idempotencyKey)
        ) else {
            Issue.record("expected a completed terminal record"); return
        }
        #expect(storedA.body == bodyA.body)

        // cancellationRequested → cancelled(verified:false)
        let journalB = SagaJournal()
        let planB = SagaPlan(steps: [journalStep()], idempotencyKey: "timeout-cancelreq")
        guard case .started(let claimB) = await journalB.begin(planB) else {
            Issue.record("expected a claim"); return
        }
        _ = await journalB.cancel(idempotencyKey: planB.idempotencyKey)
        let bodyB = SagaJournal.StoredOutcome(body: "{\"t\":\"cr\"}", isError: true)
        _ = await journalB.completeOnTimeout(claimB, outcome: bodyB)
        guard case .cancelled(let storedB, let verified) = try #require(
            await journalB.record(for: planB.idempotencyKey)
        ) else {
            Issue.record("expected a cancelled terminal record"); return
        }
        #expect(storedB.body == bodyB.body)
        #expect(!verified)
    }

    @Test
    func testAmbiguousWriteReconcilesWithoutBlindInverse() async {
        let registry = TargetRegistry()
        let appliedTarget = await bind(registry, index: 0, name: "Applied")
        let notAppliedTarget = await bind(registry, index: 1, name: "Not Applied")
        let unknownTarget = await bind(registry, index: 2, name: "Unknown")

        let appliedExecutor = MockSagaExecutor(
            states: [appliedTarget: .bool(false)],
            behaviors: [.ambiguousApplied, .applyStateA]
        )
        let appliedOutcome = await MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true }).execute(
            SagaPlan(
                steps: [step(.tracksMute, target: appliedTarget, value: .bool(true))],
                idempotencyKey: "ambiguous-applied"
            ),
            executor: appliedExecutor
        )
        #expect(appliedOutcome.state == .fullyCompensated)
        #expect(await appliedExecutor.runCount() == 2)
        #expect(appliedOutcome.journal.first?.compensationEvidence?.disposition == .verified)

        let notAppliedExecutor = MockSagaExecutor(
            states: [notAppliedTarget: .bool(false)],
            behaviors: [.ambiguousNotApplied]
        )
        let notAppliedOutcome = await MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true }).execute(
            SagaPlan(
                steps: [step(.tracksSolo, target: notAppliedTarget, value: .bool(true))],
                idempotencyKey: "ambiguous-not-applied"
            ),
            executor: notAppliedExecutor
        )
        #expect(notAppliedOutcome.state == .partiallyApplied)
        #expect(!notAppliedOutcome.complete)
        #expect(await notAppliedExecutor.runCount() == 1)
        #expect(notAppliedOutcome.journal.first?.compensationEvidence?.disposition == .notNeeded)

        let unknownExecutor = MockSagaExecutor(
            states: [unknownTarget: .bool(false)],
            behaviors: [.ambiguousUnknown]
        )
        let unknownOutcome = await MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true }).execute(
            SagaPlan(
                steps: [step(.tracksArm, target: unknownTarget, value: .bool(true))],
                idempotencyKey: "ambiguous-unknown"
            ),
            executor: unknownExecutor
        )
        #expect(unknownOutcome.state == .rollbackUncertain)
        #expect(!unknownOutcome.complete)
        #expect(await unknownExecutor.runCount() == 1)
        #expect(unknownOutcome.journal.first?.compensationEvidence?.disposition == .uncertain)
    }

    @Test
    func testCompensationFailureIsNotTopLevelSuccess() async {
        let registry = TargetRegistry()
        let firstTarget = await bind(registry, index: 0, name: "First")
        let secondTarget = await bind(registry, index: 1, name: "Second")
        let executor = MockSagaExecutor(
            states: [firstTarget: .string("First"), secondTarget: .double(0.1)],
            behaviors: [.applyStateA, .failBeforeWrite, .failBeforeWrite]
        )
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let outcome = await saga.execute(
            SagaPlan(
                steps: [
                    step(.tracksRename, target: firstTarget, value: .string("Changed")),
                    step(.mixerSetVolume, target: secondTarget, value: .double(0.8)),
                ],
                idempotencyKey: "failed-compensation"
            ),
            executor: executor
        )

        #expect(outcome.state == .compensationFailed)
        #expect(!outcome.complete)
        #expect(outcome.state != .completed)
        #expect(outcome.journal.first?.compensationEvidence?.disposition == .failed)
    }

    @Test
    func testIdempotencyAndDefaultOff() async {
        let flag = "LOGIC_MCP_ADR004_MUTATION_SAGA"
        let previous = getenv(flag).map { String(cString: $0) }
        unsetenv(flag)
        defer {
            if let previous {
                setenv(flag, previous, 1)
            } else {
                unsetenv(flag)
            }
        }

        #expect(!FeatureFlags.adr004MutationSaga)
        let registry = TargetRegistry()
        let target = await bind(registry, index: 0, name: "Idempotent")
        let plan = SagaPlan(
            steps: [step(.tracksRename, target: target, value: .string("Once"))],
            idempotencyKey: "completed-key"
        )

        let disabledExecutor = MockSagaExecutor(
            states: [target: .string("Before")],
            behaviors: [.applyStateA]
        )
        let disabledOutcome = await MutationSaga(targetRegistry: registry, routeAvailable: { _ in true }).execute(
            plan,
            executor: disabledExecutor
        )
        #expect(!disabledOutcome.complete)
        #expect(disabledOutcome.preflightIssues == [.featureDisabled])
        #expect(await disabledExecutor.runCount() == 0)
        #expect(await disabledExecutor.readCount() == 0)

        let executor = MockSagaExecutor(
            states: [target: .string("Before")],
            behaviors: [.applyStateA]
        )
        let saga = MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
        let first = await saga.execute(plan, executor: executor)
        let second = await saga.execute(plan, executor: executor)
        #expect(first == second)
        #expect(first.state == .completed)
        #expect(await executor.runCount() == 1)

        let partialPlan = SagaPlan(
            steps: [step(.tracksSolo, target: target, value: .bool(true))],
            idempotencyKey: "partial-key"
        )
        let partialExecutor = MockSagaExecutor(
            states: [target: .bool(false)],
            behaviors: [.ambiguousNotApplied]
        )
        let partial = await saga.execute(partialPlan, executor: partialExecutor)
        let replay = await saga.execute(partialPlan, executor: partialExecutor)
        #expect(partial.state == .partiallyApplied)
        #expect(replay.preflightIssues == [.automaticReplayBlocked])
        #expect(!replay.complete)
        #expect(await partialExecutor.runCount() == 1)
    }

    @Test
    func testStateMachineAndAllowlistAreExact() {
        #expect(SagaState.allCases == [
            .draft,
            .validated,
            .awaitingConfirmation,
            .running,
            .completed,
            .partiallyApplied,
            .reconciling,
            .compensating,
            .fullyCompensated,
            .partiallyCompensated,
            .compensationFailed,
            .rollbackUncertain,
            .cancelled,
        ])
        #expect(MutationSaga.reversibleOperationIDs == Set([
            .tracksRename,
            .mixerSetVolume,
            .mixerSetPan,
            .tracksMute,
            .tracksSolo,
            .tracksArm,
        ]))
    }
}
