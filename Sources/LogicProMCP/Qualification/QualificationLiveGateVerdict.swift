import Foundation

// The live gate's verdict, as a pure function.
//
// Until this existed `realReleaseBinaryExecutesEveryOperationWithIndependentReadback` accepted
// "the recipe ran and refused", "the readback was fetched and never compared", "only the
// unknown-parameter probe answered" and "protocolSmoke" as green. 112 of 138 operations could pass
// without being exercised. Every one of the 138 now gets EXACTLY ONE verdict:
//
//   EXERCISED      the real handler ran, an independent readback was actually compared, and for a
//                  write a mutation-restore was read back.
//   NOT_QUALIFIED  with a specific reason code (`QualificationNotQualifiedReason`).
//
// The expected NOT_QUALIFIED set is a committed list (`docs/qualification/not-qualified-logic13.json`),
// the single source of truth the release notes publish. `violations` fails when an operation is
// NOT_QUALIFIED and not listed (a new silent gap), when a listed operation is EXERCISED (a stale
// list), and when the list itself is unsound (unknown operation, duplicate, unknown reason, an
// operation that is statically unexercisable and missing).
//
// Nothing here relaxes a validator, widens an accepted shape, turns a failure into a deferral or
// skips an operation: a refusal, a deferral, an unknown-parameter probe, an environmental
// precondition, protocolSmoke and semanticValidatorUnavailable are all NOT_QUALIFIED.

enum QualificationNotQualifiedReason: String, CaseIterable, Codable, Sendable {
    // Mutating operations.
    /// No write-and-restore recipe exists. Only the unknown-parameter zero-write probe ran, and the
    /// server rejects that in strict-parameter validation BEFORE any handler is looked up.
    case unknownParamProbeOnly = "unknown_param_probe_only"
    /// Only the consent-first zero-write probe ran (`consent_required` / `invalid_params`).
    case consentProbeOnly = "consent_probe_only"
    /// A recipe exists and its kill switch (`phaseCTrackCyclesEnabled`) is off.
    case recipeDisabled = "recipe_disabled"
    /// The registry says the operation is unsupported by contract.
    case unsupportedByContract = "unsupported_by_contract"
    /// A recipe ran (or should have) and produced no verified record.
    case recipeRefused = "recipe_refused"
    /// A record exists but the cycle, its status or its restore readback did not verify.
    case restoreNotVerified = "restore_not_verified"
    // Read-only operations.
    /// The response passed its oracle, but the oracle's verdict does not depend on the readback.
    case readbackNotCompared = "readback_not_compared"
    /// The readback is a second read of the SAME producer, not an independent observation.
    case readbackNotIndependent = "readback_not_independent"
    /// The oracle declares `independentReadbackDeferral`: best possible status is protocolSmoke.
    case semanticValidatorUnavailable = "semantic_validator_unavailable"
    /// The response reached protocolSmoke and nothing else.
    case protocolSmokeOnly = "protocol_smoke_only"
    /// Credit needs a fixture-bound value check and no fixture facts were supplied.
    case needsFixtureValueCheck = "needs_fixture_value_check"
    case envPrecondition = "env_precondition"
    case operationPrecondition = "operation_precondition"
    /// A read refused.
    case refused = "refused"
    case deferred = "deferred"
    // Never listable: these are gate failures, not qualification gaps.
    case failed = "failed"
    case missingResult = "missing_result"
    case valueCheckFailed = "value_check_failed"

    /// Whether the committed list may carry this reason.
    var isListable: Bool {
        switch self {
        case .failed, .missingResult, .valueCheckFailed: false
        default: true
        }
    }
}

enum QualificationOperationVerdict: Equatable, Sendable {
    case exercised
    case notQualified(QualificationNotQualifiedReason)

    var isExercised: Bool { self == .exercised }
}

/// One row of the committed NOT_QUALIFIED list.
struct QualificationNotQualifiedEntry: Codable, Equatable, Sendable {
    let operation: String
    let reason: String
    let detail: String
}

/// An operation this release claims as fixed or supported on Logic 13 with the commit
/// that claims it and the live evidence it was measured by. The live gate requires each one to be
/// EXERCISED in the same run, so a claimed op cannot slide onto the NOT_QUALIFIED list and pass.
struct QualificationPromisedEntry: Codable, Equatable, Sendable {
    let operation: String
    let commit: String
    let evidence: String
}

struct QualificationNotQualifiedList: Codable, Equatable, Sendable {
    let schema: Int
    let platform: String
    let entries: [QualificationNotQualifiedEntry]
    var promised: [QualificationPromisedEntry] = []

