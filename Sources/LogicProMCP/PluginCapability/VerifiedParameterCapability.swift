import Foundation

struct PluginIdentity: Codable, Hashable, Sendable {
    let manufacturer: String
    let name: String
    let type: String
}

struct ParameterID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum ParameterValueType: String, Codable, Sendable {
    case normalized
    case decibels
    case milliseconds
    case hertz
    case ratio
    case enumerated
    case boolean
}

enum PluginWriteMethod: String, Codable, Sendable {
    case axValue
    case axIncrement
    case textField
}

enum PluginReadbackMethod: String, Codable, Sendable {
    case axValue
    case displayString
}

enum PluginView: String, Codable, Sendable {
    case controls
    case editor
}

enum CapabilityStatus: String, Codable, Sendable {
    case experimental
    case qualified
    case `public`
    case deprecated
}

struct EvidenceReference: Codable, Hashable, Sendable {
    let id: String
    let kind: String
}

struct VerifiedParameterCapability: Codable, Equatable, Sendable {
    let pluginIdentity: PluginIdentity
    let parameterID: ParameterID
    let displayName: String
    let valueType: ParameterValueType
    let allowedRange: ClosedRange<Double>?
    let writeMethod: PluginWriteMethod
    let readbackMethod: PluginReadbackMethod
    let tolerance: Double
    let requiredView: PluginView
    let selectorSignatures: Set<String>
    let qualificationEvidence: [EvidenceReference]
    let status: CapabilityStatus

    var isPubliclyExposable: Bool {
        status == .public && !qualificationEvidence.isEmpty
    }
}
