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

    @Test func stockCatalogSplitsChannelEQEvidenceByWhatTheLiveSweepMeasured() throws {
        let channelEQ = try #require(StockPluginCatalog.entry(id: "logic.stock.effect.channel_eq"))
        #expect(channelEQ.safeWriteCapabilities == .parameterWriteReadback)
        #expect(channelEQ.parameters.count == 24)

        // The sweep drove all twenty-four through `set_eq_band_verified`. Eighteen reached State A
        // in both directions; six refused with `increment_walk_no_progress`, and those six are
        // exactly the two Cut bands on all three of their parameters. Counting BOTH sides pins the
        // split — an evidence string copied onto the wrong parameters moves one of these counts,
        // which asserting only "some parameter is verified" would not.
        let verified = channelEQ.parameters.filter { $0.availabilityState == .verified }
        let refused = channelEQ.parameters.filter {
            $0.provenance.evidence.contains("write_round_trip_refused_live_2026-09-13_increment_walk_no_progress")
        }
        #expect(verified.count == 18)
        #expect(refused.count == 6)
        #expect(Set(verified.map(\.id)).isDisjoint(with: Set(refused.map(\.id))))
        #expect(refused.allSatisfy { $0.id.contains("cut") })
        #expect(refused.allSatisfy { $0.availabilityState == .observed })

        for parameter in channelEQ.parameters {
            #expect(parameter.writeMethod == "ax_slider_increment_walk")
            #expect(parameter.provenance.evidence.contains("raw_axvalue_range_measured_live_2026-08-30"))
            #expect(parameter.provenance.evidence.contains("axvalue_increment_walk_measured_live_2026-08-30"))
        }

        // Each verified parameter's evidence must name a transition AND its reverse, and they must
        // be the pair that parameter was actually driven between. Reading the two apart — rather
        // than checking that two `observed_transition=` records exist — is what stops one pair being
        // pasted across parameters whose ranges cannot hold it.
        for parameter in verified {
            let band = try #require(ChannelEQBandCatalog.parameters.first { $0.id == parameter.id })
            let expected: (Int, Int)
            switch band.parameterName {
            case "Frequency": expected = (500, 560)
            case "Gain": expected = (200, 240)
            default: expected = band.range.upperBound == 52 ? (20, 26) : (50, 63)
            }
            #expect(parameter.provenance.evidence.contains("observed_transition=\(expected.0)->\(expected.1)"))
            #expect(parameter.provenance.evidence.contains("observed_transition=\(expected.1)->\(expected.0)"))
            #expect(Double(expected.1) <= band.range.upperBound)
            #expect(parameter.provenance.evidence.contains("operation=logic_plugins.set_eq_band_verified"))
            #expect(parameter.provenance.evidence.contains("write_method=ax_slider_increment_walk"))
        }
    }

    @Test func verifiedWriteOperationsAreDerivedFromTheRegistryRatherThanListed() {
        // The gate used to name `logic_plugins.set_param_verified` alone, and refused eighteen
        // Channel EQ parameters that had the evidence but named the operation ADR-013 shipped. The
        // set is derived now, so a third verified parameter write cannot be forgotten here. This
        // test is the other half: it pins the MEMBERSHIP, so widening the derivation to admit an
        // operation that writes no parameter — `insert_verified` is `readbackRequired` too — fails
        // rather than quietly enlarging what `.verified` can rest on.
        let operations = StockPluginCatalogValidator.verifiedParameterWriteOperations
        #expect(operations == [
            "logic_plugins.set_param_verified",
            "logic_plugins.set_eq_band_verified",
        ])
        #expect(!operations.contains("logic_plugins.insert_verified"))
    }
}
