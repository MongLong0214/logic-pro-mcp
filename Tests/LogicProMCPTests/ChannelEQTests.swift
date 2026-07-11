import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-013 Channel EQ")
struct ChannelEQTests {
    @Test func absentEQRejectsBandWrite() {
        let rejections = validateBandWrite(
            state: state(present: false),
            band: 3,
            frequencyHz: 1_000,
            gainOrSlope: 0,
            q: 1,
            plane: .c4ControlSurface,
            expectedEpoch: 7,
            actualEpoch: 7
        )

        #expect(rejections == [.eqAbsent])
    }

    @Test func coordinateOnlyPlaneIsNeverPublic() {
        #expect(!EQWritePlane.coordinateOnly.isPublicVerifiedWritable)
        #expect(EQWritePlane.c4ControlSurface.isPublicVerifiedWritable)
        #expect(EQWritePlane.qualifiedAXControls.isPublicVerifiedWritable)
        #expect(EQWritePlane.c4ControlSurface < .qualifiedAXControls)
    }

    @Test func bandAndParameterRangesFailClosed() {
        let snapshot = state()

        #expect(
            validateBandWrite(
                state: snapshot,
                band: 0,
                frequencyHz: 1_000,
                gainOrSlope: 0,
                q: 1,
                plane: .c4ControlSurface,
                expectedEpoch: nil,
                actualEpoch: nil
            ).contains(.bandOutOfRange(0))
        )

