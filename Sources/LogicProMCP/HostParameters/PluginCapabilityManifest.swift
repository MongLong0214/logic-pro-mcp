enum GenericParameterValueKind: String, Codable, Sendable {
    case exactWriteReadback
    case normalizedReadbackOnly
    case unsupported
}

/// The accessibility role observed at the control paired with a Controls-view
/// row label. This is an addressability fact, not evidence that the control can
/// be written successfully.
enum GenericParameterControlRole: String, Codable, Equatable, Sendable {
    case slider = "AXSlider"
    case checkBox = "AXCheckBox"
    case popUpButton = "AXPopUpButton"
    case radioButton = "AXRadioButton"
}

struct GenericPluginParameter: Codable, Equatable, Sendable {
    let parameterRef: TargetReference
    let name: String
    let valueKind: GenericParameterValueKind
    /// Present when a producer has observed the AX role used to address this
    /// parameter. Older producers did not have that observation.
    let controlRole: GenericParameterControlRole?
    let page: Int
    let index: Int

    init(
        parameterRef: TargetReference,
        name: String,
        valueKind: GenericParameterValueKind,
        controlRole: GenericParameterControlRole? = nil,
        page: Int,
        index: Int
    ) {
        self.parameterRef = parameterRef
        self.name = name
        self.valueKind = valueKind
        self.controlRole = controlRole
        self.page = page
        self.index = index
    }
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
