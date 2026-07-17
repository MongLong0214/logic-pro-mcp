import Foundation
import MCP

enum SagaState: String, Codable, CaseIterable, Equatable, Sendable {
    case draft
    case validated
    case awaitingConfirmation
    case running
    case completed
    case partiallyApplied
    case reconciling
    case compensating
    case fullyCompensated
    case partiallyCompensated
    case compensationFailed
    case rollbackUncertain
    case cancelled
}

struct SagaExpectedInverse: Codable, Equatable, Sendable {
    let operationID: OperationID
    let valueParameter: String
}

struct SagaStep: Codable, Equatable, Sendable {
    let operationID: OperationID
    let targetRef: TargetReference?
    let params: [String: Value]
    let expectedInverse: SagaExpectedInverse
}

struct SagaPlan: Codable, Equatable, Sendable {
    let steps: [SagaStep]
    let idempotencyKey: String
}

enum StepResultState: String, Codable, Equatable, Sendable {
    case stateA = "A"
    case stateB = "B"
    case stateC = "C"
}

struct StepResult: Codable, Equatable, Sendable {
    let state: StepResultState
    let writeBoundaryCrossed: Bool
    let detail: String
}

struct ObservedState: Codable, Equatable, Sendable {
    let value: Value
    let evidence: String
}

protocol SagaStepExecutor: Sendable {
    func run(_ step: SagaStep) async -> StepResult
    func readState(_ step: SagaStep) async -> ObservedState?
}

enum VerificationDisposition: String, Codable, Equatable, Sendable {
    case applied
    case notApplied
    case unknown
}

struct VerificationEvidence: Codable, Equatable, Sendable {
    let disposition: VerificationDisposition
    let readback: ObservedState?
}

enum CompensationDisposition: String, Codable, Equatable, Sendable {
    case verified
    case notNeeded
    case failed
    case uncertain
}

struct CompensationEvidence: Codable, Equatable, Sendable {
    let disposition: CompensationDisposition
    let executionResult: StepResult?
    let readback: ObservedState?
}

struct CompensationJournalRecord: Codable, Equatable, Sendable {
    let stepIndex: Int
    let beforeState: ObservedState?
    var writeBoundaryCrossed = false
    var executionResult: StepResult?
    var verificationEvidence: VerificationEvidence?
    var inverseOperation: SagaStep?
    var compensationEvidence: CompensationEvidence?
}

enum PreflightIssue: Equatable, Sendable {
    case featureDisabled
    case emptyPlan
    case invalidIdempotencyKey
    case registryInvalid
    case operationNotRegistered(stepIndex: Int, operationID: OperationID)
    case invalidOperationSpec(stepIndex: Int, operationID: OperationID)
    case operationNotReversible(stepIndex: Int, operationID: OperationID)
    case staleTarget(stepIndex: Int)
    case projectEpochMismatch(stepIndex: Int)
    case invalidExpectedInverse(stepIndex: Int)
    case automaticReplayBlocked
    /// The registry declares a confirmation policy for this operation; the
    /// saga wire carries no confirmation flow, so such plans reject before
    /// step 1. Defense-in-depth today (the reversible allowlist is all
    /// ConfirmationPolicy.none) — this fails closed the day the allowlist
    /// grows a confirmation-requiring operation.
    case confirmationRequired(stepIndex: Int, operationID: OperationID)
    /// No healthy route can serve this step right now (checked before any
    /// step executes, so a dead channel cannot strand a half-applied plan).
    case routeUnavailable(stepIndex: Int, operationID: OperationID)
    /// The worst-case sum of the steps' registry deadlines exceeds the
    /// saga-execute command budget — the plan could time out mid-flight.
    case deadlineBudgetExceeded(totalSeconds: Double, budgetSeconds: Double)
}

enum PreflightStatus: Equatable, Sendable {
    case ready
    case existingSession
    case rejected
}

struct PreflightResult: Sendable {
    let status: PreflightStatus
    let issues: [PreflightIssue]

    var passed: Bool { status == .ready }
}

struct SagaOutcome: Equatable, Sendable {
    let idempotencyKey: String
    var state: SagaState
    var complete: Bool
    var journal: [CompensationJournalRecord]
    var stateHistory: [SagaState]
    var preflightIssues: [PreflightIssue]
}

