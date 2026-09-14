import Foundation
import Darwin

struct QualificationDriveRequest: Sendable {
    let executableURL: URL
    let environment: [String: String]
    let expectedOperationCount: Int
    let operations: [OperationSpec]
    let expectedExecutableSHA256: String?

    init(
        executableURL: URL,
        environment: [String: String],
        expectedOperationCount: Int,
        operations: [OperationSpec] = [],
        expectedExecutableSHA256: String? = nil
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.expectedOperationCount = expectedOperationCount
        self.operations = operations
        self.expectedExecutableSHA256 = expectedExecutableSHA256
    }
}

struct QualificationWireFrame: Codable, Equatable, Sendable {
    enum Direction: String, Codable, Hashable, Sendable {
        case request
        case response
        case notification
    }

    let sequence: Int
    let direction: Direction
    let operationID: String
    let payload: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case direction
        case operationID = "operation_id"
        case payload
    }
}

struct QualificationMutationRestoreRecord: Codable, Equatable, Sendable {
    let operationID: String
    let preState: String
    let mutation: String
    let readback: String
    let restore: String
    let restoreReadback: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case preState = "pre_state"
        case mutation
        case readback
        case restore
        case restoreReadback = "restore_readback"
    }
}

struct QualificationHandshake: Equatable, Sendable {
    let protocolVersion: String
    let serverName: String
    let serverVersion: String

    var isValid: Bool {
        !protocolVersion.isEmpty && !serverName.isEmpty && !serverVersion.isEmpty
    }
}

struct QualificationHealth: Equatable, Sendable {
    let logicProRunning: Bool
    let logicProVersion: String
    let logicProBundleID: String
    let logicProVariant: String
    let logicProUILocale: String
    let processMetadataResolved: Bool
    let variants: [QualificationVariantAvailability]

    var isValid: Bool {
        !logicProVersion.isEmpty
            && !logicProVariant.isEmpty
            && QualificationLocale(rawValue: logicProUILocale) != nil
            && availabilityObservation != nil
    }

    var identifiesLiveLogic: Bool {
        logicProRunning && processMetadataResolved && logicProVersion != "unknown"
    }

    var availabilityObservation: QualificationAvailabilityObservation? {
        guard let activeVariant = Self.qualificationVariant(logicProVariant),
              let uiLocale = QualificationLocale(rawValue: logicProUILocale),
              variants.contains(where: {
                  $0.variant == activeVariant
                      && $0.bundleID == logicProBundleID
                      && $0.running
              }) else {
            return nil
        }
        return QualificationAvailabilityObservation(
            activeBundleID: logicProBundleID,
            activeVariant: activeVariant,
            logicUILocale: uiLocale,
            variants: variants
        )
    }

    private static func qualificationVariant(_ value: String) -> LogicVariant? {
        switch value {
        case LogicProVariant.desktop.rawValue: .desktop
        case LogicProVariant.creatorStudio.rawValue: .creatorStudio
        default: nil
        }
    }
}

struct QualificationTraceEntry: Equatable, Sendable {
    let traceID: String
    let operationID: String
    let phaseCount: Int
    let readbackState: String?
}

struct QualificationTraceList: Equatable, Sendable {
    let traces: [QualificationTraceEntry]
}

struct QualificationTraceDetail: Equatable, Sendable {
    let traceID: String
    let operationID: String
    let phases: [String]
}

struct QualificationOperationResult: Equatable, Sendable {
    let operationID: String
    let tool: String
    let command: String
    let mutability: Mutability
    let requestID: String?
    let responseData: Data?
    let isError: Bool?
    let state: String?
    let error: String?
    /// The refusal's actionable half. Captured because the deferral used to guess a cause the
    /// operation had already named -- see `operationUnavailable` below.
    let hint: String?
    let writeAttempted: Bool?
    let readbackSource: String?
    let readbackRequestID: String?
    let readbackData: Data?
    /// The operation contract is carried with the captured readback so that an independent read
    /// can apply a live-freshness requirement only when this operation actually promises one.
    let verification: VerificationPolicy
    let deadline: DeadlineClass
    let failureReason: String?
    /// ADR-001-c / #373 Phase B evidence: the verified write-and-restore cycle for a MUTATING
    /// operation, or nil when no recipe ran. Non-nil means every step of that cycle held — see
    /// `muteRestoreCycle`, which is the only constructor and refuses rather than returning a
    /// record for a cycle that did not verify.
    let mutationRestore: QualificationMutationRestoreRecord?
    /// Why a Phase-B recipe that RAN produced no record. Nil when no recipe exists for the
    /// operation — the two are different facts and the deferral below says which.
    let mutationRestoreRefusal: String?

    init(
        operationID: String,
        tool: String,
        command: String,
        mutability: Mutability,
        requestID: String?,
        responseData: Data?,
        isError: Bool?,
        state: String?,
        error: String?,
        hint: String?,
        writeAttempted: Bool?,
        readbackSource: String?,
        readbackRequestID: String?,
        readbackData: Data?,
        verification: VerificationPolicy = .none,
        deadline: DeadlineClass = .short,
        failureReason: String?,
        mutationRestore: QualificationMutationRestoreRecord? = nil,
        mutationRestoreRefusal: String? = nil
    ) {
        self.operationID = operationID
        self.tool = tool
        self.command = command
        self.mutability = mutability
        self.requestID = requestID
        self.responseData = responseData
        self.isError = isError
        self.state = state
        self.error = error
        self.hint = hint
        self.writeAttempted = writeAttempted
        self.readbackSource = readbackSource
        self.readbackRequestID = readbackRequestID
        self.readbackData = readbackData
        self.verification = verification
        self.deadline = deadline
        self.failureReason = failureReason
        self.mutationRestore = mutationRestore
        self.mutationRestoreRefusal = mutationRestoreRefusal
    }

    var responseArtifactData: Data? {
        guard let requestID,
              let responseData,
              let isError,
              let payload = String(data: responseData, encoding: .utf8) else {
            return nil
        }
        return Self.encoded(QualificationOperationResponseArtifact(
            operationID: operationID,
            tool: tool,
            command: command,
            requestID: requestID,
            isError: isError,
            payload: payload
        ))
    }

    var responseSHA256: String? {
        responseArtifactData.map(SupportBundleBuilder.sha256)
    }

    var readbackArtifactData: Data? {
        guard let readbackSource,
              let readbackRequestID,
              let readbackData,
              let payload = String(data: readbackData, encoding: .utf8) else {
            return nil
        }
        return Self.encoded(QualificationReadbackArtifact(
            source: readbackSource,
            requestID: readbackRequestID,
            payload: payload
        ))
    }

    var readback: QualificationReadbackEvidence? {
        guard let readbackSource, let readbackRequestID, let readbackArtifactData else { return nil }
        return QualificationReadbackEvidence(
            source: readbackSource,
            requestID: readbackRequestID,
            // A mutating deferral (e.g. a consent-gated zero-write refusal, #413)
            // must NOT claim its nested readback verified — only a passed
            // qualification does.
            verified: status == .passed,
            sha256: SupportBundleBuilder.sha256(readbackArtifactData)
        )
    }

    var status: QualificationStatus {
        if failureReason != nil || responseData == nil || readbackArtifactData == nil {
            return .failed
        }
        switch mutability {
        case .readOnly:
            guard readbackFreshness.isAdmissible else { return .notQualified }
            guard isError == false else { return .notQualified }
            switch semanticReadbackValidated {
            case .some(true): return .passed
            case .some(false): return .notQualified
            case .none: return .protocolSmoke
            }
        case .mutating:
            // ADR-001-c / #373 Phase B. A verified write-and-restore cycle is the ONLY thing that
            // promotes a mutating operation here, and `mutationRestore` is non-nil only when every
            // step of that cycle held: the mutation moved the independently observed state, and the
            // restore returned it exactly, both read back from `logic://tracks` rather than from
            // the write's own answer. The record type has no failure case, so a cycle that did not
            // verify produces nothing for this branch to see.
            // No `record.operationID == operationID` check here, deliberately. It was written and
            // then removed: a mutation that dropped it left every test green, because a foreign
            // record cannot be attached in the first place — `phaseBRecord` is declared inside one
            // sweep iteration and written only by that iteration's own recipe. A guard nothing can
            // trip is not a guard, and defending it in a comment is worse than the structure that
            // actually holds. If records ever arrive from somewhere other than the sweep, this is
            // the line to add back WITH a seam that can exercise it.
            //
            // THE OPERATION'S OWN PROBE IS CHECKED FIRST, and getting this order wrong was the
            // defect. A Phase-B record used to promote the operation before anything looked at the
            // probe, so an injected fault — a timeout, a partial state — was LAUNDERED by a recipe
            // that happened to succeed beside it: the recipe's own play/stop calls are unaffected
            // by a fault armed for the no-write probe, so the record existed and the operation read
            // `.passed` while its own answer was State C. Four fault-injection tests caught it.
            //
            // A recipe can supply evidence the probe never had. It cannot vouch for the probe.
            guard expectedZeroWriteRefusalObserved else { return .failed }
            // A successful write that carries an inadmissible live readback has not been
            // confirmed. Keep the existing no-write deferrals untouched.
            if isError == false, !readbackFreshness.isAdmissible { return .notQualified }
            // Freshness is required of the recipe's readback too: a cycle read through a stale or
            // partial resource is the same unverified claim with more steps.
            if mutationRestore != nil, readbackFreshness.isAdmissible { return .passed }
            return .notQualified
        }
    }

    /// Scope is an operation property, not a verdict from this particular run.
    ///
    /// The live probe deliberately sends `__adr001b_no_write_probe` for every
    /// mutating operation. It can observe the fail-closed refusal, but it
    /// cannot establish that the operation's success path works.
    var liveGateScope: QualificationLiveGateScope {
        switch mutability {
        case .readOnly: .inScope
        case .mutating: .outOfScope
        }
    }

    /// The observed zero-write refusal expected from a mutating probe.
    ///
    /// Kept available to the live-gate report so a missing refusal is reported
    /// as the reason for failure rather than as an unexplained operation ID.
    var expectedZeroWriteRefusalObserved: Bool {
        isError == true
            && state == "C"
            // setup_arm_key's no-write probe refuses consent-first with
            // `consent_required` (before param validation); every other mutating
            // op's no-write probe is an `invalid_params` typed refusal (#413).
            && ["consent_required", "invalid_params"].contains(error)
            && writeAttempted == false
    }

    var verified: Bool { status == .passed }

    /// An input the harness did not provide, but which the operation says it
    /// needs. This is deliberately an exact operation-and-refusal match: a
    /// different refusal from one of these operations is a product failure,
    /// not a generic exemption.
    var liveGateUnmetOperationPrecondition: String? {
        guard isError == true, error == "invalid_params" else { return nil }
        switch OperationID(rawValue: operationID) {
        case .audioAnalyzeSpectrum:
            guard hint == "analyze_spectrum requires non-empty string 'path'" else { return nil }
            return "requires non-empty string 'path'"
        case .audioRecommendEQ:
            guard hint == "recommend_eq requires non-empty string 'path'" else { return nil }
            return "requires non-empty string 'path'"
        case .systemClearTraces:
            guard hint == "clear_traces requires 'confirmed:true' because it destroys in-process diagnostic evidence"
            else { return nil }
            return "requires 'confirmed:true'"
        default:
            return nil
        }
    }

