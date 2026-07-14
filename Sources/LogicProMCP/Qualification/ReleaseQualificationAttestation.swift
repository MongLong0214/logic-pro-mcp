import Foundation

enum QualificationStatus: String, Codable, Sendable {
    case passed
    case failed
    case waived
    case skipped
    case notQualified = "not_qualified"
}

enum LogicVariant: String, Codable, CaseIterable, Sendable {
    case desktop
    case creatorStudio = "creator"
}

enum QualificationLocale: String, Codable, CaseIterable, Sendable {
    case enUS = "en-US"
    case koKR = "ko-KR"
}

enum SetupProfile: String, Codable, CaseIterable, Sendable {
    case core
    case full
}

enum CacheState: String, Codable, CaseIterable, Sendable {
    case cold
    case warm
}

enum ProjectFixture: String, Codable, CaseIterable, Sendable {
    case empty
    case medium
    case large
}

enum QualificationVerificationKind: String, Codable, Sendable {
    case readResponse = "read_response"
    case independentReadback = "independent_readback"
    case typedDeferral = "typed_deferral"
}

enum QualificationDeferralCode: String, Codable, Sendable {
    case liveMutationNotRun = "live_mutation_not_run"
    case operationUnavailable = "operation_unavailable"
}

struct QualificationDeferral: Codable, Equatable, Sendable {
    let code: QualificationDeferralCode
    let detail: String
}

struct QualificationReadbackEvidence: Codable, Equatable, Sendable {
    let source: String
    let requestID: String
    let verified: Bool
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case source
        case requestID = "request_id"
        case verified
        case sha256
    }
}

struct QualificationOperationResponseArtifact: Codable, Equatable, Sendable {
    let operationID: String
    let tool: String
    let command: String
    let requestID: String
    let isError: Bool
    let payload: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case tool
        case command
        case requestID = "request_id"
        case isError = "is_error"
        case payload
    }
}

struct QualificationReadbackArtifact: Codable, Equatable, Sendable {
    let source: String
    let requestID: String
    let payload: String

    enum CodingKeys: String, CodingKey {
        case source
        case requestID = "request_id"
        case payload
    }
}

enum QualificationAvailabilityReason: String, Codable, Sendable {
    case differentLogicVariant = "different_logic_variant"
    case differentLogicUILocale = "different_logic_ui_locale"
    case differentLogicVariantAndUILocale = "different_logic_variant_and_ui_locale"
}

struct QualificationVariantAvailability: Codable, Equatable, Sendable {
    let variant: LogicVariant
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

struct QualificationAvailabilityObservation: Codable, Equatable, Sendable {
    let activeBundleID: String
    let activeVariant: LogicVariant
    let logicUILocale: QualificationLocale
    let variants: [QualificationVariantAvailability]

    enum CodingKeys: String, CodingKey {
        case activeBundleID = "active_bundle_id"
        case activeVariant = "active_variant"
        case logicUILocale = "logic_ui_locale"
        case variants
    }
}

struct QualificationCase: Codable, Equatable, Sendable {
    let id: String
    let status: QualificationStatus
    let tool: String
    let command: String
    let traceID: String
    let verified: Bool
    let evidenceFiles: [String]
    let reason: String?
    let binarySHA256: String
    let axis: QualificationAxis
    let operationID: String
    let operationRequestID: String?
    let verificationKind: QualificationVerificationKind
    let deferral: QualificationDeferral?
    let readback: QualificationReadbackEvidence?
    let availabilityReason: QualificationAvailabilityReason?
    let availabilityObservation: QualificationAvailabilityObservation?

