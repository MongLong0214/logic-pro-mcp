import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-009 plugin capabilities")
struct PluginCapabilityTests {
    private let compressor = PluginIdentity(
        manufacturer: "Apple",
        name: "Compressor",
        type: "effect"
    )

    @Test func candidatesStayExperimentalAndPublicSurfaceIsEmpty() {
        let registry = CapabilityRegistry()
        let candidates = registry.allCapabilities()

        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.status == .experimental })
        #expect(candidates.allSatisfy { $0.qualificationEvidence.isEmpty })
        #expect(registry.publicCapabilities().isEmpty)
    }

    @Test func publicStatusWithoutEvidenceIsNotExposable() {
        let withoutEvidence = capability(status: .public)
        let withEvidence = capability(
            status: .public,
            evidence: [EvidenceReference(id: "qualification-1", kind: "live_matrix")]
        )

        #expect(!withoutEvidence.isPubliclyExposable)
        #expect(withEvidence.isPubliclyExposable)
    }

    @Test func toleranceProducesConfirmedOrExactMismatch() {
        let subject = capability(tolerance: 0.1)

        #expect(verifyReadback(capability: subject, written: -12, observed: -11.9) == .confirmed)
        #expect(
            verifyReadback(capability: subject, written: -12, observed: -11.89)
                == .mismatch(observed: -11.89, expected: -12, tolerance: 0.1)
        )
    }

    @Test func outOfRangeWriteIsRejectedDuringPreflight() {
        let parameter = ParameterID(rawValue: "threshold")
        let registry = CapabilityRegistry(capabilities: [
            capability(parameterID: parameter, allowedRange: -60 ... 0),
        ])
        let request = BatchApplyRequest(
            pluginIdentity: compressor,
            targets: [(parameter, 1)]
        )

        #expect(
            planBatchApply(request, registry: registry)
                == .failure(
                    .valueOutOfRange(
                        parameterID: parameter,
                        value: 1,
                        allowedRange: -60 ... 0
                    )
                )
        )
    }

    @Test func lookupFindsRegisteredPairAndUnsupportedPreflightFailsClosed() {
        let registry = CapabilityRegistry()
        let registered = ParameterID(rawValue: "threshold")
        let unknown = ParameterID(rawValue: "not_registered")

        #expect(registry.capability(pluginIdentity: compressor, parameterID: registered) != nil)
        #expect(registry.capability(pluginIdentity: compressor, parameterID: unknown) == nil)

        // Use an in-range value for the registered param so the only preflight
        // problem is the unsupported param — isolates the fail-closed path this
        // test asserts (an out-of-range value would fail closed first, correctly,
        // but on a different typed error).
        let request = BatchApplyRequest(
            pluginIdentity: compressor,
            targets: [(registered, 50), (unknown, 0)]
        )
        #expect(
            planBatchApply(request, registry: registry)
                == .failure(.unsupportedParameter(unknown))
        )
    }

    @Test func partialBatchFailureIsNeverTopLevelSuccess() {
        let threshold = ParameterID(rawValue: "threshold")
        let ratio = ParameterID(rawValue: "ratio")
        let mismatch = ReadbackVerdict.mismatch(
            observed: 3.5,
            expected: 4,
            tolerance: 0.1
        )
        let result = BatchApplyResult(
            appliedVerified: [threshold],
            failed: [(ratio, mismatch)],
            complete: false
        )
        let outcome = BatchApplyOutcome(result)

        #expect(result == BatchApplyResult(
            appliedVerified: [threshold],
            failed: [(ratio, mismatch)],
            complete: false
        ))
        #expect(outcome == .partialFailure(result))
        #expect(!outcome.isSuccess)
    }

    @Test func snapshotDiffReportsOnlyChangedValues() throws {
        let threshold = ParameterID(rawValue: "threshold")
        let ratio = ParameterID(rawValue: "ratio")
        let before = ParameterSnapshot(
            pluginIdentity: compressor,
            values: [threshold: -12, ratio: 4]
        )
        let after = ParameterSnapshot(
            pluginIdentity: compressor,
            values: [threshold: -10, ratio: 4]
        )

        let diff = snapshotDiff(before: before, after: after)
        let change = try #require(diff[threshold])

        #expect(diff.count == 1)
        #expect(change.before == -12)
        #expect(change.after == -10)
    }

    @Test func parameterValueTypesRoundTrip() throws {
        let values: [ParameterValueType] = [
            .normalized,
            .decibels,
            .milliseconds,
            .hertz,
            .ratio,
            .enumerated,
            .boolean,
        ]

        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([ParameterValueType].self, from: data) == values)
    }

    @Test func adr009FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR009_PLUGIN_CAPABILITIES"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr009PluginCapabilities)
    }

    private func capability(
        parameterID: ParameterID = ParameterID(rawValue: "threshold"),
        allowedRange: ClosedRange<Double>? = -60 ... 0,
        tolerance: Double = 0.01,
        status: CapabilityStatus = .experimental,
        evidence: [EvidenceReference] = []
    ) -> VerifiedParameterCapability {
        VerifiedParameterCapability(
            pluginIdentity: compressor,
            parameterID: parameterID,
            displayName: "Threshold",
            valueType: .decibels,
            allowedRange: allowedRange,
            writeMethod: .axValue,
            readbackMethod: .axValue,
            tolerance: tolerance,
            requiredView: .controls,
            selectorSignatures: ["AXSlider:Threshold"],
            qualificationEvidence: evidence,
            status: status
        )
    }
}
