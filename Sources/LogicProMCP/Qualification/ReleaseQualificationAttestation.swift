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

struct QualificationCase: Codable, Equatable, Sendable {
    let id: String
    let status: QualificationStatus
    let tool: String
    let command: String
    let traceID: String
    let verified: Bool
    let evidenceFiles: [String]
    let reason: String?

    init(
        id: String,
        status: QualificationStatus,
        tool: String,
        command: String,
        traceID: String,
        verified: Bool,
        evidenceFiles: [String],
        reason: String? = nil
    ) {
        self.id = id
        self.status = status
        self.tool = tool
        self.command = command
        self.traceID = traceID
        self.verified = verified
        self.evidenceFiles = evidenceFiles
        self.reason = reason
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
    }
}

struct CaseEvidence: Codable, Sendable {
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
        failureReason: String? = nil
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
    let startedAt: Date
    let completedAt: Date
    let total: Int
    let passed: Int
    let failed: Int
    let waived: Int
    let cases: [QualificationCase]
    let waivers: [QualificationWaiver]
    let evidenceManifestSHA256: String
}

struct QualificationAxis: Equatable, Sendable {
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

    var key: String {
        "\(variant.rawValue)/\(locale.rawValue)/\(profile.rawValue)/\(cache.rawValue)"
    }
}