    init(
        id: String,
        status: QualificationStatus,
        tool: String,
        command: String,
        traceID: String,
        verified: Bool,
        evidenceFiles: [String],
        reason: String? = nil,
        binarySHA256: String = "unknown",
        axis: QualificationAxis = .defaultAxis,
        operationID: String? = nil,
        operationRequestID: String? = nil,
        verificationKind: QualificationVerificationKind = .typedDeferral,
        deferral: QualificationDeferral? = nil,
        readback: QualificationReadbackEvidence? = nil,
        availabilityReason: QualificationAvailabilityReason? = nil,
        availabilityObservation: QualificationAvailabilityObservation? = nil
    ) {
        self.id = id
        self.status = status
        self.tool = tool
        self.command = command
        self.traceID = traceID
        self.verified = verified
        self.evidenceFiles = evidenceFiles
        self.reason = reason
        self.binarySHA256 = binarySHA256
        self.axis = axis
        self.operationID = operationID ?? id
        self.operationRequestID = operationRequestID
        self.verificationKind = verificationKind
        self.deferral = deferral
        self.readback = readback
        self.availabilityReason = availabilityReason
        self.availabilityObservation = availabilityObservation
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case tool
        case command
        case traceID = "trace_id"
        case verified
        case evidenceFiles = "evidence_files"
        case reason
        case binarySHA256 = "binary_sha256"
        case axis
        case operationID = "operation_id"
        case operationRequestID = "operation_request_id"
        case verificationKind = "verification_kind"
        case deferral
        case readback
        case availabilityReason = "availability_reason"
        case availabilityObservation = "availability_observation"
    }
}

struct CaseEvidence: Codable, Equatable, Sendable {
    let schema: String
    let caseID: String
    let operationID: String
    let tool: String
    let command: String
    let registrySpecFound: Bool
    let handlerBound: Bool
    let traceStarted: Bool
    let traceCompleted: Bool
    let handshakeOK: Bool
    let healthOK: Bool
    let catalogCountMatch: Bool
    let traceOK: Bool
    let negativeFailclosed: Bool
    let observedVariant: String
    let observedLocale: String
    let negativeState: String?
    let negativeWriteAttempted: Bool?
    let healthReadStable: Bool
    let catalogReadStable: Bool
    let failureReason: String?
    let binarySHA256: String
    let axis: QualificationAxis
    let status: QualificationStatus
    let verified: Bool
    let verificationKind: QualificationVerificationKind
    let deferral: QualificationDeferral?
    let readback: QualificationReadbackEvidence?
    let operationResponseSHA256: String?
    let operationRequestID: String?
    let operationIsError: Bool?
    let operationState: String?
    let operationError: String?
    let operationWriteAttempted: Bool?
    let availabilityReason: QualificationAvailabilityReason?
    let availabilityObservation: QualificationAvailabilityObservation?