    /// An environmental prerequisite, distinct from an operation input. As
    /// above, the exact refusal is part of the classification so a new error
    /// from the same operation stays visible as a failure.
    var liveGateUnmetEnvironmentalPrecondition: String? {
        guard isError == true, error == "channels_exhausted" else { return nil }
        switch OperationID(rawValue: operationID) {
        case .tracksScanPluginPresets
            where hint == "No plugin window with Setting dropdown found. Open an instrument plugin window first.":
            return "requires an open plugin window with a Setting dropdown"
        // Measured 2026-09-02: `tracks.list_library` answers differently depending
        // on whether Logic's Library panel is open. With the panel open it returns
        // categories and presets and its readback is compared; with the panel
        // closed it refuses with this exact hint. Both observations are true — they
        // are of different states — so the closed-panel refusal is an environmental
        // prerequisite, exactly like the plug-in window above, and not a semantic
        // shortfall. Pinning it as a semantic failure made the gate's exact-match
        // assertion fire on a panel the operator happened to close.
        case .tracksListLibrary
            where hint == "Library panel not found. Open Library (Y) in Logic Pro.":
            return "requires Logic's Library panel to be open"
        default:
            return nil
        }
    }

    /// The outcome used by the live qualification gate. A non-passing
    /// read-only observation is a gate failure unless the operation named an
    /// exact missing operation or environmental prerequisite. Neither kind is
    /// counted as a pass, and every other shortfall remains a failure.
    var liveGateDisposition: QualificationLiveGateDisposition {
        if status == .failed { return .failed }
        switch liveGateScope {
        case .inScope:
            if status == .passed { return .passed }
            if liveGateUnmetOperationPrecondition != nil {
                return .notExercisableWithoutPreconditions
            }
            if liveGateUnmetEnvironmentalPrecondition != nil {
                return .environmentalPrecondition
            }
            return .failed
        case .outOfScope:
            return .outOfScope
        }
    }

    /// A diagnostic reason for a failed live-gate disposition, derived only
    /// from the captured request, readback, and response observations.
    var liveGateFailureReason: String? {
        guard liveGateDisposition == .failed else { return nil }
        if let failureReason { return failureReason }
        if responseData == nil {
            return "operation request produced no response"
        }
        if readbackArtifactData == nil {
            return "independent readback produced no response"
        }
        switch mutability {
        case .mutating:
            guard !expectedZeroWriteRefusalObserved else {
                return "mutating operation produced a failed observation after its zero-write refusal"
            }
            return "operation request missing expected typed zero-write refusal "
                + "(is_error=\(Self.observed(isError)), state=\(Self.observed(state)), "
                + "error=\(Self.observed(error)), write_attempted=\(Self.observed(writeAttempted)))"
        case .readOnly:
            if isError != false {
                return "operation request returned a refusal: "
                    + Self.unavailableDetail(error: error, hint: hint)
            }
            if let reason = readbackFreshness.refusalReason {
                return "independent readback was not admissible: \(reason)"
            }
            switch semanticReadbackValidated {
            case .some(false):
                return "semantic readback mismatch: response did not match its independent readback"
            case .none:
                return "in-scope read has no operation-specific semantic validator"
            case .some(true):
                return "in-scope read did not reach a passing qualification"
            }
        }
    }

    var verificationKind: QualificationVerificationKind {
        switch status {
        case .passed: .semanticReadback
        case .protocolSmoke: .protocolSmoke
        default: .typedDeferral
        }
    }

    var deferral: QualificationDeferral? {
        if status == .notQualified,
           isError == false,
           let reason = readbackFreshness.refusalReason {
            return QualificationDeferral(
                code: .semanticMismatch,
                detail: reason
            )
        }
        switch status {
        case .notQualified where mutability == .mutating:
            // A record EXISTS and the operation still did not qualify: the cycle verified but its
            // independent readback was not admissible. Saying "requires an operation-specific
            // recipe" here would be false — one ran, and succeeded. Measured 2026-09-14: this is
            // what `mixer.set_volume` / `mixer.set_pan` hit, because `logic://mixer` reports its
            // provenance under `data_source` while the freshness gate reads `source` (which
            // `logic://tracks` does emit), so the envelope reads as not-live.
            if mutationRestore != nil, let reason = readbackFreshness.refusalReason {
                return QualificationDeferral(
                    code: .semanticMismatch,
                    detail: "a Phase-B write-and-restore cycle VERIFIED, but its independent "
                        + "readback was not admissible: \(reason)"
                )
            }
            if let refusal = mutationRestoreRefusal {
                return QualificationDeferral(
                    code: .liveMutationNotRun,
                    detail: "a Phase-B write-and-restore recipe RAN and refused: \(refusal)"
                )
            }
            return QualificationDeferral(
                code: .liveMutationNotRun,
                detail: "deferred to ADR-001-c: live mutation requires an operation-specific fixture and independent readback"
            )
        case .notQualified where isError == false && semanticReadbackValidated == false:
            return QualificationDeferral(
                code: .semanticMismatch,
                detail: "read-only response did not match its operation-specific independent readback"
            )
        case .notQualified where error == HonestContract.FailureError.commandNotExposed.rawValue:
            return QualificationDeferral(
                code: .notExposedInProductionContract,
                detail: "the production MCP contract does not expose this operation; no probe "
                    + "parameter can qualify it while its feature flag is off"
            )
        case .notQualified:
            return QualificationDeferral(
                code: .operationUnavailable,
                // This used to assert one cause for every shortfall: that the probe sends `[:]`
                // and the operation refused for want of a parameter. That is true for some and
                // false for others, and the attestation had no way to tell them apart.
                //
                // Measured 2026-08-24: `tracks.list_library` takes NO parameters and refuses with
                // `channels_exhausted` / "Library panel not found. Open Library (Y) in Logic Pro.";
                // `tracks.scan_plugin_presets` refuses with "No plugin window with Setting dropdown
                // found." Both name their precondition exactly. The old text sent whoever read the
                // attestation to check probe parameters that do not exist for those operations,
                // while the operation had already said what it needed.
                //
                // So the detail now carries what the operation said. The generic sentence remains
                // only for a refusal that named nothing, which is the one case where a category
                // guess is all there is.
                detail: Self.unavailableDetail(error: error, hint: hint)
            )
        case .protocolSmoke:
            return QualificationDeferral(
                code: .semanticValidatorUnavailable,
                detail: "protocol transport succeeded without an operation-specific semantic validator"
            )
        default:
            return nil
        }
    }

    /// The refusal in the operation's own words when it gave any, and a stated absence otherwise.
    ///
    /// Kept deliberately literal: an attestation is read by someone deciding whether a shortfall is
    /// their environment or the product, and a paraphrase is where that distinction goes missing.
    static func unavailableDetail(error: String?, hint: String?) -> String {
        let code = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (code?.isEmpty == false ? code : nil, reason?.isEmpty == false ? reason : nil) {
        case let (.some(code), .some(reason)):
            return "read-only operation refused with `\(code)`: \(reason)"
        case let (.some(code), .none):
            return "read-only operation refused with `\(code)` and named no precondition"
        case let (.none, .some(reason)):
            return "read-only operation did not return a successful typed response: \(reason)"
        case (.none, .none):
            return "read-only operation did not return a successful typed response and named "
                + "neither an error code nor a precondition"
        }
    }

    private var semanticReadbackValidated: Bool? {
        guard mutability == .readOnly,
              let responseData,
              let readbackData else {
            return nil
        }
        return QualificationSemanticReadbackValidator.validate(
            operationID: operationID,
            responseData: responseData,
            readbackData: readbackData
        )
    }

    private var readbackFreshness: QualificationReadbackFreshness.Verdict {
        guard let readbackData else { return .cacheAgeUnknown }
        return QualificationReadbackFreshness.verdict(
            for: readbackData,
            verification: verification,
            deadline: deadline
        )
    }

    private static func encoded<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value)
    }

    private static func observed(_ value: String?) -> String {
        value ?? "not observed"
    }

    private static func observed(_ value: Bool?) -> String {
        value.map(String.init) ?? "not observed"
    }
}

enum QualificationLiveGateScope: String, Sendable {
    case inScope = "in_scope"
    case outOfScope = "out_of_scope"
}

enum QualificationLiveGateDisposition: String, Sendable {
    case passed
    case outOfScope = "out_of_scope"
    case notExercisableWithoutPreconditions = "not_exercisable_without_preconditions"
    case environmentalPrecondition = "environmental_precondition"
    case failed
}

/// The human-readable accounting for the real-process live qualification test.
///
/// It deliberately does not alter `QualificationStatus`, which is also used by
/// the release-attestation and waiver machinery. The direct live gate needs a
/// stricter interpretation: semantic shortfalls in read-only operations fail,
/// while mutating success paths are explicitly excluded.
struct QualificationLiveGateSummary: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let operationID: String
        let failureReason: String
    }

    struct Prerequisite: Equatable, Sendable {
        let operationID: String
        let reason: String
    }

    let total: Int
    let inScopePassed: Int
    let outOfScope: Int
    let mutatingOperationCount: Int
    let notExercisableWithoutPreconditions: [Prerequisite]
    let environmentalPreconditions: [Prerequisite]
    let failures: [Failure]

    init(operationResults: [QualificationOperationResult]) {
        total = operationResults.count
        mutatingOperationCount = operationResults.filter {
            $0.liveGateScope == .outOfScope
        }.count
        inScopePassed = operationResults.filter {
            $0.liveGateDisposition == .passed
        }.count
        outOfScope = operationResults.filter {
            $0.liveGateDisposition == .outOfScope
        }.count
        notExercisableWithoutPreconditions = operationResults
            .filter { $0.liveGateDisposition == .notExercisableWithoutPreconditions }
            .sorted { $0.operationID < $1.operationID }
            .map { operation in
                guard let reason = operation.liveGateUnmetOperationPrecondition else {
                    preconditionFailure("An unmet operation precondition must retain its reason")
                }
                return Prerequisite(operationID: operation.operationID, reason: reason)
            }
        environmentalPreconditions = operationResults
            .filter { $0.liveGateDisposition == .environmentalPrecondition }
            .sorted { $0.operationID < $1.operationID }
            .map { operation in
                guard let reason = operation.liveGateUnmetEnvironmentalPrecondition else {
                    preconditionFailure("An unmet environmental precondition must retain its reason")
                }
                return Prerequisite(operationID: operation.operationID, reason: reason)
            }
        failures = operationResults
            .filter { $0.liveGateDisposition == .failed }
            .sorted { $0.operationID < $1.operationID }
            .map { operation in
                guard let failureReason = operation.liveGateFailureReason else {
                    preconditionFailure("A failed live-gate operation must retain an observed reason")
                }
                return Failure(
                    operationID: operation.operationID,
                    failureReason: failureReason
                )
            }
    }

    var failed: Int { failures.count }

    var accounted: Int {
        inScopePassed
            + outOfScope
            + notExercisableWithoutPreconditions.count
            + environmentalPreconditions.count
            + failed
    }

    var classificationLine: String {
        "qualification live gate: in_scope_passed=\(inScopePassed), "
            + "out_of_scope=\(outOfScope), "
            + "not_exercisable_without_preconditions=\(notExercisableWithoutPreconditions.count), "
            + "environmental_preconditions=\(environmentalPreconditions.count), "
            + "failed=\(failed) of \(total)"
    }

    var mutatingOperationExclusionLine: String {
        "qualification live gate coverage: mutating operations are not exercised; "
            + "\(mutatingOperationCount) are out of scope for semantic qualification and receive "
            + "only zero-write refusal probes"
    }

    var failureLine: String? {
        guard !failures.isEmpty else { return nil }
        return "failed operations: " + failures.map {
            "\($0.operationID) (failureReason=\($0.failureReason))"
        }.joined(separator: ", ")
    }

    var unmetOperationPreconditionsLine: String? {
        guard !notExercisableWithoutPreconditions.isEmpty else { return nil }
        return "not-exercisable without operation preconditions: "
            + notExercisableWithoutPreconditions.map {
                "\($0.operationID) (reason=\($0.reason))"
            }.joined(separator: ", ")
    }

    var environmentalPreconditionsLine: String? {
        guard !environmentalPreconditions.isEmpty else { return nil }
        return "unmet environmental preconditions: " + environmentalPreconditions.map {
            "\($0.operationID) (reason=\($0.reason))"
        }.joined(separator: ", ")
    }
}

