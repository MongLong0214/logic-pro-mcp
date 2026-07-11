import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-011 compressor capabilities")
struct CompressorCapabilityTests {
    @Test func manifestSpecializesADR009CapabilitiesByCircuit() throws {
        let manifest = CompressorCapabilityManifest()
        let platinum = manifest.availableParameters(for: .platinum)
        let vintageOpto = manifest.availableParameters(for: .vintageOpto)

        #expect(platinum != vintageOpto)
        #expect(platinum.contains(.knee))
        #expect(!vintageOpto.contains(.knee))
        #expect(manifest.capability(circuit: .vintageOpto, parameter: .knee) == nil)

        for circuit in CompressorCircuitModel.allCases {
            for parameter in manifest.availableParameters(for: circuit) {
                let capability = try #require(
                    manifest.capability(circuit: circuit, parameter: parameter)
                )
                #expect(capability.status == .experimental)
                #expect(capability.qualificationEvidence.isEmpty)
                #expect(!capability.isPubliclyExposable)
            }
        }
    }

    @Test func coordinateOnlyCannotBecomeAPublicVerifiedWrite() {
        #expect(!canPublicVerifiedWrite(.coordinateOnly))
        #expect(canPublicVerifiedWrite(.controlsViewAX))
        #expect(preferredPlane(available: [.coordinateOnly]) == .coordinateOnly)
        #expect(
            preferredPlane(available: [.coordinateOnly, .qualifiedNativeAdapter, .mcuC4])
                == .mcuC4
        )
        #expect(
            preferredPlane(available: [.qualifiedNativeAdapter, .controlsViewAX])
                == .controlsViewAX
        )
        #expect(preferredPlane(available: []) == nil)
    }

    @Test func physicalUnitsRoundTripThroughNormalizedValues() {
        let cases: [(CompressorUnit, Double, ClosedRange<Double>)] = [
            (.decibels, -12, -60 ... 0),
            (.milliseconds, 250, 5 ... 5_000),
            (.ratio, 4, 1 ... 30),
            (.percent, 65, 0 ... 100),
        ]

        for (unit, display, range) in cases {
            let normalized = displayToNormalized(display, unit: unit, range: range)
            let roundTrip = normalizedToDisplay(normalized, unit: unit, range: range)
            #expect(abs(roundTrip - display) < 1e-9)
        }
    }

    @Test func outcomeComparisonUsesRequestedReadbackTolerance() throws {
        let before = snapshot(values: [.thresholdDb: -18, .ratio: 2])
        let after = snapshot(values: [.thresholdDb: -11.95, .ratio: 3.8])
        let outcome = compareOutcome(
            before: before,
            after: after,
            requested: [.thresholdDb: -12, .ratio: 4],
            tolerance: 0.1
        )
        let threshold = try #require(outcome[.thresholdDb])
        let ratio = try #require(outcome[.ratio])

        #expect(threshold.requested == -12)
        #expect(threshold.observed == -11.95)
        #expect(threshold.verified)
        #expect(ratio.requested == 4)
        #expect(ratio.observed == 3.8)
        #expect(!ratio.verified)
    }

    @Test func sagaRequiresCompleteBeforeReadbackAndVerifiedCompensation() {
        let before = snapshot()

        #expect(
            sagaEligibility(
                beforeSnapshot: before,
                readbackPresent: true,
                compensationVerified: true
            ).eligible
        )

        let missingBefore = sagaEligibility(
            beforeSnapshot: nil,
            readbackPresent: true,
            compensationVerified: true
        )
        #expect(!missingBefore.eligible)
        #expect(missingBefore.missing == ["complete_before_snapshot"])

        let missingReadback = sagaEligibility(
            beforeSnapshot: before,
            readbackPresent: false,
            compensationVerified: true
        )
        #expect(!missingReadback.eligible)
        #expect(missingReadback.missing == ["requested_parameter_readback"])

        let missingCompensation = sagaEligibility(
            beforeSnapshot: before,
            readbackPresent: true,
            compensationVerified: false
        )
        #expect(!missingCompensation.eligible)
        #expect(missingCompensation.missing == ["verified_compensation"])

        let incomplete = sagaEligibility(
            beforeSnapshot: snapshot(complete: false, partialReason: "controls unavailable"),
            readbackPresent: true,
            compensationVerified: true
        )
        #expect(!incomplete.eligible)
        #expect(incomplete.missing == ["complete_before_snapshot"])
    }

    @Test func completeSnapshotAlwaysDropsPartialReason() throws {
        let complete = snapshot(complete: true, partialReason: "stale")
        let incomplete = snapshot(complete: false, partialReason: "controls unavailable")

        #expect(complete.partialReason == nil)
        #expect(incomplete.partialReason == "controls unavailable")

        let decoded = try JSONDecoder().decode(
            CompressorStateSnapshot.self,
            from: Data(
                #"{"insertRef":null,"circuit":"platinum","values":[],"complete":true,"partialReason":"stale"}"#.utf8
            )
        )
        #expect(decoded.partialReason == nil)
    }

    @Test func adr011FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR011_COMPRESSOR_CONTROL"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr011CompressorControl)
    }

    private func snapshot(
        values: [CompressorParameter: Double] = [:],
        complete: Bool = true,
        partialReason: String? = nil
    ) -> CompressorStateSnapshot {
        CompressorStateSnapshot(
            insertRef: TargetReference(rawValue: "ins_test"),
            circuit: .platinum,
            values: values,
            complete: complete,
            partialReason: partialReason
        )
    }
}
