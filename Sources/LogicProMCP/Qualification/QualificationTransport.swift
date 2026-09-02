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
        failureReason: String?
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
            // A successful write that carries an inadmissible live readback has not been
            // confirmed. Keep the existing no-write deferrals untouched, but make a future
            // Phase-B success path refuse this observation instead of accepting equal stale data.
            if isError == false, !readbackFreshness.isAdmissible { return .notQualified }
            return expectedZeroWriteRefusalObserved ? .notQualified : .failed
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

    /// The outcome used by the live qualification gate. A non-passing
    /// read-only observation is a gate failure; it must not be silently
    /// accounted for with mutating operations that the gate does not exercise.
    var liveGateDisposition: QualificationLiveGateDisposition {
        if status == .failed { return .failed }
        switch liveGateScope {
        case .inScope:
            return status == .passed ? .passed : .failed
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
            return QualificationDeferral(
                code: .liveMutationNotRun,
                detail: "deferred to ADR-001-c: live mutation requires an operation-specific fixture and independent readback"
            )
        case .notQualified where isError == false && semanticReadbackValidated == false:
            return QualificationDeferral(
                code: .semanticMismatch,
                detail: "read-only response did not match its operation-specific independent readback"
            )
        // DERIVED from what the operation answered, not from a list. `clear_traces` needs a set
        // because nothing in its refusal distinguishes "declined on purpose" from "called wrong";
        // this one announces itself, and a list here would be a second place to keep in step with
        // the feature flags.
        case .notQualified where error == HonestContract.FailureError.commandNotExposed.rawValue:
            return QualificationDeferral(
                code: .notExposedInProductionContract,
                detail: "the production MCP contract does not expose this operation; no probe "
                    + "parameter can qualify it while its feature flag is off"
            )
        case .notQualified where QualificationTransport.declinesItsSuccessPathByDesign
            .contains(operationID):
            return QualificationDeferral(
                code: .deliberateZeroWriteProbe,
                detail: "the probe declines this operation's success path by design; reaching it "
                    + "would destroy or mutate state the qualification must not touch"
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

    let total: Int
    let inScopePassed: Int
    let outOfScope: Int
    let mutatingOperationCount: Int
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

    var accounted: Int { inScopePassed + outOfScope + failed }

    var classificationLine: String {
        "qualification live gate: in_scope_passed=\(inScopePassed), "
            + "out_of_scope=\(outOfScope), failed=\(failed) of \(total)"
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
        #if QUALIFICATION_FAULT_SEAM
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
            var operationResults: [String: QualificationOperationResult] = [:]
            for spec in request.operations {
                var response: (text: String, isError: Bool)?
                var responseRequestID: String?
                var responseFailure: String?
                do {
                    if spec.id == .systemSagaExecute {
                        responseRequestID = "5"
                        response = (traceSeedBody.text, traceSeedBody.toolIsError)
                    } else if spec.id == .tracksRename {
                        responseRequestID = "8"
                        response = (negativeBody.text, negativeBody.toolIsError)
                    } else {
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
                            traceID: traceSummary.traceID,
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
                    failureReason: responseFailure ?? readbackFailure
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

    /// Operations whose probe parameters are chosen to REFUSE, not to succeed.
    ///
    /// Kept beside `probeParams` on purpose: the reason an operation is here is a value that
    /// function sends, and separating the two is how a list stops matching the code it describes.
    /// `system.clear_traces` is probed `confirmed: false` so qualification never destroys the
    /// diagnostic evidence it is producing -- its oracle pins the real success contract
    /// (`success == true`, a `receipt_path`, a cleared count), and that contract can only be
    /// satisfied by actually clearing traces.
    /// One spelling of the key, shared by the seed and the probe. Two literals would be two
    /// places to keep in step, and the failure mode is silent: `saga_status` would look up a
    /// record nothing wrote and report exactly what it reported before the seed existed.
    static let sagaProbeIdempotencyKey = "qualification-read-probe"

    static let declinesItsSuccessPathByDesign: Set<String> = [
        OperationID.systemClearTraces.rawValue,
    ]

    private static func probeParams(for spec: OperationSpec, traceID: String) -> [String: Any] {
        if spec.mutability == .mutating {
            return ["__adr001b_no_write_probe": true]
        }
        switch spec.id {
        case .systemListRecentTraces:
            return ["limit": 10]
        case .systemGetTrace:
            return ["trace_id": traceID]
        case .systemClearTraces:
            return ["confirmed": false]
        case .systemHelp:
            return ["category": "system"]
        case .systemSagaPreflight:
            return ["idempotency_key": Self.sagaProbeIdempotencyKey, "steps": []]
        case .systemSagaStatus:
            return ["idempotency_key": Self.sagaProbeIdempotencyKey]

        // #373 Phase A. `default: [:]` sends NO parameters, so every read-only operation that
        // requires one refuses correctly and is recorded as unavailable -- the product working,
        // scored as a failure. `SemanticOracleTable`'s KNOWN GAPS note lists six in that state.
        // These two are the ones a qualifying parameter can fix without a fixture or a side effect.
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
            return ["path": "/System/Library/Sounds/Ping.aiff"]
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
                    let chunk = output.availableData
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
            while true {
                let chunk = error.availableData
                guard !chunk.isEmpty else { break }
                stderr.append(chunk)
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