enum QualificationSemanticReadbackValidator {
    static func validate(
        operationID: String,
        responseData: Data,
        readbackData: Data
    ) -> Bool? {
        switch OperationID(rawValue: operationID) {
        case .systemHealth:
            // Bespoke: full typed-payload equality against the independent read.
            return healthMatches(responseData, readbackData)
        case .some(let id):
            // #373 Phase A: the read-only surface is covered by the data-driven
            // oracle table. Only an operation with no oracle at all falls
            // through to nil, which the runner honestly records as
            // protocolSmoke rather than passing it.
            guard let oracle = SemanticOracleTable.byOperationID[id] else { return nil }
            return oracle.evaluate(responseData: responseData, readbackData: readbackData)
        case .none:
            return nil
        }
    }

    private static func healthMatches(_ responseData: Data, _ readbackData: Data) -> Bool {
        guard let response = try? JSONDecoder().decode(HealthResult.self, from: responseData),
              let readback = try? JSONDecoder().decode(HealthResult.self, from: readbackData) else {
            return false
        }
        return response == readback
    }
}

struct QualificationNegativeResult: Equatable, Sendable {
    let toolIsError: Bool
    let state: String
    let error: String
    let writeAttempted: Bool
    let healthBefore: Data
    let healthAfter: Data
    let catalogBefore: Data
    let catalogAfter: Data

    var healthReadStable: Bool { healthBefore == healthAfter }
    var catalogReadStable: Bool { catalogBefore == catalogAfter }

    var isFailClosedAndStable: Bool {
        // Health warms during cache polling and MCU registration; zero-write plus a stable catalog is dispositive.
        toolIsError
            && state == "C"
            && error == "invalid_params"
            && !writeAttempted
            && catalogReadStable
    }
}

struct QualificationDriveResult: Equatable, Sendable {
    let handshake: QualificationHandshake?
    let health: QualificationHealth?
    let catalog: OperationCatalogSnapshot?
    let expectedOperationCount: Int
    let traceList: QualificationTraceList?
    let traceDetail: QualificationTraceDetail?
    let negative: QualificationNegativeResult?
    let observedLocale: String
    let operationResults: [String: QualificationOperationResult]
    let wireFrames: [QualificationWireFrame]
    let mutationRestoreRecords: [QualificationMutationRestoreRecord]
    let failureReason: String?

    init(
        handshake: QualificationHandshake?,
        health: QualificationHealth?,
        catalog: OperationCatalogSnapshot?,
        expectedOperationCount: Int,
        traceList: QualificationTraceList?,
        traceDetail: QualificationTraceDetail? = nil,
        negative: QualificationNegativeResult?,
        observedLocale: String,
        operationResults: [String: QualificationOperationResult] = [:],
        wireFrames: [QualificationWireFrame] = [],
        mutationRestoreRecords: [QualificationMutationRestoreRecord] = [],
        failureReason: String?
    ) {
        self.handshake = handshake
        self.health = health
        self.catalog = catalog
        self.expectedOperationCount = expectedOperationCount
        self.traceList = traceList
        self.traceDetail = traceDetail
        self.negative = negative
        self.observedLocale = observedLocale
        self.operationResults = operationResults
        self.wireFrames = wireFrames
        self.mutationRestoreRecords = mutationRestoreRecords
        self.failureReason = failureReason
    }

    var handshakeOK: Bool { handshake?.isValid == true }
    var healthOK: Bool { health?.isValid == true && health?.identifiesLiveLogic == true }
    var catalogCountMatch: Bool {
        guard let catalog else { return false }
        return catalog.operationCount == expectedOperationCount
            && catalog.operations.count == catalog.operationCount
    }
    var traceOK: Bool {
        guard let traceDetail,
              traceDetail.operationID == OperationID.systemSagaExecute.rawValue,
              traceDetail.phases.first == TracePhase.requestReceived.rawValue,
              traceDetail.phases.last == TracePhase.resultEmitted.rawValue,
              let summary = traceList?.traces.first(where: {
                  $0.traceID == traceDetail.traceID
                      && $0.operationID == traceDetail.operationID
              }) else {
            return false
        }
        return summary.phaseCount > 0 && summary.phaseCount == traceDetail.phases.count
    }
    var negativeFailclosed: Bool { negative?.isFailClosedAndStable == true }
    var allChecksPass: Bool {
        handshakeOK && healthOK && catalogCountMatch && traceOK && negativeFailclosed
    }
    var observedVariant: String {
        guard let identifier = health?.logicProVariant else { return "unknown" }
        return identifier == LogicProVariant.creatorStudio.rawValue
            ? LogicVariant.creatorStudio.rawValue
            : identifier
    }
    var logicProVersion: String { health?.logicProVersion ?? "unknown" }
    var identifiesLiveLogic: Bool { health?.identifiesLiveLogic == true }
    var availabilityObservation: QualificationAvailabilityObservation? {
        health?.availabilityObservation
    }
}

enum QualificationTransportError: Error, Equatable, CustomStringConvertible, Sendable {
    case requestTimeout(phase: String)
    case nonZeroExit(status: Int32, stderr: String)
    case malformedFrame(String)
    case closedPipe(phase: String)
    case launchFailed(String)
    case protocolViolation(String)
    case shutdownTimeout
    case unimplemented

    var description: String {
        switch self {
        case .requestTimeout(let phase): "qualification_transport_timeout:\(phase)"
        case .nonZeroExit(let status, let stderr):
            "qualification_transport_nonzero_exit:\(status):\(stderr)"
        case .malformedFrame(let detail): "qualification_transport_malformed_frame:\(detail)"
        case .closedPipe(let phase): "qualification_transport_closed_pipe:\(phase)"
        case .launchFailed(let detail): "qualification_transport_launch_failed:\(detail)"
        case .protocolViolation(let detail): "qualification_transport_protocol_violation:\(detail)"
        case .shutdownTimeout: "qualification_transport_shutdown_timeout"
        case .unimplemented: "qualification_transport_unimplemented"
        }
    }
}

struct QualificationTransport: Sendable {
    let handshakeTimeout: TimeInterval
    let requestTimeout: TimeInterval
    let shutdownGrace: TimeInterval

    init(
        handshakeTimeout: TimeInterval = 45,
        requestTimeout: TimeInterval = 10,
        shutdownGrace: TimeInterval = 1
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.requestTimeout = requestTimeout
        self.shutdownGrace = shutdownGrace
    }