        let invalidValues = validateBandWrite(
            state: snapshot,
            band: 3,
            frequencyHz: 19,
            gainOrSlope: 25,
            q: 0.09,
            plane: .c4ControlSurface,
            expectedEpoch: nil,
            actualEpoch: nil
        )
        #expect(
            invalidValues == [
                .frequencyOutOfRange(19),
                .gainOutOfRange(25),
                .qOutOfRange(0.09),
            ]
        )

        #expect(
            validateBandWrite(
                state: snapshot,
                band: 1,
                frequencyHz: 20,
                gainOrSlope: 0,
                q: 100,
                plane: .qualifiedAXControls,
                expectedEpoch: nil,
                actualEpoch: nil
            ).contains(.gainOutOfRange(0))
        )
    }

    @Test func staleEpochRejectsBandWrite() {
        let rejections = validateBandWrite(
            state: state(),
            band: 4,
            frequencyHz: 500,
            gainOrSlope: -2,
            q: 1.2,
            plane: .qualifiedAXControls,
            expectedEpoch: 4,
            actualEpoch: 5
        )

        #expect(rejections == [.staleTarget])
    }

    @Test func validPresentBandWritePassesPreflight() {
        let rejections = validateBandWrite(
            state: state(),
            band: 3,
            frequencyHz: 1_000,
            gainOrSlope: -2,
            q: 1,
            plane: .c4ControlSurface,
            expectedEpoch: 9,
            actualEpoch: 9
        )

        #expect(rejections.isEmpty)
    }

    @Test func sagaRequiresFullBeforeSnapshotAndVerifiedRestore() {
        let eligible = sagaEligibility(beforeSnapshot: state(), restoreVerified: true)
        #expect(eligible.eligible)
        #expect(eligible.missing.isEmpty)

        let missingRestore = sagaEligibility(beforeSnapshot: state(), restoreVerified: false)
        #expect(!missingRestore.eligible)
        #expect(missingRestore.missing == ["verified_restore"])

        let incomplete = sagaEligibility(
            beforeSnapshot: state(complete: false, partialReason: "readback incomplete"),
            restoreVerified: true
        )
        #expect(!incomplete.eligible)
        #expect(incomplete.missing == ["full_8_band_before_snapshot"])

        let absent = sagaEligibility(beforeSnapshot: state(present: false), restoreVerified: true)
        #expect(!absent.eligible)
        #expect(absent.missing == ["full_8_band_before_snapshot"])

        let missing = sagaEligibility(beforeSnapshot: nil, restoreVerified: true)
        #expect(!missing.eligible)
        #expect(missing.missing == ["full_8_band_before_snapshot"])
    }

    @Test func comparisonReportsExactChangedBandParameters() {
        let before = state()
        var changedBands = bands()
        changedBands[2] = band(
            3,
            .parametric1,
            frequencyHz: 300,
            gainOrSlope: -3,
            q: 1.2,
            enabled: false
        )
        changedBands[7] = band(8, .lowPass, frequencyHz: 16_000, gainOrSlope: 12, q: 1.5)

        let changes = compareChannelEQ(before: before, after: state(bands: changedBands))

        #expect(changes.count == 4)
        #expect(changes[0].band == 3)
        #expect(changes[0].field == "frequencyHz")
        #expect(changes[0].before == 250)
        #expect(changes[0].after == 300)
        #expect(changes[1].band == 3)
        #expect(changes[1].field == "gainOrSlope")
        #expect(changes[1].before == 0)
        #expect(changes[1].after == -3)
        #expect(changes[2].band == 3)
        #expect(changes[2].field == "q")
        #expect(changes[2].before == 1)
        #expect(changes[2].after == 1.2)
        #expect(changes[3].band == 8)
        #expect(changes[3].field == "q")
        #expect(changes[3].before == 1)
        #expect(changes[3].after == 1.5)
    }

    @Test func stateEnforcesEightBandsAndCompleteReasonInvariant() throws {
        let incompleteBands = Array(bands().dropLast())
        let invalidPresent = state(bands: incompleteBands)
        let complete = state(complete: true, partialReason: "stale")

        #expect(!invalidPresent.present)
        #expect(complete.partialReason == nil)
        #expect(
            bands().map(\.filterRole) == [
                .highPass,
                .lowShelf,
                .parametric1,
                .parametric2,
                .parametric3,
                .parametric4,
                .highShelf,
                .lowPass,
            ]
        )

        let encoded = try JSONEncoder().encode(
            state(complete: false, partialReason: "readback incomplete")
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["bands"] = Array(try #require(object["bands"] as? [[String: Any]]).dropLast())
        object["present"] = true
        object["complete"] = true
        object["partialReason"] = "stale"

        let decoded = try JSONDecoder().decode(
            ChannelEQState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!decoded.present)
        #expect(decoded.partialReason == nil)
    }

    @Test func adr013FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR013_CHANNEL_EQ"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr013ChannelEQ)
    }

    private func state(
        present: Bool = true,
        bands: [ChannelEQBandState]? = nil,
        complete: Bool = true,
        partialReason: String? = nil
    ) -> ChannelEQState {
        ChannelEQState(
            insertRef: TargetReference(rawValue: "ins_test"),
            present: present,
            bands: bands ?? self.bands(),
            masterGainDb: 0,
            complete: complete,
            partialReason: partialReason
        )
    }

    private func bands() -> [ChannelEQBandState] {
        [
            band(1, .highPass, frequencyHz: 40, gainOrSlope: 12, q: 1),
            band(2, .lowShelf, frequencyHz: 100, gainOrSlope: 0, q: 1),
            band(3, .parametric1, frequencyHz: 250, gainOrSlope: 0, q: 1),
            band(4, .parametric2, frequencyHz: 500, gainOrSlope: 0, q: 1),
            band(5, .parametric3, frequencyHz: 1_000, gainOrSlope: 0, q: 1),
            band(6, .parametric4, frequencyHz: 3_000, gainOrSlope: 0, q: 1),
            band(7, .highShelf, frequencyHz: 8_000, gainOrSlope: 0, q: 1),
            band(8, .lowPass, frequencyHz: 16_000, gainOrSlope: 12, q: 1),
        ]
    }

    private func band(
        _ number: Int,
        _ role: EQBandRole,
        frequencyHz: Double,
        gainOrSlope: Double,
        q: Double,
        enabled: Bool = true
    ) -> ChannelEQBandState {
        ChannelEQBandState(
            band: number,
            filterRole: role,
            frequencyHz: frequencyHz,
            gainOrSlope: gainOrSlope,
            q: q,
            enabled: enabled
        )
    }
}
