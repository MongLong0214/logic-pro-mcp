func isManifestValid(
    _ manifest: PluginCapabilityManifest,
    currentBuildFingerprint: String,
    currentUISignature: String
) -> Bool {
    manifest.buildFingerprint == currentBuildFingerprint
        && manifest.uiSignatureFingerprint == currentUISignature
}

func publicParameters(
    _ manifest: PluginCapabilityManifest,
    currentBuildFingerprint: String,
    currentUISignature: String
) -> [GenericPluginParameter] {
    guard manifest.approved,
          isManifestValid(
              manifest,
              currentBuildFingerprint: currentBuildFingerprint,
              currentUISignature: currentUISignature
          ),
          manifest.provider.canHostVerifiedWrite
    else {
        return []
    }
    return manifest.parameters.filter { $0.valueKind != .unsupported }
}

enum HostWriteRejection: Equatable, Sendable {
    case manifestNotApproved
    case manifestInvalidated(reason: String)
    case providerNotHostVerified
    case unsupportedParameter(TargetReference)
}

func validateHostWrite(
    manifest: PluginCapabilityManifest,
    parameterRef: TargetReference,
    currentBuildFingerprint: String,
    currentUISignature: String
) -> [HostWriteRejection] {
    var rejections: [HostWriteRejection] = []
    if !manifest.approved {
        rejections.append(.manifestNotApproved)
    }

    var invalidationReasons: [String] = []
    if manifest.buildFingerprint != currentBuildFingerprint {
        invalidationReasons.append("build_fingerprint_changed")
    }
    if manifest.uiSignatureFingerprint != currentUISignature {
        invalidationReasons.append("ui_signature_changed")
    }
    if !invalidationReasons.isEmpty {
        rejections.append(.manifestInvalidated(reason: invalidationReasons.joined(separator: ",")))
    }

    if !manifest.provider.canHostVerifiedWrite {
        rejections.append(.providerNotHostVerified)
    }
    let valueKind = manifest.parameters.first {
        $0.parameterRef == parameterRef
    }?.valueKind
    if valueKind == nil || valueKind == .unsupported {
        rejections.append(.unsupportedParameter(parameterRef))
    }
    return rejections
}

func sagaEligibility(
    fullParameterSnapshotPresent: Bool,
    verifiedInverseSnapshotPresent: Bool
) -> (eligible: Bool, missing: [String]) {
    var missing: [String] = []
    if !fullParameterSnapshotPresent {
        missing.append("full_parameter_snapshot")
    }
    if !verifiedInverseSnapshotPresent {
        missing.append("verified_inverse_snapshot")
    }
    return (eligible: missing.isEmpty, missing: missing)
}
