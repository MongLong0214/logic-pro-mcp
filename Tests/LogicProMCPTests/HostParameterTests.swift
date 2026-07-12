import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-018 host parameters")
struct HostParameterTests {
    @Test func onlyLogicHostedPlanesCanVerifyWrites() {
        #expect(PluginParameterProvider.mcuC4PluginEdit.canHostVerifiedWrite)
        #expect(PluginParameterProvider.controlsViewAX.canHostVerifiedWrite)
        #expect(!PluginParameterProvider.separateAUInstance.canHostVerifiedWrite)
        #expect(!PluginParameterProvider.pixelGUI.canHostVerifiedWrite)
    }

    @Test func preferredPlaneUsesProviderPriority() {
        #expect(preferredHostPlane(available: []) == nil)
        #expect(
            preferredHostPlane(available: [.pixelGUI, .controlsViewAX, .separateAUInstance])
                == .controlsViewAX
        )
        #expect(
            preferredHostPlane(available: [.pixelGUI, .mcuC4PluginEdit, .controlsViewAX])
                == .mcuC4PluginEdit
        )
    }

    @Test func fingerprintChangesInvalidateManifestAndHideParameters() {
        let parameter = makeParameter("ins_gain", .exactWriteReadback)
        let subject = makeManifest(
            provider: .mcuC4PluginEdit,
            approved: true,
            parameters: [parameter]
        )

        #expect(
            isManifestValid(
                subject,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            )
        )
        #expect(
            !isManifestValid(
                subject,
                currentBuildFingerprint: "build-2",
                currentUISignature: "ui-1"
            )
        )
        #expect(
            !isManifestValid(
                subject,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-2"
            )
        )
        #expect(
            publicParameters(
                subject,
                currentBuildFingerprint: "build-2",
                currentUISignature: "ui-1"
            ).isEmpty
        )
        #expect(
            publicParameters(
                subject,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-2"
            ).isEmpty
        )
    }

    @Test func unapprovedManifestFailsClosed() {
        let parameter = makeParameter("ins_gain", .exactWriteReadback)
        let subject = makeManifest(
            provider: .mcuC4PluginEdit,
            approved: false,
            parameters: [parameter]
        )

        #expect(
            publicParameters(
                subject,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ).isEmpty
        )
        #expect(
            validateHostWrite(
                manifest: subject,
                parameterRef: parameter.parameterRef,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ) == [.manifestNotApproved]
        )
    }

    @Test func unsupportedParameterIsHiddenAndRejected() {
        let supported = makeParameter("ins_gain", .exactWriteReadback)
        let unsupported = makeParameter("ins_unknown", .unsupported)
        let subject = makeManifest(
            provider: .controlsViewAX,
            approved: true,
            parameters: [supported, unsupported]
        )

        #expect(
            publicParameters(
                subject,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ) == [supported]
        )
        #expect(
            validateHostWrite(
                manifest: subject,
                parameterRef: unsupported.parameterRef,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ) == [.unsupportedParameter(unsupported.parameterRef)]
        )
    }

    @Test func nonHostedProviderCannotExposeOrValidateWrite() {
        let parameter = makeParameter("ins_gain", .exactWriteReadback)
        let subject = makeManifest(
            provider: .separateAUInstance,
            approved: true,
            parameters: [parameter]
        )

        #expect(
            publicParameters(
                subject,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ).isEmpty
        )
        #expect(
            validateHostWrite(
                manifest: subject,
                parameterRef: parameter.parameterRef,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ) == [.providerNotHostVerified]
        )
    }

    @Test func approvedValidHostVerifiedParameterPasses() {
        let parameter = makeParameter("ins_gain", .exactWriteReadback)
        let subject = makeManifest(
            provider: .mcuC4PluginEdit,
            approved: true,
            parameters: [parameter]
        )

        #expect(
            publicParameters(
                subject,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ) == [parameter]
        )
        #expect(
            validateHostWrite(
                manifest: subject,
                parameterRef: parameter.parameterRef,
                currentBuildFingerprint: "build-1",
                currentUISignature: "ui-1"
            ).isEmpty
        )
    }

    @Test func invalidWriteReportsDeterministicFingerprintReasons() {
        let parameter = makeParameter("ins_gain", .exactWriteReadback)
        let subject = makeManifest(
            provider: .mcuC4PluginEdit,
            approved: true,
            parameters: [parameter]
        )

        #expect(
            validateHostWrite(
                manifest: subject,
                parameterRef: parameter.parameterRef,
                currentBuildFingerprint: "build-2",
                currentUISignature: "ui-2"
            ) == [.manifestInvalidated(
                reason: "build_fingerprint_changed,ui_signature_changed"
            )]
        )
    }

    @Test func sagaRequiresFullAndVerifiedInverseSnapshots() {
        let eligible = sagaEligibility(
            fullParameterSnapshotPresent: true,
            verifiedInverseSnapshotPresent: true
        )
        #expect(eligible.eligible)
        #expect(eligible.missing.isEmpty)

        #expect(
            sagaEligibility(
                fullParameterSnapshotPresent: false,
                verifiedInverseSnapshotPresent: true
            ).missing == ["full_parameter_snapshot"]
        )
        #expect(
            sagaEligibility(
                fullParameterSnapshotPresent: true,
                verifiedInverseSnapshotPresent: false
            ).missing == ["verified_inverse_snapshot"]
        )
        let neither = sagaEligibility(
            fullParameterSnapshotPresent: false,
            verifiedInverseSnapshotPresent: false
        )
        #expect(!neither.eligible)
        #expect(neither.missing == ["full_parameter_snapshot", "verified_inverse_snapshot"])
    }

    @Test func manifestCodableRoundTrips() throws {
        let subject = makeManifest(
            provider: .controlsViewAX,
            approved: true,
            parameters: [
                makeParameter("ins_gain", .exactWriteReadback),
                makeParameter("ins_mix", .normalizedReadbackOnly),
                makeParameter("ins_unknown", .unsupported),
            ]
        )

        let encoded = try JSONEncoder().encode(subject)
        #expect(try JSONDecoder().decode(PluginCapabilityManifest.self, from: encoded) == subject)
    }

    @Test func adr018FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR018_HOST_PARAMS"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr018HostParams)
    }

    private func makeParameter(
        _ rawReference: String,
        _ valueKind: GenericParameterValueKind
    ) -> GenericPluginParameter {
        GenericPluginParameter(
            parameterRef: TargetReference(rawValue: rawReference),
            name: rawReference,
            valueKind: valueKind,
            page: 0,
            index: 0
        )
    }

    private func makeManifest(
        provider: PluginParameterProvider,
        approved: Bool,
        parameters: [GenericPluginParameter]
    ) -> PluginCapabilityManifest {
        PluginCapabilityManifest(
            provider: provider,
            pluginName: "Synthetic Plug-in",
            buildFingerprint: "build-1",
            uiSignatureFingerprint: "ui-1",
            parameters: parameters,
            approved: approved,
            manifestFingerprint: "manifest-1"
        )
    }
}
