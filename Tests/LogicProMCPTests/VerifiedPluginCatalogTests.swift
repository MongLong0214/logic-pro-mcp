import Foundation
import Testing
@testable import LogicProMCP

// T3/T4 — verified-plugin identity + capability resolution (R5/R6, AC10/AC11).
// Deterministic; no live AX.

// MARK: - Plugin identity alias resolution (AC11)

@Test func testCanonicalPluginIDResolvesDisplayNameAndSuffix() {
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "Gain") == "logic.stock.effect.gain")
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "gain") == "logic.stock.effect.gain")
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "  GAIN  ") == "logic.stock.effect.gain")
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "logic.stock.effect.gain") == "logic.stock.effect.gain")
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "Channel EQ") == "logic.stock.effect.channel_eq")
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "Compressor") == "logic.stock.effect.compressor")
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "Noise Gate") == "logic.stock.effect.noise_gate")
}

@Test func testCanonicalPluginIDRejectsUnbackedIdentity() {
    // AC11: an ungrounded com.apple.logic.* id has no alias mapping → refuse.
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "com.apple.logic.gain") == nil)
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "") == nil)
    #expect(VerifiedPluginCatalog.canonicalPluginID(from: "Definitely Not A Plugin") == nil)
}

// MARK: - Parameter key alias resolution (R5: gain → gain_db)

@Test func testCanonicalParamKeyMapsGainAlias() {
    let gain = "logic.stock.effect.gain"
    #expect(VerifiedPluginCatalog.canonicalParamKey(pluginID: gain, alias: "gain_db") == "gain")
    #expect(VerifiedPluginCatalog.canonicalParamKey(pluginID: gain, alias: "gain") == "gain")
    #expect(VerifiedPluginCatalog.canonicalParamKey(pluginID: gain, alias: "GAIN_DB") == "gain")
    #expect(VerifiedPluginCatalog.canonicalParamKey(pluginID: gain, alias: "unknown_param") == nil)
}

// MARK: - Observed-name → plugin_id for get_inventory

@Test func testObservedNameMapsToCanonicalID() {
    #expect(VerifiedPluginCatalog.pluginID(forObservedName: "Gain") == "logic.stock.effect.gain")
    #expect(VerifiedPluginCatalog.pluginID(forObservedName: "Noise Gate") == "logic.stock.effect.noise_gate")
    // A non-allowlisted (or third-party) plugin name does not resolve.
    #expect(VerifiedPluginCatalog.pluginID(forObservedName: "Drum Machine Designer") == nil)
}

// MARK: - Capability preflight (AC10) — Gain is currently unsupported

@Test func testGainParamCapabilityIsUnsupportedUntilEvidence() {
    // Gain's catalog param has writeMethod:nil, readbackMethod:nil (.inferred),
    // so preflight must report .unsupported → State C unsupported_param_readback.
    let cap = VerifiedPluginCatalog.paramCapability(pluginID: "logic.stock.effect.gain", paramKey: "gain")
    #expect(cap == .unsupported)
}

@Test func testUnknownParamCapabilityIsUnknownParameter() {
    #expect(
        VerifiedPluginCatalog.paramCapability(pluginID: "logic.stock.effect.gain", paramKey: "nope")
            == .unknownParameter
    )
    // Ratio is deliberately known-but-unsupported in Controls view, so use a
    // genuinely absent Compressor key for the unknown-parameter assertion.
    #expect(
        VerifiedPluginCatalog.paramCapability(pluginID: "logic.stock.effect.compressor", paramKey: "not_a_compressor_parameter")
            == .unknownParameter
    )
}

// MARK: - T5: Compressor threshold is the first verified-writable parameter

@Test func testCompressorThresholdCapabilityIsWriteReadback() {
    // T0 spike filled the AX write/readback methods, so preflight now admits a
    // verified write for this one parameter.
    #expect(
        VerifiedPluginCatalog.paramCapability(pluginID: "logic.stock.effect.compressor", paramKey: "threshold")
            == .writeReadback
    )
    #expect(VerifiedPluginCatalog.canonicalParamKey(pluginID: "logic.stock.effect.compressor", alias: "threshold") == "threshold")
}

@Test func testCompressorThresholdUnitRangeToleranceAndAXDescription() {
    let id = "logic.stock.effect.compressor"
    #expect(VerifiedPluginCatalog.paramUnit(pluginID: id, paramKey: "threshold") == "normalized")
    let range = VerifiedPluginCatalog.paramRange(pluginID: id, paramKey: "threshold")
    #expect(range?.min == 0)
    #expect(range?.max == 100)
    #expect(VerifiedPluginCatalog.paramTolerance(pluginID: id, paramKey: "threshold") == 1.0)
    // AX identification is by AXDescription only (AXIdentifier is unstable).
    #expect(VerifiedPluginCatalog.paramAXDescription(pluginID: id, paramKey: "threshold") == "Threshold")
}

