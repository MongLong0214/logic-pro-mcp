import CryptoKit
import Foundation
import MCP

/// LPMCP-PRD-005 — the session saga journal is split into two independently
/// bounded tiers so that saturation costs OUTCOME BODIES, never same-key replay
/// protection.
///
/// - The COMPACT tier (`idempotencySet`) holds one small row per key ever begun
///   in this generation: plan hash, terminal kind, sequence. It is append-only
///   within a generation — a key that reached a terminal state is NEVER dropped
///   while the session lives, so a replayed key can never fall back to
///   `.started` and re-fire a write.
/// - The BODY tier holds the full state a caller can still be handed back:
///   in-flight entries (`entries`, plan + claim, never evictable) and stored
///   terminal outcomes (`outcomeBodies`, evictable oldest-first). It is bounded
///   by `maxRecords`.
///
/// When a body is evicted the compact row survives, so the key answers
/// `.outcomeEvicted` — "this already ran, and I can no longer show you what
/// happened". That is deliberately NOT `.completed` (which would replay a body
/// we no longer have) and NOT `.started` (which would re-execute a write).
///
/// There is no wall-clock TTL anywhere: eviction is count-based and ordered by
/// begin sequence, so behaviour is deterministic and testable.
actor SagaJournal {
    /// Bounds the BODY tier: in-flight entries + retained terminal outcomes.
    static let defaultMaxRecords = 1_024
    /// Bounds the COMPACT tier: every key begun in this generation.
    static let defaultCompactCapacity = 65_536

    struct StoredOutcome: Equatable, Sendable {
        let body: String
        let isError: Bool
    }

    /// WHICH terminal path a key finished on — NOT a claim that the caller's
    /// intent succeeded. A saga that only partially applied still terminates via
    /// `.completed` (with an isError body). Once the body is evicted, this is
    /// all that survives, so callers must reconcile with a live read rather than
    /// read `completed` as "it worked".
    enum TerminalKind: String, Equatable, Sendable {
        case completed
        case cancelled
    }

    struct Claim: Equatable, Sendable {
        fileprivate let idempotencyKey: String
        fileprivate let generation: UInt64
        fileprivate let sequence: UInt64
    }

    enum Record: Equatable, Sendable {
        case inProgress
        case cancellationRequested
        case cancelled(StoredOutcome, verified: Bool)
        case completed(StoredOutcome)
        case outcomeEvicted(terminal: TerminalKind)
    }

    enum BeginResult: Equatable, Sendable {
        case started(Claim)
        case inProgress
        case cancellationRequested
        case cancelled
        case completed(StoredOutcome)
        case outcomeEvicted(terminal: TerminalKind)
        case conflict
        case capacityExceeded
    }

    enum PlanDisposition: Equatable, Sendable {
        case available
        case inProgress
        case cancellationRequested
        case cancelled
        case completed
        case outcomeEvicted(terminal: TerminalKind)
        case conflict
        case capacityExceeded
    }

    enum CancelResult: Equatable, Sendable {
        case requested
        case alreadyRequested
        case cancelled(StoredOutcome, verified: Bool)
        case completed
        case outcomeEvicted(terminal: TerminalKind)
        case notFound
    }

    /// Ops/test counters for the two tiers. Deliberately NOT a caller-recovery
    /// API: nothing here tells a client "retry later and it will fit".
    struct Metrics: Equatable, Sendable {
        /// Body-tier occupancy: in-flight entries + retained terminal outcomes.
        /// Compare against `recordCapacity`.
        let fullBodyCount: Int
        let compactCount: Int
        /// Monotonic for the life of the process — `clear()` does not reset it.
        let bodyEvictions: UInt64
        let compactCapacity: Int
        let recordCapacity: Int
    }

    /// Only ever an in-flight state — terminal keys leave `entries` entirely,
    /// which makes "a live entry is terminal" unrepresentable.
    private enum LiveRecord: Equatable, Sendable {
        case inProgress
        case cancellationRequested
    }

    private enum TerminalRecord: Equatable, Sendable {
        case completed(StoredOutcome)
        case cancelled(StoredOutcome, verified: Bool)

        var kind: TerminalKind {
            switch self {
            case .completed: .completed
            case .cancelled: .cancelled
            }
        }

        var record: Record {
            switch self {
            case .completed(let outcome): .completed(outcome)
            case .cancelled(let outcome, let verified): .cancelled(outcome, verified: verified)
            }
        }
    }

    private struct Entry: Sendable {
        let plan: SagaPlan
        let claim: Claim
        var record: LiveRecord
    }

    /// The append-only identity row. `planHash` replaces holding the whole plan
    /// once the body is gone; `sequence` is the begin order that drives
    /// oldest-first body eviction.
    private struct CompactRow: Sendable {
        let planHash: String
        let sequence: UInt64
        var terminal: TerminalKind?
    }

    private struct TerminalBody: Sendable {
        let record: TerminalRecord
        let sequence: UInt64
    }

    private let maxRecords: Int
    private let compactCapacity: Int
    private var entries: [String: Entry] = [:]
    private var idempotencySet: [String: CompactRow] = [:]
    private var outcomeBodies: [String: TerminalBody] = [:]
    private var bodyEvictions: UInt64 = 0
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0

    init(
        maxRecords: Int = SagaJournal.defaultMaxRecords,
        compactCapacity: Int = SagaJournal.defaultCompactCapacity
    ) {
        self.maxRecords = max(1, maxRecords)
        self.compactCapacity = max(max(1, maxRecords), compactCapacity)
    }

    func metrics() -> Metrics {
        Metrics(
            fullBodyCount: entries.count + outcomeBodies.count,
            compactCount: idempotencySet.count,
            bodyEvictions: bodyEvictions,
            compactCapacity: compactCapacity,
            recordCapacity: maxRecords
        )
    }

    func disposition(for plan: SagaPlan) -> PlanDisposition {
        if let entry = entries[plan.idempotencyKey] {
            guard entry.plan == plan else { return .conflict }
            switch entry.record {
            case .inProgress: return .inProgress
            case .cancellationRequested: return .cancellationRequested
            }
        }
        if let row = idempotencySet[plan.idempotencyKey] {
            guard Self.planHash(plan) == row.planHash, let terminal = row.terminal else {
                return .conflict
            }
            guard let body = outcomeBodies[plan.idempotencyKey] else {
                return .outcomeEvicted(terminal: terminal)
            }
            switch body.record {
            case .completed: return .completed
            case .cancelled: return .cancelled
            }
        }
        return canAdmitNewKey() ? .available : .capacityExceeded
    }

    func begin(_ plan: SagaPlan) -> BeginResult {
        if let entry = entries[plan.idempotencyKey] {
            guard entry.plan == plan else { return .conflict }
            switch entry.record {
            case .inProgress: return .inProgress
            case .cancellationRequested: return .cancellationRequested
            }
        }
        if let row = idempotencySet[plan.idempotencyKey] {
            // The plan itself is gone once a key goes terminal, so identity is
            // re-established by hashing the incoming plan. A mismatch is the
            // same `.conflict` full-plan equality reports for a live key.
            guard Self.planHash(plan) == row.planHash, let terminal = row.terminal else {
                return .conflict
            }
            guard let body = outcomeBodies[plan.idempotencyKey] else {
                return .outcomeEvicted(terminal: terminal)
            }
            switch body.record {
            case .completed(let outcome): return .completed(outcome)
            case .cancelled: return .cancelled
            }
        }
        guard idempotencySet.count < compactCapacity else { return .capacityExceeded }
        while entries.count + outcomeBodies.count >= maxRecords {
            // Fail closed when nothing is evictable (a body tier full of
            // in-flight sagas): admitting anyway would mean dropping a plan we
            // still need for equality.
            guard evictOldestBody() else { return .capacityExceeded }
        }
        sequence &+= 1
        let claim = Claim(
            idempotencyKey: plan.idempotencyKey,
            generation: generation,
            sequence: sequence
        )
        idempotencySet[plan.idempotencyKey] = CompactRow(
            planHash: Self.planHash(plan),
            sequence: sequence,
            terminal: nil
        )
        entries[plan.idempotencyKey] = Entry(plan: plan, claim: claim, record: .inProgress)
        return .started(claim)
    }

    @discardableResult
    func complete(_ claim: Claim, outcome: StoredOutcome) -> Bool {
        guard claim.generation == generation,
              let entry = entries[claim.idempotencyKey],
              entry.claim == claim,
              entry.record == .inProgress else { return false }
        finalize(claim.idempotencyKey, record: .completed(outcome), sequence: claim.sequence)
        return true
    }

    @discardableResult
    func completeCancellation(
        _ claim: Claim,
        outcome: StoredOutcome,
        verified: Bool
    ) -> Bool {
        guard claim.generation == generation,
              let entry = entries[claim.idempotencyKey],
              entry.claim == claim,
              entry.record == .cancellationRequested else { return false }
        finalize(
            claim.idempotencyKey,
            record: .cancelled(outcome, verified: verified),
            sequence: claim.sequence
        )
        return true
    }

    /// The ONLY legitimate pre-write retract of a compact row.
    ///
    /// LPMCP-PRD-005: dropping a compact row is dropping replay protection, so
    /// it is only sound where "no write happened" is PROVABLE rather than
    /// assumed. It is provable here and nowhere else: the mutation gate refused,
    /// so the claim never reached an executor. `inProgress` alone cannot carry
    /// that proof — it IS the write window — which is why no general
    /// `abandon(claim)` escape door exists on this API.
    func finishGateRefusal(_ claim: Claim, cancellationOutcome: StoredOutcome) {
        guard claim.generation == generation,
              let entry = entries[claim.idempotencyKey],
              entry.claim == claim else { return }
        switch entry.record {
        case .inProgress:
            forget(claim.idempotencyKey)
        case .cancellationRequested:
            finalize(
                claim.idempotencyKey,
                record: .cancelled(cancellationOutcome, verified: true),
                sequence: claim.sequence
            )
        }
    }

    @discardableResult
    func completeBeforeWrite(_ claim: Claim, outcome: StoredOutcome) -> Bool {
        guard claim.generation == generation,
              let entry = entries[claim.idempotencyKey],
              entry.claim == claim else { return false }
        switch entry.record {
        case .inProgress:
            finalize(claim.idempotencyKey, record: .completed(outcome), sequence: claim.sequence)
        case .cancellationRequested:
            finalize(
                claim.idempotencyKey,
                record: .cancelled(outcome, verified: true),
                sequence: claim.sequence
            )
        }
        return true
    }

    /// #412: the single first-writer-wins coupling point both saga finishers
    /// (the work child on normal completion and the lifecycle-timeout handler)
    /// terminalize through, so the client response body can never disagree with
    /// the journal terminal record.
    ///
    /// If this claim is still live it finalizes with `proposed` — mirroring
    /// `completeBeforeWrite`'s dual-state switch (`.inProgress` → `.completed`,
    /// `.cancellationRequested` → `.cancelled`) — and returns `proposed` (which
    /// is now the terminal body). If the claim already lost the race (the other
    /// finisher finalized first, so the entry is gone or the generation moved),
    /// it finalizes NOTHING and returns the body the winner actually stored.
    /// Either way the returned bytes ARE the journal terminal record — resuming
    /// a locally-built body after losing the finalize would let the response
    /// disagree with the terminal record, which this exists to prevent.
    ///
    /// `verifiedIfCancelled` is honored only on the `.cancellationRequested`
    /// branch: the work child passes the real compensation result, the timeout
    /// handler passes `false` (outcome unknown). It never affects the returned
    /// body — only the journal `verified` flag surfaced by saga_status.
    ///
    /// Returns `didFinalize` — `true` only when THIS call actually terminalized
    /// the entry, `false` when it lost the first-writer race. The lifecycle-
    /// timeout handler gates its abandon side effects on this bit so a timeout
    /// that wins the resume race AFTER the work child already finalized a
    /// success does not force-mark the gate — winning the race is not the same
    /// as terminalizing as a timeout.
    @discardableResult
    func finalizeReturningWinner(
        _ claim: Claim,
        proposed: StoredOutcome,
        verifiedIfCancelled: Bool = false
    ) -> (body: StoredOutcome, didFinalize: Bool) {
        guard claim.generation == generation,
              let entry = entries[claim.idempotencyKey],
              entry.claim == claim else {
            // Lost the first-writer race: return the body the winner stored so
            // the caller resumes with the journal's terminal bytes, not a local
            // body (a local body could disagree with the terminal record). Falls
            // back to `proposed` only if the session was cleared out from under
            // both finishers. didFinalize is false — this call terminalized
            // nothing.
            return (storedTerminalOutcome(for: claim.idempotencyKey) ?? proposed, false)
        }
        switch entry.record {
        case .inProgress:
            finalize(claim.idempotencyKey, record: .completed(proposed), sequence: claim.sequence)
        case .cancellationRequested:
            finalize(
                claim.idempotencyKey,
                record: .cancelled(proposed, verified: verifiedIfCancelled),
                sequence: claim.sequence
            )
        }
        return (proposed, true)
    }

    /// #412: the lifecycle-timeout finisher. Terminalizes BOTH live states and
    /// returns the winning body plus `didFinalize` (whether THIS call
    /// terminalized), exactly like `finalizeReturningWinner` with
    /// `verifiedIfCancelled: false` (a timed-out outcome is never verified).
    @discardableResult
    func completeOnTimeout(
        _ claim: Claim,
        outcome: StoredOutcome
    ) -> (body: StoredOutcome, didFinalize: Bool) {
        finalizeReturningWinner(claim, proposed: outcome, verifiedIfCancelled: false)
    }

    /// The stored terminal body for a key that already reached a terminal state
    /// in this generation, or nil if it is still live / evicted / unknown.
    private func storedTerminalOutcome(for key: String) -> StoredOutcome? {
        guard let body = outcomeBodies[key] else { return nil }
        switch body.record {
        case .completed(let outcome): return outcome
        case .cancelled(let outcome, _): return outcome
        }
    }

    func record(for idempotencyKey: String) -> Record? {
        if let entry = entries[idempotencyKey] {
            switch entry.record {
            case .inProgress: return .inProgress
            case .cancellationRequested: return .cancellationRequested
            }
        }
        guard let row = idempotencySet[idempotencyKey], let terminal = row.terminal else {
            return nil
        }
        guard let body = outcomeBodies[idempotencyKey] else {
            return .outcomeEvicted(terminal: terminal)
        }
        return body.record.record
    }

    func cancel(idempotencyKey: String) -> CancelResult {
        if var entry = entries[idempotencyKey] {
            switch entry.record {
            case .inProgress:
                entry.record = .cancellationRequested
                entries[idempotencyKey] = entry
                return .requested
            case .cancellationRequested:
                return .alreadyRequested
            }
        }
        guard let row = idempotencySet[idempotencyKey], let terminal = row.terminal else {
            return .notFound
        }
        guard let body = outcomeBodies[idempotencyKey] else {
            return .outcomeEvicted(terminal: terminal)
        }
        switch body.record {
        case .completed: return .completed
        case .cancelled(let outcome, let verified): return .cancelled(outcome, verified: verified)
        }
    }

    func clear() {
        generation &+= 1
        entries.removeAll(keepingCapacity: true)
        idempotencySet.removeAll(keepingCapacity: true)
        outcomeBodies.removeAll(keepingCapacity: true)
    }

    // MARK: - private

    /// Moves a key from the in-flight tier to the terminal tier. Body-tier
    /// occupancy is unchanged (one entry out, one body in), so terminating a
    /// saga never triggers eviction — only admitting a NEW key does.
    private func finalize(_ key: String, record: TerminalRecord, sequence: UInt64) {
        entries.removeValue(forKey: key)
        idempotencySet[key]?.terminal = record.kind
        outcomeBodies[key] = TerminalBody(record: record, sequence: sequence)
    }

    private func forget(_ key: String) {
        entries.removeValue(forKey: key)
        idempotencySet.removeValue(forKey: key)
        outcomeBodies.removeValue(forKey: key)
    }

    private func evictOldestBody() -> Bool {
        guard let oldest = outcomeBodies.min(by: { $0.value.sequence < $1.value.sequence })
        else { return false }
        outcomeBodies.removeValue(forKey: oldest.key)
        bodyEvictions &+= 1
        return true
    }

    private func canAdmitNewKey() -> Bool {
        guard idempotencySet.count < compactCapacity else { return false }
        guard entries.count + outcomeBodies.count >= maxRecords else { return true }
        return !outcomeBodies.isEmpty
    }

    /// SHA256 over a `.sortedKeys` canonical JSON encoding of the plan. Hashing
    /// the encoded plan — rather than concatenating fields with a delimiter —
    /// is what keeps a crafted step value from forging another plan's identity.
    ///
    /// A plan that cannot be encoded (e.g. a directly-constructed plan carrying
    /// a non-finite number, which the wire layer already rejects) hashes to a
    /// per-call unique sentinel. That fails CLOSED: such a plan can never match
    /// a stored row, so it answers `.conflict` rather than aliasing another
    /// saga's record.
    private static func planHash(_ plan: SagaPlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else {
            return "unencodable:\(UUID().uuidString)"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SagaWireError: Error, Equatable, Sendable {
    case invalid(String)
}

enum SagaWire {
    static let maxIdempotencyKeyBytes = 256
    static let maxPlanSteps = 16
    static let maxTargetRefBytes = 256
    static let maxParamsBytes = 4_096
    static let maxValueDepth = 4
    static let maxCollectionEntries = 32

    static var sessionFields: [String: Any] {
        [
            "journal_scope": "session",
            "journal_persistence": "cleared_on_server_session_end",
            "journal_survives_process_restart": false,
        ]
    }

    static func plan(from params: [String: Value]) throws -> SagaPlan {
        try requireExactKeys(params, allowed: ["steps", "idempotency_key"], context: "plan")
        guard let rawSteps = params["steps"]?.arrayValue else {
            throw SagaWireError.invalid("plan 'steps' must be an array")
        }
        guard rawSteps.count <= maxPlanSteps else {
            throw SagaWireError.invalid("plan 'steps' must contain at most \(maxPlanSteps) entries")
        }
        let idempotencyKey = try nonemptyString(params["idempotency_key"], key: "idempotency_key")
        let steps = try rawSteps.enumerated().map { index, rawStep in
            guard let object = rawStep.objectValue else {
                throw SagaWireError.invalid("steps[\(index)] must be an object")
            }
            return try step(from: object, index: index)
        }
        return SagaPlan(steps: steps, idempotencyKey: idempotencyKey)
    }

    static func idempotencyKey(from params: [String: Value]) throws -> String {
        try requireExactKeys(params, allowed: ["idempotency_key"], context: "request")
        return try nonemptyString(params["idempotency_key"], key: "idempotency_key")
    }

    static func invalidParams(_ error: Error) -> CallTool.Result {
        scopedStateC(
            .invalidParams,
            hint: (error as? SagaWireError).map { wireError in
                switch wireError {
                case .invalid(let message): message
                }
            } ?? "invalid saga request",
            extras: ["write_attempted": false]
        )
    }

    static func scopedStateC(
        _ error: HonestContract.FailureError,
        hint: String? = nil,
        extras: [String: Any] = [:]
    ) -> CallTool.Result {
        let scoped = sessionFields.merging(["verified": false]) { _, new in new }
            .merging(extras) { _, new in new }
        return toolStateCResult(error, hint: hint, extras: scoped)
    }

    static func idempotencyConflict(_ idempotencyKey: String) -> CallTool.Result {
        scopedStateC(
            .idempotencyKeyConflict,
            hint: "This idempotency_key is already bound to a different saga plan",
            extras: ["idempotency_key": idempotencyKey]
        )
    }

    static func journalCapacityExceeded(_ idempotencyKey: String) -> CallTool.Result {
        scopedStateC(
            .sagaJournalCapacityExceeded,
            hint: "The session saga journal has reached its bounded record capacity",
            extras: ["idempotency_key": idempotencyKey]
        )
    }

    /// LPMCP-PRD-005 — the key is replay-protected but its outcome body is gone.
    ///
    /// The hint deliberately refuses to imply success: `terminal_kind` only says
    /// WHICH path terminated, and a `completed` saga may still have applied
    /// partially. The only honest recovery is to observe current state, so the
    /// hint routes the caller to a live read and explicitly forbids re-firing
    /// the same intent (`safe_to_retry: false`).
    static func outcomeUnavailable(
        _ idempotencyKey: String,
        terminal: SagaJournal.TerminalKind
    ) -> CallTool.Result {
        scopedStateC(
            .sagaOutcomeUnavailable,
            hint: "This idempotency_key already reached a terminal saga state in this session, "
                + "but its stored outcome body is no longer retained (bounded outcome retention). "
                + "'\(terminal.rawValue)' names the terminal path only — it does NOT assert the "
                + "intent succeeded. Reconcile the current state with a live read "
                + "(system.saga_status, or the relevant read operations) and decide from what you "
                + "observe; do NOT re-fire the same intent blindly.",
            extras: [
                "idempotency_key": idempotencyKey,
                "terminal_kind": terminal.rawValue,
                "outcome_retained": false,
                "safe_to_retry": false,
                "write_attempted": false,
            ]
        )
    }

    /// Ops/test counters for the journal's two bounded tiers. NOT a
    /// caller-recovery API — nothing here promises a retry will fit.
    static func journalMetricsFields(_ metrics: SagaJournal.Metrics) -> [String: Any] {
        [
            "journal_full_body_count": metrics.fullBodyCount,
            "journal_compact_count": metrics.compactCount,
            "journal_body_evictions": metrics.bodyEvictions,
            "journal_compact_capacity": metrics.compactCapacity,
            "journal_record_capacity": metrics.recordCapacity,
        ]
    }

    static func preflightIssue(_ preflightIssue: PreflightIssue) -> [String: Any] {
        switch preflightIssue {
        case .featureDisabled:
            return ["code": "feature_disabled"]
        case .emptyPlan:
            return ["code": "empty_plan"]
        case .invalidIdempotencyKey:
            return ["code": "invalid_idempotency_key"]
        case .registryInvalid:
            return ["code": "registry_invalid"]
        case .operationNotRegistered(let index, let operationID):
            return indexedIssue("operation_not_registered", index: index, operationID: operationID)
        case .invalidOperationSpec(let index, let operationID):
            return indexedIssue("invalid_operation_spec", index: index, operationID: operationID)
        case .operationNotReversible(let index, let operationID):
            return indexedIssue("operation_not_reversible", index: index, operationID: operationID)
        case .staleTarget(let index):
            return ["code": "stale_target", "step_index": index]
        case .projectEpochMismatch(let index):
            return ["code": "project_epoch_mismatch", "step_index": index]
        case .invalidExpectedInverse(let index):
            return ["code": "invalid_expected_inverse", "step_index": index]
        case .automaticReplayBlocked:
            return ["code": "automatic_replay_blocked"]
        case .confirmationRequired(let index, let operationID):
            return indexedIssue("confirmation_required", index: index, operationID: operationID)
        case .routeUnavailable(let index, let operationID):
            return indexedIssue("route_unavailable", index: index, operationID: operationID)
        case .deadlineBudgetExceeded(let totalSeconds, let budgetSeconds):
            return [
                "code": "deadline_budget_exceeded",
                "worst_case_seconds": totalSeconds,
                "budget_seconds": budgetSeconds,
            ]
        }
    }

    static func jsonObject(_ body: String) -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else {
            return body
        }
        return object
    }

    static func availabilityObjects(
        _ availability: [SagaBeforeStateAvailability],
        plan: SagaPlan
    ) -> [[String: Any]] {
        availability.map { item in
            var object: [String: Any] = [
                "step_index": item.stepIndex,
                "operation_id": plan.steps[item.stepIndex].operationID.rawValue,
                "available": item.state != nil,
            ]
            if let state = item.state { object["before_state"] = observedState(state) }
            return object
        }
    }

    static func availabilityIssues(
        _ availability: [SagaBeforeStateAvailability],
        plan: SagaPlan
    ) -> [[String: Any]] {
        availability.compactMap { item in
            guard item.state == nil else { return nil }
            return [
                "code": "before_state_unavailable",
                "step_index": item.stepIndex,
                "operation_id": plan.steps[item.stepIndex].operationID.rawValue,
            ]
        }
    }

    static func executionFailureError(
        preflightIssues: [PreflightIssue],
        availabilityIssues: [[String: Any]]
    ) -> HonestContract.FailureError {
        if preflightIssues.contains(where: { issue in
            if case .featureDisabled = issue { return true }
            return false
        }) {
            return .notSupported
        }
        if preflightIssues.contains(where: { issue in
            switch issue {
            case .staleTarget, .projectEpochMismatch: return true
            default: return false
            }
        }) {
            return .staleTargetReference
        }
        if !availabilityIssues.isEmpty {
            return .readbackUnavailable
        }
        return .invalidParams
    }

    static func storedOutcome(
        plan: SagaPlan,
        outcome: SagaOutcome
    ) -> SagaJournal.StoredOutcome {
        var extras = sessionFields.merging([
            "idempotency_key": plan.idempotencyKey,
            "duplicate": false,
            "saga_state": outcome.state.rawValue,
            "state_history": outcome.stateHistory.map(\.rawValue),
            "steps": stepObjects(plan: plan, outcome: outcome),
        ]) { _, new in new }

        let body: String
        let isError: Bool
        switch outcome.state {
        case .completed:
            body = HonestContract.encodeStateA(extras: extras)
            isError = false
        case .fullyCompensated, .partiallyApplied:
            extras["verified"] = false
            extras["compensation"] = compensationObject(outcome)
            body = HonestContract.encodeStateC(
                error: .sagaExecutionFailed,
                hint: "The requested saga did not complete successfully",
                extras: extras
            )
            isError = true
        case .partiallyCompensated, .compensationFailed, .rollbackUncertain,
             .reconciling, .compensating:
            extras["compensation"] = compensationObject(outcome)
            body = HonestContract.encodeStateB(
                reason: .sagaReconciliationRequired,
                extras: extras
            )
            isError = false
        case .draft, .validated, .awaitingConfirmation, .running:
            extras["verified"] = false
            extras["preflight_issues"] = outcome.preflightIssues.map(preflightIssue)
            body = HonestContract.encodeStateC(
                error: .sagaExecutionFailed,
                hint: "The requested saga did not reach execution",
                extras: extras
            )
            isError = true
        case .cancelled:
            extras["verified"] = false
            body = HonestContract.encodeStateC(
                error: .sagaExecutionFailed,
                hint: "The requested saga was cancelled before completion",
                extras: extras
            )
            isError = true
        }
        return SagaJournal.StoredOutcome(body: body, isError: isError)
    }

    static func cancellationVerified(_ outcome: SagaOutcome) -> Bool {
        outcome.state == .cancelled || outcome.state == .fullyCompensated
    }

    static func duplicateOutcome(
        _ stored: SagaJournal.StoredOutcome
    ) -> SagaJournal.StoredOutcome {
        guard var object = jsonObject(stored.body) as? [String: Any] else { return stored }
        object["duplicate"] = true
        return SagaJournal.StoredOutcome(
            body: HonestContract.jsonString(object),
            isError: stored.isError
        )
    }

    /// #412: the fail-closed saga wedge/timeout body. The lifecycle timeout
    /// fires with the step outcome UNKNOWN (a synchronous AX dispatch may be in
    /// flight and cannot be interrupted), so this NEVER reads the possibly
    /// lagging journal for its fields: it forces `write_attempted` /
    /// `write_boundary_crossed = true`, `safe_to_retry = false`, `verified =
    /// false`, and reports the gate as reclaimable only after the grace window.
    /// The SAME `StoredOutcome` becomes the journal terminal record via
    /// `completeOnTimeout`, so the client body and the journal agree.
    static func sagaWedgeTimeout(
        idempotencyKey: String,
        seconds: Double,
        gateReclaimAfterSec: Double
    ) -> SagaJournal.StoredOutcome {
        let extras = sessionFields.merging([
            "idempotency_key": idempotencyKey,
            "duplicate": false,
            "operation": "system.saga_execute",
            "timeout_sec": seconds,
            "verified": false,
            "write_attempted": true,
            "write_boundary_crossed": true,
            "safe_to_retry": false,
            "outcome_retained": true,
            "underlying_operation_stopped": false,
            "mutation_gate": "reclaimable_after_grace",
            "gate_reclaim_after_sec": gateReclaimAfterSec,
            "recovery_hint": "The saga exceeded its lifecycle deadline and was abandoned so the "
                + "stdio loop stays responsive. A dispatch may have crossed the write boundary with "
                + "an unknown outcome; do NOT blindly retry. Reconcile with a live read "
                + "(system.saga_status, or the relevant read operations).",
        ]) { _, new in new }
        let body = HonestContract.encodeStateC(
            error: .operationTimeout,
            hint: "system.saga_execute exceeded its \(Int(seconds))s lifecycle deadline and was "
                + "abandoned; the outcome is unknown (fail-closed).",
            extras: extras
        )
        return SagaJournal.StoredOutcome(body: body, isError: true)
    }

    static func storedOutcome(from result: CallTool.Result) -> SagaJournal.StoredOutcome {
        guard case .text(let body, _, _) = result.content.first else {
            return SagaJournal.StoredOutcome(
                body: HonestContract.encodeStateC(error: .sagaExecutionFailed),
                isError: true
            )
        }
        return SagaJournal.StoredOutcome(body: body, isError: result.isError ?? false)
    }

    private static func step(from object: [String: Value], index: Int) throws -> SagaStep {
        try requireExactKeys(
            object,
            allowed: ["operation_id", "target_ref", "params", "expected_inverse"],
            context: "steps[\(index)]"
        )
        guard let rawOperationID = object["operation_id"]?.stringValue,
              let operationID = OperationID(rawValue: rawOperationID) else {
            throw SagaWireError.invalid("steps[\(index)].operation_id is invalid")
        }
        let targetRef: TargetReference?
        if let rawTarget = object["target_ref"] {
            guard let value = rawTarget.stringValue else {
                throw SagaWireError.invalid("steps[\(index)].target_ref must be a string")
            }
            guard value.utf8.count <= maxTargetRefBytes else {
                throw SagaWireError.invalid(
                    "steps[\(index)].target_ref must be at most \(maxTargetRefBytes) UTF-8 bytes"
                )
            }
            targetRef = TargetReference(rawValue: value)
        } else {
            targetRef = nil
        }
        guard let rawStepParams = object["params"]?.objectValue else {
            throw SagaWireError.invalid("steps[\(index)].params must be an object")
        }
        try validateValueTree(
            .object(rawStepParams),
            depth: 0,
            context: "steps[\(index)].params"
        )
        guard let encodedParams = try? JSONEncoder().encode(Value.object(rawStepParams)),
              encodedParams.count <= maxParamsBytes else {
            throw SagaWireError.invalid(
                "steps[\(index)].params must encode to at most \(maxParamsBytes) bytes"
            )
        }
        let stepParams = try canonicalParams(
            rawStepParams,
            operationID: operationID,
            index: index
        )
        guard let inverse = object["expected_inverse"]?.objectValue else {
            throw SagaWireError.invalid("steps[\(index)].expected_inverse must be an object")
        }
        try requireExactKeys(
            inverse,
            allowed: ["operation_id", "value_parameter"],
            context: "steps[\(index)].expected_inverse"
        )
        guard let rawInverseID = inverse["operation_id"]?.stringValue,
              let inverseID = OperationID(rawValue: rawInverseID) else {
            throw SagaWireError.invalid("steps[\(index)].expected_inverse.operation_id is invalid")
        }
        guard let valueParameter = inverse["value_parameter"]?.stringValue else {
            throw SagaWireError.invalid("steps[\(index)].expected_inverse.value_parameter must be a string")
        }
        guard valueParameter.utf8.count <= 64 else {
            throw SagaWireError.invalid(
                "steps[\(index)].expected_inverse.value_parameter must be at most 64 UTF-8 bytes"
            )
        }
        return SagaStep(
            operationID: operationID,
            targetRef: targetRef,
            params: stepParams,
            expectedInverse: SagaExpectedInverse(
                operationID: inverseID,
                valueParameter: valueParameter
            )
        )
    }

    private static func stepObjects(
        plan: SagaPlan,
        outcome: SagaOutcome
    ) -> [[String: Any]] {
        outcome.journal.map { record in
            var object: [String: Any] = [
                "step_index": record.stepIndex,
                "operation_id": plan.steps[record.stepIndex].operationID.rawValue,
            ]
            if let result = record.executionResult {
                object["result"] = [
                    "state": result.state.rawValue,
                    "write_boundary_crossed": result.writeBoundaryCrossed,
                    "detail": result.detail,
                ]
            }
            var evidence: [String: Any] = [:]
            if let beforeState = record.beforeState {
                evidence["before_state"] = observedState(beforeState)
            }
            if let verification = record.verificationEvidence {
                let readback: Any
                if let observed = verification.readback {
                    readback = observedState(observed)
                } else {
                    readback = NSNull()
                }
                var verificationObject: [String: Any] = [
                    "disposition": verification.disposition.rawValue,
                    "readback": readback,
                ]
                if let comparison = verification.comparison {
                    verificationObject["comparison"] = comparisonObject(comparison)
                }
                evidence["verification"] = verificationObject
            }
            object["evidence"] = evidence
            if let compensation = record.compensationEvidence {
                let readback: Any
                if let observed = compensation.readback {
                    readback = observedState(observed)
                } else {
                    readback = NSNull()
                }
                var compensationRecord: [String: Any] = [
                    "disposition": compensation.disposition.rawValue,
                    "readback": readback,
                ]
                if let comparison = compensation.comparison {
                    compensationRecord["comparison"] = comparisonObject(comparison)
                }
                object["compensation"] = compensationRecord
            }
            return object
        }
    }

    private static func compensationObject(_ outcome: SagaOutcome) -> [String: Any] {
        let evidence: [[String: Any]] = outcome.journal.compactMap { record in
            guard let compensation = record.compensationEvidence,
                  let readback = compensation.readback else { return nil }
            var object: [String: Any] = [
                "step_index": record.stepIndex,
                "disposition": compensation.disposition.rawValue,
                "readback": observedState(readback),
            ]
            if let comparison = compensation.comparison {
                object["comparison"] = comparisonObject(comparison)
            }
            return object
        }
        let verifiedCount = outcome.journal.filter {
            $0.compensationEvidence?.disposition == .verified
        }.count
        let failedCount = outcome.journal.filter {
            $0.compensationEvidence?.disposition == .failed
        }.count
        let uncertainCount = outcome.journal.filter {
            $0.compensationEvidence?.disposition == .uncertain
        }.count
        let forwardWriteBoundaryCount = outcome.journal.filter(\.writeBoundaryCrossed).count
        let compensationWriteBoundaryCount = outcome.journal.filter {
            $0.compensationEvidence?.executionResult?.writeBoundaryCrossed ?? false
        }.count
        return [
            "status": compensationStatus(outcome.state),
            "fully_compensated": outcome.state == .fullyCompensated,
            "readback_evidence": evidence,
            "journal_summary": [
                "record_count": outcome.journal.count,
                "write_boundary_count": forwardWriteBoundaryCount + compensationWriteBoundaryCount,
                "forward_write_boundary_count": forwardWriteBoundaryCount,
                "compensation_write_boundary_count": compensationWriteBoundaryCount,
                "verified_compensation_count": verifiedCount,
                "failed_compensation_count": failedCount,
                "uncertain_compensation_count": uncertainCount,
            ],
        ]
    }

    private static func compensationStatus(_ state: SagaState) -> String {
        switch state {
        case .fullyCompensated: "fully_compensated"
        case .partiallyCompensated: "partially_compensated"
        case .compensationFailed: "compensation_failed"
        case .rollbackUncertain: "unknown"
        case .partiallyApplied: "not_needed"
        default: state.rawValue
        }
    }

    /// LPMCP-PRD-004: saga observations carry structured provenance so an
    /// operator can audit WHERE a rollback value came from — not just a prose
    /// string. `evidence` stays the human summary (`ax_live tracks[3].volume
    /// (header_fader)`).
    private static func observedState(_ state: ObservedState) -> [String: Any] {
        var object: [String: Any] = [
            "value": foundationValue(state.value),
            "evidence": state.evidence,
        ]
        guard let read = state.read else { return object }
        object["read_source"] = read.readSource.rawValue
        object["provenance"] = read.provenance.rawValue
        object["track_index"] = read.trackIndex
        object["field"] = read.field
        object["observed"] = foundationValue(read.observed)
        object["sampled_at"] = read.sampledAt
        return object
    }

    /// How a disposition was decided: comparator, epsilon, desired, observed,
    /// delta. Absent keys mean "not applicable" (no epsilon for an exact
    /// comparator; no delta for a string/bool field).
    private static func comparisonObject(
        _ comparison: SagaComparisonEvidence
    ) -> [String: Any] {
        var object: [String: Any] = [
            "comparator": comparison.comparator.rawValue,
            "equal": comparison.equal,
        ]
        if let epsilon = comparison.epsilon { object["epsilon"] = epsilon }
        if let desired = comparison.desired { object["desired"] = foundationValue(desired) }
        if let observed = comparison.observed { object["observed"] = foundationValue(observed) }
        if let delta = comparison.delta { object["delta"] = delta }
        return object
    }

    private static func foundationValue(_ value: Value) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ) else {
            return String(describing: value)
        }
        return object
    }

    private static func nonemptyString(_ value: Value?, key: String) throws -> String {
        guard let raw = value?.stringValue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SagaWireError.invalid("'\(key)' must be a non-empty string")
        }
        guard raw.utf8.count <= maxIdempotencyKeyBytes else {
            throw SagaWireError.invalid(
                "'\(key)' must be at most \(maxIdempotencyKeyBytes) UTF-8 bytes"
            )
        }
        return raw
    }

    private static func canonicalParams(
        _ params: [String: Value],
        operationID: OperationID,
        index: Int
    ) throws -> [String: Value] {
        let context = "steps[\(index)].params"
        switch operationID {
        case .tracksRename:
            try requireExactKeys(params, allowed: ["name"], context: context)
            guard let name = params["name"]?.stringValue, !name.isEmpty else {
                throw SagaWireError.invalid("\(context).name must be a non-empty string")
            }
            guard name.count <= 128 else {
                throw SagaWireError.invalid("\(context).name must be 128 characters or fewer")
            }
            return ["name": .string(name)]

        case .mixerSetVolume, .mixerSetPan:
            try requireExactKeys(params, allowed: ["value"], context: context)
            guard let rawValue = params["value"] else {
                throw SagaWireError.invalid("\(context).value must be a finite number")
            }
            let value: Double
            switch rawValue {
            case .int(let integer): value = Double(integer)
            case .double(let double): value = double
            default:
                throw SagaWireError.invalid("\(context).value must be a finite number")
            }
            guard value.isFinite else {
                throw SagaWireError.invalid("\(context).value must be a finite number")
            }
            let range = operationID == .mixerSetVolume ? 0.0...1.0 : -1.0...1.0
            guard range.contains(value) else {
                throw SagaWireError.invalid("\(context).value is outside the supported range")
            }
            return ["value": .double(value)]

        case .tracksMute, .tracksSolo, .tracksArm:
            try requireExactKeys(params, allowed: ["enabled"], context: context)
            guard let enabled = params["enabled"]?.boolValue else {
                throw SagaWireError.invalid("\(context).enabled must be a literal boolean")
            }
            return ["enabled": .bool(enabled)]

        default:
            return params
        }
    }

    private static func validateValueTree(
        _ value: Value,
        depth: Int,
        context: String
    ) throws {
        guard depth <= maxValueDepth else {
            throw SagaWireError.invalid("\(context) exceeds maximum nesting depth")
        }
        switch value {
        case .null, .bool, .int:
            return
        case .double(let number):
            guard number.isFinite else {
                throw SagaWireError.invalid("\(context) contains a non-finite number")
            }
        case .string(let string):
            guard string.utf8.count <= maxParamsBytes else {
                throw SagaWireError.invalid("\(context) contains an oversized string")
            }
        case .data:
            throw SagaWireError.invalid("\(context) must not contain binary data")
        case .array(let values):
            guard values.count <= maxCollectionEntries else {
                throw SagaWireError.invalid("\(context) contains too many array entries")
            }
            for item in values {
                try validateValueTree(item, depth: depth + 1, context: context)
            }
        case .object(let object):
            guard object.count <= maxCollectionEntries else {
                throw SagaWireError.invalid("\(context) contains too many object entries")
            }
            for (key, item) in object {
                guard key.utf8.count <= 128 else {
                    throw SagaWireError.invalid("\(context) contains an oversized key")
                }
                try validateValueTree(item, depth: depth + 1, context: context)
            }
        }
    }

    private static func requireExactKeys(
        _ object: [String: Value],
        allowed: Set<String>,
        context: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw SagaWireError.invalid("\(context) contains unknown keys: \(unknown.joined(separator: ", "))")
        }
    }

    private static func indexedIssue(
        _ code: String,
        index: Int,
        operationID: OperationID
    ) -> [String: Any] {
        ["code": code, "step_index": index, "operation_id": operationID.rawValue]
    }
}