    static func parse(_ data: Data) throws -> QualificationNotQualifiedList {
        try JSONDecoder().decode(QualificationNotQualifiedList.self, from: data)
    }

    /// The release-notes rendering. Deterministic, so a committed copy can be compared byte for
    /// byte with this output.
    var markdown: String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [
            "# Operations not qualified on \(platform)",
            "",
            "Generated from `docs/qualification/not-qualified-logic13.json`. Do not edit by hand:",
            "`QualificationNotQualifiedListTests` fails when this file differs from the generator.",
            "",
            "An operation is listed here when the live gate does not EXERCISE it: the real handler ran,",
            "an independent readback was compared, and (for a write) the restore was read back.",
            "Nothing listed here is reported as qualified.",
            "",
            "Listed operations: \(entries.count)",
            "",
            "## By reason",
            "",
            "| reason | count |",
            "|---|---|",
        ]
        let byReason = Dictionary(grouping: entries, by: \.reason)
        for reason in byReason.keys.sorted() {
            lines.append("| `\(reason)` | \(byReason[reason]?.count ?? 0) |")
        }
        lines += ["", "## Operations", "", "| operation | reason | detail |", "|---|---|---|"]
        let ordered = entries.sorted { ($0.reason, $0.operation) < ($1.reason, $1.operation) }
        for entry in ordered {
            lines.append("| `\(entry.operation)` | `\(entry.reason)` | \(cell(entry.detail)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Facts about the disposable fixture the value checks bind to. Nil in a run that
/// built no fixture: the operations that need these facts are then NOT_QUALIFIED, never passed.
struct QualificationLiveGateFixtureFacts: Equatable, Sendable {
    /// N: the known note count of the one selected MIDI region.
    let selectedRegionNoteCount: Int
    /// The region's note pitches, when known (compared as a multiset).
    let selectedRegionPitches: [Int]?
    /// The software-instrument track's index.
    let siTrackIndex: Int
    /// The body of `plugins.get_inventory {track: siTrackIndex}` taken in this run.
    let siInventoryResponse: Data
}

enum QualificationLiveGateValueChecks {
    /// The operations whose credit rests on a fixture-bound value check.
    static let operations: Set<OperationID> = [.midiReadSelectedRegionEvents, .pluginsGetInventory]

    /// `raw_rows.count == N`, the count text agrees with it, and the pitches (when
    /// known) are the region's. An empty row list next to a `0개의 이벤트` count text is exactly the
    /// measured M4 body and is a violation whenever N > 0.
    static func midiRowsViolations(
        responseData: Data,
        expectedNoteCount: Int,
        expectedPitches: [Int]? = nil
    ) -> [String] {
        guard let root = JSONInspector.parse(responseData) as? [String: Any] else {
            return ["midi read response is not a JSON object"]
        }
        var violations: [String] = []
        guard let rows = root["raw_rows"] as? [Any] else {
            return ["raw_rows is not an array"]
        }
        if rows.count != expectedNoteCount {
            violations.append("raw_rows.count \(rows.count) != fixture N \(expectedNoteCount)")
        }
        if let text = root["event_list_item_count_text"] as? String {
            if let counted = AXLogicProElements.parseMarkerListItemCount(text) {
                if counted != rows.count {
                    violations.append(
                        "count text \"\(text)\" says \(counted) but raw_rows.count is \(rows.count)")
                }
                if counted != expectedNoteCount {
                    violations.append(
                        "count text \"\(text)\" says \(counted) != fixture N \(expectedNoteCount)")
                }
            } else {
                violations.append("count text \"\(text)\" has no leading count")
            }
        } else {
            violations.append("event_list_item_count_text is missing")
        }
        if root["selected_region_observation"] as? [String: Any] == nil {
            violations.append("selected_region_observation is missing")
        }
        if let expectedPitches {
            let observed = rows.compactMap { row -> Int? in
                guard let columns = row as? [String: Any],
                      let num = columns["Num"] as? [String: Any],
                      let value = num["slider_value"] else { return nil }
                return JSONInspector.integer(of: value)
            }
            if observed.sorted() != expectedPitches.sorted() {
                violations.append(
                    "Num.slider_value pitches \(observed.sorted()) != fixture \(expectedPitches.sorted())")
            }
        }
        return violations
    }

    /// The software-instrument track's plug-in inventory is State A and complete, for
    /// that track, with no slot the strip could not read or classify.
    static func siInventoryViolations(responseData: Data, siTrackIndex: Int) -> [String] {
        guard let root = JSONInspector.parse(responseData) as? [String: Any] else {
            return ["inventory response is not a JSON object"]
        }
        var violations: [String] = []
        if root["state"] as? String != "A" {
            violations.append("state is \(root["state"] as? String ?? "absent"), not A")
        }
        if let success = root["success"], !JSONInspector.isBoolean(success) || (success as? Bool) != true {
            violations.append("success is not true")
        }
        if let complete = root["complete"], JSONInspector.isBoolean(complete) {
            if (complete as? Bool) != true { violations.append("complete is false") }
        } else {
            violations.append("complete is missing")
        }
        if let track = root["track"].flatMap({ JSONInspector.integer(of: $0) }) {
            if track != siTrackIndex {
                violations.append("inventory is for track \(track), not the SI track \(siTrackIndex)")
            }
        } else {
            violations.append("track is missing")
        }
        if let reason = root["plugins_unknown_reason"], !(reason is NSNull) {
            violations.append("plugins_unknown_reason is \(reason)")
        }
        guard let plugins = root["plugins"] as? [Any] else {
            violations.append("plugins is not an array")
            return violations
        }
        for case let item as [String: Any] in plugins {
            let status = item["read_status"] as? String
            if status != "empty" && status != "ok" {
                violations.append(
                    "insert \(item["insert"] ?? "?") read_status \(status ?? "absent")")
            }
        }
        return violations
    }
}

enum QualificationLiveGateVerdict {
    struct Evaluation: Equatable, Sendable {
        let operationID: String
        let verdict: QualificationOperationVerdict
        /// Gate violations specific to this operation (failed status, failed value check).
        let violations: [String]
    }

    // MARK: static classification

    /// The reason an operation can NEVER be EXERCISED by the code as it stands, derived from the
    /// registry and the qualification tables rather than pinned. Nil when it could be.
    static func staticReason(
        for spec: OperationSpec,
        fixture: QualificationLiveGateFixtureFacts?
    ) -> QualificationNotQualifiedReason? {
        if spec.availability == .unsupported { return .unsupportedByContract }
        switch spec.mutability {
        case .mutating:
            guard let policy = QualificationTransport.mutationRestorePolicy(for: spec.id) else {
                return QualificationTransport.consentFirstMutationProbeOperationIDs.contains(spec.id)
                    ? .consentProbeOnly : .unknownParamProbeOnly
            }
            switch policy {
            case .trackCreate, .trackDelete:
                return QualificationTransport.phaseCTrackCyclesEnabled ? nil : .recipeDisabled
            default:
                return nil
            }
        case .readOnly:
            if SemanticOracleTable.bespokeOperationIDs.contains(spec.id) { return .readbackNotIndependent }
            if QualificationLiveGateValueChecks.operations.contains(spec.id) {
                return fixture == nil ? .needsFixtureValueCheck : nil
            }
            if !QualificationSemanticReadbackValidator.canUseIndependentReadback(for: spec.id) {
                return .semanticValidatorUnavailable
            }
            return nil
        }
    }

    // MARK: readback comparison

    /// Whether the oracle's verdict on this result actually depends on its readback. The recorded
    /// response is re-judged against readbacks that cannot belong to it; an oracle that still says
    /// `true` never looked at the readback.
    static func readbackIsCompared(_ result: QualificationOperationResult) -> Bool {
        guard let response = result.responseData, let readback = result.readbackData else { return false }
        func judge(_ readback: Data) -> Bool? {
            QualificationSemanticReadbackValidator.validate(
                operationID: result.operationID,
                responseData: response,
                readbackData: readback,
                readbackSource: result.readbackSource
            )
        }
        guard judge(readback) == true else { return false }
        return perturbedReadbacks.allSatisfy { judge($0) != true }
    }

    static let perturbedReadbacks: [Data] = [
        Data(),
        Data("{}".utf8),
        Data("null".utf8),
        Data(#"{"__qualification_readback_perturbation":true}"#.utf8),
    ]

    // MARK: per-operation verdict

    static func evaluate(
        spec: OperationSpec,
        result: QualificationOperationResult?,
        fixture: QualificationLiveGateFixtureFacts?
    ) -> Evaluation {
        let id = spec.id.rawValue
        guard let result else {
            return Evaluation(
                operationID: id, verdict: .notQualified(.missingResult),
                violations: ["\(id): no result was recorded for this operation"])
        }
        if result.status == .failed {
            return Evaluation(
                operationID: id, verdict: .notQualified(.failed),
                violations: ["\(id): failed: \(result.liveGateFailureReason ?? result.failureReason ?? "no reason recorded")"])
        }
        if let reason = staticReason(for: spec, fixture: fixture) {
            return Evaluation(operationID: id, verdict: .notQualified(reason), violations: [])
        }
        switch spec.mutability {
        case .mutating:
            return Evaluation(operationID: id, verdict: mutatingVerdict(result), violations: [])
        case .readOnly:
            return readOnlyEvaluation(spec: spec, result: result, fixture: fixture)
        }
    }

    private static func mutatingVerdict(_ result: QualificationOperationResult) -> QualificationOperationVerdict {
        if let record = result.mutationRestore {
            let verified = result.status == .passed
                && result.verificationKind == .verifiedWriteCycle
                && result.mutationRestoreRefusal == nil
                && result.expectedZeroWriteRefusalObserved
                && record.operationID == result.operationID
                && record.verifiedCycleShape
                && result.restore?.verified == true
            return verified ? .exercised : .notQualified(.restoreNotVerified)
        }
        return .notQualified(.recipeRefused)
    }

    private static func readOnlyEvaluation(
        spec: OperationSpec,
        result: QualificationOperationResult,
        fixture: QualificationLiveGateFixtureFacts?
    ) -> Evaluation {
        let id = spec.id.rawValue
        func verdict(_ value: QualificationOperationVerdict, _ violations: [String] = []) -> Evaluation {
            Evaluation(operationID: id, verdict: value, violations: violations)
        }
        let valueChecked = QualificationLiveGateValueChecks.operations.contains(spec.id)
        switch result.status {
        case .passed, .protocolSmoke:
            guard result.isError == false else { return verdict(.notQualified(.refused)) }
            if valueChecked, let fixture {
                // The fixture-bound value check is the compared witness for these operations.
                let found = valueCheck(spec.id, result: result, fixture: fixture)
                if !found.isEmpty {
                    return verdict(
                        .notQualified(.valueCheckFailed), found.map { "\(id): value check: \($0)" })
                }
                if spec.id == .pluginsGetInventory, result.status != .passed {
                    return verdict(.notQualified(.protocolSmokeOnly))
                }
                return verdict(.exercised)
            }
            if result.status == .protocolSmoke { return verdict(.notQualified(.protocolSmokeOnly)) }
            return verdict(readbackIsCompared(result) ? .exercised : .notQualified(.readbackNotCompared))
        default:
            if result.liveGateUnmetOperationPrecondition != nil {
                return verdict(.notQualified(.operationPrecondition))
            }
            if result.liveGateUnmetEnvironmentalPrecondition != nil {
                return verdict(.notQualified(.envPrecondition))
            }
            if result.isError != false { return verdict(.notQualified(.refused)) }
            return verdict(.notQualified(.deferred))
        }
    }

    private static func valueCheck(
        _ id: OperationID,
        result: QualificationOperationResult,
        fixture: QualificationLiveGateFixtureFacts
    ) -> [String] {
        switch id {
        case .midiReadSelectedRegionEvents:
            guard let response = result.responseData else { return ["no response body"] }
            return QualificationLiveGateValueChecks.midiRowsViolations(
                responseData: response,
                expectedNoteCount: fixture.selectedRegionNoteCount,
                expectedPitches: fixture.selectedRegionPitches
            )
        case .pluginsGetInventory:
            return QualificationLiveGateValueChecks.siInventoryViolations(
                responseData: fixture.siInventoryResponse, siTrackIndex: fixture.siTrackIndex)
        default:
            return []
        }
    }

    // MARK: whole-run verdicts and violations

    static func verdicts(
        results: [QualificationOperationResult],
        requested: [OperationSpec],
        fixture: QualificationLiveGateFixtureFacts?
    ) -> [Evaluation] {
        let byID = Dictionary(results.map { ($0.operationID, $0) }, uniquingKeysWith: { first, _ in first })
        return requested.map { evaluate(spec: $0, result: byID[$0.id.rawValue], fixture: fixture) }
    }

    /// Every rule, each string naming the operation. Empty means the gate holds.
    static func violations(
        results: [QualificationOperationResult],
        requested: [OperationSpec],
        fixture: QualificationLiveGateFixtureFacts?,
        list: QualificationNotQualifiedList
    ) -> [String] {
        let evaluations = verdicts(results: results, requested: requested, fixture: fixture)
        var found = evaluations.flatMap(\.violations)
        found += listViolations(list: list, requested: requested, fixture: fixture)
        var listed: [String: QualificationNotQualifiedEntry] = [:]
        for entry in list.entries where listed[entry.operation] == nil { listed[entry.operation] = entry }
        for evaluation in evaluations {
            let id = evaluation.operationID
            let entry = listed[id]
            switch evaluation.verdict {
            case .exercised:
                if let entry {
                    found.append("\(id): stale NOT_QUALIFIED list: EXERCISED this run but listed as \(entry.reason)")
                }
            case .notQualified(let reason) where reason.isListable:
                guard let entry else {
                    found.append("\(id): NOT_QUALIFIED (\(reason.rawValue)) and not on the list: a new silent gap")
                    continue
                }
                if entry.reason != reason.rawValue {
                    found.append(
                        "\(id): NOT_QUALIFIED as \(reason.rawValue) but the list says \(entry.reason)")
                }
            case .notQualified:
                break // failed / missing / value-check failures were reported above
            }
        }
        let verdictByID = Dictionary(
            evaluations.map { ($0.operationID, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        for promise in list.promised {
            switch verdictByID[promise.operation] {
            case .exercised?:
                break
            case .notQualified(let reason)?:
                found.append(
                    "\(promise.operation): promised by \(promise.commit) but NOT_QUALIFIED (\(reason.rawValue)) this run")
            case nil:
                found.append("\(promise.operation): promised by \(promise.commit) but not requested in this run")
            }
        }
        return found
    }

    /// The list's own soundness against the registry, independent of any run.
    static func listViolations(
        list: QualificationNotQualifiedList,
        requested: [OperationSpec],
        fixture: QualificationLiveGateFixtureFacts?
    ) -> [String] {
        var found: [String] = []
        if list.schema != 1 { found.append("list schema \(list.schema) is not 1") }
        let registry = Set(OperationRegistry.specs.map(\.id.rawValue))
        var seen = Set<String>()
        for entry in list.entries {
            if !registry.contains(entry.operation) {
                found.append("\(entry.operation): the list names an operation that is not in the registry")
            }
            if !seen.insert(entry.operation).inserted {
                found.append("\(entry.operation): listed more than once")
            }
            if let reason = QualificationNotQualifiedReason(rawValue: entry.reason) {
                if !reason.isListable {
                    found.append("\(entry.operation): reason \(entry.reason) can never be an expected gap")
                }
            } else {
                found.append("\(entry.operation): unknown reason code \(entry.reason)")
            }
            if entry.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append("\(entry.operation): the list gives no detail for its reason")
            }
        }
        let listed = Dictionary(
            list.entries.map { ($0.operation, $0) }, uniquingKeysWith: { first, _ in first })
        var promisedSeen = Set<String>()
        for promise in list.promised {
            if !registry.contains(promise.operation) {
                found.append("\(promise.operation): promised but not in the registry")
            }
            if !promisedSeen.insert(promise.operation).inserted {
                found.append("\(promise.operation): promised more than once")
            }
            if let entry = listed[promise.operation] {
                found.append(
                    "\(promise.operation): promised by \(promise.commit) but on the NOT_QUALIFIED list as \(entry.reason)")
            }
            if promise.commit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || promise.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append("\(promise.operation): a promise needs its claiming commit and its live evidence")
            }
        }
        for spec in requested {
            guard let reason = staticReason(for: spec, fixture: fixture) else { continue }
            guard let entry = listed[spec.id.rawValue] else {
                found.append(
                    "\(spec.id.rawValue): statically NOT_QUALIFIED (\(reason.rawValue)) and missing from the list")
                continue
            }
            if entry.reason != reason.rawValue {
                found.append(
                    "\(spec.id.rawValue): statically \(reason.rawValue) but the list says \(entry.reason)")
            }
        }
        return found
    }
}

enum QualificationLiveGateVerdictReport {
    /// `exercised=N, not_qualified=M (reason=count, ...) of T`, so a run's log says how many
    /// operations were genuinely exercised rather than "passed".
    static func summaryLine(_ evaluations: [QualificationLiveGateVerdict.Evaluation]) -> String {
        let exercised = evaluations.filter { $0.verdict.isExercised }.count
        var byReason: [String: Int] = [:]
        for evaluation in evaluations {
            if case .notQualified(let reason) = evaluation.verdict { byReason[reason.rawValue, default: 0] += 1 }
        }
        let detail = byReason.keys.sorted().map { "\($0)=\(byReason[$0] ?? 0)" }.joined(separator: ", ")
        return "qualification live gate verdicts: exercised=\(exercised), "
            + "not_qualified=\(evaluations.count - exercised) (\(detail)) of \(evaluations.count)"
    }
}
