import Foundation

enum QualificationStatus: String, Codable, Sendable {
    case passed
    case failed
    case waived
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

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case tool
        case command
        case traceID = "trace_id"
        case verified
        case evidenceFiles = "evidence_files"
    }
}

struct QualificationWaiver: Codable, Equatable, Sendable {
    let caseID: String
    let reasonCode: String
    let owningIssue: String
    let userImpact: String
    let affectedCapability: String
    let affectsDefaultProfile: Bool
    let expiryVersion: String
    let releaseNoteVisible: Bool
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
