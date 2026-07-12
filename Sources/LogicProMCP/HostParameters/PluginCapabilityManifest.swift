enum GenericParameterValueKind: String, Codable, Sendable {
    case exactWriteReadback
    case normalizedReadbackOnly
    case unsupported
}

struct GenericPluginParameter: Codable, Equatable, Sendable {
    let parameterRef: TargetReference
    let name: String
    let valueKind: GenericParameterValueKind
    let page: Int
    let index: Int
}

struct PluginCapabilityManifest: Codable, Equatable, Sendable {
    let provider: PluginParameterProvider
    let pluginName: String
    let buildFingerprint: String
    let uiSignatureFingerprint: String
    let parameters: [GenericPluginParameter]
    let approved: Bool
    let manifestFingerprint: String
}
