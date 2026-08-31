import Testing
@testable import LogicProMCP

@Suite("Channel EQ band parameter catalog")
struct ChannelEQBandCatalogTests {
    @Test func catalogDerivesAllTwentyFourNamedBandParameters() {
        let parameters = ChannelEQBandCatalog.parameters

        // Mutation caught: omitting the cut-band Q or a generated band silently
        // turns the measured 24-control census into a shorter registry.
        #expect(parameters.count == 24)
        #expect(Set(parameters.map(\.id)).count == 24)
        #expect(parameters.map(\.axDescription) == parameters.map(\.displayName))
    }

    @Test func cutsUseOrderWhileAllOtherBandsUseGain() {
        let ids = Set(ChannelEQBandCatalog.parameters.map(\.id))

        // Mutation caught: generating Gain for cuts (or Order for shelves and
        // peaks) points future AX lookup at a control that was not observed.
        #expect(ids.contains("low_cut_order"))
        #expect(ids.contains("high_cut_order"))
        #expect(!ids.contains("low_cut_gain"))
        #expect(!ids.contains("high_cut_gain"))
        #expect(ids.contains("low_shelf_gain"))
        #expect(ids.contains("peak_1_gain"))
        #expect(ids.contains("high_shelf_gain"))
    }

    @Test func rawRangesPreserveTheReportedControlKinds() throws {
        let parameters = ChannelEQBandCatalog.parameters
        let lowShelfQ = try #require(parameters.first { $0.id == "low_shelf_q" })
        let highShelfQ = try #require(parameters.first { $0.id == "high_shelf_q" })
        let peakQ = try #require(parameters.first { $0.id == "peak_3_q" })
        let cutQ = try #require(parameters.first { $0.id == "high_cut_q" })
        let frequency = try #require(parameters.first { $0.id == "peak_2_frequency" })
        let gain = try #require(parameters.first { $0.id == "peak_2_gain" })
        let order = try #require(parameters.first { $0.id == "low_cut_order" })

        // Mutation caught: sharing the peak/cut Q range with shelves permits
        // raw values the shelf control does not expose.
        #expect(lowShelfQ.range == 0 ... 52)
        #expect(highShelfQ.range == 0 ... 52)
        #expect(peakQ.range == 0 ... 127)
        #expect(cutQ.range == 0 ... 127)
        #expect(frequency.range == 0 ... 1_050)
        #expect(gain.range == 0 ... 480)
        #expect(order.range == 0 ... 5)
    }

    @Test func catalogLabelsRangesAsRawAXValuesAndDeclaresOnlyMeasuredDisplayUnits() {
        // Mutation caught: labelling these non-linear slider ranges as Hz or
        // dB would fabricate an engineering conversion from raw AX values.
        #expect(ChannelEQBandCatalog.parameters.allSatisfy { $0.rawUnit == "raw_ax_value" })
        #expect(ChannelEQBandCatalog.parameter(bandName: "Peak 1", parameterName: "Frequency")?.declaredUnits == ["raw_ax_value", "Hz"])
        #expect(ChannelEQBandCatalog.parameter(bandName: "Peak 1", parameterName: "Gain")?.declaredUnits == ["raw_ax_value", "dB"])
        #expect(ChannelEQBandCatalog.parameter(bandName: "Peak 1", parameterName: "Q")?.declaredUnits == ["raw_ax_value", "Q"])
        #expect(ChannelEQBandCatalog.parameter(bandName: "Low Cut", parameterName: "Order")?.declaredUnits == ["raw_ax_value"])
    }

    @Test func stockCatalogRecordsMeasuredIncrementWalkCapabilityAndNoRoundTripEvidence() throws {
        let channelEQ = try #require(StockPluginCatalog.entry(id: "logic.stock.effect.channel_eq"))
        #expect(channelEQ.safeWriteCapabilities == .parameterWriteReadback)
        #expect(channelEQ.parameters.count == 24)
        for parameter in channelEQ.parameters {
            #expect(parameter.writeMethod == "ax_slider_increment_walk")
            #expect(parameter.provenance.observedAt == "2026-08-30T00:00:00Z")
            #expect(parameter.provenance.evidence.contains("raw_axvalue_range_measured_live_2026-08-30"))
            #expect(parameter.provenance.evidence.contains("axvalue_increment_walk_measured_live_2026-08-30"))
            #expect(!parameter.provenance.evidence.contains("parameter_write_readback"))
        }
    }
}
