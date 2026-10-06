import Testing
@testable import LogicProMCP

/// Pure catalog-validator witnesses. Edited evidence below is synthetic test input,
/// not a new native measurement or qualification of the copied stock parameter.
@Suite("Issue 292 — verified evidence fits its declared canonical range")
struct Issue292ParameterEvidenceRangeTests {
    enum ParameterCase: CaseIterable, Sendable {
        case shelfQ
        case compressorBoolean
    }

    private struct Fixture {
        let entry: StockPluginCatalogEntry
        let parameter: StockPluginParameterMetadata
        let index: Int
        let range: StockPluginValueRange
        let badUpperPair: [String]
        let historicalPair: [String]
    }

    private func fixture(_ kind: ParameterCase) throws -> Fixture {
        // Explicit deterministic census: no production snapshot, installed-app
        // census, resource handler, AX runtime, or recording channel is invoked.
        let snapshot = StockPluginCatalog.defaultSnapshot(census: .deterministic())
        let pluginID: String
        let parameterID: String
        let badUpperPair: [String]
        let historicalPair: [String]
        switch kind {
        case .shelfQ:
            pluginID = "logic.stock.effect.channel_eq"
            parameterID = "low_shelf_q"
            badUpperPair = ["50->63", "63->50"]
            historicalPair = ["20->26", "26->20"]
        case .compressorBoolean:
            pluginID = "logic.stock.effect.compressor"
            parameterID = "limiter_on"
            badUpperPair = ["2->3", "3->2"]
            historicalPair = ["0->1", "1->0"]
        }
        let entry = try #require(snapshot.entries.first { $0.id == pluginID })
        let index = try #require(entry.parameters.firstIndex { $0.id == parameterID })
        let parameter = entry.parameters[index]
        let range = try #require(parameter.valueRange)
        #expect(parameter.availabilityState == .verified)
        #expect(range.min == 0)
        switch kind {
        case .shelfQ:
            #expect(parameter.unit == "raw_ax_value")
            #expect(range.max == 52)
        case .compressorBoolean:
            #expect(parameter.unit == "boolean")
            #expect(range.max == 1)
        }
        for transition in historicalPair {
            #expect(parameter.provenance.evidence.contains("observed_transition=" + transition))
        }
        return Fixture(entry: entry, parameter: parameter, index: index, range: range,
                       badUpperPair: badUpperPair, historicalPair: historicalPair)
    }

    private func copying(_ f: Fixture, transitions: [String], withoutRange: Bool = false) -> StockPluginCatalogEntry {
        let p = f.parameter
        let original = p.provenance
        let provenance = StockPluginProvenance(
            source: original.source, method: original.method, observedAt: original.observedAt,
            logicVersion: original.logicVersion, locale: original.locale,
            sourcePath: original.sourcePath, inferenceReason: original.inferenceReason,
            evidence: original.evidence.filter { !$0.hasPrefix("observed_transition=") }
                + transitions.map { "observed_transition=" + $0 }
        )
        let parameter = StockPluginParameterMetadata(
            id: p.id, displayName: p.displayName, unit: p.unit, acceptedUnits: p.acceptedUnits,
            valueRange: withoutRange ? nil : p.valueRange,
            writeMethod: p.writeMethod, readbackMethod: p.readbackMethod,
            tolerance: p.tolerance, axDescription: p.axDescription,
            controlsViewRowLabel: p.controlsViewRowLabel,
            controlsViewControlRole: p.controlsViewControlRole,
            controlsViewActuationState: p.controlsViewActuationState,
            editorWindowAnchorAXDescription: p.editorWindowAnchorAXDescription,
            availabilityState: p.availabilityState, provenance: provenance
        )
        var parameters = f.entry.parameters
        parameters[f.index] = parameter
        let e = f.entry
        return StockPluginCatalogEntry(
            id: e.id, displayName: e.displayName, type: e.type, category: e.category,
            availabilityState: e.availabilityState, provenance: e.provenance,
            insertPaths: e.insertPaths, slotSupport: e.slotSupport, knownPresets: e.knownPresets,
            knownPresetsTruncated: e.knownPresetsTruncated, knownPresetsTotal: e.knownPresetsTotal,
            parameters: parameters, safeWriteCapabilities: e.safeWriteCapabilities,
            limitations: e.limitations
        )
    }

