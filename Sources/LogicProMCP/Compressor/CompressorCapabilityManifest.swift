enum CompressorCircuitModel: String, Codable, CaseIterable, Hashable, Sendable {
    case platinum
    case studioVCA
    case studioFET
    case classicVCA
    case vintageVCA
    case vintageFET
    case vintageOpto
}

enum CompressorParameter: String, Codable, CaseIterable, Hashable, Sendable {
    case circuitModel
    case inputGainDb
    case thresholdDb
    case ratio
    case knee
    case attackMs
    case releaseMs
    case autoReleaseEnabled
    case makeupGainDb
    case autoGainMode
    case mixPercent
    case outputGainDb
    case limiterEnabled
}

/// Compressor-specific specialization of ADR-009 capabilities, not a competing registry.
struct CompressorCapabilityManifest: Sendable {
    func availableParameters(for circuit: CompressorCircuitModel) -> Set<CompressorParameter> {
        var parameters = Set(CompressorParameter.allCases)
        switch circuit {
        case .platinum, .studioVCA, .studioFET, .classicVCA:
            break
        case .vintageVCA:
            parameters.remove(.autoReleaseEnabled)
        case .vintageFET:
            parameters.remove(.knee)
        case .vintageOpto:
            parameters.subtract([.knee, .autoReleaseEnabled])
        }
        return parameters
    }

    func capability(
        circuit: CompressorCircuitModel,
        parameter: CompressorParameter
    ) -> VerifiedParameterCapability? {
        guard availableParameters(for: circuit).contains(parameter) else { return nil }
        let details = details(for: parameter)
        return VerifiedParameterCapability(
            pluginIdentity: PluginIdentity(
                manufacturer: "Apple",
                name: "Compressor",
                type: "effect"
            ),
            parameterID: ParameterID(rawValue: parameter.rawValue),
            displayName: details.displayName,
            valueType: details.valueType,
            allowedRange: details.range,
            writeMethod: .axValue,
            readbackMethod: .axValue,
            tolerance: details.tolerance,
            requiredView: .controls,
            selectorSignatures: [],
            qualificationEvidence: [],
            status: .experimental
        )
    }

    private func details(
        for parameter: CompressorParameter
    ) -> (
        displayName: String,
        valueType: ParameterValueType,
        range: ClosedRange<Double>,
        tolerance: Double
    ) {
        switch parameter {
        case .circuitModel:
            ("Circuit Model", .enumerated, 0 ... 6, 0)
        case .inputGainDb:
            ("Input Gain", .decibels, -20 ... 20, 0.1)
        case .thresholdDb:
            ("Threshold", .decibels, -60 ... 0, 0.1)
        case .ratio:
            ("Ratio", .ratio, 1 ... 30, 0.01)
        case .knee:
            ("Knee", .normalized, 0 ... 100, 0.1)
        case .attackMs:
            ("Attack", .milliseconds, 0 ... 200, 0.1)
        case .releaseMs:
            ("Release", .milliseconds, 5 ... 5_000, 1)
        case .autoReleaseEnabled:
            ("Auto Release", .boolean, 0 ... 1, 0)
        case .makeupGainDb:
            ("Makeup Gain", .decibels, -20 ... 20, 0.1)
        case .autoGainMode:
            ("Auto Gain", .enumerated, 0 ... 2, 0)
        case .mixPercent:
            ("Mix", .normalized, 0 ... 100, 0.1)
        case .outputGainDb:
            ("Output Gain", .decibels, -20 ... 20, 0.1)
        case .limiterEnabled:
            ("Limiter", .boolean, 0 ... 1, 0)
        }
    }
}
