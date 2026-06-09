import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func stockPluginResourceObject(_ uri: String) async throws -> [String: Any] {
    let result = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
    return try #require(sharedJSONObject(sharedResourceText(result)))
}

private func makeStockPluginEntry(
    id: String,
    state: StockPluginTruthState,
    provenance: StockPluginProvenance,
    parameters: [StockPluginParameterMetadata] = []
) -> StockPluginCatalogEntry {
    StockPluginCatalogEntry(
        id: id,
        displayName: "Gain",
        type: .effect,
        category: "Utility",
        availabilityState: state,
        provenance: provenance,
        insertPaths: [
            StockPluginInsertPath(
                path: ["Audio FX", "Utility", "Gain"],
                availabilityState: state,
                provenance: provenance
            ),
        ],
        slotSupport: StockPluginSlotSupport(audio: true, instrument: false, midiFX: false, aux: true),
        knownPresets: [],
        parameters: parameters,
        safeWriteCapabilities: .insertOnly,
        limitations: ["fixture"]
    )
}

@Suite("Stock plugin intelligence")
struct StockPluginCatalogTests {
    @Test("validator rejects duplicate stable IDs")
    func duplicateIDsRejected() {
        let provenance = StockPluginProvenance.inferred(reason: "fixture")
        let entries = [
            makeStockPluginEntry(id: "logic.stock.effect.gain", state: .inferred, provenance: provenance),
            makeStockPluginEntry(id: "logic.stock.effect.gain", state: .inferred, provenance: provenance),
        ]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.contains { $0.code == "duplicate_id" })
    }

    @Test("verified entries require source, method, timestamp, and evidence")
    func verifiedProvenanceRequired() {
        let bad = StockPluginProvenance(
            source: "",
            method: "",
            observedAt: nil,
            logicVersion: nil,
            locale: nil,
            sourcePath: nil,
            inferenceReason: nil,
            evidence: []
        )
        let entries = [makeStockPluginEntry(id: "logic.stock.effect.gain", state: .verified, provenance: bad)]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.contains { $0.code == "verified_missing_provenance" })
    }

    @Test("verified parameters require explicit readback evidence")
    func verifiedParametersRequireReadback() {
        let provenance = StockPluginProvenance.verified(
            source: "live_logic",
            method: "ax_plugin_window",
            observedAt: "2026-06-09T00:00:00Z",
            logicVersion: "12.2",
            locale: "en_US",
            evidence: ["window_identity"]
        )
        let parameter = StockPluginParameterMetadata(
            id: "gain",
            displayName: "Gain",
            unit: "dB",
            valueRange: StockPluginValueRange(min: -24, max: 24, defaultValue: 0),
            writeMethod: "unsupported",
            readbackMethod: nil,
            availabilityState: .verified,
            provenance: provenance
        )
        let entries = [
            makeStockPluginEntry(
                id: "logic.stock.effect.gain",
                state: .verified,
                provenance: provenance,
                parameters: [parameter]
            ),
        ]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.contains { $0.code == "verified_parameter_missing_readback" })
    }

    @Test("default catalog includes honest inferred and unavailable states")
    func defaultCatalogHasConservativeTruthLabels() {
        let snapshot = StockPluginCatalog.defaultSnapshot()
        let states = Set(snapshot.entries.map(\.availabilityState))

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.entries.contains { $0.id == "logic.stock.effect.gain" })
        #expect(states.contains(.inferred) || states.contains(.manifested) || states.contains(.verified))
        #expect(states.contains(.unavailable))
        #expect(snapshot.validation.isValid, "default catalog should validate: \(snapshot.validation.issues)")
    }

    @Test("MCP resources expose stock plugin list, detail, search, census, and capabilities")
    func stockPluginResources() async throws {
        let list = try await stockPluginResourceObject("logic://stock-plugins")
        #expect(list["schema_version"] as? Int == 1)
        #expect((list["entries"] as? [[String: Any]])?.isEmpty == false)
        #expect((list["validation"] as? [String: Any])?["is_valid"] as? Bool == true)

        let detail = try await stockPluginResourceObject("logic://stock-plugins/logic.stock.effect.gain")
        #expect((detail["entry"] as? [String: Any])?["id"] as? String == "logic.stock.effect.gain")
        #expect((detail["entry"] as? [String: Any])?["known_presets"] as? [String] != nil)

        let search = try await stockPluginResourceObject("logic://stock-plugins/search?query=gain")
        #expect((search["entries"] as? [[String: Any]])?.contains { $0["id"] as? String == "logic.stock.effect.gain" } == true)

        let census = try await stockPluginResourceObject("logic://stock-plugins/census")
        #expect(census["catalog_source"] as? String != nil)
        #expect(census["logic_version"] != nil)

        let capabilities = try await stockPluginResourceObject("logic://stock-plugins/capabilities")
        #expect((capabilities["truth_labels"] as? [String])?.contains("verified") == true)
        #expect((capabilities["catalog_entry_fields"] as? [String])?.contains("known_presets") == true)
        #expect((capabilities["resources"] as? [String])?.contains("logic://stock-plugins") == true)
    }
}