    private func expectOnlyMissingWriteObservation(_ entry: StockPluginCatalogEntry, index: Int) {
        let result = StockPluginCatalogValidator.validate([entry])
        #expect(!result.isValid)
        #expect(result.issues.count == 1)
        #expect(result.issues.contains {
            $0.code == "verified_parameter_missing_write_observation"
                && $0.path == "entries[0].parameters[\(index)]"
        })
    }

    @Test(arguments: ParameterCase.allCases)
    func copiedStockEvidenceRejectsReciprocalEndpointsAboveItsOwnRange(_ kind: ParameterCase) throws {
        let f = try fixture(kind)
        let positive = StockPluginCatalogValidator.validate([f.entry])
        #expect(positive.isValid)
        #expect(positive.issues.isEmpty)
        // Only this parameter's transition records change. Other metadata,
        // parameters, operation/method evidence, and historical provenance stay.
        let bad = copying(f, transitions: f.badUpperPair)
        #expect(bad.parameters[f.index].valueRange == f.parameter.valueRange)
        expectOnlyMissingWriteObservation(bad, index: f.index)
        let restored = StockPluginCatalogValidator.validate([f.entry])
        #expect(restored.isValid)
        #expect(restored.issues.isEmpty)
    }

    @Test(arguments: ParameterCase.allCases)
    func copiedStockEvidenceRejectsReciprocalEndpointsBelowItsOwnRange(_ kind: ParameterCase) throws {
        let f = try fixture(kind)
        let bad = copying(f, transitions: ["-1->0", "0->-1"])
        expectOnlyMissingWriteObservation(bad, index: f.index)
        #expect(StockPluginCatalogValidator.validate([f.entry]).isValid)
    }

    @Test(arguments: ParameterCase.allCases)
    func canonicalRangeBoundariesRemainInclusiveInBothDirections(_ kind: ParameterCase) throws {
        let f = try fixture(kind)
        let min = String(f.range.min)
        let max = String(f.range.max)
        // Synthetic boundary records exercise validator semantics, not a claim
        // that the host has been driven to either physical endpoint.
        let boundary = copying(f, transitions: [max + "->" + min, min + "->" + max])
        let result = StockPluginCatalogValidator.validate([boundary])
        #expect(result.isValid)
        #expect(result.issues.isEmpty)
    }

    @Test(arguments: ParameterCase.allCases)
    func oneInRangeReciprocalPairStillSupportsEvidenceWithExtraInvalidPairs(_ kind: ParameterCase) throws {
        let f = try fixture(kind)
        let mixed = copying(f, transitions: f.badUpperPair + ["-1->0", "0->-1"] + f.historicalPair)
        let result = StockPluginCatalogValidator.validate([mixed])
        #expect(result.isValid)
        #expect(result.issues.isEmpty)
    }

    @Test(arguments: ParameterCase.allCases)
    func absentRangePreservesFiniteReciprocalEvidenceWithoutInventingBounds(_ kind: ParameterCase) throws {
        let f = try fixture(kind)
        let unbounded = copying(f, transitions: f.badUpperPair, withoutRange: true)
        #expect(unbounded.parameters[f.index].valueRange == nil)
        let result = StockPluginCatalogValidator.validate([unbounded])
        #expect(result.isValid)
        #expect(result.issues.isEmpty)
        // Lack of a range does not excuse lack of an actual reciprocal change.
        let noChange = copying(f, transitions: ["2->2"], withoutRange: true)
        expectOnlyMissingWriteObservation(noChange, index: f.index)
    }
}
