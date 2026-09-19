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

    /// The name of the first reading in this record that says it did not HAPPEN, or nil when all
    /// three report a real one.
    ///
    /// Why this exists rather than leaning on `readbackFreshness`: that verdict is computed from
    /// the operation's own later readback, not from these three, and it short-circuits to
    /// `.admissible` for every verification policy that is not `.readbackRequired`.
    ///
    /// THE FIRST VERSION OF THIS COMMENT NAMED THE WRONG OPERATIONS, and a blind review caught it.
    /// It said `mixer.set_volume` and `mixer.set_pan` were `.none` and were "the only two
    /// operations this record is built for". Both halves were false. `OperationRegistry.swift`
    /// hardcodes `verification: .readbackRequired` for the whole `.logicMixer` block; the `.none`
    /// beside those rows is the **ConfirmationPolicy** — the tuple is
    /// `(OperationID, String, ConfirmationPolicy, TargetPolicy, Set<String>)`. And fourteen cycles
    /// in this file produce a `QualificationMutationRestoreRecord`, not two.
    ///
    /// The operations where freshness really is vacuous are in the TRANSPORT family —
    /// `transport.toggle_cycle` and `transport.set_tempo` are `.none` verification — and those read
    /// `logic://transport/state`, whose envelope carries neither `readable` nor `verified_empty`.
    /// It says so a different way: `unverified: true` with `source: "cache"`. So that is checked
    /// here too, or this guard would be absent from exactly the family it is the only defence for.
    ///
    /// What it checks is whether a reading OCCURRED, never whether it is fresh: staleness is a
    /// different complaint and has its own verdict.
    var readingThatDidNotHappen: String? {
        for (name, raw) in [("pre_state", preState), ("readback", readback),
                            ("restore_readback", restoreReadback)] {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "\(name): not readable as a JSON envelope"
            }
            if object["readable"] as? Bool == false { return "\(name): readable=false" }
            if object["ax_occluded"] as? Bool == true { return "\(name): ax_occluded=true" }
            // The transport envelope's own word for "this is not a reading of the live surface".
            if object["unverified"] as? Bool == true { return "\(name): unverified=true" }
            // THE FRESHNESS GATE'S OWN QUESTION, widened by exactly one step. These were two
            // checks and they disagreed on an absent rows key -- this one refused, that one waved
            // it through -- so whether a rowless readback was admissible depended on which gate
            // asked. Both were also blind to a DICTIONARY payload, which this subsystem reads.
            //
            // `showsNoRows` rather than `isEmpty(object["data"])` because a record carries no URI:
            // its three readings come from whichever resource the recipe used, and `logic://mixer`
            // publishes `strips` where `logic://tracks` publishes `data`. Asking only about `data`
            // called every mixer reading empty.
            if QualificationReadbackFreshness.showsNoRows(object),
               object["verified_empty"] as? Bool != true {
                return "\(name): empty without verified_empty"
            }
        }
        return nil
    }

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
            //
            // And freshness is not enough on its own. `readbackFreshness` is computed from the
            // operation's LATER readback and returns `.admissible` unconditionally for any policy
            // that is not `.readbackRequired` — `transport.toggle_cycle` and `transport.set_tempo`
            // among them. So the record's own readings are inspected here for whether a reading
            // happened at all, which is a question freshness never asks.
            if let record = mutationRestore, readbackFreshness.isAdmissible {
                return record.readingThatDidNotHappen == nil ? .passed : .notQualified
            }
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
        // A MUTATING pass and a READ pass are opposite evidence and must not share a kind. A read
        // passes because its response agreed with an independent readback, so its probe SUCCEEDED.
        // A mutating operation passes because a write-and-restore cycle was recorded and its probe
        // was REFUSED fail-closed -- `expectedZeroWriteRefusalObserved`, which requires
        // `isError == true`. Filing both as `semanticReadback` sent every mutating pass into a
        // shape rule that requires `operationIsError == false`, so the verifier rejected the whole
        // class while the runner kept reporting it passed. Nothing noticed: no test had ever put a
        // mutation-restore record through verification.
        // `mutationRestore != nil`, not `mutability == .mutating`. A verified write cycle is a
        // case that RESTS ON a recorded cycle; being a mutating operation is not the same claim.
        // The first version branched on mutability and turned every mutating pass into a cycle
        // case, including ones that never recorded one -- which the verifier then rejected for
        // lacking the record they never had.
        case .passed: mutationRestore != nil ? .verifiedWriteCycle : .semanticReadback
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
            uri: readbackSource,
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
                        // 2026-09-14 and did nothing. THE REASON RECORDED THEN WAS WRONG, and it
                        // is corrected here rather than deleted because the wrong one closed this
                        // operation as unfixable. It said `scan_library` "returns its presets in
                        // the response without ever writing that file". It DOES write:
                        // `AccessibilityChannel+Library.swift:270` writes
                        // `Resources/library-inventory-disk.json` for a disk scan, and
                        // `parseScanMode` answers `.disk` for an absent mode -- so the default
                        // scan wrote a file the reader had never been taught to look for. That
                        // filename split was fixed on 2026-09-19 (#923); the reader now carries
                        // both names, canonical first.
                        //
                        // Seeding is STILL not attempted here, for a reason that survives the
                        // correction: the seed would have to run a real library scan against the
                        // operator's Logic, which is minutes of work and touches nothing this
                        // operation is about. Re-measure before calling it unfixable again.
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
                        if spec.id == .transportSetTempo {
                            do {
                                let cycle = try tempoRestoreCycle(
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
                        // Two operations move the playhead by bar number and read it back out of
                        // the same transport resource: `navigate.goto_bar` and
                        // `transport.goto_position`. `goto_position` also accepts a `position`
                        // string, and the cycle deliberately drives the `bar` form — that is the
                        // shape both share, so one machine covers both without the recipe having to
                        // know which dispatcher it landed in.
                        if Self.playheadRestoreOperations.contains(spec.id) {
                            do {
                                let cycle = try playheadRestoreCycle(
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
                        if Self.phaseCTrackCyclesEnabled, spec.id == .tracksDelete {
                            do {
                                let cycle = try trackStagedDeleteCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_c recipe")
                                nextID += 60
                            }
                        }
                        if Self.phaseCTrackCyclesEnabled,
                           Self.trackCreateRestoreOperations.contains(spec.id) {
                            let cleanupWitness = PhaseCCleanupWitness()
                            do {
                                let cycle = try trackCreateRestoreCycle(
                                    session, startingAt: nextID, spec: spec, cleanup: cleanupWitness)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_c recipe")
                                    + "; cleanup: " + cleanupWitness.summary
                                nextID += 40
                            }
                        }
                        if let direction = Self.historyRestoreDirection[spec.id] {
                            do {
                                let cycle = try historyRestoreCycle(
                                    session, startingAt: nextID, spec: spec, direction: direction)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 40
                            }
                        }
                        if spec.id == .navigateGotoMarker {
                            do {
                                let cycle = try markerNavigationRestoreCycle(
                                    session, startingAt: nextID, spec: spec)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 60
                            }
                        }
                        if let mode = Self.markerStagedRestoreMode[spec.id] {
                            do {
                                let cycle = try markerStagedRestoreCycle(
                                    session, startingAt: nextID, spec: spec, mode: mode)
                                mutationRestoreRecords.append(cycle.record)
                                phaseBRecord = cycle.record
                                nextID = cycle.nextID
                            } catch {
                                phaseBRefusal = Self.observedFailureReason(
                                    from: error, during: "phase_b recipe")
                                nextID += 60
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

    /// #373 Phase B: the two history operations, and which way each one moves the stack.
    static let historyRestoreDirection: [OperationID: HistoryDirection] = [
        .editUndo: .undo,
        .editRedo: .redo,
    ]

    /// #373 Phase B: the marker operations that need a marker to exist before they can run, and
    /// the staged shape each one takes. See `markerStagedRestoreCycle`.
    static let markerStagedRestoreMode: [OperationID: MarkerStagedMode] = [
        .navigateRenameMarker: .rename,
        .navigateDeleteMarker: .delete,
    ]

    /// #373 Phase B: the mutating operations that move the playhead to a bar and are read back
    /// out of `logic://transport/state`.
    ///
    /// `navigate.goto_bar` and `transport.goto_position` are two dispatchers over one observable.
    /// Membership here is the claim that the operation takes a `bar` number and that the transport
    /// resource reports where the playhead ended up — not that the two commands are interchangeable
    /// for callers, which they are not: `goto_position` also accepts a `position` string and a
    /// SMPTE form that this cycle does not exercise.
    static let playheadRestoreOperations: Set<OperationID> = [
        .navigateGotoBar,
        .transportGotoPosition,
    ]

    /// #373 Phase B: the mutating operations whose recipe is a reversible boolean toggle, and the
    /// `logic://tracks` field that independently reports each one.
    ///
    /// A table rather than a switch because the addition it invites is a ROW — an operation, plus
    /// the field a reader can check it against. An operation with no honest independent field does
    /// not belong here and must not be given one that merely correlates.
    /// #373 Phase B: the toggles whose actuator refuses unless the TARGET TRACK is the only
    /// selected one, so the recipe has to arrange that before it writes.
    ///
    /// `tracks.arm` posts a key chord, and Logic's record-arm acts on the selection — so the rung
    /// re-checks `selectionIsExclusive(index:)` immediately before every post and refuses
    /// otherwise. Measured 2026-09-14: driven on its own after a `select`, `tracks.arm` answers
    /// State A verified on the same track the sweep failed on; inside the sweep nothing had
    /// selected it, the rung refused, and the answer that reached the recipe was the next channel's.
    /// `mute` and `solo` write an AX value and need no selection, which is why they are not here —
    /// staging one for them would move a selection the cycle has no reason to touch.
    static let requiresExclusiveSelection: Set<OperationID> = [.tracksArm]

    static let booleanToggleReadbackField: [OperationID: String] = [
        .tracksMute: "isMuted",
        .tracksSolo: "isSoloed",
        .tracksArm: "isArmed",
    ]

    /// Did the operation's own envelope say the write DID NOT happen?
    ///
    /// The recipes used to refuse on `isError`, which is too strict by exactly the case Phase B
    /// exists for. Measured 2026-09-14: `navigate.goto_bar` answers **State B**, `success: true`,
    /// `verified: false`, `reason: readback_unavailable` — "the write landed but I could not
    /// confirm it" — and the playhead moved from bar 20 to bar 17. Refusing that means Phase B can
    /// never qualify the operations that most need it, because supplying the independent
    /// confirmation the operation could not get is the recipe's whole job.
    ///
    /// State C is different and still refuses: it is the contract's "the write itself didn't
    /// succeed". So the question asked here is narrow — did the operation say it failed — and the
    /// readback guards decide everything else.
    private static func mutationSaysItFailed(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // An unparseable answer is not a claim that the write landed.
            return true
        }
        if let state = object["state"] as? String { return state == "C" }
        if let success = object["success"] as? Bool { return !success }
        return true
    }

    /// One tool call with CALLER-SUPPLIED params.
    ///
    /// `operation(…)` above always sends `probeParams`, which for a mutating operation is the
    /// deliberate no-write probe. A Phase-B recipe has to send a real request, so it needs this.
    /// Kept separate rather than adding a parameter to `operation` so the no-write probe stays the
    /// only thing the sweep itself can send.
    /// `timeout` nil uses the transport's generic 10 s request bound, which is right for a resource
    /// read and WRONG for the operation a Phase-B cycle is exercising: the registry already says
    /// how long each operation may take, and a harness that gives up inside that window reports a
    /// timeout of its own making. Measured 2026-09-14 — with `tracks.arm`'s write path finally
    /// working, its cycle failed as `qualification_transport_timeout:phase_b.mutation` while the
    /// operation was still inside its own `.short` deadline, having done nothing wrong.
    private func invoke(
        _ session: QualificationSubprocessSession,
        id: Int,
        tool: String,
        command: String,
        params: [String: Any],
        phase: String,
        timeout: TimeInterval? = nil
    ) throws -> (text: String, isError: Bool) {
        let result: ToolCallResult = try session.request(
            id: id,
            method: "tools/call",
            params: ["name": tool, "arguments": ["command": command, "params": params]],
            phase: phase,
            timeout: timeout
        )
        return (try result.text(phase: phase), result.isError == true)
    }

    /// Read one track's mute state from the independent `logic://tracks` resource.
    ///
    /// The recipe below needs the SAME reading three times — before, after the write, and after the
    /// restore — and it must come from a source other than the write's own answer, or the cycle
    /// proves nothing. `logic://tracks` is that source.
    /// `awaiting` is the value the caller is WAITING FOR, and nil means "just read".
    ///
    /// A single refreshed read is enough for `mute` and `solo`, whose write and whose poller update
    /// land together. It is not enough for `arm`: measured 2026-09-14, once its write path finally
    /// worked, the cycle still refused with `isArmed did not move — observed false, expected true`
    /// while a manual drive of the same call moved the flag and read it back two seconds later.
    /// The write was fine and the reading was early.
    ///
    /// Waiting does not relax the assertion. The loop exits early ONLY on the value the caller has
    /// already decided is correct; a wrong value spends the whole budget and is returned as it is,
    /// to be judged by the guard that asked for it. Each attempt costs two ids, and the spent count
    /// is returned so the caller advances past them instead of reusing a later step's id.
    private func observedTrackFlag(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String,
        awaiting: Bool? = nil
    ) throws -> (value: Bool, raw: String, spent: Int) {
        // REFRESH FIRST. `logic://tracks` is served from a poller-backed cache, and without this
        // the read after the write returns the pre-write value — measured 2026-09-14: mute moved
        // `true -> false` in Logic and three consecutive reads still answered `true`, while the
        // same sequence with a refresh between them reported `true -> false -> true`. A cycle built
        // on the unrefreshed read would have compared a write against its own stale precondition
        // and called it a failure; the guard below caught exactly that and refused, which is how
        // this was found.
        var spent = 0
        var last: (Bool, String)?
        for attempt in 0..<6 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.8) }
            _ = try? invoke(
                session, id: id + spent, tool: "logic_system", command: "refresh_cache",
                params: [:], phase: "\(phase).refresh")
            spent += 1
            let data = try resourceReadback(
                session, id: id + spent, uri: "logic://tracks", phase: phase)
            spent += 1
            let raw = String(decoding: data, as: UTF8.self)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]],
                  trackIndex < rows.count,
                  let value = rows[trackIndex][field] as? Bool else {
                throw QualificationTransportError.protocolViolation(
                    "\(phase): logic://tracks did not report \(field) for track \(trackIndex)"
                )
            }
            last = (value, raw)
            if awaiting == nil || value == awaiting { break }
        }
        guard let last else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks was never read for \(field)")
        }
        return (last.0, last.1, spent)
    }

    /// The index of the single selected track, or nil when none or more than one is selected.
    ///
    /// nil is the honest answer for "more than one", because a caller staging an EXCLUSIVE
    /// selection cannot restore a multi-selection it never captured.
    private func observedSelectedTrackIndex(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (index: Int?, spent: Int) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(session, id: id + 1, uri: "logic://tracks", phase: phase)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks did not report any rows")
        }
        let selected = rows.enumerated().filter { ($0.element["isSelected"] as? Bool) == true }
        return (selected.count == 1 ? selected[0].offset : nil, 2)
    }

    /// #373 Phase B: the mutating operations whose recipe restores a VALUE rather than flipping a
    /// flag, and the `logic://tracks` field that independently reports each one.
    static let valueRestoreReadbackField: [OperationID: String] = [
        .mixerSetVolume: "volume",
        .mixerSetPan: "pan",
    ]

    /// The row's `track_ref` comes back with its value, and its absence is a refusal rather than a
    /// fallback. The cycle addresses the track by that reference; an index is a position, and the
    /// position of a row is not a property of the track sitting in it.
    private func observedTrackValue(
        _ session: QualificationSubprocessSession,
        id: Int,
        trackIndex: Int,
        field: String,
        phase: String
    ) throws -> (value: Double, raw: String, trackRef: String) {
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
        guard let trackRef = rows[trackIndex]["track_ref"] as? String, !trackRef.isEmpty else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks row \(trackIndex) carries no track_ref, so this cycle has "
                    + "no identity to address. It does NOT fall back to the bare index: the index is "
                    + "what the identity exists to replace."
            )
        }
        return (value, raw, trackRef)
    }

    /// Put the value back after the cycle has failed somewhere between the write and its restore.
    ///
    /// Returns a sentence describing what happened, which the caller folds into the error it throws.
    /// A compensating restore that fails silently is worse than none: the sweep continues, the
    /// refusal is recorded, and nothing says the operator's mixer was left moved.
    private func compensateValue(
        _ session: QualificationSubprocessSession,
        spec: OperationSpec,
        field: String,
        trackIndex: Int,
        targetRef: String,
        value: Double,
        nextID: inout Int
    ) -> String {
        let callID = nextID
        nextID += 1
        do {
            let answer = try invoke(
                session, id: callID,
                tool: spec.tool.rawValue, command: spec.command,
                params: ["target_ref": targetRef, field: value],
                phase: "phase_b.compensate", timeout: spec.deadline.seconds + 5)
            if Self.mutationSaysItFailed(answer.text) {
                return "REFUSED, \(field) may still be moved: " + answer.text.prefix(200)
            }
            // RE-READ. "sent" is not "landed": State B is accepted-but-unverified and is not State
            // C, so without this a compensating write the server took but that moved nothing read
            // identically to one that worked -- which is the exact condition this helper exists to
            // stop the sweep from walking past.
            let confirmID = nextID
            nextID += 2
            do {
                let seen = try observedTrackValue(
                    session, id: confirmID, trackIndex: trackIndex, field: field,
                    phase: "phase_b.compensate_readback")
                if seen.trackRef != targetRef {
                    return "sent and re-read, but row \(trackIndex) now holds \(seen.trackRef) "
                        + "rather than \(targetRef), so this reading does not describe the track "
                        + "that was moved"
                }
                return seen.value == value
                    ? "LANDED, \(field) re-read at \(value)"
                    : "SENT BUT NOT LANDED, \(field) re-read at \(seen.value), wanted \(value)"
            } catch {
                return "sent, but the confirming read failed, so whether \(field) came back is "
                    + "unknown: \(error)"
            }
        } catch {
            return "THREW, \(field) may still be moved: \(error)"
        }
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

        // Everything from here can leave the operator's mixer moved, INCLUDING a call that throws:
        // a timeout is a statement about the answer, not about the effect. So every exit between
        // this point and a verified restore compensates, and says in the thrown error whether the
        // compensation landed. Without this the sweep recorded a refusal and walked on with the
        // fader still at `target`.
        // Only true once a request that could MOVE something has been issued. A refusal carrying
        // `write_attempted: false` is the contract saying nothing was written, and compensating
        // that path is not harmless: the compensating write drives the fader to `pre.value`, which
        // came from the poller-backed cache, so on a stale read it moves a fader the product left
        // alone to a value neither the product nor the operator chose.
        var writeMayHaveLanded = false
        func failing(_ message: String) -> QualificationTransportError {
            guard writeMayHaveLanded else { return .protocolViolation(message) }
            let note = compensateValue(
                session, spec: spec, field: readbackField, trackIndex: trackIndex,
                targetRef: pre.trackRef, value: pre.value, nextID: &nextID)
            return .protocolViolation(message + " | compensating restore: " + note)
        }
        func writeAttemptedIsExplicitlyFalse(_ text: String) -> Bool {
            guard let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return false }
            return object["write_attempted"] as? Bool == false
        }

        do {
            // Set BEFORE the call, not after: a timeout is a statement about the answer, not about
            // the effect, so a throw here can still have moved the fader.
            writeMayHaveLanded = true
            let mutation = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: spec.command,
                params: ["target_ref": pre.trackRef, readbackField: target],
                phase: "phase_b.mutation", timeout: spec.deadline.seconds + 5)
            guard !Self.mutationSaysItFailed(mutation.text) else {
                // The refusal's own word for it. `write_attempted: false` is the fail-closed shape
                // this repository refuses with everywhere, and it is the one case where the answer
                // is authoritative that nothing moved.
                if writeAttemptedIsExplicitlyFalse(mutation.text) { writeMayHaveLanded = false }
                throw failing("phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
            }
            let after = try observedTrackValue(
                session, id: readStep(), trackIndex: trackIndex, field: readbackField,
                phase: "phase_b.readback")
            // The row at this index must still be the SAME track. Logic reorders on selection, and
            // a cycle that read one track, wrote to another and "restored" the first one's value
            // onto it would satisfy every comparison below while corrupting a track it never named.
            guard after.trackRef == pre.trackRef else {
                throw failing("phase_b.readback: row \(trackIndex) changed identity mid-cycle — "
                    + "pre \(pre.trackRef), now \(after.trackRef)")
            }
            guard after.value != pre.value else {
                throw failing("phase_b.readback: \(readbackField) did not move from \(pre.value)")
            }
            let restore = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: spec.command,
                params: ["target_ref": pre.trackRef, readbackField: pre.value],
                phase: "phase_b.restore", timeout: spec.deadline.seconds + 5)
            guard !Self.mutationSaysItFailed(restore.text) else {
                throw failing("phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
            }
            let restored = try observedTrackValue(
                session, id: readStep(), trackIndex: trackIndex, field: readbackField,
                phase: "phase_b.restore_readback")
            guard restored.trackRef == pre.trackRef else {
                throw failing("phase_b.restore_readback: row \(trackIndex) changed identity — "
                    + "pre \(pre.trackRef), now \(restored.trackRef)")
            }
            guard restored.value == pre.value else {
                throw failing("phase_b.restore_readback: \(readbackField) not restored — observed "
                    + "\(restored.value), expected \(pre.value); the restore answered: "
                    + restore.text.prefix(300))
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
        } catch {
            // NOT `catch let error as QualificationTransportError`. `observedTrackValue` calls
            // `try JSONSerialization.jsonObject(...)`, which raises an NSError on a malformed
            // `logic://tracks` body -- and that is reached from BOTH post-write readbacks. Narrowed
            // to the transport's own error type, such a body let a landed write exit this function
            // with no compensation at all, and the sweep's untyped catch recorded a refusal with no
            // note. The universal in the comment above has to be enforced by the catch, not
            // asserted next to one that is narrower than it.
            if let transportError = error as? QualificationTransportError,
               case .protocolViolation(let text) = transportError,
               text.contains("compensating restore:") {
                throw error          // `failing()` already compensated for this one
            }
            guard writeMayHaveLanded else { throw error }
            let note = compensateValue(
                session, spec: spec, field: readbackField, trackIndex: trackIndex,
                targetRef: pre.trackRef, value: pre.value, nextID: &nextID)
            throw QualificationTransportError.protocolViolation(
                "\(error) | compensating restore: " + note)
        }
    }

    /// #373 Phase B: transport operations whose effect is a boolean the transport resource reports,
    /// mapped to the state each one is supposed to leave behind.
    static let transportExpectedPlaying: [OperationID: Bool] = [
        .transportPlay: true,
        .transportStop: false,
        // `pause` targets the same observable as `stop` — Logic's pause halts the running
        // transport, and the dispatcher verifies `isPlaying == false` for both. It is here rather
        // than folded into `stop` because it is a distinct operation whose own evidence was
        // missing; what it shares is the field, not the identity. `record` is deliberately NOT
        // here: its readback would be the same flag, and running it would write audio into the
        // fixture, which belongs to Phase C-live with a disposable project.
        .transportPause: false,
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
            params: [:], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
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

        // Each read advances `nextID` by what it SPENT — a polled read costs more than two ids.
        let pre = try observedTrackFlag(
            session, id: nextID, trackIndex: 0, field: "isSelected",
            phase: "phase_b.pre_state")
        nextID += pre.spent
        // Select row 1 when row 0 holds the selection, and row 0 otherwise — always a real move.
        let target = pre.value ? 1 : 0
        let original = pre.value ? 0 : 1
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": target], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let gained = try observedTrackFlag(
            session, id: nextID, trackIndex: target, field: "isSelected",
            phase: "phase_b.readback", awaiting: true)
        nextID += gained.spent
        let lost = try observedTrackFlag(
            session, id: nextID, trackIndex: original, field: "isSelected",
            phase: "phase_b.readback_other", awaiting: false)
        nextID += lost.spent
        guard gained.value, !lost.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: selection did not MOVE — target \(gained.value), "
                    + "original \(lost.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": original], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        let restored = try observedTrackFlag(
            session, id: nextID, trackIndex: original, field: "isSelected",
            phase: "phase_b.restore_readback", awaiting: true)
        nextID += restored.spent
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

    /// What a marker-list read is waiting FOR, and therefore when it may stop polling early.
    ///
    /// A count was the only condition this poll knew, and that is wrong for a rename: the list
    /// length does not move, so the first — stale — read satisfies it and the recipe judges the
    /// operation against a list taken before the write settled. Measured 2026-09-14:
    /// `rename_marker` was refused by its own cycle for a name change that Logic had in fact made.
    /// The settle condition has to name the thing the mutation actually changed.
    enum MarkerSettle: Sendable {
        /// Read once; the caller is not waiting for anything.
        case read
        /// Wait until the list holds exactly this many rows.
        case count(Int)
        /// Wait until every `present` name is in the list and no `absent` name is.
        case names(present: [String], absent: [String])
    }

    private func observedMarkerCount(
        _ session: QualificationSubprocessSession,
        id: Int,
        settling: MarkerSettle,
        phase: String
    ) throws -> (count: Int, raw: String, spent: Int) {
        // POLLS rather than reads once. The marker list settles more slowly than the other
        // resources this file reads: measured 2026-09-14, a delete that had actually taken effect
        // still read as present immediately after `refresh_cache`, and answered correctly a couple
        // of seconds later. Reading once would make this recipe flaky and — worse — would report a
        // working operation as one that did nothing.
        //
        // `settling` is what the caller is waiting FOR, and `.read` means "just read". Waiting is
        // not relaxing the assertion: the loop exits early only on the state the caller already
        // decided is correct, and a wrong state simply runs out the budget and is returned as it
        // is, to be judged by the guard that asked.
        var spent = 0
        var last: (Int, String) = (-1, "")
        for attempt in 0..<6 {
            // WAIT between attempts. The first version polled with no delay, so six attempts
            // finished in well under a second — far too fast for this list. Measured 2026-09-14: a
            // `delete_marker` at the correct index still showed the marker 1.8 s later and was gone
            // by 3 s. A poll that spins is not waiting; it is reading the same stale answer six
            // times and then reporting it as the truth.
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.8) }
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
            let names = Set(rows.compactMap { $0["name"] as? String })
            let settled: Bool = switch settling {
            case .read: true
            case .count(let expected): rows.count == expected
            case .names(let present, let absent):
                present.allSatisfy(names.contains) && !absent.contains(where: names.contains)
            }
            if settled { break }
        }
        return (last.0, last.1, spent)
    }

    /// #373 Phase B for the project tempo.
    ///
    /// `transport.set_tempo` refuses when the project holds more than one tempo event — Logic
    /// answers that edit with a modal alert and the operation reports
    /// `readback_lost_after_write` (#304). That refusal arrives here as a State C mutation and the
    /// cycle declines, which is the right outcome: a fixture with a tempo map cannot qualify this
    /// operation through the control bar, and pretending otherwise would be the grader looking
    /// away.
    private func tempoRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        func tempo(of raw: String, phase: String) throws -> Double {
            guard let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = object["data"] as? [String: Any],
                  let state = payload["state"] as? [String: Any],
                  let value = state["tempo"] as? Double else {
                throw QualificationTransportError.protocolViolation(
                    "\(phase): logic://transport/state did not report tempo")
            }
            return value
        }

        let pre = try observedTransportPosition(session, id: readStep(), phase: "phase_b.pre_state")
        let preTempo = try tempo(of: pre.raw, phase: "phase_b.pre_state")
        // A few BPM away, inside the operation's own 5...990 range and far enough that the
        // readback cannot agree by rounding.
        let target = preTempo > 100 ? preTempo - 6 : preTempo + 6
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bpm": target], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        var needsRestore = true
        defer {
            if needsRestore {
                _ = try? invoke(
                    session, id: nextID + 900, tool: spec.tool.rawValue, command: spec.command,
                    params: ["bpm": preTempo], phase: "phase_b.cleanup",
            timeout: spec.deadline.seconds + 5)
            }
        }
        let after = try observedTransportPosition(session, id: readStep(), phase: "phase_b.readback")
        let afterTempo = try tempo(of: after.raw, phase: "phase_b.readback")
        guard afterTempo != preTempo else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: tempo did not move from \(preTempo)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bpm": preTempo], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.restore_readback")
        let restoredTempo = try tempo(of: restored.raw, phase: "phase_b.restore_readback")
        guard restoredTempo == preTempo else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: tempo is \(restoredTempo), expected \(preTempo)")
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

    /// #373 Phase B for the playhead — `navigate.goto_bar` today.
    ///
    /// The restore target is read out of the pre-state's own position string rather than assumed,
    /// so the playhead goes back to the bar the operator was actually on. How many components that
    /// string carries depends on the control bar's display mode (#304), so only the leading BAR is
    /// parsed and compared — the finer components are whatever the mode happens to expose and
    /// comparing them would make this recipe fail on a display setting rather than on the operation.
    /// The bar number the transport reports, out of a `logic://transport/state` body.
    private func observedBar(of raw: String, phase: String) throws -> Int {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let state = payload["state"] as? [String: Any],
              let position = state["position"] as? String,
              let leading = position.split(separator: ".").first,
              let value = Int(leading) else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): could not read a bar out of the transport position")
        }
        return value
    }

    /// #373 Phase B for `navigate.goto_marker`.
    ///
    /// The operation needs a marker to go TO, and it must be somewhere the playhead is not, or the
    /// readback would agree without the operation having moved anything. So the cycle stages both:
    /// it parks the playhead at a bar of its own choosing, drops a marker there, brings the
    /// playhead back, and only then asks `goto_marker` to find it.
    ///
    /// The marker is identified BY NAME in the request as well as in the cleanup — `goto_marker`
    /// accepts an index, and using one would make the cycle depend on the position-sorted order
    /// that has already caused one destructive defect in this file.
    private func markerNavigationRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let probeName = "qualification_phase_b_probe"
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let origin = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.stage_precondition")
        let originBar = try observedBar(of: origin.raw, phase: "phase_b.stage_precondition")
        let markerBar = originBar > 4 ? originBar - 3 : originBar + 3

        let existing = try observedMarkerCount(
            session, id: nextID, settling: .read, phase: "phase_b.stage_precondition")
        nextID += existing.spent
        guard markerIndex(named: probeName, in: existing.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_precondition: a marker named \(probeName) is already in the "
                    + "project — an earlier run left it, and this cycle cannot tell its own marker "
                    + "from that one")
        }
        _ = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "goto_bar",
            params: ["bar": markerBar], phase: "phase_b.stage")
        let parked = try observedTransportPosition(session, id: readStep(), phase: "phase_b.stage")
        guard try observedBar(of: parked.raw, phase: "phase_b.stage") == markerBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: could not park the playhead at bar \(markerBar), so a marker "
                    + "dropped here would not be where this cycle thinks it is")
        }
        let staged = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "create_marker",
            params: ["name": probeName], phase: "phase_b.stage")
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: create_marker refused, so there is nothing for "
                    + "\(spec.id.rawValue) to navigate to: " + staged.text.prefix(220))
        }
        // A MARKER NOW EXISTS. Every exit removes it, and the removal is verified — see
        // `markerCreateRestoreCycle` for why an unchecked delete is not a removal.
        defer {
            var cleanupID = nextID + 900
            for _ in 0..<6 {
                guard let seen = try? observedMarkerCount(
                    session, id: cleanupID, settling: .read, phase: "phase_b.cleanup_readback"
                ) else { break }
                cleanupID += seen.spent
                guard let index = markerIndex(named: probeName, in: seen.raw) else { break }
                _ = try? invoke(
                    session, id: cleanupID, tool: spec.tool.rawValue, command: "delete_marker",
                    params: ["index": index], phase: "phase_b.cleanup")
                cleanupID += 1
            }
        }
        let listed = try observedMarkerCount(
            session, id: nextID, settling: .names(present: [probeName], absent: []),
            phase: "phase_b.stage_readback")
        nextID += listed.spent
        guard markerIndex(named: probeName, in: listed.raw) != nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_readback: \(probeName) never appeared in the marker list")
        }
        _ = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "goto_bar",
            params: ["bar": originBar], phase: "phase_b.stage_return")
        let pre = try observedTransportPosition(session, id: readStep(), phase: "phase_b.pre_state")
        let preBar = try observedBar(of: pre.raw, phase: "phase_b.pre_state")
        guard preBar != markerBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: the playhead is already at the marker's bar \(markerBar), so "
                    + "arriving there would prove nothing")
        }

        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["name": probeName], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTransportPosition(session, id: readStep(), phase: "phase_b.readback")
        let afterBar = try observedBar(of: after.raw, phase: "phase_b.readback")
        guard afterBar == markerBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: playhead is at bar \(afterBar), expected the marker's bar "
                    + "\(markerBar)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: "goto_bar",
            params: ["bar": preBar], phase: "phase_b.restore")
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: goto_bar refused the restore: " + restore.text.prefix(220))
        }
        let restored = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.restore_readback")
        let restoredBar = try observedBar(of: restored.raw, phase: "phase_b.restore_readback")
        guard restoredBar == preBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: playhead is at bar \(restoredBar), expected \(preBar)")
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

    private func playheadRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let pre = try observedTransportPosition(session, id: readStep(), phase: "phase_b.pre_state")
        let preBar = try observedBar(of: pre.raw, phase: "phase_b.pre_state")
        // Somewhere else in the arrangement, and never bar 0 — `goto_bar` counts from 1.
        let target = preBar > 4 ? preBar - 3 : preBar + 3
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bar": target], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTransportPosition(session, id: readStep(), phase: "phase_b.readback")
        let afterBar = try observedBar(of: after.raw, phase: "phase_b.readback")
        guard afterBar == target else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: playhead is at bar \(afterBar), expected \(target)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["bar": preBar], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTransportPosition(
            session, id: readStep(), phase: "phase_b.restore_readback")
        let restoredBar = try observedBar(of: restored.raw, phase: "phase_b.restore_readback")
        guard restoredBar == preBar else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: playhead is at bar \(restoredBar), expected \(preBar)")
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

    private func observedTransportPosition(
        _ session: QualificationSubprocessSession,
        id: Int,
        phase: String
    ) throws -> (raw: String, spent: Int) {
        _ = try? invoke(
            session, id: id, tool: "logic_system", command: "refresh_cache",
            params: [:], phase: "\(phase).refresh")
        let data = try resourceReadback(
            session, id: id + 1, uri: "logic://transport/state", phase: phase)
        return (String(decoding: data, as: UTF8.self), 2)
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
            params: ["index": 0, readbackField: probeValue], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        var needsRestore = true
        defer {
            if needsRestore {
                var cleanupID = nextID + 900
                for _ in 0..<4 {
                    _ = try? invoke(
                        session, id: cleanupID, tool: spec.tool.rawValue, command: spec.command,
                        params: ["index": 0, readbackField: pre.value], phase: "phase_b.cleanup",
            timeout: spec.deadline.seconds + 5)
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
            params: ["index": 0, readbackField: pre.value], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
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

    /// Which half of the undo stack a `historyRestoreCycle` run is exercising.
    enum HistoryDirection: Sendable {
        case undo
        case redo
    }

    /// #373 Phase B for `edit.undo` and `edit.redo`.
    ///
    /// These are the clearest case the whole mode exists for. Measured 2026-09-14: `edit.undo`
    /// reverses a track rename and reports **State B** for it —
    /// `reason: noop_unobservable`, `verify_source: ax_edit_menu_entry`, with the detail that "the
    /// Edit menu names the same entry before and after, so this surface cannot separate a stack
    /// that moved from one that did not". The operation is right to refuse: the menu entry genuinely
    /// cannot tell it. `logic://tracks` can, and supplying the confirmation the operation could not
    /// obtain is precisely what a Phase B recipe is.
    ///
    /// The cycle manufactures its own undoable edit rather than undoing whatever the operator did
    /// last. Pressing undo against an unknown stack top is not a qualification; it is an edit to
    /// somebody else's project whose effect this recipe could not even name.
    private func historyRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        direction: HistoryDirection
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        let trackIndex = 0
        let probeName = "qualification_phase_b_probe"
        var nextID = id
        func readStep() -> Int { defer { nextID += 2 }; return nextID }
        func step() -> Int { defer { nextID += 1 }; return nextID }

        let original = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.stage_precondition")
        guard original.value != probeName else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_precondition: track \(trackIndex) is already called \(probeName) "
                    + "— an earlier run left it, and this cycle cannot tell its own edit from that "
                    + "one")
        }
        let staged = try invoke(
            session, id: step(), tool: "logic_tracks", command: "rename",
            params: ["index": trackIndex, "name": probeName], phase: "phase_b.stage")
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: rename refused, so there is no edit for \(spec.id.rawValue) to "
                    + "move over: " + staged.text.prefix(220))
        }
        // THE TRACK IS NOW RENAMED and every exit has to put the original back. The cleanup
        // WRITES the name rather than pressing undo again: undo is the operation under test, and a
        // cleanup that depends on it cannot be trusted to run when the thing it depends on is what
        // just failed.
        // `let`, not `var`: for these two shapes the staged edit is ALWAYS owed a cleanup — the
        // restore puts the probe name back rather than the original — so there is no exit that
        // clears it, and saying so in the type is more honest than a flag that never moves.
        let nameNeedsRestoring = true
        defer {
            if nameNeedsRestoring {
                var cleanupID = nextID + 900
                for _ in 0..<4 {
                    guard let seen = try? observedTrackString(
                        session, id: cleanupID, trackIndex: trackIndex, field: "name",
                        phase: "phase_b.cleanup_readback") else { break }
                    cleanupID += 2
                    if seen.value == original.value { break }
                    _ = try? invoke(
                        session, id: cleanupID, tool: "logic_tracks", command: "rename",
                        params: ["index": trackIndex, "name": original.value],
                        phase: "phase_b.cleanup")
                    cleanupID += 1
                }
            }
        }
        let renamed = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.stage_readback")
        guard renamed.value == probeName else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_readback: track \(trackIndex) reads \(renamed.value), so the edit "
                    + "this cycle meant to stage is not on the stack")
        }
        if direction == .redo {
            // `redo` needs something to redo, so the staged edit is undone FIRST. That undo is
            // arrangement, not evidence: it is not what the record reports on, and if it fails the
            // cycle refuses rather than reporting a redo that had nothing to move.
            _ = try invoke(
                session, id: step(), tool: spec.tool.rawValue, command: "undo", params: [:],
                phase: "phase_b.stage_undo")
            let reverted = try observedTrackString(
                session, id: readStep(), trackIndex: trackIndex, field: "name",
                phase: "phase_b.stage_undo_readback")
            guard reverted.value == original.value else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.stage_undo_readback: track \(trackIndex) reads \(reverted.value), "
                        + "so there is nothing for redo to move forward to")
            }
        }

        let expectedAfter = direction == .undo ? original.value : probeName
        let expectedRestored = direction == .undo ? probeName : original.value
        let restoreCommand = direction == .undo ? "redo" : "undo"

        let pre = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.pre_state")
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command, params: [:],
            phase: "phase_b.mutation", timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.readback")
        guard after.value == expectedAfter else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: track \(trackIndex) reads \(after.value), expected "
                    + "\(expectedAfter)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: restoreCommand, params: [:],
            phase: "phase_b.restore")
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(restoreCommand) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTrackString(
            session, id: readStep(), trackIndex: trackIndex, field: "name",
            phase: "phase_b.restore_readback")
        guard restored.value == expectedRestored else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: track \(trackIndex) reads \(restored.value), expected "
                    + "\(expectedRestored)")
        }
        // The cycle is closed and the track may still be called `probeName` — for `undo` the
        // restore is a redo, which puts the staged name back. The cleanup below is what returns the
        // fixture, and the flag stays set so it runs.
        _ = nameNeedsRestoring
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
            params: [:], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTransportFlag(
            session, id: readStep(), field: readbackField, phase: "phase_b.readback")
        guard after.value == !pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) is \(after.value), expected \(!pre.value)")
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: [:], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
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
            session, id: nextID, settling: .read, phase: "phase_b.pre_state")
        guard markerIndex(named: probeName, in: pre.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: a marker named \(probeName) is already in the project — an "
                    + "earlier run left it, and this cycle cannot tell its own marker from that one")
        }
        nextID += pre.spent
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command,
            params: ["name": probeName], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
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
                        session, id: cleanupID, settling: .read, phase: "phase_b.cleanup_readback"
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
            session, id: nextID, settling: .names(present: [probeName], absent: []),
            phase: "phase_b.readback")
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
            session, id: nextID, settling: .names(present: [], absent: [probeName]),
            phase: "phase_b.restore_readback")
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

    /// #373 Phase B for the two marker operations that need a marker to already be there:
    /// `navigate.rename_marker` and `navigate.delete_marker`.
    ///
    /// Both are run against a marker this cycle STAGES, never against one the project came with.
    /// That is the difference between qualifying an operation and editing the user's arrangement to
    /// do it: a rename cycle that borrowed an existing marker would be correct on paper — it puts
    /// the name back — and would still have written to something it did not own, with a window
    /// where a crash leaves that marker called `qualification_phase_b_probe`.
    ///
    /// The staged marker means the record's `preState` is the list AFTER staging, which is the
    /// honest pre-state OF THE MUTATION rather than of the run. The staging create and the final
    /// removal both sit outside the record, and the removal is verified on every exit for the
    /// reason `markerCreateRestoreCycle` records: an unverified cleanup is a request.
    private func markerStagedRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        mode: MarkerStagedMode
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let probeName = "qualification_phase_b_probe"
        let renamedName = "qualification_phase_b_renamed"

        let original = try observedMarkerCount(
            session, id: nextID, settling: .read, phase: "phase_b.stage_precondition")
        nextID += original.spent
        for leftover in [probeName, renamedName] where markerIndex(named: leftover, in: original.raw) != nil {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage_precondition: a marker named \(leftover) is already in the project "
                    + "— an earlier run left it, and this cycle cannot tell its own marker from "
                    + "that one")
        }
        let staged = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: "create_marker",
            params: ["name": probeName], phase: "phase_b.stage")
        nextID += 1
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.stage: create_marker refused, so there is nothing to exercise "
                    + "\(spec.id.rawValue) against: " + staged.text.prefix(220))
        }
        // A MARKER NOW EXISTS under one of two names, and every exit from here has to remove it.
        // `let` for the same reason as the history cycle: the staged marker is still there when the
        // record closes, because that is what "restored" means for a rename or a delete.
        let stagedMarkerNeedsRemoval = true
        defer {
            if stagedMarkerNeedsRemoval {
                var cleanupID = nextID + 900
                for _ in 0..<6 {
                    guard let seen = try? observedMarkerCount(
                        session, id: cleanupID, settling: .read, phase: "phase_b.cleanup_readback"
                    ) else { break }
                    cleanupID += seen.spent
                    // The mutation under test may have renamed it, so the cleanup looks for BOTH
                    // names. A cleanup that only knew the name it staged would leave the marker
                    // behind exactly when the rename half-succeeded.
                    let index = markerIndex(named: probeName, in: seen.raw)
                        ?? markerIndex(named: renamedName, in: seen.raw)
                    guard let index else { break }
                    _ = try? invoke(
                        session, id: cleanupID, tool: spec.tool.rawValue, command: "delete_marker",
                        params: ["index": index], phase: "phase_b.cleanup")
                    cleanupID += 1
                }
            }
        }

        let pre = try observedMarkerCount(
            session, id: nextID, settling: .names(present: [probeName], absent: []),
            phase: "phase_b.pre_state")
        nextID += pre.spent
        guard let stagedIndex = markerIndex(named: probeName, in: pre.raw) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.pre_state: the staged marker \(probeName) is not in the list, so the "
                    + "cycle has no target it can name")
        }

        let mutationParams: [String: Any] = switch mode {
        case .rename: ["index": stagedIndex, "name": renamedName]
        case .delete: ["index": stagedIndex]
        }
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command,
            params: mutationParams, phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }

        // WAIT ON THE NAME, not the length. A rename leaves the count where it was, so a
        // count-settled read is satisfied by the list as it stood BEFORE the write and the cycle
        // then refuses a rename Logic actually performed — measured 2026-09-14, on this recipe's
        // first live run.
        let afterSettle: MarkerSettle = switch mode {
        case .rename: .names(present: [renamedName], absent: [probeName])
        case .delete: .names(present: [], absent: [probeName])
        }
        let after = try observedMarkerCount(
            session, id: nextID, settling: afterSettle, phase: "phase_b.readback")
        nextID += after.spent
        switch mode {
        case .rename:
            guard after.count == pre.count,
                  markerIndex(named: probeName, in: after.raw) == nil,
                  markerIndex(named: renamedName, in: after.raw) != nil else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: after rename_marker the list must carry \(renamedName) and "
                        + "not \(probeName), at an unchanged count of \(pre.count); it reports "
                        + "\(after.count)")
            }
        case .delete:
            guard after.count == pre.count - 1,
                  markerIndex(named: probeName, in: after.raw) == nil else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: after delete_marker \(probeName) must be absent at a count "
                        + "of \(pre.count - 1); the list reports \(after.count)")
            }
        }

        // The restore's target is resolved AGAIN from the readback rather than reused from the
        // pre-state. A delete shifts every later row down, so an index captured before the mutation
        // names a different marker afterwards — the mistake that made an earlier version of the
        // create cycle delete other people's markers while the count balanced.
        let restoreCommand: String
        let resolvedRestoreParams: [String: Any]
        switch mode {
        case .rename:
            guard let renamedIndex = markerIndex(named: renamedName, in: after.raw) else {
                throw QualificationTransportError.protocolViolation(
                    "phase_b.readback: \(renamedName) is not in the list, so the restore has no "
                        + "target it can name")
            }
            restoreCommand = spec.command
            resolvedRestoreParams = ["index": renamedIndex, "name": probeName]
        case .delete:
            restoreCommand = "create_marker"
            resolvedRestoreParams = ["name": probeName]
        }
        let restore = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: restoreCommand,
            params: resolvedRestoreParams, phase: "phase_b.restore")
        nextID += 1
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(restoreCommand) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedMarkerCount(
            session, id: nextID,
            settling: .names(present: [probeName], absent: [renamedName]),
            phase: "phase_b.restore_readback")
        nextID += restored.spent
        guard restored.count == pre.count,
              markerIndex(named: probeName, in: restored.raw) != nil,
              markerIndex(named: renamedName, in: restored.raw) == nil else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: the list must be back to \(pre.count) rows carrying "
                    + "\(probeName) and not \(renamedName); it reports \(restored.count)")
        }

        // The staged marker is still there — it is what "restored" means for these two — so the
        // cleanup above is still owed, and the flag stays set. The record closes here; removing the
        // staging is not part of what the operation is being qualified for.
        _ = stagedMarkerNeedsRemoval
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

    /// #373 Phase C: the track operations that are each other's restore.
    ///
    /// **NOT ENABLED, and the reason is a defect in this cycle's own verification.** It compares
    /// TRACK COUNTS, and a count is not a stable quantity here: `logic://tracks` reports the rows
    /// the arrange rail is showing, so expanding a track stack changes what the number counts
    /// without changing the project. Measured 2026-09-15 on the operator's project — before a
    /// sweep, 19 rows, `complete: false`, `collapsed_track_stack`, first row `Absolute Zero`;
    /// after, 19 rows, `complete: true`, first row `오디오 1`. The count matched and the content
    /// did not: the stack had expanded and a track this cycle created was still there. The
    /// count-based leak check passed a run that had left a track behind.
    ///
    /// The cycle's own reference checks are right — it deletes the `track_ref` that was not there
    /// before, and verifies that reference is gone. What is wrong is the SURROUNDING claim that a
    /// matching count means nothing was left. Fixing that means verifying against the reference SET
    /// rather than its size, and refusing outright when `complete` changes between the two reads,
    /// because then the two readings are not of the same thing.
    ///
    /// `create_audio` and `create_instrument` add a track; `delete` removes one. That makes a
    /// create-then-delete a COMPLETE cycle on the operator's own project — the same shape
    /// `markerCreateRestoreCycle` already proved — and it means these three do not have to wait for
    /// a disposable-project phase to carry evidence. The destructive operations that genuinely need
    /// one are the ones with no inverse.
    ///
    /// The created track is identified by its `track_ref`, never by an index. A delete addressed by
    /// position is the mistake that made an earlier marker cycle remove somebody else's marker
    /// while its count still balanced, and a track is a more expensive thing to lose.
    private func trackCreateRestoreCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec,
        cleanup: PhaseCCleanupWitness
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id

        let pre = try observedTrackInventory(session, id: nextID, phase: "phase_c.pre_state")
        nextID += pre.spent
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command, params: [:],
            phase: "phase_c.mutation", timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        // A TRACK NOW EXISTS and every exit has to remove it. A create cycle that can throw between
        // the create and the delete is a cycle that edits the project on failure — the lesson the
        // marker cycle paid for, and a track costs more than a marker.
        var createdNeedsRemoval = true
        // THE HANDLE THE CYCLE OWNS. Set once, at the instant the new track is unambiguous, and
        // read by the cleanup below. Asking again later is what failed: by the time the cleanup
        // runs, the only question it could ask was "what did the create say it made", and a create
        // whose modal reconciliation came back incomplete says nothing at all.
        var createdHandle: String?
        defer {
            if createdNeedsRemoval {
                var cleanupID = nextID + 900
                cleanup.note("entered")
                for attempt in 0..<3 {
                    cleanup.note("attempt \(attempt)")
                    // WAIT for the extra track before concluding there is none. The first version
                    // read ONCE with no settle and `break`ed when it saw nothing extra — so a
                    // create that landed AFTER the readback budget was never cleaned up. Measured
                    // 2026-09-15: two sweeps later the operator's project carried a leaked
                    // `오디오 2` and a pre-state of 22 tracks where the live project has 19. This
                    // is the same class the marker cycle paid for, and it bit again because a
                    // track create is slower than a marker create.
                    guard let seen = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: pre.count + 1,
                        phase: "phase_c.cleanup_readback") else {
                        cleanup.note("inventory read FAILED")
                        break
                    }
                    cleanupID += seen.spent
                    cleanup.note("saw \(seen.count) rows complete=\(String(describing: seen.complete))")
                    // The SAME narrow rule the readback uses: the created name AND a reference
                    // that is new, with exactly one match. A cleanup allowed to delete "anything
                    // new" is the hazard, not the safety net — under a stack expansion every newly
                    // visible child looks new.
                    // THREE WAYS TO NAME IT, in order of how much the cycle controls them, and a
                    // refusal when none answers. The carried handle is the cycle's own and needs no
                    // one else's readback; the create's reported name is what the first version
                    // relied on ALONE, and a run that landed carried none of it; the selection is
                    // re-derived here for the case where the handle was never set because the
                    // readback itself threw.
                    let byHandle = createdHandle.flatMap { seen.refs.contains($0) ? $0 : nil }
                    let byName = Self.soleCreatedTrack(
                        named: Self.createdTrackName(from: mutation.text),
                        in: seen.rows, excluding: pre.refs)
                    let bySelection = Self.soleNewlySelectedTrack(
                        in: seen.rows, excluding: pre.refs)
                    guard let extra = byHandle ?? byName ?? bySelection else {
                        cleanup.note("no handle: carried="
                            + (createdHandle ?? "<none>")
                            + " name=" + (Self.createdTrackName(from: mutation.text) ?? "<none reported>")
                            + " selection=<none sole> — nothing deleted")
                        break
                    }
                    cleanup.note("deleting \(extra) via "
                        + (byHandle != nil ? "carried handle"
                            : byName != nil ? "reported name" : "selection"))
                    _ = try? invoke(
                        session, id: cleanupID, tool: "logic_tracks", command: "delete",
                        params: ["target_ref": extra], phase: "phase_c.cleanup")
                    cleanupID += 1
                    // AND VERIFY IT WENT. An unverified delete is a request, not a removal — the
                    // sentence the marker cycle already carries, applied to a costlier object.
                    guard let after = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: pre.count,
                        phase: "phase_c.cleanup_verify") else {
                        cleanup.note("verify read FAILED — removal unconfirmed")
                        break
                    }
                    cleanupID += after.spent
                    if !after.refs.contains(extra) {
                        cleanup.note("confirmed gone")
                        break
                    }
                    cleanup.note("still present after delete")
                }
            }
        }

        let after = try observedTrackInventory(
            session, id: nextID, awaitingCount: pre.count + 1, phase: "phase_c.readback")
        nextID += after.spent
        // A COUNT IS NOT A STABLE QUANTITY HERE. `logic://tracks` reports the rows the arrange rail
        // is SHOWING, so expanding a track stack changes what the number counts without changing
        // the project. Measured 2026-09-15: a run this check called clean had swapped the
        // operator's first track for one of its own — 19 rows before and 19 after, `complete`
        // false then true. Two readings taken at different completeness are not readings of the
        // same thing, and the cycle refuses rather than comparing them.
        guard after.complete == pre.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the track rail's completeness changed between readings "
                    + "(\(String(describing: pre.complete)) -> \(String(describing: after.complete))), "
                    + "so the before and after are not readings of the same thing")
        }
        guard Set(after.refs).isSuperset(of: pre.refs), after.count == pre.count + 1 else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the pre-state references must all still be present and exactly "
                    + "one must be added; count is \(after.count), expected \(pre.count + 1); "
                    + "the operation answered: " + mutation.text.prefix(220))
        }
        // The created track must match BOTH what the operation says it made and a reference that
        // was not in the pre-state, and there must be exactly one such track. "Any new reference"
        // is not safe: under a stack expansion every newly visible child is new.
        // The created track must be identified by something OBSERVED, and the first version of this
        // accepted exactly one source: the name the create reported. Measured 2026-09-15, a create
        // that landed reported no name at all, so the cycle had nothing to remove and left the
        // track in the operator's project. Logic SELECTS a newly created track and it is the only
        // selected one, so the selection answers where the report does not — and neither source is
        // allowed to point at a reference that was already there.
        let createdName = Self.createdTrackName(from: mutation.text)
        let named = Self.soleCreatedTrack(named: createdName, in: after.rows, excluding: pre.refs)
        let selected = Self.soleNewlySelectedTrack(in: after.rows, excluding: pre.refs)
        guard let createdRef = named ?? selected else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: \(spec.id.rawValue) left exactly one new track but the cycle "
                    + "cannot say which: the reported name is "
                    + (createdName.map { "'\($0)'" } ?? "absent")
                    + " and no single new row is selected — it will not delete by guess")
        }
        // Two sources that answer with DIFFERENT tracks is not a tie to break. One of them is wrong
        // and the cycle does not know which, so it removes nothing.
        if let named, let selected, named != selected {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the reported name points at \(named) and the selection at "
                    + "\(selected); the cycle deletes only what both agree on or what only one "
                    + "of them can see")
        }
        createdHandle = createdRef
        let restore = try invoke(
            session, id: nextID, tool: "logic_tracks", command: "delete",
            params: ["target_ref": createdRef], phase: "phase_c.restore",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore: delete refused — the created track is still in the project: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTrackInventory(
            session, id: nextID, awaitingCount: pre.count, phase: "phase_c.restore_readback")
        nextID += restored.spent
        guard restored.complete == pre.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the track rail's completeness changed "
                    + "(\(String(describing: pre.complete)) -> \(String(describing: restored.complete))), "
                    + "so this reading cannot be compared with the pre-state")
        }
        // THE SET, not its size. A balanced count is not proof the right track went — and on a
        // project with a track stack it is not even proof the same rows are being counted.
        guard Set(restored.refs) == Set(pre.refs) else {
            let lost = Set(pre.refs).subtracting(restored.refs)
            let extra = Set(restored.refs).subtracting(pre.refs)
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the project did not come back — "
                    + "\(lost.count) reference(s) missing, \(extra.count) left behind")
        }
        createdNeedsRemoval = false
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

    /// #373 Phase C for `tracks.delete`, against a track the cycle STAGES.
    ///
    /// Deleting one of the operator's tracks to prove a delete works would be the worst trade in
    /// this file. So the cycle creates its own, deletes that, and puts a track of the same kind
    /// back — and the restore is honest about what it restores: the COUNT and the KIND, not the
    /// identity. A created track has no prior identity to return to, and saying otherwise in a
    /// record that exists to be trusted would be worse than the gap it papers over.
    private func trackStagedDeleteCycle(
        _ session: QualificationSubprocessSession,
        startingAt id: Int,
        spec: OperationSpec
    ) throws -> (record: QualificationMutationRestoreRecord, nextID: Int) {
        var nextID = id
        let original = try observedTrackInventory(session, id: nextID, phase: "phase_c.stage_precondition")
        nextID += original.spent

        let staged = try invoke(
            session, id: nextID, tool: "logic_tracks", command: "create_audio", params: [:],
            phase: "phase_c.stage", timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(staged.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.stage: create_audio refused, so there is nothing for \(spec.id.rawValue) "
                    + "to delete: " + staged.text.prefix(220))
        }
        // A TRACK NOW EXISTS. Every exit removes it, waiting for it to appear first and verifying
        // that it went — the shape the create cycle had to learn after it leaked one.
        var stagedNeedsRemoval = true
        // The handle the cycle owns, set the moment the staged track is unambiguous. It is
        // reassigned after the restore, because by then the track this cleanup must remove is the
        // REPLACEMENT and not the one that was staged.
        var stagedHandle: String?
        defer {
            if stagedNeedsRemoval {
                var cleanupID = nextID + 900
                for _ in 0..<3 {
                    guard let seen = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: original.count + 1,
                        phase: "phase_c.cleanup_readback") else { break }
                    cleanupID += seen.spent
                    let byHandle = stagedHandle.flatMap { seen.refs.contains($0) ? $0 : nil }
                    guard let extra = byHandle
                        ?? Self.soleCreatedTrack(
                            named: Self.createdTrackName(from: staged.text),
                            in: seen.rows, excluding: original.refs)
                        ?? Self.soleNewlySelectedTrack(in: seen.rows, excluding: original.refs)
                    else { break }
                    _ = try? invoke(
                        session, id: cleanupID, tool: "logic_tracks", command: "delete",
                        params: ["target_ref": extra], phase: "phase_c.cleanup")
                    cleanupID += 1
                    guard let after = try? observedTrackInventory(
                        session, id: cleanupID, awaitingCount: original.count,
                        phase: "phase_c.cleanup_verify") else { break }
                    cleanupID += after.spent
                    if !after.refs.contains(extra) { break }
                }
            }
        }

        let pre = try observedTrackInventory(
            session, id: nextID, awaitingCount: original.count + 1, phase: "phase_c.pre_state")
        nextID += pre.spent
        let stagedName = Self.createdTrackName(from: staged.text)
        let stagedByName = Self.soleCreatedTrack(
            named: stagedName, in: pre.rows, excluding: original.refs)
        let stagedBySelection = Self.soleNewlySelectedTrack(
            in: pre.rows, excluding: original.refs)
        guard let stagedRef = stagedByName ?? stagedBySelection else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.pre_state: create_audio left exactly one new track but the cycle cannot "
                    + "say which: the reported name is "
                    + (stagedName.map { "'\($0)'" } ?? "absent")
                    + " and no single new row is selected — it will not delete by guess")
        }
        if let stagedByName, let stagedBySelection, stagedByName != stagedBySelection {
            throw QualificationTransportError.protocolViolation(
                "phase_c.pre_state: the reported name points at \(stagedByName) and the selection "
                    + "at \(stagedBySelection); the cycle deletes only what both agree on or what "
                    + "only one of them can see")
        }
        stagedHandle = stagedRef
        let mutation = try invoke(
            session, id: nextID, tool: spec.tool.rawValue, command: spec.command,
            params: ["target_ref": stagedRef], phase: "phase_c.mutation",
            timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTrackInventory(
            session, id: nextID, awaitingCount: original.count, phase: "phase_c.readback")
        nextID += after.spent
        guard after.complete == original.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the track rail's completeness changed between readings, so the "
                    + "before and after are not readings of the same thing")
        }
        guard Set(after.refs) == Set(original.refs), !after.refs.contains(stagedRef) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.readback: the staged track must be gone at a count of \(original.count); "
                    + "the list reports \(after.count) and the reference is "
                    + (after.refs.contains(stagedRef) ? "still there" : "absent"))
        }
        stagedNeedsRemoval = false
        let restore = try invoke(
            session, id: nextID, tool: "logic_tracks", command: "create_audio", params: [:],
            phase: "phase_c.restore", timeout: spec.deadline.seconds + 5)
        nextID += 1
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore: create_audio refused the restore: " + restore.text.prefix(220))
        }
        stagedNeedsRemoval = true
        // THE STAGED REFERENCE IS DEAD HERE — the readback above proved it is gone. Leaving it in
        // the handle would point the cleanup at a track that no longer exists and, worse, make it
        // look like the cleanup had an answer. Clear it before the restore's own track appears.
        stagedHandle = nil
        let restored = try observedTrackInventory(
            session, id: nextID, awaitingCount: original.count + 1,
            phase: "phase_c.restore_readback")
        nextID += restored.spent
        guard restored.complete == original.complete else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the track rail's completeness changed, so this reading "
                    + "cannot be compared with the pre-state")
        }
        // Every reference that was there before must still be there, plus exactly one new one —
        // the replacement. The restore returns the COUNT and the KIND, never the identity.
        guard Set(restored.refs).isSuperset(of: original.refs),
              restored.count == original.count + 1 else {
            throw QualificationTransportError.protocolViolation(
                "phase_c.restore_readback: the pre-state references must all still be present with "
                    + "exactly one replacement added; count is \(restored.count), expected "
                    + "\(original.count + 1)")
        }
        // The replacement is what the cleanup must now remove. Same two sources, same refusal when
        // they disagree — and when neither answers the cleanup re-derives, which is why clearing
        // the dead handle above matters more than setting this one.
        let replacementByName = Self.soleCreatedTrack(
            named: Self.createdTrackName(from: restore.text),
            in: restored.rows, excluding: original.refs)
        let replacementBySelection = Self.soleNewlySelectedTrack(
            in: restored.rows, excluding: original.refs)
        if replacementByName == nil || replacementBySelection == nil
            || replacementByName == replacementBySelection {
            stagedHandle = replacementByName ?? replacementBySelection
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

    /// The reference of the sole SELECTED row whose reference is new, or nil when that is not
    /// exactly one row.
    ///
    /// The cycle cannot rely on the create to name what it created: measured 2026-09-15, a create
    /// that LANDED reported no `observed_track_name` because its own modal reconciliation came back
    /// incomplete, and the cleanup then had nothing it could safely delete. Logic selects a newly
    /// created track and it is the only selected one — measured the same day, twice — so the cycle
    /// takes THAT as its handle, once and immediately, and carries the reference rather than asking
    /// again later.
    ///
    /// The handle is a reference, never a row position. Renaming the track to a name the cycle owns
    /// would be a second identity, but `tracks.rename` is driven by a bare `index`
    /// (`AccessibilityChannel+Tracks.swift:1714`), so taking that route would put positional
    /// targeting back inside the harness to remove a dependency on a readback. The reference is
    /// already an identity the cycle controls; a second one is not worth that.
    static func soleNewlySelectedTrack(
        in rows: [[String: Any]],
        excluding preStateRefs: [String]
    ) -> String? {
        let known = Set(preStateRefs)
        let matches = rows.compactMap { row -> String? in
            guard (row["isSelected"] as? Bool) == true,
                  let ref = row["track_ref"] as? String,
                  !known.contains(ref) else { return nil }
            return ref
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// What a Phase C cleanup actually did, written as it happens so a refusal can carry it.
    ///
    /// The cleanup runs in a `defer`, after the error that triggered it was already built, so its
    /// story cannot go into that message directly. Without a witness the only thing a leak leaves
    /// behind is the leak — which is how four of them in a row got diagnosed by guesswork.
    final class PhaseCCleanupWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []

        func note(_ step: String) {
            lock.lock(); defer { lock.unlock() }
            steps.append(step)
        }

        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return steps.isEmpty ? "cleanup did not run" : steps.joined(separator: " -> ")
        }
    }

    /// The single track a Phase C cycle is allowed to delete, or nil when that is not exactly one.
    ///
    /// Both conditions, never one: the row carries the name the create REPORTED, and its reference
    /// was not in the pre-state. "A reference that is new" alone is unsafe — if the track stack
    /// expands mid-run every newly visible child is new, and the rule would then be free to name
    /// one of the operator's tracks.
    ///
    /// nil means REFUSE. Zero matches and several matches are both answers the caller must not
    /// paper over with a guess, and they are deliberately not distinguished here: neither one
    /// licenses a delete.
    static func soleCreatedTrack(
        named createdName: String?,
        in rows: [[String: Any]],
        excluding preStateRefs: [String]
    ) -> String? {
        guard let createdName,
              !createdName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let known = Set(preStateRefs)
        let matches = rows.compactMap { row -> String? in
            guard (row["name"] as? String) == createdName,
                  let ref = row["track_ref"] as? String,
                  !known.contains(ref) else { return nil }
            return ref
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The name the create operation says it made, or nil when it could not read one.
    ///
    /// The cycles identify what they created by this name AND by a reference that was not in the
    /// pre-state — both, and exactly one candidate — instead of by "any reference that is new".
    /// Measured 2026-09-15: if the track stack EXPANDS mid-run, every newly visible child is a
    /// reference that was not in the pre-state, so the looser rule can name one of the OPERATOR'S
    /// tracks. Narrowing it is what makes that unreachable; refusing when the name is absent is
    /// what keeps a guess from filling the gap.
    private static func createdTrackName(from envelope: String) -> String? {
        guard let data = envelope.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["observed_track_name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    /// The track references currently in the project, with the raw body they were read from.
    ///
    /// `awaitingCount` is what the caller is waiting FOR; nil means "just read". Same discipline as
    /// the marker settle: waiting is not relaxing the assertion, the loop exits early only on the
    /// count the caller already decided is correct.
    private func observedTrackInventory(
        _ session: QualificationSubprocessSession,
        id: Int,
        awaitingCount: Int? = nil,
        phase: String
    ) throws -> (count: Int, refs: [String], rows: [[String: Any]], complete: Bool?, raw: String, spent: Int) {
        var spent = 0
        var last: (Int, [String], [[String: Any]], Bool?, String)?
        for attempt in 0..<6 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.8) }
            _ = try? invoke(
                session, id: id + spent, tool: "logic_system", command: "refresh_cache",
                params: [:], phase: "\(phase).refresh")
            spent += 1
            let data = try resourceReadback(
                session, id: id + spent, uri: "logic://tracks", phase: phase)
            spent += 1
            let raw = String(decoding: data, as: UTF8.self)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]] else {
                throw QualificationTransportError.protocolViolation(
                    "\(phase): logic://tracks did not report any rows")
            }
            let refs = rows.compactMap { $0["track_ref"] as? String }
            last = (rows.count, refs, rows, object["complete"] as? Bool, raw)
            if awaitingCount == nil || rows.count == awaitingCount { break }
        }
        guard let last else {
            throw QualificationTransportError.protocolViolation(
                "\(phase): logic://tracks was never read")
        }
        return (last.0, last.1, last.2, last.3, last.4, spent)
    }

    /// #373 Phase C: the track creations whose restore is a delete of what they made.
    ///
    /// **EMPTY ON PURPOSE — the cycle is written, measured and NOT enabled.** It completes when
    /// driven on its own (create State A, delete State A, count back where it started), and a
    /// sweep driven from the CLI left the project at the count it found. A sweep driven from the
    /// live-gate test then left a track behind anyway, a second time, and the difference between
    /// those two runs is not understood.
    ///
    /// A recipe that can add a track to the operator's project and not remove it does not belong
    /// in a run that touches the operator's project, whatever its evidence would be worth. It
    /// re-enters this set when a run that leaks is understood and a run that does not is
    /// reproducible — not before, and not on the strength of one clean measurement.
    ///
    /// Membership here is what a sweep executes; the cycle below stays so the next attempt starts
    /// from measured code rather than from a description of it.
    /// ONE switch for every Phase C track cycle, because two switches is how the last leak got
    /// out: the create cycle was disabled and the staged-DELETE cycle — which stages by creating a
    /// track — was not, so it kept running and kept leaking. A kill switch that does not cover
    /// every path that writes is not a kill switch.
    ///
    /// **false** until a leaking run is explained AND a clean one is reproducible. The reference-set
    /// verification and the completeness refusal below are necessary and are not, on their own,
    /// that proof.
    static let phaseCTrackCyclesEnabled = false

    static let trackCreateRestoreOperations: Set<OperationID> = [
        .tracksCreateAudio,
        .tracksCreateInstrument,
    ]

    /// Which staged-marker shape a `markerStagedRestoreCycle` run is exercising.
    enum MarkerStagedMode: Sendable {
        /// `navigate.rename_marker`: write a new name, read it back, write the old one.
        case rename
        /// `navigate.delete_marker`: remove the staged marker, read its absence, re-create it.
        case delete
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

        // STAGE THE PRECONDITION the actuator documents, and put the selection back afterwards.
        // The prior selection is read first so the restore returns the operator's own row rather
        // than one this recipe manufactured.
        var priorSelection: Int?
        if Self.requiresExclusiveSelection.contains(spec.id) {
            let before = try observedSelectedTrackIndex(
                session, id: nextID, phase: "phase_b.selection_precondition")
            nextID += before.spent
            priorSelection = before.index
            if before.index != trackIndex {
                _ = try invoke(
                    session, id: step(), tool: spec.tool.rawValue, command: "select",
                    params: ["index": trackIndex], phase: "phase_b.selection_precondition",
                    timeout: spec.deadline.seconds + 5)
                let staged = try observedSelectedTrackIndex(
                    session, id: nextID, phase: "phase_b.selection_precondition_readback")
                nextID += staged.spent
                guard staged.index == trackIndex else {
                    throw QualificationTransportError.protocolViolation(
                        "phase_b.selection_precondition: track \(trackIndex) is not the selected "
                            + "row (\(staged.index.map(String.init) ?? "none")), and "
                            + "\(spec.id.rawValue) refuses to write onto a selection it does not own")
                }
            }
        }
        defer {
            if let priorSelection, priorSelection != trackIndex {
                _ = try? invoke(
                    session, id: nextID + 800, tool: spec.tool.rawValue, command: "select",
                    params: ["index": priorSelection], phase: "phase_b.selection_restore")
            }
        }

        // A POLLED read spends more than two ids, so each one advances `nextID` by what it
        // actually spent. Keeping `readStep()`'s fixed two here would hand a later step an id this
        // read had already used, and the transport matches responses by id.
        let pre = try observedTrackFlag(
            session, id: nextID, trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.pre_state")
        nextID += pre.spent
        let mutation = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, "enabled": !pre.value], phase: "phase_b.mutation",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(mutation.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.mutation: \(spec.id.rawValue) refused the real request: "
                    + mutation.text.prefix(220))
        }
        let after = try observedTrackFlag(
            session, id: nextID, trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.readback", awaiting: !pre.value)
        nextID += after.spent
        guard after.value == !pre.value else {
            // CARRY THE OPERATION'S OWN ANSWER. Without it this refusal says only that a field did
            // not move and discards the one thing that says WHY — measured 2026-09-14, when
            // `tracks.arm` failed here inside the sweep while the identical call moved the flag in
            // a standalone drive, and the envelope that would have separated the two was gone.
            throw QualificationTransportError.protocolViolation(
                "phase_b.readback: \(readbackField) did not move — observed \(after.value), "
                    + "expected \(!pre.value); the operation answered: "
                    + mutation.text.prefix(300))
        }
        let restore = try invoke(
            session, id: step(), tool: spec.tool.rawValue, command: spec.command,
            params: ["index": trackIndex, "enabled": pre.value], phase: "phase_b.restore",
            timeout: spec.deadline.seconds + 5)
        guard !Self.mutationSaysItFailed(restore.text) else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore: \(spec.id.rawValue) refused the restore: "
                    + restore.text.prefix(220))
        }
        let restored = try observedTrackFlag(
            session, id: nextID, trackIndex: trackIndex, field: readbackField,
            phase: "phase_b.restore_readback", awaiting: pre.value)
        nextID += restored.spent
        guard restored.value == pre.value else {
            throw QualificationTransportError.protocolViolation(
                "phase_b.restore_readback: \(readbackField) not restored — observed "
                    + "\(restored.value), expected \(pre.value); the restore answered: "
                    + restore.text.prefix(300))
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