    /// Environment the same-artifact qualification drives the server with.
    ///
    /// #394: ADR-002 target_ref ships DEFAULT ON — the server reads an ABSENT
    /// `LOGIC_MCP_ADR002_TARGET_REF` as ON (`!= "0"`). Qualification therefore
    /// attests the SHIPPED DEFAULT by leaving the variable ABSENT (even if the
    /// base inherited a pin), exactly what a default deployment runs — rather
    /// than pinning the `=0` kill-switch, which diverged from the shipped
    /// default. The session-random target/trace IDs this surfaces are
    /// ID-normalized by `QualificationTranscriptNormalizer` before the transcript
    /// is emitted (cross-run ID stability). The `=0` kill-switch is the operator
    /// rollback config — it is NOT run as a secondary same-artifact qualification
    /// drive; it is exercised only by a FeatureFlags env-contract UNIT test (via
    /// `adr002KillSwitchEnvironment`, alongside the absent / `=0` / `=1` cases in
    /// `FeatureFlagEnvironmentTests`).
    ///
    /// ADR-003 strict params and ADR-005 tracing are pinned to their shipped
    /// default ("1" reads identically to the default-ON `!= "0"`), so
    /// qualification and production agree on those too.
    static func qualificationEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "LOGIC_MCP_ADR002_TARGET_REF")
        environment["LOGIC_MCP_ADR003_STRICT_PARAMS"] = "1"
        environment["LOGIC_MCP_ADR005_OPERATION_TRACE"] = "1"
        return environment
    }

    /// The `=0` kill-switch environment — the operator's documented ADR-002
    /// rollback. Consumed by a FeatureFlags env-contract UNIT test, NOT by a
    /// secondary same-artifact qualification drive, so the rollback config stays
    /// exercised now that the PRIMARY qualification attests the shipped default
    /// (absent = ON) instead of this config.
    static func adr002KillSwitchEnvironment(base: [String: String]) -> [String: String] {
        var environment = qualificationEnvironment(base: base)
        environment["LOGIC_MCP_ADR002_TARGET_REF"] = "0"
        return environment
    }

    static func qualificationLocaleIdentifier(_ identifier: String) -> String {
        switch Locale(identifier: identifier).language.languageCode?.identifier.lowercased() {
        case "en": QualificationLocale.enUS.rawValue
        case "ko": QualificationLocale.koKR.rawValue
        default: identifier.replacingOccurrences(of: "_", with: "-")
        }
    }

    func drive(_ request: QualificationDriveRequest) throws -> QualificationDriveResult {
        // #399 (CEO audit P0) — the fault-injection probe timeout only applies in
        // debug, where the seam exists. A release build has no
        // `QualificationFaultInjection`, so `faultActive` is a constant false and
        // the probe uses its normal request timeout.
        #if FAULT_TEST_SEAM
        let faultActive = QualificationFaultInjection(environment: request.environment) != nil
        #else
        let faultActive = false
        #endif
        let session = QualificationSubprocessSession(
            request: request,
            requestTimeout: requestTimeout,
            shutdownGrace: shutdownGrace
        )
        try session.start()

        do {
            let handshake = try initialize(session)
            // The UI locale comes from a MENU-BAR read (`AXLogicProElements+Menu.swift:25`): the
            // observed top-level titles must contain one language's full set. That read is
            // TRANSIENTLY EMPTY -- measured, three consecutive fresh processes reported `unknown`
            // and two reads seconds later reported `en-US`, with Logic untouched between them.
            //
            // Sampling it once meant a single unreadable read aborted the entire run, and the guard
            // downstream reported it as a locale MISMATCH for a locale that was correct. That
            // message cost eight wrong explanations before the mechanism was found.
            //
            // Retried ONLY while the value is unrecognised. A recognised locale -- en-US or ko-KR --
            // stops immediately even when it is the WRONG one, because that is a real mismatch and
            // must still fail closed. Retrying an unrecognised value cannot convert a genuine
            // ko-KR run into an en-US pass: ko-KR is recognised and exits the loop on the first read.
            var healthBefore = try health(session, id: 2, phase: "health_before")
            var localeRetryID = 900
            while QualificationLocale(rawValue: healthBefore.value.logicProUILocale) == nil,
                  localeRetryID < 906 {
                Thread.sleep(forTimeInterval: 1.5)
                healthBefore = try health(session, id: localeRetryID, phase: "health_before_retry")
                localeRetryID += 1
            }
            let catalogBefore = try catalog(session, id: 3, phase: "catalog_before")
            let baselineTraceList = try traces(session, id: 4)
            let baselineTraceIDs = Set(baselineTraceList.traces.map(\.traceID))
            let traceSeedBody = try traceSeed(session, id: 5)
            let traceList = try traces(session, id: 6)
            let seededTraces = traceList.traces.filter {
                !baselineTraceIDs.contains($0.traceID)
                    && $0.operationID == OperationID.systemSagaExecute.rawValue
                    && $0.phaseCount > 0
                    && TraceID.isValid($0.traceID)
            }
            guard seededTraces.count == 1, let traceSummary = seededTraces.first else {
                throw QualificationTransportError.protocolViolation(
                    "trace_roundtrip: expected one new traced operation with events"
                )
            }
            let traceDetail = try trace(session, id: 7, traceID: traceSummary.traceID)
            guard traceDetail.traceID == traceSummary.traceID,
                  traceDetail.operationID == traceSummary.operationID,
                  traceDetail.phases.first == TracePhase.requestReceived.rawValue,
                  traceDetail.phases.last == TracePhase.resultEmitted.rawValue else {
                throw QualificationTransportError.protocolViolation(
                    "trace_roundtrip: trace identity or events mismatch"
                )
            }
            let negativeBody = try negative(session, id: 8)
            // #373 Phase A: seed a saga JOURNAL record so `system.saga_status` has something to
            // report. Exactly the shape `traceSeed` above already establishes -- the transport
            // arranges the state a read-only probe needs, then probes it. Nothing new is being
            // decided here; `probeParams` has handed `systemGetTrace` a seeded `trace_id` since
            // this file was written.
            //
            // The seed is a REFUSED saga (`feature_disabled`), so no step ever executes and nothing
            // is mutated -- but the journal still records the outcome, which is what
            // `saga_status` reads. A zero-write seed.
            _ = try? sagaSeed(session, id: 9)
            var nextID = 10
            // The trace id the next `system.get_trace` probe should ask for. It starts as the one
            // the round-trip above proved, and is replaced whenever a reader re-seeds.
            var seededTraceID = traceSummary.traceID
            // #373 Phase B: the verified write-and-restore cycles this run produced. Empty until a
            // recipe exists for an operation, which is the honest shape — the artifact has always
            // been emitted and has always been empty.
            var mutationRestoreRecords: [QualificationMutationRestoreRecord] = []
            var operationResults: [String: QualificationOperationResult] = [:]
            for spec in request.operations {
                var response: (text: String, isError: Bool)?
                var responseRequestID: String?
                var responseFailure: String?
                var phaseBRecord: QualificationMutationRestoreRecord?
                var phaseBRefusal: String?
                // `tracks.rename` reuses the negative probe's response below and never reaches the
                // normal dispatch, so its recipe runs HERE rather than inside that branch. Putting
                // it with the others cost a run to find out: the recipe was written, compiled, and
                // silently never fired.
                if spec.id == .tracksRename {
                    do {
                        let cycle = try trackStringRestoreCycle(
                            session, startingAt: nextID, spec: spec, readbackField: "name")
                        mutationRestoreRecords.append(cycle.record)
                        phaseBRecord = cycle.record
                        nextID = cycle.nextID
                    } catch {
                        phaseBRefusal = Self.observedFailureReason(
                            from: error, during: "phase_b recipe")
                        nextID += 20
                    }
                }
                do {
                    if spec.id == .systemSagaExecute {
                        responseRequestID = "5"
                        response = (traceSeedBody.text, traceSeedBody.toolIsError)
                    } else if spec.id == .tracksRename {
                        responseRequestID = "8"
                        response = (negativeBody.text, negativeBody.toolIsError)
                    } else {
                        // #373 Phase A: RE-SEED the trace store immediately before the two
                        // operations that read it.
                        //
                        // The sweep does not run in registry-declaration order — measured
                        // 2026-09-14, it probed `system.clear_traces` (readback-145) BEFORE
                        // `system.get_trace` (149) and `system.list_recent_traces` (155), so the
                        // clear wiped the store and both readers then read an empty one:
                        // `{"traces":[]}` and `element_not_found: No operation trace exists for the
                        // requested trace_id`. Both came back `not_qualified`, and the cause was
                        // the recipe's ordering rather than anything about the operations.
                        //
                        // Fixing the ORDER would work until the order changes again. Seeding here
                        // makes each reader arrange the state it needs, which is the pattern the
                        // trace seed above already establishes and is indifferent to sweep order.
                        // The seed is a REFUSED `saga_execute` — a typed zero-write refusal — so it
                        // records a trace without mutating anything.
                        // NOT SEEDED, and the reason is worth keeping: `tracks.list_library`'s
                        // independent readback is `logic://library/inventory`, which on a fresh
                        // server answers `{"cached":false,"note":"Run logic_library scan to
                        // populate…"}`. Seeding it with `tracks.scan_library` was tried on
                        // 2026-09-14 and does nothing — that resource reads a cache FILE
                        // (`Resources/library-inventory.json` or the Application Support copy) and
                        // `scan_library` returns its presets in the response without ever writing
                        // that file. So the readback source is a file the product does not produce,
                        // and no arrangement this transport can make will satisfy it.
                        //
                        // That is why the operation sits in `knownLiveGateFailures`. It is not a
                        // disagreement between two readings; it is a missing second reading. The
                        // dispositions are to give the operation a readback the product actually
                        // emits, or to waive it with a reason — NOT to seed it, and the seeding
                        // attempt is removed rather than left looking like it helps.
                        // #373 Phase B: operations with a write-and-restore recipe run it here.
                        // A refusal inside the cycle is NOT swallowed into a pass — the record is
                        // simply absent and the operation falls through to the existing zero-write
                        // deferral, which is what "no evidence" should look like.
                        if let field = Self.parameterlessToggleField[spec.id] {
                            do {
                                let cycle = try parameterlessToggleRestoreCycle(
                                    session, startingAt: nextID, spec: spec, readbackField: field)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 12
                            }
                        }
                        if spec.id == .navigateCreateMarker {
                            do {
                                let cycle = try markerCreateRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 40
                            }
                        }
                        if let expected = Self.transportExpectedPlaying[spec.id] {
                            do {
                                let cycle = try transportRestoreCycle(
                                    session, startingAt: nextID, spec: spec,
                                    expectedPlaying: expected)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 16
                            }
                        }
                        if spec.id == .tracksSelect {
                            do {
                                let cycle = try selectionRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 14
                            }
                        }
                        if let field = Self.valueRestoreReadbackField[spec.id] {
                            do {
                                let cycle = try valueRestoreCycle(
                                    session, startingAt: nextID, spec: spec, readbackField: field)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 12
                            }
                        }
                        if let field = Self.booleanToggleReadbackField[spec.id] {
                            do {
                                let cycle = try booleanToggleRestoreCycle(
                                    session, startingAt: nextID, spec: spec, readbackField: field)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                // A recipe that ran and REFUSED is not the same fact as no recipe,
                                // and the old `try?` made them identical — both arrived as the
                                // generic "live mutation requires an operation-specific recipe".
                                // Measured 2026-09-14: `tracks.arm` answers State B with
                                // `verified:false` and `logic://tracks` shows `isArmed` unmoved, so
                                // the cycle refused for a reason worth reading. Carrying it turns a
                                // silent skip into a diagnosis.
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 12
                            }
                        }
                        if spec.id == .systemGetTrace || spec.id == .systemListRecentTraces {
                            let seedID = nextID
                            nextID += 1
                            _ = try? traceSeed(session, id: seedID)
                            // Read the id back rather than take it from the seed's own envelope.
                            // The refusal `saga_execute` emits carries no `trace_id`, so trusting
                            // its body left `seededTraceID` holding the pre-sweep value that
                            // `clear_traces` had already wiped — `get_trace` then asked for a trace
                            // that no longer existed and was refused, which is the same failure
                            // wearing a different cause. The listing is the authority on what the
                            // store currently holds.
                            let listID = nextID
                            nextID += 1
                            if let listed = try? traces(session, id: listID),
                               let newest = listed.traces.first {
                                seededTraceID = newest.traceID
                            }
                        }
                        let responseID = nextID
                        nextID += 1
                        responseRequestID = String(responseID)
                        let probeTimeout: TimeInterval? = faultActive && spec.id == .transportPlay
                            ? spec.deadline.seconds + 5
                            : nil
                        response = try operation(
                            session,
                            id: responseID,
                            spec: spec,
                            traceID: seededTraceID,
                            timeout: probeTimeout
                        )
                    }
                } catch {
                    responseFailure = Self.observedFailureReason(
                        from: error,
                        during: "operation request"
                    )
                }
                let readbackRequestID = "operation-readback-\(nextID)"
                let readbackSource = Self.readbackSource(for: spec)
                var readbackData: Data?
                var readbackFailure: String?
                do {
                    readbackData = try resourceReadback(
                        session,
                        id: nextID,
                        uri: readbackSource,
                        phase: readbackRequestID
                    )
                } catch {
                    readbackFailure = Self.observedFailureReason(
                        from: error,
                        during: "independent readback"
                    )
                }
                nextID += 1
                let typed = response.flatMap {
                    try? Self.decodeInner(
                        $0.text,
                        phase: "operation_probe.\(spec.id.rawValue)"
                    ) as OperationProbeResult
                }
                operationResults[spec.id.rawValue] = QualificationOperationResult(
                    operationID: spec.id.rawValue,
                    tool: spec.tool.rawValue,
                    command: spec.command,
                    mutability: spec.mutability,
                    requestID: responseRequestID,
                    responseData: response.map { Data($0.text.utf8) },
                    isError: response?.isError,
                    state: typed?.state,
                    error: typed?.error,
                    hint: typed?.hint,
                    writeAttempted: typed?.writeAttempted,
                    readbackSource: readbackSource,
                    readbackRequestID: readbackRequestID,
                    readbackData: readbackData,
                    verification: spec.verification,
                    deadline: spec.deadline,
                    failureReason: responseFailure ?? readbackFailure,
                    mutationRestore: phaseBRecord,
                    mutationRestoreRefusal: phaseBRefusal
                )
            }
            let healthAfter = try health(session, id: nextID, phase: "health_after")
            nextID += 1
            let catalogAfter = try catalog(session, id: nextID, phase: "catalog_after")
            let negative = QualificationNegativeResult(
                toolIsError: negativeBody.toolIsError,
                state: negativeBody.body.state,
                error: negativeBody.body.error,
                writeAttempted: negativeBody.body.writeAttempted,
                healthBefore: healthBefore.stableData,
                healthAfter: healthAfter.stableData,
                catalogBefore: catalogBefore.stableData,
                catalogAfter: catalogAfter.stableData
            )
            let outcome = try session.shutdown()
            guard !outcome.forced else {
                throw QualificationTransportError.shutdownTimeout
            }
            guard outcome.status == 0 else {
                throw QualificationTransportError.nonZeroExit(
                    status: outcome.status,
                    stderr: session.stderrTail
                )
            }
            return QualificationDriveResult(
                handshake: handshake,
                health: healthBefore.value,
                catalog: catalogBefore.value,
                expectedOperationCount: request.expectedOperationCount,
                traceList: traceList,
                traceDetail: traceDetail,
                negative: negative,
                observedLocale: healthBefore.value.logicProUILocale,
                operationResults: operationResults,
                wireFrames: session.transcriptFrames,
                mutationRestoreRecords: mutationRestoreRecords,
                failureReason: nil
            )
        } catch {
            let outcome: QualificationSubprocessSession.ShutdownOutcome
            do {
                outcome = try session.shutdown()
            } catch {
                throw error
            }
            if !outcome.forced, outcome.status != 0 {
                throw QualificationTransportError.nonZeroExit(
                    status: outcome.status,
                    stderr: session.stderrTail
                )
            }
            throw error
        }
    }

    private func initialize(_ session: QualificationSubprocessSession) throws -> QualificationHandshake {
        let result: InitializeResult = try session.request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "adr001b-qualification", "version": "1.0"],
            ],
            phase: "handshake",
            timeout: handshakeTimeout
        )
        try session.notify(method: "notifications/initialized")
        return QualificationHandshake(
            protocolVersion: result.protocolVersion,
            serverName: result.serverInfo.name,
            serverVersion: result.serverInfo.version
        )
    }

    private func health(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (value: QualificationHealth, stableData: Data) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": ["command": "health", "params": [:] as [String: Any]],
            ],
            phase: phase
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation("\(phase): tool returned isError")
        }
        let text = try result.text(phase: phase)
        let wire: HealthResult = try Self.decodeInner(text, phase: phase)
        return (
            QualificationHealth(
                logicProRunning: wire.logicProRunning,
                logicProVersion: wire.logicProVersion,
                logicProBundleID: wire.logicProBundleID,
                logicProVariant: wire.logicProVariant,
                logicProUILocale: wire.logicProUILocale,
                processMetadataResolved: wire.processMetadataResolved,
                variants: wire.variants.compactMap { variant in
                    let mapped: LogicVariant
                    switch variant.variant {
                    case LogicProVariant.desktop.rawValue:
                        mapped = .desktop
                    case LogicProVariant.creatorStudio.rawValue:
                        mapped = .creatorStudio
                    default:
                        return nil
                    }
                    return QualificationVariantAvailability(
                        variant: mapped,
                        bundleID: variant.bundleID,
                        installed: variant.installed,
                        running: variant.running
                    )
                }
            ),
            try Self.stableHealthData(text, phase: phase)
        )
    }

    private func catalog(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (value: OperationCatalogSnapshot, stableData: Data) {
        let result: ResourceReadResult = try session.request(
            id: id,
            method: "resources/read",
            params: ["uri": "logic://system/operations"],
            phase: phase
        )
        guard let content = result.contents.first,
              content.uri == "logic://system/operations",
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing operations content")
        }
        return (
            try Self.decodeInner(text, phase: phase),
            try Self.stableCatalogData(text, phase: phase)
        )
    }

    private func traces(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> QualificationTraceList {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "list_recent_traces",
                    "params": ["limit": 10],
                ],
            ],
            phase: "trace_roundtrip"
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation(
                "trace_roundtrip: \(try result.text(phase: "trace_roundtrip"))"
            )
        }
        let wire: TraceListResult = try Self.decodeInner(
            result.text(phase: "trace_roundtrip"),
            phase: "trace_roundtrip"
        )
        guard wire.traceDisabled != true else {
            throw QualificationTransportError.protocolViolation("trace_roundtrip: trace_disabled")
        }
        return QualificationTraceList(traces: wire.traces.map {
            QualificationTraceEntry(
                traceID: $0.traceID,
                operationID: $0.operationID,
                phaseCount: $0.phaseCount,
                readbackState: $0.readbackState
            )
        })
    }

    private func trace(
        _ session: QualificationSubprocessSession,
        id: Int,
        traceID: String
    ) throws -> QualificationTraceDetail {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "get_trace",
                    "params": ["trace_id": traceID],
                ],
            ],
            phase: "trace_get"
        )
        guard result.isError != true else {
            throw QualificationTransportError.protocolViolation("trace_get: tool returned isError")
        }
        let wire: TraceDetailResult = try Self.decodeInner(
            result.text(phase: "trace_get"),
            phase: "trace_get"
        )
        return QualificationTraceDetail(
            traceID: wire.traceID,
            operationID: wire.operationID,
            phases: wire.events.map(\.phase)
        )
    }

    private func operation(
        _ session: QualificationSubprocessSession,
        id: Int,
        spec: OperationSpec,
        traceID: String,
        timeout: TimeInterval? = nil
    ) throws -> (text: String, isError: Bool) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": spec.tool.rawValue,
                "arguments": [
                    "command": spec.command,
                    "params": Self.probeParams(for: spec, traceID: traceID),
                ],
            ],
            phase: "operation_probe.\(spec.id.rawValue)",
            timeout: timeout
        )
        return (
            try result.text(phase: "operation_probe.\(spec.id.rawValue)"),
            result.isError == true
        )
    }

    /// #373 Phase B: the mutating operations whose recipe is a reversible boolean toggle, and the
    /// `logic://tracks` field that independently reports each one.
    ///
    /// A table rather than a switch because the addition it invites is a ROW — an operation, plus
    /// the field a reader can check it against. An operation with no honest independent field does
    /// not belong here and must not be given one that merely correlates.
    static let booleanToggleReadbackField: [OperationID: String] = [
        .tracksMute: "isMuted",
        .tracksSolo: "isSoloed",
        .tracksArm: "isArmed",
    ]

    /// One tool call with CALLER-SUPPLIED params.
    ///
    /// `operation(…)` above always sends `probeParams`, which for a mutating operation is the
    /// deliberate no-write probe. A Phase-B recipe has to send a real request, so it needs this.
    /// Kept separate rather than adding a parameter to `operation` so the no-write probe stays the
    /// only thing the sweep itself can send.
    private func invoke(
        _ session: QualificationSubprocessSession,
        id: Int,
        tool: String,
        command: String,
        params: [String: Any],
        phase: String
    ) throws -> (text: String, isError: Bool) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: ["name": tool, "arguments": ["command": command, "params": params]],
            phase: phase
        )
        return (try result.text(phase: phase), result.isError == true)
    }

    /// Read one track's mute state from the independent `logic://tracks` resource.
    ///
    /// The recipe below needs the SAME reading three times — before, after the write, and after the
    /// restore — and it must come from a source other than the write's own answer, or the cycle
    /// proves nothing. `logic://tracks` is that source.
    private func observedTrackFlag(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String
    ) throws -> (value: Bool, raw: String) {
        // REFRESH FIRST. `logic://tracks` is served from a poller-backed cache, and without this
        // the read after the write returns the pre-write value — measured 2026-09-14: mute moved
        // `true -> false` in Logic and three consecutive reads still answered `true`, while the
        // same sequence with a refresh between them reported `true -> false -> true`. A cycle built
        // on the unrefreshed read would have compared a write against its own stale precondition
        // and called it a failure; the guard below caught exactly that and refused, which is how
        // this was found.
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(session, id: id + 1, uri: "logic://tracks", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]],
              trackIndex < rows.count,
              let value = rows[trackIndex][field] as? Bool else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks did not report \(field) for track \(trackIndex)"
            )
        }
        return (value, raw)
    }

    /// #373 Phase B: the mutating operations whose recipe restores a VALUE rather than flipping a
    /// flag, and the `logic://tracks` field that independently reports each one.
    static let valueRestoreReadbackField: [OperationID: String] = [
        .mixerSetVolume: "volume",
        .mixerSetPan: "pan",
    ]

    private func observedTrackValue(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String
    ) throws -> (value: Double, raw: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(session, id: id + 1, uri: "logic://tracks", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]],
              trackIndex < rows.count,
              let value = rows[trackIndex][field] as? Double else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks did not report \(field) for track \(trackIndex)"
            )
        }
        return (value, raw)
    }

    /// #373 Phase B for a continuous control: pre-state → move → readback → restore → readback.
    ///
    /// WHAT THIS DOES NOT ASSERT, and why. The observed value is NOT required to equal the
    /// requested one. Measured 2026-09-14: asking for volume `0.8579` lands `0.8636`, and pan
    /// `0.1079` lands `0.1654` — Logic exposes these faders in detents, and the operation reports
    /// `verified: true` against its own observation. Demanding equality here would fail a control
    /// that behaved correctly, which is a grader asserting something the surface never promised.
    ///
    /// What IS asserted is the pair that actually carries the claim:
    ///
    ///   * the value MOVED — an operation that did nothing cannot pass by agreeing with a stale
    ///     reading, which is the failure mode the boolean cycle found in the poller cache;
    ///   * the restore returns the pre-state EXACTLY, read back rather than assumed. Both measured
    ///     operations restore to the original bit pattern, so exactness is a real bar here and not
    ///     a hopeful one.
    private func valueRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        let trackIndex = 0
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTrackValue(
            session, id: readStep(), trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.pre_state")
        // Move toward the middle of the range, so a control already at an extreme still has
        // somewhere to go. 0.1 is far enough to clear any detent the measurements showed.
        let target = pre.value > 0.5 ? max(0.1, pre.value - 0.1) : min(0.9, pre.value + 0.1)
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, readbackField: target], phase: "phase_b.mutation")
        guard mutation.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request")
        }
        let after = try observedTrackValue(
            session, id: readStep(), trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.readback")
        guard after.value != pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) did not move from \(pre.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, readbackField: pre.value], phase: "phase_b.restore")
        guard restore.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore")
        }
        let restored = try observedTrackValue(
            session, id: readStep(), trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.restore_readback")
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) not restored — observed "
                    + "\(restored.value), expected \(pre.value)")
        }
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    /// #373 Phase B: transport operations whose effect is a boolean the transport resource reports,
    /// mapped to the state each one is supposed to leave behind.
    static let transportExpectedPlaying: [OperationID: Bool] = [
        .transportPlay: true,
        .transportStop: false,
    ]

    private func observedPlaying(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (playing: Bool, raw: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(
            session, id: id + 1, uri: "logic://transport/state", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let state = payload["state"] as? [String: Any],
              let playing = state["isPlaying"] as? Bool else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://transport/state did not report isPlaying")
        }
        return (playing, raw)
    }

    /// #373 Phase B for transport. Same five steps, with one extra obligation the others do not
    /// have: the operation must have somewhere to GO.
    ///
    /// `transport.play` proves nothing if the transport is already playing, and `stop` proves
    /// nothing if it is already stopped — the readback would agree without the operation doing
    /// anything, which is the exact shape the poller cache produced for mute. So the precondition
    /// is forced with the INVERSE operation first, and the session's real pre-state is recorded
    /// before any of that so the restore returns to where the operator actually was, not to the
    /// state this recipe manufactured.
    private func transportRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        expectedPlaying: Bool
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }
        let inverse = expectedPlaying ? "stop" : "play"

        let pre = try observedPlaying(session, id: readStep(), phase: "phase_b.pre_state")
        if pre.playing == expectedPlaying {
            _ = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: inverse,
                params: [:], phase: "phase_b.precondition")
            let staged = try observedPlaying(
                session, id: readStep(), phase: "phase_b.precondition_readback")
            guard staged.playing != expectedPlaying else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.precondition: could not stage isPlaying != \(expectedPlaying)")
            }
        }
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: [:], phase: "phase_b.mutation")
        guard mutation.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request")
        }
        let after = try observedPlaying(session, id: readStep(), phase: "phase_b.readback")
        guard after.playing == expectedPlaying else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: isPlaying is \(after.playing), expected \(expectedPlaying)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue,
            command: pre.playing ? "play" : "stop", params: [:], phase: "phase_b.restore")
        let restored = try observedPlaying(
            session, id: readStep(), phase: "phase_b.restore_readback")
        guard restored.playing == pre.playing else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: isPlaying is \(restored.playing), expected \(pre.playing)")
        }
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    /// #373 Phase B for `tracks.select`. The moved thing is WHICH row carries `isSelected`, so the
    /// cycle checks both ends: the new row gained it and the old row lost it. Checking only the new
    /// row would pass a selection that added rather than moved.
    private func selectionRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTrackFlag(
            session, id: readStep(), trackIndex: 0, field: "isSelected",
            phase: "phase_b.pre_state")
        // Select row 1 when row 0 holds the selection, and row 0 otherwise — always a real move.
        let target = pre.value ? 1 : 0
        let original = pre.value ? 0 : 1
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": target], phase: "phase_b.mutation")
        guard mutation.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request")
        }
        let gained = try observedTrackFlag(
            session, id: readStep(), trackIndex: target, field: "isSelected",
            phase: "phase_b.readback")
        let lost = try observedTrackFlag(
            session, id: readStep(), trackIndex: original, field: "isSelected",
            phase: "phase_b.readback_other")
        guard gained.value, !lost.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: selection did not MOVE — target \(gained.value), "
                    + "original \(lost.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": original], phase: "phase_b.restore")
        let restored = try observedTrackFlag(
            session, id: readStep(), trackIndex: original, field: "isSelected",
            phase: "phase_b.restore_readback")
        guard restored.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: original row did not regain the selection")
        }
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: gained.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    /// The index of the marker carrying `name`, or nil. Marker indices are NOT append order: the
    /// list is sorted by POSITION and `create_marker` places its marker at the playhead, so a new
    /// marker lands wherever its bar sorts to. Assuming it arrives last is what made an earlier
    /// version of this recipe delete SOMEBODY ELSE'S marker while its count check still balanced —
    /// the cycle passed and the project lost a marker it was supposed to leave alone.
    private func markerIndex(named name: String, in raw: String) -> Int? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { return nil }
        return rows.firstIndex { ($0["name"] as? String) == name }
    }

    private func observedMarkerCount(
        _ session: QualificationSubprocessSession,
        id: Int,
        expecting: Int?,
        phase: String
    ) throws -> (count: Int, raw: String, spent: Int) {
        // POLLS rather than reads once. The marker list settles more slowly than the other
        // resources this file reads: measured 2026-09-14, a delete that had actually taken effect
        // still read as present immediately after `refresh_cache`, and answered correctly a couple
        // of seconds later. Reading once would make this recipe flaky and — worse — would report a
        // working operation as one that did nothing.
        //
        // `expecting` is what the caller is waiting FOR, and nil means "just read". Waiting is not
        // relaxing the assertion: the loop exits early only on the value the caller already
        // decided is correct, and a wrong value simply runs out the budget and is returned as it
        // is, to be judged by the guard that asked.
        var spent = 0
        var last: (Int, String) = (-1, "")
        for _ in 0..<6 {
            _ = try? invoke(
                session, id: id + spent, tool: "logic_system", command: "refresh_cache",
                params: [:], phase: "\(phase).refresh")
            spent += 1
            let data = try resourceReadback(
                session, id: id + spent, uri: "logic://markers", phase: phase)
            spent += 1
            let raw = String(decoding: data, as: UTF8.self)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let rows = (object?["data"] as? [[String: Any]]) ?? []
            last = (rows.count, raw)
            if expecting == nil || rows.count == expecting { break }
        }
        return (last.0, last.1, spent)
    }

    /// #373 Phase B for a STRING field on a track — `tracks.rename` today.
    ///
    /// The probe name is deliberately unlikely and the restore writes the original back verbatim,
    /// so a failure between the two leaves a track called `qualification_phase_b_probe` rather
    /// than a plausible-looking wrong name. A cycle that renames and cannot put it back should be
    /// obvious in the project, not camouflaged.
    private func trackStringRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }
        let probeValue = "qualification_phase_b_probe"

        let pre = try observedTrackString(
            session, id: readStep(), trackIndex: 0, field: readbackField,
            phase: "phase_b.pre_state")
        guard pre.value != probeValue else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: the track already carries the probe value — an earlier run "
                    + "left it behind and this cycle cannot tell a move from a no-op")
        }
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": 0, readbackField: probeValue], phase: "phase_b.mutation")
        guard mutation.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request")
        }
        var needsRestore = true
        defer {
            if needsRestore {
                var cleanupID = nextID + 900
                for _ in 0..<4 {
                    _ = try? invoke(
                        session, id: cleanupID, tool: spec.tool.rawValue, command: spec.command,
                        params: ["index": 0, readbackField: pre.value], phase: "phase_b.cleanup")
                    cleanupID += 1
                    guard let seen = try? observedTrackString(
                        session, id: cleanupID, trackIndex: 0, field: readbackField,
                        phase: "phase_b.cleanup_readback") else { break }
                    cleanupID += 2
                    if seen.value == pre.value { break }
                }
            }
        }
        let after = try observedTrackString(
            session, id: readStep(), trackIndex: 0, field: readbackField,
            phase: "phase_b.readback")
        guard after.value == probeValue else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) is \(after.value), expected the probe value")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": 0, readbackField: pre.value], phase: "phase_b.restore")
        guard restore.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore")
        }
        let restored = try observedTrackString(
            session, id: readStep(), trackIndex: 0, field: readbackField,
            phase: "phase_b.restore_readback")
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) is \(restored.value), expected "
                    + "\(pre.value)")
        }
        needsRestore = false
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    private func observedTrackString(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String
    ) throws -> (value: String, raw: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(session, id: id + 1, uri: "logic://tracks", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]],
              trackIndex < rows.count,
              let value = rows[trackIndex][field] as? String else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks did not report \(field) for track \(trackIndex)")
        }
        return (value, raw)
    }

    /// #373 Phase B for a PARAMETERLESS toggle, where the same call is both the mutation and the
    /// restore.
    ///
    /// `transport.toggle_cycle` takes nothing and flips a flag, so unlike `tracks.mute` there is no
    /// value to ask for — the second call is what puts it back. That makes the restore assertion
    /// carry more weight here, not less: if the operation is not idempotent in the way its name
    /// claims, the flag ends up somewhere other than where it started and the cycle refuses.
    private func parameterlessToggleRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTransportFlag(
            session, id: readStep(), field: readbackField, phase: "phase_b.pre_state")
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: [:], phase: "phase_b.mutation")
        guard mutation.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request")
        }
        let after = try observedTransportFlag(
            session, id: readStep(), field: readbackField, phase: "phase_b.readback")
        guard after.value == !pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) is \(after.value), expected \(!pre.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: [:], phase: "phase_b.restore")
        guard restore.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the second call")
        }
        let restored = try observedTransportFlag(
            session, id: readStep(), field: readbackField, phase: "phase_b.restore_readback")
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) is \(restored.value), expected "
                    + "\(pre.value) — the second call did not put it back")
        }
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    private func observedTransportFlag(
        _ session: QualificationSubprocessSession,
        id: Int,
        field: String,
        phase: String
    ) throws -> (value: Bool, raw: String) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(
            session, id: id + 1, uri: "logic://transport/state", phase: phase)
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let state = payload["state"] as? [String: Any],
              let value = state[field] as? Bool else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://transport/state did not report \(field)")
        }
        return (value, raw)
    }

    /// Parameterless transport toggles and the transport-state flag each one flips.
    ///
    /// `transport.record` is deliberately ABSENT. It reaches State A and moves `isRecording`, so it
    /// would qualify — and it also records into the project, which makes its restore an undo of a
    /// region rather than a second toggle. That belongs to the destructive phase with a disposable
    /// fixture, not here, and adding it would have bought a passing count at the price of editing
    /// the project this recipe is supposed to leave alone.
    static let parameterlessToggleField: [OperationID: String] = [
        .transportToggleCycle: "isCycleEnabled",
        .transportToggleMetronome: "isMetronomeEnabled",
    ]

    /// #373 Phase B for a CREATE, whose restore is a delete.
    ///
    /// The other machines move something that already exists and put it back. This one brings
    /// something into being and must remove it, which makes the restore the part that matters: a
    /// cycle that created a marker and left it behind would have changed the project while
    /// reporting success.
    private func markerCreateRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let probeName = "qualification_phase_b_probe"
        let pre = try observedMarkerCount(
            session, id: nextID, expecting: nil, phase: "phase_b.pre_state")
        guard markerIndex(named: probeName, in: pre.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: a marker named \(probeName) is already in the project — an "
                    + "earlier run left it, and this cycle cannot tell its own marker from that one")
        }
        nextID += pre.spent
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command,
            params: ["name": probeName], phase: "phase_b.mutation")
        nextID += 1
        guard mutation.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request")
        }
        // FROM HERE ON A MARKER EXISTS, so every exit has to remove it. Measured 2026-09-14: a run
        // whose cycle refused after the create left `qualification_phase_b_probe` in the project,
        // and the NEXT run's `create_marker` then refused because of it — one failure became a
        // permanent one, and the fixture needed manual cleaning. A create-shaped recipe that can
        // throw between the create and the delete is a recipe that edits the project on failure.
        var createdMarkerNeedsRemoval = true
        defer {
            if createdMarkerNeedsRemoval {
                // THE CLEANUP VERIFIES. A first version issued one best-effort delete and moved on,
                // and a live run still left `qualification_phase_b_probe` in the project —
                // the marker list settles slowly enough that a single unchecked delete is not a
                // removal, it is a request. An unverified cleanup is the same shape as the
                // unverified success claims this whole change exists to remove, so it retries until
                // the count is back where it started or its budget runs out.
                var cleanupID = nextID + 900
                for _ in 0..<4 {
                    guard let seen = try? observedMarkerCount(
                        session, id: cleanupID, expecting: nil, phase: "phase_b.cleanup_readback"
                    ) else { break }
                    cleanupID += seen.spent
                    guard let index = markerIndex(named: probeName, in: seen.raw) else { break }
                    _ = try? invoke(
                        session, id: cleanupID, tool: spec.tool.rawValue, command: "delete_marker",
                        params: ["index": index], phase: "phase_b.cleanup")
                    cleanupID += 1
                }
            }
        }

        let after = try observedMarkerCount(
            session, id: nextID, expecting: pre.count + 1, phase: "phase_b.readback")
        nextID += after.spent
        guard after.count == pre.count + 1 else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: marker count is \(after.count), expected \(pre.count + 1)")
        }
        // Delete the one just added, found BY NAME. See `markerIndex(named:in:)`.
        guard let createdIndex = markerIndex(named: probeName, in: after.raw) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: the marker count rose but no row carries \(probeName) — the "
                    + "cycle cannot identify what it created and will not delete by guess")
        }
        let restore = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: "delete_marker",
            params: ["index": createdIndex], phase: "phase_b.restore")
        nextID += 1
        guard restore.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: delete_marker refused — the probe marker is still in the project")
        }
        let restored = try observedMarkerCount(
            session, id: nextID, expecting: pre.count, phase: "phase_b.restore_readback")
        nextID += restored.spent
        guard restored.count == pre.count, markerIndex(named: probeName, in: restored.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: marker count is \(restored.count), expected "
                    + "\(pre.count), and \(probeName) must be absent — a balanced count is not "
                    + "proof the right marker went")
        }
        // The restore is confirmed, so the cleanup above has nothing left to do. Clearing the flag
        // here rather than earlier keeps the window it covers exactly the window where a marker
        // exists and has not been proven gone.
        createdMarkerNeedsRemoval = false
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    /// ADR-001-c / #373 Phase B: the write-and-readback cycle, on one operation.
    ///
    /// The issue's own status line said Phase B "needs a write-and-read-back qualification mode,
    /// which does not exist" — and the record type for it DID exist, with exactly these five
    /// fields, while nothing in the tree constructed one. This is that constructor.
    ///
    /// `tracks.set_mute` is the first operation to get a recipe because it is the safest shape the
    /// registry has: `Mutability.mutating`, reversible by definition, and with an independent
    /// readback (`logic://tracks`) that is not the write's own answer. The cycle is
    /// pre-state → mutation → readback → restore → restore-readback, and EVERY step is checked:
    ///
    ///   * the mutation must actually flip the observed state, or an operation that did nothing
    ///     would pass by agreeing with a stale reading;
    ///   * the restore must return it to the pre-state EXACTLY, read back rather than assumed.
    ///
    /// A record is returned ONLY when all of that held. There is no failure case in the record
    /// type, and that absence is the guard: a cycle that did not verify produces no evidence, so
    /// `status` cannot see one.
    private func booleanToggleRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        readbackField: String
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        let trackIndex = 0
        var nextID = id
        // Each observation spends TWO ids — a refresh and the resource read — so the step counter
        // advances by two for reads and one for writes.
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTrackFlag(
            session, id: readStep(), trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.pre_state")
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, "enabled": !pre.value], phase: "phase_b.mutation")
        guard mutation.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request")
        }
        let after = try observedTrackFlag(
            session, id: readStep(), trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.readback")
        guard after.value == !pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) did not move — observed \(after.value), "
                    + "expected \(!pre.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, "enabled": pre.value], phase: "phase_b.restore")
        guard restore.isError == false else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore")
        }
        let restored = try observedTrackFlag(
            session, id: readStep(), trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.restore_readback")
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) not restored — observed "
                    + "\(restored.value), expected \(pre.value)")
        }
        return (
            QualificationMutationRestoreRecord(
                operationID: spec.id.rawValue,
                preState: pre.raw,
                mutation: mutation.text,
                readback: after.raw,
                restore: restore.text,
                restoreReadback: restored.raw
            ),
            nextID
        )
    }

    /// Inputs shared by the non-mutating operation probes.
    ///
    /// `system.clear_traces` receives `confirmed:true`: its destructive scope is the in-process
    /// trace store, the runner reads the trace evidence it needs before entering the operation
    /// loop, and the operation itself writes the durable receipt its oracle verifies. Sending
    /// `false` only exercised the confirmation refusal and permanently misclassified correct
    /// validation as a live-gate failure.
    /// One spelling of the key, shared by the seed and the probe. Two literals would be two
    /// places to keep in step, and the failure mode is silent: `saga_status` would look up a
    /// record nothing wrote and report exactly what it reported before the seed existed.
    static let sagaProbeIdempotencyKey = "qualification-read-probe"
    static let qualificationAudioProbePath = "/System/Library/Sounds/Ping.aiff"

    static func probeParams(for spec: OperationSpec, traceID: String) -> [String: Any] {
        if spec.mutability == .mutating {
            return ["__adr001b_no_write_probe": true]
        }
        switch spec.id {
        case .systemListRecentTraces:
            return ["limit": 10]
        case .systemGetTrace:
            return ["trace_id": traceID]
        case .systemClearTraces:
            return ["confirmed": true]
        case .systemHelp:
            return ["category": "system"]
        case .systemSagaPreflight:
            return ["idempotency_key": Self.sagaProbeIdempotencyKey, "steps": []]
        case .systemSagaStatus:
            return ["idempotency_key": Self.sagaProbeIdempotencyKey]

        // #373 Phase A established the semantic oracle surface. These probes provide documented,
        // deterministic inputs without weakening any operation's validation.
        case .tracksResolvePath:
            // A LIBRARY path classifier, not a filesystem one. Its oracle accepts either contract:
            // a hit must name `matchedPath` and classify the node, a miss must say why. This path
            // is a deterministic MISS, chosen on purpose -- a hit depends on what patches the
            // machine happens to have installed, and a gate whose result varies by host is not a
            // gate. The limitation is real and stated: the HIT branch stays unexercised here, and
            // covering it needs a fixture library rather than a different string.
            return ["path": "__qualification_probe__/definitely-absent"]
        case .audioAnalyzeFile:
            // The oracle requires `verification.status ∈ {pass, warn}` -- a `fail` arrives with
            // isError and is classified before the oracle runs, so accepting it could only launder
            // a failed analysis into a semantic pass. That means a REAL, analysable file.
            //
            // A macOS system sound rather than a committed fixture, and the trade is deliberate:
            // a repo fixture is repo-controlled but the binary has no way to locate it at run time,
            // which would need a new option threaded through the transport. This file is externally
            // owned, which is the weaker guarantee -- but if it ever disappears, `analyze_file`
            // returns its typed refusal and the case defers exactly as it does today. The downside
            // is the current state, so this cannot regress anything.
            //
            // Measured: 1.502 s, 48 kHz, `verification.status == "pass"`.
            return ["path": Self.qualificationAudioProbePath]
        case .audioAnalyzeSpectrum:
            // The spectral commands share the same documented non-empty audio path precondition
            // as `analyze_file`. Reusing the measured system sound exercises the real analysis
            // path; omitting it merely tests that the dispatcher refuses missing input.
            return ["path": Self.qualificationAudioProbePath]
        case .audioRecommendEQ:
            // Ping's measured level confidence is 0.538. Its default 0.6 recommendation threshold
            // correctly returns the safe `level_below_minimum` branch, but this probe needs to
            // exercise the recommendation branch and its semantic constraints. 0.5 is still a
            // caller-supplied, finite documented value, not a change to the operation's policy.
            return ["path": Self.qualificationAudioProbePath, "minimum_level": 0.5]
        case .projectExportPlan:
            // A DRY RUN whose oracle allows `status ∈ {planned, degraded}`. An absent project is
            // honestly `degraded` and still returns a complete, schema-valid manifest, so the probe
            // needs no fixture project and no path that varies by host. `output_root` is required
            // too -- omitting it refuses with `output_root must be an absolute local path`, which
            // is why supplying only `project` still failed.
            return [
                "project": "/__qualification_probe__/absent.logicx",
                "output_root": "/tmp",
            ]
        case .pluginsGetInventory:
            // Track 0 exists whenever a project does: `project.new` reports
            // `mandatory_track_created`. On a projectless Logic this still returns a typed refusal
            // rather than the bare `invalid_params` an absent parameter produced.
            return ["track": 0]

        default:
            return [:]
        }
    }

    static func readbackSource(for spec: OperationSpec) -> String {
        switch spec.tool {
        case .logicTransport:
            return "logic://transport/state"
        case .logicMixer, .logicPlugins:
            return "logic://mixer"
        case .logicNavigate:
            return "logic://markers"
        case .logicEdit:
            return "logic://tracks"
        case .logicProject:
            switch spec.id {
            case .projectGetRegions:
                return "logic://tracks"
            case .projectAudit:
                return "logic://project/audit"
            case .projectCleanupPlan, .projectCleanupApply:
                return "logic://project/cleanup-plan"
            default:
                return "logic://project/info"
            }
        case .logicMidi:
            return "logic://midi/ports"
        case .logicTracks:
            switch spec.id {
            case .tracksListLibrary, .tracksScanLibrary, .tracksResolvePath,
                 .tracksScanPluginPresets:
                return "logic://library/inventory"
            default:
                return "logic://tracks"
            }
        case .logicAudio:
            return "logic://system/health"
        case .logicSystem:
            switch spec.id {
            case .systemListRecentTraces, .systemGetTrace, .systemClearTraces, .systemHelp:
                return "logic://system/operations"
            default:
                return "logic://system/health"
            }
        }
    }

    static func observedFailureReason(
        from error: Error,
        during observation: String
    ) -> String {
        if let transportError = error as? QualificationTransportError,
           case .requestTimeout = transportError {
            return "\(observation) timeout: \(error)"
        }
        return "\(observation) failed: \(error)"
    }

    private func resourceReadback(
        _ session: QualificationSubprocessSession,
        id: Int,
        uri: String,
        phase: String
    ) throws -> Data {
        let result: ResourceReadResult = try session.request(
            id: id,
            method: "resources/read",
            params: ["uri": uri],
            phase: phase
        )
        guard let content = result.contents.first,
              content.uri == uri,
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing readback content")
        }
        return Data(text.utf8)
    }

    private func negative(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> (toolIsError: Bool, body: NegativeResult, text: String) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_tracks",
                "arguments": [
                    "command": "rename",
                    "params": ["track_index": 1],
                ],
            ],
            phase: "negative_failclosed"
        )
        let text = try result.text(phase: "negative_failclosed")
        let body: NegativeResult = try Self.decodeInner(
            text,
            phase: "negative_failclosed"
        )
        return (result.isError == true, body, text)
    }

    /// Seed a saga journal record under the key `probeParams` hands `system.saga_status`.
    ///
    /// Deliberately tolerant: the qualification must not fail because a SETUP step did not take.
    /// If this does not land, `saga_status` reports `element_not_found` and defers exactly as it
    /// did before -- the downside is the previous behaviour, so the seed cannot make things worse.
    @discardableResult
    private func sagaSeed(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> Bool {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "saga_execute",
                    "params": [
                        "idempotency_key": Self.sagaProbeIdempotencyKey,
                        "steps": [] as [Any],
                    ],
                ],
            ],
            phase: "saga_seed"
        )
        return result.isError == true
    }

    private func traceSeed(
        _ session: QualificationSubprocessSession,
        id: Int
    ) throws -> (toolIsError: Bool, body: OperationProbeResult, text: String) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: [
                "name": "logic_system",
                "arguments": [
                    "command": "saga_execute",
                    "params": [:] as [String: Any],
                ],
            ],
            phase: "trace_seed"
        )
        let text = try result.text(phase: "trace_seed")
        let body: OperationProbeResult = try Self.decodeInner(text, phase: "trace_seed")
        guard result.isError == true,
              body.state == "C",
              body.error == "invalid_params",
              body.writeAttempted == false else {
            throw QualificationTransportError.protocolViolation(
                "trace_seed: expected typed zero-write refusal"
            )
        }
        return (true, body, text)
    }

    private static func decodeInner<Value: Decodable>(
        _ text: String,
        phase: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid typed JSON")
        }
    }

    private static func stableHealthData(_ text: String, phase: String) throws -> Data {
        guard var object = try jsonObject(text, phase: phase) as? [String: Any] else {
            throw QualificationTransportError.protocolViolation("\(phase): health is not an object")
        }
        object.removeValue(forKey: "process")
        if var cache = object["cache"] as? [String: Any] {
            cache.removeValue(forKey: "transport_age_sec")
            object["cache"] = cache
        }
        if var mcu = object["mcu"] as? [String: Any] {
            mcu.removeValue(forKey: "last_feedback_at")
            mcu.removeValue(forKey: "feedback_stale")
            object["mcu"] = mcu
        }
        if let channels = object["channels"] as? [[String: Any]] {
            object["channels"] = channels.map { channel in
                var stable = channel
                stable.removeValue(forKey: "latency_ms")
                return stable
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func stableCatalogData(_ text: String, phase: String) throws -> Data {
        guard var object = try jsonObject(text, phase: phase) as? [String: Any] else {
            throw QualificationTransportError.protocolViolation("\(phase): catalog is not an object")
        }
        object.removeValue(forKey: "generated_at")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonObject(_ text: String, phase: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid JSON")
        }
    }
}

private struct InitializeResult: Decodable {
    struct ServerInfo: Decodable {
        let name: String
        let version: String
    }

    let protocolVersion: String
    let serverInfo: ServerInfo
}

private struct ToolCallResult: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
    }

    let content: [Content]
    let isError: Bool?

    func text(phase: String) throws -> String {
        guard let content = content.first(where: { $0.type == "text" }),
              let text = content.text else {
            throw QualificationTransportError.protocolViolation("\(phase): missing text content")
        }
        return text
    }
}

