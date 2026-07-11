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
    private var unknownNextRead: Set<TargetReference> = []
    private var runs: [SagaStep] = []
    private var reads = 0

    init(states: [TargetReference: Value], behaviors: [MockSagaBehavior]) {
        self.states = states
        self.behaviors = behaviors
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
        reads += 1
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

    @Test
    func testPreflightRejectsInvalidPlansBeforeRun() async {
        let registry = TargetRegistry()
        let stale = await bind(registry, index: 0, name: "Stale")
        await registry.bumpTopologyGeneration()
        let valid = await bind(registry, index: 1, name: "Valid")
        let executor = MockSagaExecutor(states: [valid: .string("Before")], behaviors: [])
        let saga = MutationSaga(targetRegistry: registry, enabled: true)

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
        let saga = MutationSaga(targetRegistry: registry, enabled: true)
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
        let saga = MutationSaga(targetRegistry: registry, enabled: true)
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
    func testAmbiguousWriteReconcilesWithoutBlindInverse() async {
        let registry = TargetRegistry()
        let appliedTarget = await bind(registry, index: 0, name: "Applied")
        let notAppliedTarget = await bind(registry, index: 1, name: "Not Applied")
        let unknownTarget = await bind(registry, index: 2, name: "Unknown")

        let appliedExecutor = MockSagaExecutor(
            states: [appliedTarget: .bool(false)],
            behaviors: [.ambiguousApplied, .applyStateA]
        )
        let appliedOutcome = await MutationSaga(targetRegistry: registry, enabled: true).execute(
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
        let notAppliedOutcome = await MutationSaga(targetRegistry: registry, enabled: true).execute(
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
        let unknownOutcome = await MutationSaga(targetRegistry: registry, enabled: true).execute(
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
        let saga = MutationSaga(targetRegistry: registry, enabled: true)
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
        let disabledOutcome = await MutationSaga(targetRegistry: registry).execute(
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
        let saga = MutationSaga(targetRegistry: registry, enabled: true)
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
