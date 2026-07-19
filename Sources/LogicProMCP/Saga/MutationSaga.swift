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

/// Which live AX primitive produced a saga observation. These are the SAME
/// primitives the dispatchers use for their State-A verification — the saga
/// reads the surface, never the cache mirror.
enum SagaReadSource: String, Codable, Equatable, Sendable {
    case axTrackHeaderFader = "ax_track_header_fader"
    case axTrackHeaderPan = "ax_track_header_pan"
    case axTrackName = "ax_track_name"
    case axTrackToggle = "ax_track_toggle"

    /// Short label for the human summary string.
    var label: String {
        switch self {
        case .axTrackHeaderFader: "header_fader"
        case .axTrackHeaderPan: "header_pan"
        case .axTrackName: "track_name"
        case .axTrackToggle: "track_toggle"
        }
    }
}

/// LPMCP-PRD-004: every saga observation is an INDEPENDENT live read. The enum
/// has exactly one case on purpose — there is no legal cache-sourced saga
/// observation, so no `state_cache` provenance can be constructed.
enum SagaProvenance: String, Codable, Equatable, Sendable {
    case liveIndependent = "live_independent"
}

/// Structured provenance for one saga observation. Serialized into the journal
/// so an operator can audit WHERE a rollback value came from.
struct SagaReadEvidence: Codable, Equatable, Sendable {
    let readSource: SagaReadSource
    let provenance: SagaProvenance
    let trackIndex: Int
    let field: String
    let observed: Value
    let sampledAt: String

    /// Human summary, e.g. `ax_live tracks[3].volume (header_fader)`.
    var summary: String {
        "ax_live tracks[\(trackIndex)].\(field) (\(readSource.label))"
    }

    enum CodingKeys: String, CodingKey {
        case readSource = "read_source"
        case provenance
        case trackIndex = "track_index"
        case field
        case observed
        case sampledAt = "sampled_at"
    }
}

struct ObservedState: Codable, Equatable, Sendable {
    let value: Value
    let evidence: String
    var read: SagaReadEvidence?
}