actor MutationSaga {
    private struct ReversibleDefinition: Sendable {
        let tool: ToolID
        let command: String
        let valueParameter: String
    }

    private static let reversibleDefinitions: [OperationID: ReversibleDefinition] = [
        .tracksRename: ReversibleDefinition(tool: .logicTracks, command: "rename", valueParameter: "name"),
        .mixerSetVolume: ReversibleDefinition(tool: .logicMixer, command: "set_volume", valueParameter: "value"),
        .mixerSetPan: ReversibleDefinition(tool: .logicMixer, command: "set_pan", valueParameter: "value"),
        .tracksMute: ReversibleDefinition(tool: .logicTracks, command: "mute", valueParameter: "enabled"),
        .tracksSolo: ReversibleDefinition(tool: .logicTracks, command: "solo", valueParameter: "enabled"),
        .tracksArm: ReversibleDefinition(tool: .logicTracks, command: "arm", valueParameter: "enabled"),
    ]

    nonisolated static let reversibleOperationIDs: Set<OperationID> = Set(reversibleDefinitions.keys)

    private let targetRegistry: TargetRegistry
    private let enabled: Bool
    private var sessions: [String: SagaOutcome] = [:]

    /// Route-health probe for preflight. REQUIRED — a silent skip default
    /// would be fail-open (a future construction site forgetting the probe
    /// would silently drop route checks; adversarial review flagged exactly
    /// that regression path). Pure unit contexts pass `{ _ in true }`
    /// explicitly; the public dispatcher wires the real channel-health probe.
    private let routeAvailable: @Sendable (OperationID) async -> Bool

    init(
        targetRegistry: TargetRegistry,
        enabled: Bool = FeatureFlags.adr004MutationSaga,
        routeAvailable: @escaping @Sendable (OperationID) async -> Bool
    ) {
        self.targetRegistry = targetRegistry
        self.enabled = enabled
        self.routeAvailable = routeAvailable
    }

    func preflight(_ plan: SagaPlan) async -> PreflightResult {
        guard enabled else {
            return PreflightResult(status: .rejected, issues: [.featureDisabled])
        }
        if let existing = sessions[plan.idempotencyKey] {
            if isReturnable(existing.state) {
                return PreflightResult(status: .existingSession, issues: [])
            }
            return PreflightResult(status: .rejected, issues: [.automaticReplayBlocked])
        }

        var issues: [PreflightIssue] = []
        if plan.steps.isEmpty { issues.append(.emptyPlan) }
        if plan.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.invalidIdempotencyKey)
        }
        if !OperationRegistry.validationErrors().isEmpty {
            issues.append(.registryInvalid)
        }

        let projectEpoch = await targetRegistry.currentProjectEpoch
        var worstCaseSeconds: Double = 0
        for (index, step) in plan.steps.enumerated() {
            let registeredSpec = OperationRegistry.specs.first { $0.id == step.operationID }
            if registeredSpec == nil {
                issues.append(.operationNotRegistered(
                    stepIndex: index,
                    operationID: step.operationID
                ))
            }
            if let spec = registeredSpec {
                worstCaseSeconds += spec.deadline.seconds
                if spec.confirmation != .none {
                    issues.append(.confirmationRequired(
                        stepIndex: index,
                        operationID: step.operationID
                    ))
                }
            }
            if await !routeAvailable(step.operationID) {
                issues.append(.routeUnavailable(
                    stepIndex: index,
                    operationID: step.operationID
                ))
            }

            if let definition = Self.reversibleDefinitions[step.operationID] {
                let spec = OperationRegistry.spec(
                    tool: definition.tool.rawValue,
                    command: definition.command
                )
                if spec?.id != step.operationID
                    || spec?.mutability != Mutability.`mutating`
                    || spec?.verification != .readbackRequired
                    || spec?.retry != .neverAutomatic
                    || spec?.availability == .unsupported
                    || registeredSpec?.tool != definition.tool
                    || registeredSpec?.command != definition.command
                {
                    issues.append(.invalidOperationSpec(
                        stepIndex: index,
                        operationID: step.operationID
                    ))
                }
                if step.expectedInverse.operationID != step.operationID
                    || step.expectedInverse.valueParameter != definition.valueParameter
                    || step.params[definition.valueParameter] == nil
                {
                    issues.append(.invalidExpectedInverse(stepIndex: index))
                }
            } else {
                issues.append(.operationNotReversible(
                    stepIndex: index,
                    operationID: step.operationID
                ))
            }

            guard let targetRef = step.targetRef,
                  let binding = await targetRegistry.resolve(targetRef) else {
                issues.append(.staleTarget(stepIndex: index))
                continue
            }
            if binding.projectEpoch != projectEpoch {
                issues.append(.projectEpochMismatch(stepIndex: index))
            }
        }

        // ADR-004: reject before step 1 when the plan's modeled duration
        // cannot fit the saga-execute command budget — otherwise the
        // whole-command deadline could fire mid-plan. HONEST SCOPE: the model
        // is COARSE — 2× the per-step registry deadline (write + verification
        // readback); availability capture, cache refresh, and a late-failure
        // compensation replay are NOT reserved, so a mid-flight timeout
        // remains possible for pathological plans — this check bounds the
        // obvious overcommit, it does not guarantee completion. Rejection is
        // >= (an exact-fit plan has zero headroom for the unmodeled work).
        // The budget is registry-derived, never a local constant.
        let budgetSeconds = OperationRegistry.spec(
            tool: ToolID.logicSystem.rawValue,
            command: "saga_execute"
        )?.deadline.seconds ?? DeadlineClass.long.seconds
        let modeledSeconds = worstCaseSeconds * 2
        if modeledSeconds >= budgetSeconds {
            issues.append(.deadlineBudgetExceeded(
                totalSeconds: modeledSeconds,
                budgetSeconds: budgetSeconds
            ))
        }

        return PreflightResult(
            status: issues.isEmpty ? .ready : .rejected,
            issues: issues
        )
    }

    func execute<Executor: SagaStepExecutor>(
        _ plan: SagaPlan,
        executor: Executor,
        cancellationRequested: @Sendable () async -> Bool = { false }
    ) async -> SagaOutcome {
        let result = await preflight(plan)
        switch result.status {
        case .existingSession:
            if let existing = sessions[plan.idempotencyKey] { return existing }
            return rejectedOutcome(plan, issues: [.automaticReplayBlocked])
        case .rejected:
            return rejectedOutcome(plan, issues: result.issues)
        case .ready:
            break
        }

        if let existing = sessions[plan.idempotencyKey] {
            if isReturnable(existing.state) { return existing }
            return rejectedOutcome(plan, issues: [.automaticReplayBlocked])
        }

        var outcome = SagaOutcome(
            idempotencyKey: plan.idempotencyKey,
            state: .draft,
            complete: false,
            journal: [],
            stateHistory: [.draft],
            preflightIssues: []
        )
        sessions[plan.idempotencyKey] = outcome
        advance(.validated, outcome: &outcome)
        advance(.awaitingConfirmation, outcome: &outcome)
        advance(.running, outcome: &outcome)

        var appliedIndices: [Int] = []
        for (index, step) in plan.steps.enumerated() {
            if await cancellationRequested() {
                return await cancel(
                    appliedIndices: appliedIndices,
                    executor: executor,
                    outcome: outcome
                )
            }
            guard let beforeState = await executor.readState(step),
                  let desiredValue = step.params[step.expectedInverse.valueParameter] else {
                outcome.journal.append(CompensationJournalRecord(
                    stepIndex: index,
                    beforeState: nil,
                    verificationEvidence: VerificationEvidence(
                        disposition: .unknown,
                        readback: nil
                    ),
                    compensationEvidence: CompensationEvidence(
                        disposition: .notNeeded,
                        executionResult: nil,
                        readback: nil
                    )
                ))
                return await compensate(
                    appliedIndices: appliedIndices,
                    rollbackIsUncertain: false,
                    executor: executor,
                    outcome: outcome
                )
            }

            var inverseParams = step.params
            inverseParams[step.expectedInverse.valueParameter] = beforeState.value
            let inverse = SagaStep(
                operationID: step.expectedInverse.operationID,
                targetRef: step.targetRef,
                params: inverseParams,
                expectedInverse: step.expectedInverse
            )
            outcome.journal.append(CompensationJournalRecord(
                stepIndex: index,
                beforeState: beforeState,
                inverseOperation: inverse
            ))
            sessions[plan.idempotencyKey] = outcome

            if await cancellationRequested() {
                return await cancel(
                    appliedIndices: appliedIndices,
                    executor: executor,
                    outcome: outcome
                )
            }
            let executionResult = await executor.run(step)
            outcome.journal[index].writeBoundaryCrossed = executionResult.writeBoundaryCrossed
            outcome.journal[index].executionResult = executionResult
            sessions[plan.idempotencyKey] = outcome

            switch executionResult.state {
            case .stateA:
                let readback = await executor.readState(step)
                let disposition = classify(
                    readback,
                    desiredValue: desiredValue,
                    beforeState: beforeState
                )
                outcome.journal[index].verificationEvidence = VerificationEvidence(
                    disposition: disposition,
                    readback: readback
                )
                if disposition == .applied {
                    appliedIndices.append(index)
                    sessions[plan.idempotencyKey] = outcome
                    if await cancellationRequested() {
                        return await cancel(
                            appliedIndices: appliedIndices,
                            executor: executor,
                            outcome: outcome
                        )
                    }
                    continue
                }
                markReconciliation(outcome: &outcome)
                markNoInverseOrUncertain(
                    disposition,
                    readback: readback,
                    index: index,
                    outcome: &outcome
                )
                return await compensate(
                    appliedIndices: appliedIndices,
                    rollbackIsUncertain: disposition == .unknown,
                    executor: executor,
                    outcome: outcome
                )

            case .stateB:
                markReconciliation(outcome: &outcome)
                let readback = await executor.readState(step)
                let disposition = classify(
                    readback,
                    desiredValue: desiredValue,
                    beforeState: beforeState
                )
                outcome.journal[index].verificationEvidence = VerificationEvidence(
                    disposition: disposition,
                    readback: readback
                )
                if disposition == .applied { appliedIndices.append(index) }
                if disposition != .applied {
                    markNoInverseOrUncertain(
                        disposition,
                        readback: readback,
                        index: index,
                        outcome: &outcome
                    )
                }
                return await compensate(
                    appliedIndices: appliedIndices,
                    rollbackIsUncertain: disposition == .unknown,
                    executor: executor,
                    outcome: outcome
                )

            case .stateC:
                if executionResult.writeBoundaryCrossed {
                    markReconciliation(outcome: &outcome)
                    let readback = await executor.readState(step)
                    let disposition = classify(
                        readback,
                        desiredValue: desiredValue,
                        beforeState: beforeState
                    )
                    outcome.journal[index].verificationEvidence = VerificationEvidence(
                        disposition: disposition,
                        readback: readback
                    )
                    if disposition == .applied { appliedIndices.append(index) }
                    if disposition != .applied {
                        markNoInverseOrUncertain(
                            disposition,
                            readback: readback,
                            index: index,
                            outcome: &outcome
                        )
                    }
                    return await compensate(
                        appliedIndices: appliedIndices,
                        rollbackIsUncertain: disposition == .unknown,
                        executor: executor,
                        outcome: outcome
                    )
                }

                outcome.journal[index].verificationEvidence = VerificationEvidence(
                    disposition: .notApplied,
                    readback: nil
                )
                outcome.journal[index].compensationEvidence = CompensationEvidence(
                    disposition: .notNeeded,
                    executionResult: nil,
                    readback: nil
                )
                return await compensate(
                    appliedIndices: appliedIndices,
                    rollbackIsUncertain: false,
                    executor: executor,
                    outcome: outcome
                )
            }
        }

        if await cancellationRequested() {
            return await cancel(
                appliedIndices: appliedIndices,
                executor: executor,
                outcome: outcome
            )
        }

        outcome.complete = true
        advance(.completed, outcome: &outcome)
        return outcome
    }

    func cancel<Executor: SagaStepExecutor>(
        outcome: SagaOutcome,
        executor: Executor
    ) async -> SagaOutcome {
        let appliedIndices = outcome.journal.indices.filter {
            outcome.journal[$0].verificationEvidence?.disposition == .applied
        }
        return await cancel(
            appliedIndices: appliedIndices,
            executor: executor,
            outcome: outcome
        )
    }

    private func cancel<Executor: SagaStepExecutor>(
        appliedIndices: [Int],
        executor: Executor,
        outcome: SagaOutcome
    ) async -> SagaOutcome {
        guard !appliedIndices.isEmpty else {
            var cancelled = outcome
            advance(.cancelled, outcome: &cancelled)
            return cancelled
        }
        return await compensate(
            appliedIndices: appliedIndices,
            rollbackIsUncertain: false,
            executor: executor,
            outcome: outcome
        )
    }

    private func compensate<Executor: SagaStepExecutor>(
        appliedIndices: [Int],
        rollbackIsUncertain: Bool,
        executor: Executor,
        outcome initialOutcome: SagaOutcome
    ) async -> SagaOutcome {
        // ADR-005: compensation begin is visible on the PARENT saga trace
        // (the step scopes below carry parent_trace_id for the inverse
        // dispatches themselves).
        await OperationTraceContext.record(.compensationStarted, attributes: [
            "outcome": rollbackIsUncertain ? "rollback_uncertain" : "partially_applied",
        ])
        var outcome = initialOutcome
        if outcome.state != .partiallyApplied && outcome.state != .reconciling {
            advance(.partiallyApplied, outcome: &outcome)
        }

        guard !appliedIndices.isEmpty else {
            advance(rollbackIsUncertain ? .rollbackUncertain : .partiallyApplied, outcome: &outcome)
            return outcome
        }

        advance(.compensating, outcome: &outcome)
        var verifiedCount = 0
        var uncertain = rollbackIsUncertain

        for index in appliedIndices.reversed() {
            guard let inverse = outcome.journal[index].inverseOperation,
                  let beforeState = outcome.journal[index].beforeState else {
                outcome.journal[index].compensationEvidence = CompensationEvidence(
                    disposition: .failed,
                    executionResult: nil,
                    readback: nil
                )
                sessions[outcome.idempotencyKey] = outcome
                continue
            }

            let compensationResult = await executor.run(inverse)
            let readback = await executor.readState(inverse)
            let disposition: CompensationDisposition
            if readback?.value == beforeState.value {
                disposition = .verified
                verifiedCount += 1
            } else if readback == nil && compensationResult.writeBoundaryCrossed {
                disposition = .uncertain
                uncertain = true
            } else {
                disposition = .failed
            }
            outcome.journal[index].compensationEvidence = CompensationEvidence(
                disposition: disposition,
                executionResult: compensationResult,
                readback: readback
            )
            sessions[outcome.idempotencyKey] = outcome
        }

        if uncertain {
            advance(.rollbackUncertain, outcome: &outcome)
        } else if verifiedCount == appliedIndices.count {
            advance(.fullyCompensated, outcome: &outcome)
        } else if verifiedCount > 0 {
            advance(.partiallyCompensated, outcome: &outcome)
        } else {
            advance(.compensationFailed, outcome: &outcome)
        }
        return outcome
    }

    private func classify(
        _ readback: ObservedState?,
        desiredValue: Value,
        beforeState: ObservedState
    ) -> VerificationDisposition {
        if readback?.value == desiredValue { return .applied }
        if readback?.value == beforeState.value { return .notApplied }
        return .unknown
    }

    private func markReconciliation(outcome: inout SagaOutcome) {
        advance(.partiallyApplied, outcome: &outcome)
        advance(.reconciling, outcome: &outcome)
    }

    private func markNoInverseOrUncertain(
        _ disposition: VerificationDisposition,
        readback: ObservedState?,
        index: Int,
        outcome: inout SagaOutcome
    ) {
        outcome.journal[index].compensationEvidence = CompensationEvidence(
            disposition: disposition == .notApplied ? .notNeeded : .uncertain,
            executionResult: nil,
            readback: readback
        )
        sessions[outcome.idempotencyKey] = outcome
    }

    private func advance(_ state: SagaState, outcome: inout SagaOutcome) {
        outcome.state = state
        if outcome.stateHistory.last != state { outcome.stateHistory.append(state) }
        sessions[outcome.idempotencyKey] = outcome
    }

    private func rejectedOutcome(
        _ plan: SagaPlan,
        issues: [PreflightIssue]
    ) -> SagaOutcome {
        SagaOutcome(
            idempotencyKey: plan.idempotencyKey,
            state: .draft,
            complete: false,
            journal: [],
            stateHistory: [.draft],
            preflightIssues: issues
        )
    }

    private func isReturnable(_ state: SagaState) -> Bool {
        switch state {
        case .draft, .validated, .awaitingConfirmation, .running, .reconciling, .compensating,
             .completed:
            true
        case .partiallyApplied, .fullyCompensated, .partiallyCompensated,
             .compensationFailed, .rollbackUncertain, .cancelled:
            false
        }
    }
}