@Test func testChannelEQParamsAreUnregisteredUntilCensus() {
    let id = "logic.stock.effect.channel_eq"
    let param = "band_gain"
    #expect(VerifiedPluginCatalog.canonicalParamKey(pluginID: id, alias: param) == nil)
    #expect(VerifiedPluginCatalog.paramCapability(pluginID: id, paramKey: param) == .unknownParameter)
    #expect(VerifiedPluginCatalog.paramTolerance(pluginID: id, paramKey: param) == nil)
    #expect(VerifiedPluginCatalog.paramAXDescription(pluginID: id, paramKey: param) == nil)
}

// MARK: - Unit + range exposure (R8)

@Test func testGainParamUnitAndRange() {
    #expect(VerifiedPluginCatalog.paramUnit(pluginID: "logic.stock.effect.gain", paramKey: "gain") == "dB")
    let range = VerifiedPluginCatalog.paramRange(pluginID: "logic.stock.effect.gain", paramKey: "gain")
    #expect(range?.min == -96)
    #expect(range?.max == 24)
}

// MARK: - ADR-009 (#292): a declared write capability must rest on measured evidence

/// A parameter that claims a write path must not carry INFERRED provenance.
///
/// ADR-009's decision is "expose only plugin parameters with independent write/readback
/// evidence … do not treat generic AX control movement as public parameter support". The
/// catalog was built to express that — every parameter carries `writeMethod`, `readbackMethod`
/// and a `provenance` — but nothing enforced it. Gain is the shape the rule protects:
/// `writeMethod: nil` with the reason "no write/readback path is claimed" written out.
///
/// Without this, the cheapest way to make a parameter writable is to fill in a `writeMethod`
/// and leave the provenance saying it was inferred from documentation. That is exactly the
/// claim the ADR exists to refuse, and it would ship as State A.
private func writeCapabilityRestsOnInference(_ param: StockPluginParameterMetadata) -> Bool {
    let claimsWrite = !(param.writeMethod?.isEmpty ?? true)
    guard claimsWrite else { return false }
    // EMPTY EVIDENCE is the disqualifier, not the presence of an inference reason. A first
    // version of this predicate rejected any `inferenceReason`, and it immediately failed on
    // Compressor's Threshold — which carries BOTH a reason and
    // `evidence: ["parameter_write_readback", "CHANGELOG.md"]`. That reason is a scoping
    // caveat ("proven on a duplicate, not census-verified in this response"), not a statement
    // that the capability is a guess. Rejecting it would have pushed toward deleting the
    // caveat to pass the check, which is the wrong direction: a caveat is information.
    //
    // `.inferred(reason:)` is the constructor that leaves evidence empty, so this catches the
    // shape the ADR refuses without matching on a case the catalog keeps private.
    return param.provenance.evidence.isEmpty
}

@Test func testEveryDeclaredWriteMethodRestsOnMeasuredEvidence() {
    let offenders = StockPluginCatalog.productionSnapshot.entries.flatMap { entry in
        entry.parameters
            .filter(writeCapabilityRestsOnInference)
            .map { "\(entry.id).\($0.id) writeMethod=\($0.writeMethod ?? "-")" }
    }
    #expect(
        offenders.isEmpty,
        "a parameter may not declare a write path on inferred provenance: \(offenders)"
    )
}

@Test func testTheEvidenceInvariantCanFail() {
    // The check above is only worth having if a violation trips it. Build the shape it exists
    // to refuse — a write path with the provenance Gain carries — and confirm it is caught.
    let fabricated = StockPluginParameterMetadata(
        id: "fabricated",
        displayName: "Fabricated",
        unit: "dB",
        valueRange: StockPluginValueRange(min: 0, max: 1, defaultValue: 0),
        writeMethod: "ax_slider_axvalue",
        readbackMethod: "ax_slider_axvalue",
        availabilityState: .inferred,
        provenance: .inferred(reason: "documented range only")
    )
    #expect(writeCapabilityRestsOnInference(fabricated))

    let honest = StockPluginParameterMetadata(
        id: "honest",
        displayName: "Honest",
        unit: "dB",
        valueRange: StockPluginValueRange(min: 0, max: 1, defaultValue: 0),
        writeMethod: nil,
        readbackMethod: nil,
        availabilityState: .inferred,
        provenance: .inferred(reason: "no write/readback path is claimed")
    )
    #expect(!writeCapabilityRestsOnInference(honest))
}
