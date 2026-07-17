import Foundation
import MCP

actor SagaJournal {
    static let defaultMaxRecords = 1_024

    struct StoredOutcome: Equatable, Sendable {
        let body: String
        let isError: Bool
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
    }

    enum BeginResult: Equatable, Sendable {
        case started(Claim)
        case inProgress
        case cancellationRequested
        case cancelled
        case completed(StoredOutcome)
        case conflict
        case capacityExceeded
    }

    enum PlanDisposition: Equatable, Sendable {
        case available
        case inProgress
        case cancellationRequested
        case cancelled
        case completed
        case conflict
        case capacityExceeded
    }

    enum CancelResult: Equatable, Sendable {
        case requested
        case alreadyRequested
        case cancelled(StoredOutcome, verified: Bool)
        case completed
        case notFound
    }

    private struct Entry: Sendable {
        let plan: SagaPlan
        let claim: Claim
        var record: Record
    }

    private let maxRecords: Int
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0

    init(maxRecords: Int = SagaJournal.defaultMaxRecords) {
        self.maxRecords = max(1, maxRecords)
    }

    func disposition(for plan: SagaPlan) -> PlanDisposition {
        guard let entry = entries[plan.idempotencyKey] else {
            return entries.count >= maxRecords ? .capacityExceeded : .available
        }
        guard entry.plan == plan else { return .conflict }
        switch entry.record {
        case .inProgress: return .inProgress
        case .cancellationRequested: return .cancellationRequested
        case .cancelled: return .cancelled
        case .completed: return .completed
        }
    }

    func begin(_ plan: SagaPlan) -> BeginResult {
        if let entry = entries[plan.idempotencyKey] {
            guard entry.plan == plan else { return .conflict }
            switch entry.record {
            case .inProgress:
                return .inProgress
            case .cancellationRequested:
                return .cancellationRequested
            case .cancelled:
                return .cancelled
            case .completed(let outcome):
                return .completed(outcome)
            }
        }
        guard entries.count < maxRecords else { return .capacityExceeded }
        sequence &+= 1
        let claim = Claim(
            idempotencyKey: plan.idempotencyKey,
            generation: generation,
            sequence: sequence
        )
        entries[plan.idempotencyKey] = Entry(plan: plan, claim: claim, record: .inProgress)
        return .started(claim)
    }

    @discardableResult
    func complete(_ claim: Claim, outcome: StoredOutcome) -> Bool {
        guard claim.generation == generation,
              var entry = entries[claim.idempotencyKey],
              entry.claim == claim,
              entry.record == .inProgress else { return false }
        entry.record = .completed(outcome)
        entries[claim.idempotencyKey] = entry
        return true
    }

    @discardableResult
    func completeCancellation(
        _ claim: Claim,
        outcome: StoredOutcome,
        verified: Bool
    ) -> Bool {
        guard claim.generation == generation,
              var entry = entries[claim.idempotencyKey],
              entry.claim == claim,
              entry.record == .cancellationRequested else { return false }
        entry.record = .cancelled(outcome, verified: verified)
        entries[claim.idempotencyKey] = entry
        return true
    }

    func abandon(_ claim: Claim) {
        guard claim.generation == generation,
              let entry = entries[claim.idempotencyKey],
              entry.claim == claim,
              entry.record == .inProgress else { return }
        entries.removeValue(forKey: claim.idempotencyKey)
    }

    func finishGateRefusal(_ claim: Claim, cancellationOutcome: StoredOutcome) {
        guard claim.generation == generation,
              var entry = entries[claim.idempotencyKey],
              entry.claim == claim else { return }
        switch entry.record {
        case .inProgress:
            entries.removeValue(forKey: claim.idempotencyKey)
        case .cancellationRequested:
            entry.record = .cancelled(cancellationOutcome, verified: true)
            entries[claim.idempotencyKey] = entry
        case .cancelled, .completed:
            break
        }
    }

    @discardableResult
    func completeBeforeWrite(_ claim: Claim, outcome: StoredOutcome) -> Bool {
        guard claim.generation == generation,
              var entry = entries[claim.idempotencyKey],
              entry.claim == claim else { return false }
        switch entry.record {
        case .inProgress:
            entry.record = .completed(outcome)
        case .cancellationRequested:
            entry.record = .cancelled(outcome, verified: true)
        case .cancelled, .completed:
            return false
        }
        entries[claim.idempotencyKey] = entry
        return true
    }

    func record(for idempotencyKey: String) -> Record? {
        entries[idempotencyKey]?.record
    }

    func cancel(idempotencyKey: String) -> CancelResult {
        guard var entry = entries[idempotencyKey] else { return .notFound }
        switch entry.record {
        case .inProgress:
            entry.record = .cancellationRequested
            entries[idempotencyKey] = entry
            return .requested
        case .cancellationRequested:
            return .alreadyRequested
        case .cancelled(let outcome, let verified):
            return .cancelled(outcome, verified: verified)
        case .completed:
            return .completed
        }
    }

    func clear() {
        generation &+= 1
        entries.removeAll(keepingCapacity: true)
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
                evidence["verification"] = [
                    "disposition": verification.disposition.rawValue,
                    "readback": readback,
                ]
            }
            object["evidence"] = evidence
            if let compensation = record.compensationEvidence {
                let readback: Any
                if let observed = compensation.readback {
                    readback = observedState(observed)
                } else {
                    readback = NSNull()
                }
                object["compensation"] = [
                    "disposition": compensation.disposition.rawValue,
                    "readback": readback,
                ]
            }
            return object
        }
    }

    private static func compensationObject(_ outcome: SagaOutcome) -> [String: Any] {
        let evidence: [[String: Any]] = outcome.journal.compactMap { record in
            guard let compensation = record.compensationEvidence,
                  let readback = compensation.readback else { return nil }
            return [
                "step_index": record.stepIndex,
                "disposition": compensation.disposition.rawValue,
                "readback": observedState(readback),
            ]
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

    private static func observedState(_ state: ObservedState) -> [String: Any] {
        ["value": foundationValue(state.value), "evidence": state.evidence]
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