    init(
        schema: String,
        caseID: String,
        operationID: String,
        tool: String,
        command: String,
        registrySpecFound: Bool,
        handlerBound: Bool,
        traceStarted: Bool,
        traceCompleted: Bool,
        handshakeOK: Bool = false,
        healthOK: Bool = false,
        catalogCountMatch: Bool = false,
        traceOK: Bool = false,
        negativeFailclosed: Bool = false,
        observedVariant: String = "unknown",
        observedLocale: String = "unknown",
        negativeState: String? = nil,
        negativeWriteAttempted: Bool? = nil,
        healthReadStable: Bool = false,
        catalogReadStable: Bool = false,
        failureReason: String? = nil,
        binarySHA256: String = "unknown",
        axis: QualificationAxis = .defaultAxis,
        status: QualificationStatus = .failed,
        verified: Bool = false,
        verificationKind: QualificationVerificationKind = .typedDeferral,
        deferral: QualificationDeferral? = nil,
        readback: QualificationReadbackEvidence? = nil,
        operationResponseSHA256: String? = nil,
        operationRequestID: String? = nil,
        operationIsError: Bool? = nil,
        operationState: String? = nil,
        operationError: String? = nil,
        operationWriteAttempted: Bool? = nil,
        availabilityReason: QualificationAvailabilityReason? = nil,
        availabilityObservation: QualificationAvailabilityObservation? = nil
    ) {
        self.schema = schema
        self.caseID = caseID
        self.operationID = operationID
        self.tool = tool
        self.command = command
        self.registrySpecFound = registrySpecFound
        self.handlerBound = handlerBound
        self.traceStarted = traceStarted
        self.traceCompleted = traceCompleted
        self.handshakeOK = handshakeOK
        self.healthOK = healthOK
        self.catalogCountMatch = catalogCountMatch
        self.traceOK = traceOK
        self.negativeFailclosed = negativeFailclosed
        self.observedVariant = observedVariant
        self.observedLocale = observedLocale
        self.negativeState = negativeState
        self.negativeWriteAttempted = negativeWriteAttempted
        self.healthReadStable = healthReadStable
        self.catalogReadStable = catalogReadStable
        self.failureReason = failureReason
        self.binarySHA256 = binarySHA256
        self.axis = axis
        self.status = status
        self.verified = verified
        self.verificationKind = verificationKind
        self.deferral = deferral
        self.readback = readback
        self.operationResponseSHA256 = operationResponseSHA256
        self.operationRequestID = operationRequestID
        self.operationIsError = operationIsError
        self.operationState = operationState
        self.operationError = operationError
        self.operationWriteAttempted = operationWriteAttempted
        self.availabilityReason = availabilityReason
        self.availabilityObservation = availabilityObservation
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case caseID = "case_id"
        case operationID = "operation_id"
        case tool
        case command
        case registrySpecFound = "registry_spec_found"
        case handlerBound = "handler_bound"
        case traceStarted = "trace_started"
        case traceCompleted = "trace_completed"
        case handshakeOK = "handshake_ok"
        case healthOK = "health_ok"
        case catalogCountMatch = "catalog_count_match"
        case traceOK = "trace_ok"
        case negativeFailclosed = "negative_failclosed"
        case observedVariant = "observed_variant"
        case observedLocale = "observed_locale"
        case negativeState = "negative_state"
        case negativeWriteAttempted = "negative_write_attempted"
        case healthReadStable = "health_read_stable"
        case catalogReadStable = "catalog_read_stable"
        case failureReason = "failure_reason"
        case binarySHA256 = "binary_sha256"
        case axis
        case status
        case verified
        case verificationKind = "verification_kind"
        case deferral
        case readback
        case operationResponseSHA256 = "operation_response_sha256"
        case operationRequestID = "operation_request_id"
        case operationIsError = "operation_is_error"
        case operationState = "operation_state"
        case operationError = "operation_error"
        case operationWriteAttempted = "operation_write_attempted"
        case availabilityReason = "availability_reason"
        case availabilityObservation = "availability_observation"
    }
}

struct QualificationCaseManifest: Codable, Equatable, Sendable {
    let schema: String
    let binarySHA256: String
    let cases: [QualificationCase]

    enum CodingKeys: String, CodingKey {
        case schema
        case binarySHA256 = "binary_sha256"
        case cases
    }
}

struct QualificationWaiver: Codable, Equatable, Sendable {
    static let hostAxisAvailabilityCapability = "ADR-001-a host-axis availability"

    let caseID: String
    let reasonCode: String
    let owningIssue: String
    let userImpact: String
    let affectedCapability: String
    let affectsDefaultProfile: Bool
    let expiryVersion: String
    let releaseNoteVisible: Bool

    var governsHostAxisAvailability: Bool {
        affectedCapability == Self.hostAxisAvailabilityCapability
    }
}

enum QualificationWaiverReasonCode: String, CaseIterable, Sendable {
    case knownLimitation = "known-limitation"
}

enum QualificationWaiverValidationIssue: Equatable, Sendable {
    case invalidField(caseID: String, field: String)
    case duplicateCaseID(caseID: String)
}

struct QualificationWaiverValidator {
    static func issues(in waivers: [QualificationWaiver]) -> [QualificationWaiverValidationIssue] {
        var issues: [QualificationWaiverValidationIssue] = []
        var caseIDs: Set<String> = []
        for waiver in waivers {
            let caseID = waiver.caseID.trimmingCharacters(in: .whitespacesAndNewlines)
            if caseID.isEmpty {
                issues.append(.invalidField(caseID: waiver.caseID, field: "caseID"))
            }
            if QualificationWaiverReasonCode(rawValue: waiver.reasonCode) == nil {
                issues.append(.invalidField(caseID: caseID, field: "reasonCode"))
            }
            if waiver.owningIssue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.invalidField(caseID: caseID, field: "owningIssue"))
            }
            if waiver.userImpact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.invalidField(caseID: caseID, field: "userImpact"))
            }
            if waiver.affectedCapability.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.invalidField(caseID: caseID, field: "affectedCapability"))
            }
            if SemanticVersion(waiver.expiryVersion) == nil {
                issues.append(.invalidField(caseID: caseID, field: "expiryVersion"))
            }
            if !caseID.isEmpty, !caseIDs.insert(caseID).inserted {
                issues.append(.duplicateCaseID(caseID: caseID))
            }
        }
        return issues
    }
}

