struct CapabilityRegistry: Sendable {
    private let capabilities: [VerifiedParameterCapability]

    init(capabilities: [VerifiedParameterCapability] = Self.candidates) {
        self.capabilities = capabilities
    }

    func allCapabilities() -> [VerifiedParameterCapability] {
        capabilities
    }

    func publicCapabilities() -> [VerifiedParameterCapability] {
        capabilities.filter { $0.status == .public && $0.isPubliclyExposable }
    }

    func capability(
        pluginIdentity: PluginIdentity,
        parameterID: ParameterID
    ) -> VerifiedParameterCapability? {
        capabilities.first {
            $0.pluginIdentity == pluginIdentity && $0.parameterID == parameterID
        }
    }

    private static let compressor = PluginIdentity(
        manufacturer: "Apple",
        name: "Compressor",
        type: "effect"
    )
    private static let gain = PluginIdentity(
        manufacturer: "Apple",
        name: "Gain",
        type: "effect"
    )
    private static let limiter = PluginIdentity(
        manufacturer: "Apple",
        name: "Limiter",
        type: "effect"
    )

    private static let candidates: [VerifiedParameterCapability] = [
        candidate(compressor, "threshold", "Threshold", .normalized, 0 ... 100, 1),
        candidate(compressor, "ratio", "Ratio", .ratio, 1 ... 30, 0.01),
        candidate(compressor, "attack", "Attack", .milliseconds, 0 ... 200, 0.1),
        candidate(compressor, "release", "Release", .milliseconds, 5 ... 5_000, 1),
        candidate(compressor, "makeup", "Makeup", .decibels, -20 ... 20, 0.1),
        candidate(gain, "gain", "Gain", .decibels, -96 ... 24, 0.1),
        candidate(gain, "phaseInvert", "Phase Invert", .boolean, 0 ... 1, 0),
        candidate(limiter, "gain", "Gain", .decibels, 0 ... 24, 0.1),
        candidate(limiter, "outputCeiling", "Output Ceiling", .decibels, -24 ... 0, 0.1),
        candidate(limiter, "release", "Release", .milliseconds, 10 ... 1_000, 1),
    ]

    private static func candidate(
        _ pluginIdentity: PluginIdentity,
        _ parameterID: String,
        _ displayName: String,
        _ valueType: ParameterValueType,
        _ allowedRange: ClosedRange<Double>,
        _ tolerance: Double
    ) -> VerifiedParameterCapability {
        VerifiedParameterCapability(
            pluginIdentity: pluginIdentity,
            parameterID: ParameterID(rawValue: parameterID),
            displayName: displayName,
            valueType: valueType,
            allowedRange: allowedRange,
            writeMethod: .axValue,
            readbackMethod: .axValue,
            tolerance: tolerance,
            requiredView: .controls,
            selectorSignatures: [],
            qualificationEvidence: [],
            status: .experimental
        )
    }
}