private struct ResourceReadResult: Decodable {
    struct Content: Decodable {
        let uri: String
        let text: String?
    }

    let contents: [Content]
}

private struct HealthResult: Decodable, Equatable {
    struct VariantAvailability: Decodable, Equatable {
        let variant: String
        let bundleID: String
        let installed: Bool
        let running: Bool

        enum CodingKeys: String, CodingKey {
            case variant
            case bundleID = "bundle_id"
            case installed
            case running
        }
    }

    let logicProRunning: Bool
    let logicProVersion: String
    let logicProBundleID: String
    let logicProVariant: String
    let logicProUILocale: String
    let processMetadataResolved: Bool
    let variants: [VariantAvailability]

    enum CodingKeys: String, CodingKey {
        case logicProRunning = "logic_pro_running"
        case logicProVersion = "logic_pro_version"
        case logicProBundleID = "logic_pro_bundle_id"
        case logicProVariant = "logic_pro_variant"
        case logicProUILocale = "logic_pro_ui_locale"
        case processMetadataResolved = "process_metadata_resolved"
        case variants = "logic_pro_variants"
    }
}

private struct TraceListResult: Decodable {
    struct Trace: Decodable {
        let traceID: String
        let operationID: String
        let phaseCount: Int
        let readbackState: String?