struct ReleaseQualificationAttestation: Codable, Equatable, Sendable {
    let schema: String
    let serverVersion: String
    let commitSHA: String
    let binarySHA256: String
    let logicVariant: LogicVariant
    let logicVersion: String
    let locale: QualificationLocale
    let profile: SetupProfile
    let cache: CacheState
    let fixture: ProjectFixture
    let startedAt: Date
    let completedAt: Date
    let total: Int
    let passed: Int
    let failed: Int
    let waived: Int
    let cases: [QualificationCase]
    let waivers: [QualificationWaiver]
    let evidenceManifestSHA256: String

    init(
        schema: String,
        serverVersion: String,
        commitSHA: String,
        binarySHA256: String,
        logicVariant: LogicVariant,
        logicVersion: String,
        locale: QualificationLocale,
        profile: SetupProfile,
        cache: CacheState = .cold,
        fixture: ProjectFixture = .empty,
        startedAt: Date,
        completedAt: Date,
        total: Int,
        passed: Int,
        failed: Int,
        waived: Int,
        cases: [QualificationCase],
        waivers: [QualificationWaiver],
        evidenceManifestSHA256: String
    ) {
        self.schema = schema
        self.serverVersion = serverVersion
        self.commitSHA = commitSHA
        self.binarySHA256 = binarySHA256
        self.logicVariant = logicVariant
        self.logicVersion = logicVersion
        self.locale = locale
        self.profile = profile
        self.cache = cache
        self.fixture = fixture
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.total = total
        self.passed = passed
        self.failed = failed
        self.waived = waived
        self.cases = cases
        self.waivers = waivers
        self.evidenceManifestSHA256 = evidenceManifestSHA256
    }
}

struct QualificationAxis: Codable, Equatable, Hashable, Sendable {
    let variant: LogicVariant
    let locale: QualificationLocale
    let profile: SetupProfile
    let cache: CacheState
    let fixture: ProjectFixture

    static let requiredCombinations: [QualificationAxis] = [
        QualificationAxis(
            variant: .desktop,
            locale: .enUS,
            profile: .core,
            cache: .cold,
            fixture: .empty
        ),
        QualificationAxis(
            variant: .desktop,
            locale: .koKR,
            profile: .core,
            cache: .cold,
            fixture: .empty
        ),
        QualificationAxis(
            variant: .creatorStudio,
            locale: .enUS,
            profile: .core,
            cache: .cold,
            fixture: .empty
        ),
        QualificationAxis(
            variant: .creatorStudio,
            locale: .koKR,
            profile: .core,
            cache: .cold,
            fixture: .empty
        ),
    ]

    static func requiredAxes(
        profile: SetupProfile,
        cache: CacheState,
        fixture: ProjectFixture
    ) -> [QualificationAxis] {
        requiredCombinations.map {
            QualificationAxis(
                variant: $0.variant,
                locale: $0.locale,
                profile: profile,
                cache: cache,
                fixture: fixture
            )
        }
    }

    static let defaultAxis = QualificationAxis(
        variant: .desktop,
        locale: .enUS,
        profile: .core,
        cache: .cold,
        fixture: .empty
    )

    var key: String {
        "\(variant.rawValue)/\(locale.rawValue)/\(profile.rawValue)/\(cache.rawValue)/\(fixture.rawValue)"
    }
}