extension ObservedState {
    /// Build an observation from a live read — the value, the human summary,
    /// and the structured provenance always agree because they share one source.
    init(read: SagaReadEvidence) {
        self.init(value: read.observed, evidence: read.summary, read: read)
    }
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
    /// How the disposition was decided (comparator/epsilon/desired/observed/
    /// delta). Absent when no comparison ran — e.g. a pre-write State C, where
    /// `notApplied` follows from the write never crossing the boundary.
    var comparison: SagaComparisonEvidence?
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
    /// Live readback vs the captured live before-state, within the operation's
    /// epsilon. Absent when no inverse was dispatched.
    var comparison: SagaComparisonEvidence?
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
        /// LPMCP-PRD-004: how an observed live value is compared to an expected
        /// one for THIS operation. Declared next to the inverse contract so a
        /// future allowlist entry cannot be added without deciding it.
        let tolerance: SagaTolerance
    }

    /// Epsilon rationale (absolute, on the operation's normalized range):
    /// - rename: a name is a discrete string — `"A"` and `"A "` are different
    ///   tracks to the operator, so exact.
    /// - mute/solo/arm: booleans have no near-miss.
    /// - volume (0...1, eps 0.01): the AX header fader is exposed in ~10-raw-unit
    ///   detents, so a verified write lands on the nearest representable level,
    ///   not the requested double.
    /// - pan (-1...1, eps 0.05): the same detent quantization over a range twice
    ///   as wide, and the pan control is coarser still.
    private static let reversibleDefinitions: [OperationID: ReversibleDefinition] = [
        .tracksRename: ReversibleDefinition(
            tool: .logicTracks, command: "rename", valueParameter: "name",
            tolerance: .exact
        ),
        .mixerSetVolume: ReversibleDefinition(
            tool: .logicMixer, command: "set_volume", valueParameter: "value",
            tolerance: .absoluteEpsilon(0.01)
        ),
        .mixerSetPan: ReversibleDefinition(
            tool: .logicMixer, command: "set_pan", valueParameter: "value",
            tolerance: .absoluteEpsilon(0.05)
        ),
        .tracksMute: ReversibleDefinition(
            tool: .logicTracks, command: "mute", valueParameter: "enabled",
            tolerance: .exact
        ),
        .tracksSolo: ReversibleDefinition(
            tool: .logicTracks, command: "solo", valueParameter: "enabled",
            tolerance: .exact
        ),
        .tracksArm: ReversibleDefinition(
            tool: .logicTracks, command: "arm", valueParameter: "enabled",
            tolerance: .exact
        ),
    ]

    nonisolated static let reversibleOperationIDs: Set<OperationID> = Set(reversibleDefinitions.keys)

    /// The declared comparison contract for `operationID`, or nil when the
    /// operation is not saga-reversible.
    nonisolated static func tolerance(for operationID: OperationID) -> SagaTolerance? {
        reversibleDefinitions[operationID]?.tolerance
    }

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
        cancellationRequested: @Sendable () async -> Bool = { false },
        // #412: the lifecycle deadline threads through execute -> the private
        // cancel() -> compensate() so the compensation-abandon checkpoint is
        // reachable on the main deadline-trip route (the trip enters cancel()
        // via the forward cancellation checkpoints). Forward is unchanged: the
        // dispatcher folds deadlineReached into `cancellationRequested`, so the
        // forward checkpoints need no new branch.
        deadlineReached: @Sendable () -> Bool = { false }
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
                    outcome: outcome,
                    deadlineReached: deadlineReached
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
                    outcome: outcome,
                    deadlineReached: deadlineReached
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
                    outcome: outcome,
                    deadlineReached: deadlineReached
                )
            }
            let executionResult = await executor.run(step)
            outcome.journal[index].writeBoundaryCrossed = executionResult.writeBoundaryCrossed
            outcome.journal[index].executionResult = executionResult
            sessions[plan.idempotencyKey] = outcome

            switch executionResult.state {
            case .stateA:
                let readback = await executor.readState(step)
                let disposition = classifyVerifiedWrite(
                    readback,
                    desiredValue: desiredValue,
                    operationID: step.operationID
                )
                outcome.journal[index].verificationEvidence = VerificationEvidence(
                    disposition: disposition,
                    readback: readback,
                    comparison: SagaValueComparator.evidence(
                        observed: readback?.value,
                        desired: desiredValue,
                        op: step.operationID
                    )
                )
                if disposition == .applied {
                    appliedIndices.append(index)
                    sessions[plan.idempotencyKey] = outcome
                    if await cancellationRequested() {
                        return await cancel(
                            appliedIndices: appliedIndices,
                            executor: executor,
                            outcome: outcome,
                            deadlineReached: deadlineReached
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
                    outcome: outcome,
                    deadlineReached: deadlineReached
                )

            case .stateB:
                markReconciliation(outcome: &outcome)
                let readback = await executor.readState(step)
                let disposition = classify(
                    readback,
                    desiredValue: desiredValue,
                    beforeState: beforeState,
                    operationID: step.operationID
                )
                outcome.journal[index].verificationEvidence = VerificationEvidence(
                    disposition: disposition,
                    readback: readback,
                    comparison: SagaValueComparator.evidence(
                        observed: readback?.value,
                        desired: desiredValue,
                        op: step.operationID
                    )
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
                    outcome: outcome,
                    deadlineReached: deadlineReached
                )

            case .stateC:
                if executionResult.writeBoundaryCrossed {
                    markReconciliation(outcome: &outcome)
                    let readback = await executor.readState(step)
                    let disposition = classify(
                        readback,
                        desiredValue: desiredValue,
                        beforeState: beforeState,
                        operationID: step.operationID
                    )
                    outcome.journal[index].verificationEvidence = VerificationEvidence(
                        disposition: disposition,
                        readback: readback,
                        comparison: SagaValueComparator.evidence(
                            observed: readback?.value,
                            desired: desiredValue,
                            op: step.operationID
                        )
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
                        outcome: outcome,
                        deadlineReached: deadlineReached
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
                    outcome: outcome,
                    deadlineReached: deadlineReached
                )
            }
        }

        if await cancellationRequested() {
            return await cancel(
                appliedIndices: appliedIndices,
                executor: executor,
                outcome: outcome,
                deadlineReached: deadlineReached
            )
        }

        outcome.complete = true
        advance(.completed, outcome: &outcome)
        return outcome
    }

    func cancel<Executor: SagaStepExecutor>(
        outcome: SagaOutcome,
        executor: Executor,
        deadlineReached: @Sendable () -> Bool = { false }
    ) async -> SagaOutcome {
        let appliedIndices = outcome.journal.indices.filter {
            outcome.journal[$0].verificationEvidence?.disposition == .applied
        }
        return await cancel(
            appliedIndices: appliedIndices,
            executor: executor,
            outcome: outcome,
            deadlineReached: deadlineReached
        )
    }

    private func cancel<Executor: SagaStepExecutor>(
        appliedIndices: [Int],
        executor: Executor,
        outcome: SagaOutcome,
        deadlineReached: @Sendable () -> Bool
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
            outcome: outcome,
            deadlineReached: deadlineReached
        )
    }

    private func compensate<Executor: SagaStepExecutor>(
        appliedIndices: [Int],
        rollbackIsUncertain: Bool,
        executor: Executor,
        outcome initialOutcome: SagaOutcome,
        deadlineReached: @Sendable () -> Bool
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
            // #412: the lifecycle deadline is checked immediately before each
            // inverse dispatch; once elapsed no further inverse is issued and
            // every not-yet-run applied index is marked uncertain directly —
            // never failed (that disposition is only for a real dispatched
            // inverse whose readback mismatched) and never via `executor.run`.
            // `uncertain` then drives the honest `rollbackUncertain` terminal.
            // There is no reserved compensation budget: a full-budget forward
            // legitimately leaves all inverses abandoned as uncertain.
            if deadlineReached() {
                markRemainingUncertain(appliedIndices, from: index, outcome: &outcome)
                uncertain = true
                break
            }
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
            // LPMCP-PRD-004: the restore target is the LIVE before-state
            // captured at step time, and the proof is an independent live
            // readback compared within the operation's epsilon — a quantized
            // fader that restores to 0.249 has restored 0.25.
            //
            // No ambiguous zone here (unlike `classify`): this asks ONE
            // question — is the surface back at the before-state? — and
            // compares against the before-state alone. Where the desired value
            // sits within epsilon of the before-state, the two are the same
            // value under the declared tolerance, so no second hypothesis
            // competes and no different action could follow from one.
            let comparison = SagaValueComparator.evidence(
                observed: readback?.value,
                desired: beforeState.value,
                op: inverse.operationID
            )
            let disposition: CompensationDisposition
            if comparison.equal {
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
                readback: readback,
                comparison: comparison
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

    /// State-B/C reconciliation: the write path could NOT verify itself, so the
    /// saga decides from an independent live read, compared within the
    /// operation's declared epsilon.
    ///
    /// THE AMBIGUOUS ZONE: an epsilon-tolerant comparison — unlike the exact `==`
    /// it replaced — can match the readback against BOTH the desired value and
    /// the before-state at once, whenever `|desired - before| <= epsilon`. A pan
    /// step from -1.0 to -0.96 (eps 0.05) whose write failed leaves the surface
    /// at -1.0, and -1.0 matches the desired -0.96 within epsilon. Checking
    /// desired first would call that failed write `applied` — a false success
    /// with no compensation. The two hypotheses (it landed / it never landed)
    /// are indistinguishable from this read, so the honest disposition is
    /// `unknown`: the operator is told we cannot tell, and the plan reconciles
    /// as uncertain instead of claiming a success it did not observe.
    private func classify(
        _ readback: ObservedState?,
        desiredValue: Value,
        beforeState: ObservedState,
        operationID: OperationID
    ) -> VerificationDisposition {
        guard let readback else { return .unknown }
        let matchesDesired = SagaValueComparator.equals(
            observed: readback.value,
            expected: desiredValue,
            op: operationID
        )
        let matchesBefore = SagaValueComparator.equals(
            observed: readback.value,
            expected: beforeState.value,
            op: operationID
        )
        if matchesDesired {
            return matchesBefore ? .unknown : .applied
        }
        return matchesBefore ? .notApplied : .unknown
    }

    /// State A means the DISPATCHER already verified the write against the live
    /// AX surface at the moment it landed. LPMCP-PRD-004: re-deciding that from
    /// a second, later read is strictly worse information — a concurrent
    /// operator nudge, or plain quantization under the old exact `==`, would
    /// downgrade a verified write to `notApplied` and roll back a change that
    /// actually applied. So a State-A step is `applied`. A corroborating live
    /// read is optional evidence that can only escalate to `unknown` (drift we
    /// cannot explain), never demote to `notApplied`.
    private func classifyVerifiedWrite(
        _ readback: ObservedState?,
        desiredValue: Value,
        operationID: OperationID
    ) -> VerificationDisposition {
        guard let readback else { return .applied }
        return SagaValueComparator.equals(
            observed: readback.value,
            expected: desiredValue,
            op: operationID
        ) ? .applied : .unknown
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

    /// #412: mark every applied index the compensation loop has NOT yet
    /// dispatched an inverse for as `.uncertain`, directly — no `executor.run`,
    /// never `.failed`. `appliedIndices` is appended in ascending forward order
    /// and the loop consumes it in reverse, so when the deadline trips at
    /// `index` the un-run remainder is exactly the applied indices `<= index`
    /// (the larger ones already compensated).
    private func markRemainingUncertain(
        _ appliedIndices: [Int],
        from index: Int,
        outcome: inout SagaOutcome
    ) {
        for applied in appliedIndices where applied <= index {
            outcome.journal[applied].compensationEvidence = CompensationEvidence(
                disposition: .uncertain,
                executionResult: nil,
                readback: nil,
                comparison: nil
            )
        }
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