        enum CodingKeys: String, CodingKey {
            case traceID = "trace_id"
            case operationID = "operation_id"
            case phaseCount = "phase_count"
            case readbackState = "readback_state"
        }
    }

    let traces: [Trace]
    let traceDisabled: Bool?

    enum CodingKeys: String, CodingKey {
        case traces
        case traceDisabled = "trace_disabled"
    }
}

private struct TraceDetailResult: Decodable {
    struct Event: Decodable {
        let phase: String
    }

    let traceID: String
    let operationID: String
    let events: [Event]

    enum CodingKeys: String, CodingKey {
        case traceID = "trace_id"
        case operationID = "operation_id"
        case events
    }
}

private struct OperationProbeResult: Decodable {
    let state: String?
    let error: String?
    let hint: String?
    let writeAttempted: Bool?
    let traceID: String?

    enum CodingKeys: String, CodingKey {
        case state
        case error
        case hint
        case writeAttempted = "write_attempted"
        case traceID = "trace_id"
    }
}

private struct NegativeResult: Decodable {
    let state: String
    let error: String
    let writeAttempted: Bool

    enum CodingKeys: String, CodingKey {
        case state
        case error
        case writeAttempted = "write_attempted"
    }
}

private struct RPCResponse<Result: Decodable>: Decodable {
    struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    let jsonrpc: String
    let id: Int
    let result: Result?
    let error: RPCError?
}


