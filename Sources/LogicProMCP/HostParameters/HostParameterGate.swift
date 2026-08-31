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
    // A readable normalized value is not a write/readback qualification. Keep
    // it out of the host-write surface even after a manifest is approved.
    return manifest.parameters.filter { $0.valueKind == .exactWriteReadback }
}

enum HostWriteRejection: Equatable, Sendable {
    case manifestNotApproved
    case manifestInvalidated(reason: String)
    case providerNotHostVerified
    case readbackOnlyParameter(TargetReference)
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
    switch valueKind {
    case .exactWriteReadback:
        break
    case .normalizedReadbackOnly:
        rejections.append(.readbackOnlyParameter(parameterRef))
    case .unsupported, nil:
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