/// One `read(2)` on a file handle, without Foundation's exceptions and without its blocking.
///
/// #843. Two Foundation APIs were tried here and both are wrong for a pipe carrying small frames:
///
///   * `availableData` returns what is there, which is the right SHAPE, but it raises an
///     Objective-C `NSFileHandleOperationException` when the descriptor goes bad — and a Swift
///     `catch` cannot see one, so it unwinds past the handler and kills the process.
///   * `read(upToCount:)` throws a Swift error like it should, but it WAITS for the count. Measured
///     2026-09-09: swapping it in made the qualification transport time out on its handshake, a
///     small frame that never fills a 64 KiB request. The suite went from 27 seconds green to a
///     45-second `timeout:handshake`.
///
/// POSIX `read` has both properties: it returns whatever is available, and it reports failure
/// through the return value rather than by unwinding. `EINTR` is retried; anything else is an
/// error the caller can route. Zero bytes means end of file, exactly as an empty `Data` did.
private func readAvailable(_ handle: FileHandle, upTo limit: Int = 64 * 1024) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: limit)
    while true {
        let n = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, limit) }
        if n >= 0 { return Data(buffer.prefix(n)) }
        if errno == EINTR { continue }
        throw QualificationTransportError.malformedFrame(
            "read failed on fd \(handle.fileDescriptor): errno \(errno)")
    }
}

private final class QualificationSubprocessSession: @unchecked Sendable {
    struct ShutdownOutcome {
        let status: Int32
        let forced: Bool
    }

    private let request: QualificationDriveRequest
    private let requestTimeout: TimeInterval
    private let shutdownGrace: TimeInterval
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let frames = QualificationFrameQueue()
    private let stderr = QualificationStderrBuffer()
    private let readers = DispatchGroup()
    private let exit = QualificationProcessExit()
    private let stateLock = NSLock()
    private var started = false
    private var shutdownOutcome: ShutdownOutcome?
    private var framesTranscript: [QualificationWireFrame] = []

    init(
        request: QualificationDriveRequest,
        requestTimeout: TimeInterval,
        shutdownGrace: TimeInterval
    ) {
        self.request = request
        self.requestTimeout = requestTimeout
        self.shutdownGrace = shutdownGrace
    }

    var stderrTail: String { stderr.text }

    var transcriptFrames: [QualificationWireFrame] {
        stateLock.withLock { framesTranscript }
    }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw QualificationTransportError.launchFailed("not executable: \(request.executableURL.path)")
        }
        try verifyExecutableIdentity()
        // #394: qualification now attests the SHIPPED DEFAULT for ADR-002
        // target_ref (default ON), not the `=0` kill-switch it used to pin. The
        // session-random target/trace IDs this surfaces are ID-normalized (made
        // cross-run stable in the ID dimension) by `QualificationTranscriptNormalizer`
        // at transcript-emit time. See `QualificationTransport.qualificationEnvironment`.
        let environment = QualificationTransport.qualificationEnvironment(
            base: request.environment
        )
        process.executableURL = request.executableURL.standardizedFileURL
        process.currentDirectoryURL = request.executableURL.deletingLastPathComponent()
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        exit.start(process)
        do {
            try process.run()
            try verifyExecutableIdentity()
        } catch {
            if process.isRunning { process.terminate() }
            throw QualificationTransportError.launchFailed(String(describing: error))
        }
        stateLock.lock()
        started = true
        stateLock.unlock()
        startReaders()
    }

    private func verifyExecutableIdentity() throws {
        guard let expected = request.expectedExecutableSHA256 else { return }
        let data = try Data(contentsOf: request.executableURL, options: .mappedIfSafe)
        guard SupportBundleBuilder.sha256(data) == expected else {
            throw QualificationTransportError.launchFailed("qualification executable changed")
        }
    }

    func request<Result: Decodable>(
        id: Int,
        method: String,
        params: [String: Any],
        phase: String,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        try writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ], direction: .request, operationID: phase)
        let data = try frames.response(id: id, phase: phase, timeout: timeout ?? requestTimeout)
        record(direction: .response, operationID: phase, data: data)
        let response: RPCResponse<Result>
        do {
            response = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
        } catch {
            throw QualificationTransportError.protocolViolation("\(phase): invalid response shape")
        }
        guard response.jsonrpc == "2.0", response.id == id else {
            throw QualificationTransportError.protocolViolation("\(phase): mismatched JSON-RPC envelope")
        }
        if let error = response.error {
            throw QualificationTransportError.protocolViolation(
                "\(phase): rpc \(error.code) \(error.message)"
            )
        }
        guard let result = response.result else {
            throw QualificationTransportError.protocolViolation("\(phase): missing result")
        }
        return result
    }

    func notify(method: String) throws {
        try writeJSON(
            ["jsonrpc": "2.0", "method": method],
            direction: .notification,
            operationID: method
        )
    }

    func shutdown() throws -> ShutdownOutcome {
        stateLock.lock()
        if let shutdownOutcome {
            stateLock.unlock()
            return shutdownOutcome
        }
        let didStart = started
        stateLock.unlock()
        guard didStart else { return ShutdownOutcome(status: 0, forced: false) }

        try? inputPipe.fileHandleForWriting.close()
        var forced = false
        if !exit.wait(timeout: shutdownGrace) {
            forced = true
            process.terminate()
            if !exit.wait(timeout: shutdownGrace) {
                Darwin.kill(process.processIdentifier, SIGKILL)
                guard exit.wait(timeout: shutdownGrace) else {
                    throw QualificationTransportError.shutdownTimeout
                }
            }
        }
        if readers.wait(timeout: .now() + shutdownGrace) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            guard readers.wait(timeout: .now() + shutdownGrace) == .success else {
                throw QualificationTransportError.shutdownTimeout
            }
        }
        let outcome = ShutdownOutcome(status: exit.status, forced: forced)
        stateLock.lock()
        shutdownOutcome = outcome
        stateLock.unlock()
        return outcome
    }

    private func writeJSON(
        _ object: [String: Any],
        direction: QualificationWireFrame.Direction,
        operationID: String
    ) throws {
        let data: Data
        do {
            var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            encoded.append(0x0A)
            data = encoded
        } catch {
            throw QualificationTransportError.protocolViolation("request encoding failed")
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            record(direction: direction, operationID: operationID, data: data.dropLast())
        } catch {
            throw QualificationTransportError.closedPipe(phase: "write")
        }
    }

    private func record(
        direction: QualificationWireFrame.Direction,
        operationID: String,
        data: Data
    ) {
        stateLock.withLock {
            framesTranscript.append(QualificationWireFrame(
                sequence: framesTranscript.count,
                direction: direction,
                operationID: operationID,
                payload: String(decoding: data, as: UTF8.self)
            ))
        }
    }

    private func startReaders() {
        let output = outputPipe.fileHandleForReading
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async { [frames, readers] in
            defer { readers.leave() }
            var pending = Data()
            do {
                while true {
                    let chunk = try readAvailable(output)
                    guard !chunk.isEmpty else { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        if !line.isEmpty {
                            try frames.append(line)
                        }
                    }
                    if pending.count > QualificationFrameQueue.maximumFrameBytes {
                        throw QualificationTransportError.malformedFrame("frame exceeds size limit")
                    }
                }
                if pending.isEmpty {
                    frames.finish()
                } else {
                    frames.fail(QualificationTransportError.malformedFrame("unterminated frame"))
                }
            } catch {
                frames.fail(error)
            }
        }

        let error = errorPipe.fileHandleForReading
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [stderr, readers] in
            defer { readers.leave() }
            // The stdout reader at least LOOKED like it handled a bad descriptor. This one had no
            // `do`/`catch` at all. A stderr read that fails is not fatal to the run — the
            // diagnostic is truncated, not the transport — so it is recorded and the loop ends.
            do {
                while true {
                    let chunk = try readAvailable(error)
                    guard !chunk.isEmpty else { break }
                    stderr.append(chunk)
                }
            } catch {
                stderr.append(Data(
                    "\n[qualification-transport] stderr capture ended early: \(error)\n".utf8))
            }
        }
    }
}

private final class QualificationFrameQueue: @unchecked Sendable {
    static let maximumFrameBytes = 8 * 1024 * 1024

    private let condition = NSCondition()
    private var responses: [Int: Data] = [:]
    private var terminalError: Error?
    private var finished = false

    func append(_ data: Data) throws {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QualificationTransportError.malformedFrame("top-level frame is not an object")
            }
            object = decoded
        } catch let error as QualificationTransportError {
            fail(error)
            throw error
        } catch {
            let malformed = QualificationTransportError.malformedFrame("invalid JSON")
            fail(malformed)
            throw malformed
        }
        guard object["jsonrpc"] as? String == "2.0" else {
            let malformed = QualificationTransportError.malformedFrame("missing jsonrpc 2.0")
            fail(malformed)
            throw malformed
        }
        guard let number = object["id"] as? NSNumber else {
            return
        }
        condition.lock()
        responses[number.intValue] = data
        condition.broadcast()
        condition.unlock()
    }

    func response(id: Int, phase: String, timeout: TimeInterval) throws -> Data {
        let deadline = DispatchTime.now() + timeout
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let response = responses.removeValue(forKey: id) {
                return response
            }
            if let terminalError {
                throw terminalError
            }
            if finished {
                throw QualificationTransportError.closedPipe(phase: phase)
            }
            let now = DispatchTime.now()
            guard now < deadline else {
                throw QualificationTransportError.requestTimeout(phase: phase)
            }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
            _ = condition.wait(until: Date().addingTimeInterval(remaining))
        }
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        if terminalError == nil {
            terminalError = error
        }
        condition.broadcast()
        condition.unlock()
    }
}

private final class QualificationStderrBuffer: @unchecked Sendable {
    private static let maximumBytes = 64 * 1024
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > Self.maximumBytes {
            data.removeFirst(data.count - Self.maximumBytes)
        }
        lock.unlock()
    }
}

private final class QualificationProcessExit: @unchecked Sendable {
    private let condition = NSCondition()
    private var exited = false
    private(set) var status: Int32 = 0

    func start(_ process: Process) {
        process.terminationHandler = { [self] process in
            condition.lock()
            status = process.terminationStatus
            exited = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !exited {
            guard condition.wait(until: deadline) else { return exited }
        }
        return true
    }
}
