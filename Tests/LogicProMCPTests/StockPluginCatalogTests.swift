import Foundation
import MCP
import Testing
@testable import LogicProMCP

private func stockPluginResourceObject(_ uri: String) async throws -> [String: Any] {
    let result = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
    return try #require(sharedJSONObject(sharedResourceText(result)))
}

private func stockPluginResourceThrows(_ uri: String) async -> Bool {
    do {
        _ = try await ResourceHandlers.read(uri: uri, cache: StateCache(), router: ChannelRouter())
        return false
    } catch {
        return true
    }
}

private func makeStockPluginEntry(
    id: String,
    state: StockPluginTruthState,
    provenance: StockPluginProvenance,
    knownPresets: [String] = [],
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
        knownPresets: knownPresets,
        parameters: parameters,
        safeWriteCapabilities: .insertOnly,
        limitations: ["fixture"]
    )
}

private func censusFixture(
    verified: Set<String> = [],
    observed: Set<String> = [],
    mismatched: Set<String> = [],
    unavailable: Set<String> = [],
    manifests: [String: StockPluginLocalManifest] = [:]
) -> StockPluginCensus {
    StockPluginCensus(
        observedAt: "2026-06-10T00:00:00.000Z",
        logicVersion: "12.2",
        locale: "en_US",
        logicAppPath: "/Applications/Logic Pro.app",
        verifiedPluginIDs: verified,
        observedPluginIDs: observed,
        readbackMismatchPluginIDs: mismatched,
        unavailablePluginIDs: unavailable,
        localManifests: manifests
    )
}

@Suite("Stock plugin intelligence — validator")
struct StockPluginValidatorTests {
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

    @Test("validator rejects malformed stable IDs")
    func invalidIDFormatRejected() {
        let provenance = StockPluginProvenance.inferred(reason: "fixture")
        let badIDs = ["Gain", "logic.stock.thirdparty.gain", "logic.stock.effect.Gain", "logic.stock.effect."]
        for badID in badIDs {
            let issues = StockPluginCatalogValidator.validate(
                [makeStockPluginEntry(id: badID, state: .inferred, provenance: provenance)]
            ).issues
            #expect(issues.contains { $0.code == "invalid_id_format" }, "expected invalid_id_format for \(badID)")
        }
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

    @Test("readback_mismatch entries require evidence")
    func readbackMismatchRequiresEvidence() {
        let bad = StockPluginProvenance(
            source: "live_logic",
            method: "ax_insert_readback",
            observedAt: "2026-06-10T00:00:00Z",
            logicVersion: nil,
            locale: nil,
            sourcePath: nil,
            inferenceReason: nil,
            evidence: []
        )
        let entries = [makeStockPluginEntry(id: "logic.stock.effect.gain", state: .readbackMismatch, provenance: bad)]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.contains { $0.code == "mismatch_missing_provenance" })
    }

    @Test("non-empty known presets require preset-name evidence")
    func presetsRequireProvenance() {
        let provenance = StockPluginProvenance.manifested(
            sourcePath: "/x",
            method: "factory_plugin_settings_probe",
            observedAt: "2026-06-10T00:00:00Z",
            logicVersion: "12.2",
            locale: "en_US",
            evidence: ["factory_plugin_settings_folder"]
        )
        let entries = [
            makeStockPluginEntry(
                id: "logic.stock.effect.gain",
                state: .manifested,
                provenance: provenance,
                knownPresets: ["Fabricated Preset"]
            ),
        ]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.contains { $0.code == "presets_missing_provenance" })
    }

    @Test("manifested entries require a probed source path")
    func manifestedRequiresSourcePath() {
        let bad = StockPluginProvenance(
            source: "local_logic_app",
            method: "factory_plugin_settings_probe",
            observedAt: "2026-06-10T00:00:00Z",
            logicVersion: "12.2",
            locale: "en_US",
            sourcePath: nil,
            inferenceReason: nil,
            evidence: ["factory_plugin_settings_folder"]
        )
        let entries = [makeStockPluginEntry(id: "logic.stock.effect.gain", state: .manifested, provenance: bad)]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.contains { $0.code == "manifested_missing_source_path" })
    }

    @Test("unavailable entries require absence evidence")
    func unavailableRequiresEvidence() {
        let bad = StockPluginProvenance(
            source: "live_logic",
            method: "live_census_absence",
            observedAt: "2026-06-10T00:00:00Z",
            logicVersion: "12.2",
            locale: "en_US",
            sourcePath: nil,
            inferenceReason: nil,
            evidence: []
        )
        let entries = [makeStockPluginEntry(id: "logic.stock.effect.gain", state: .unavailable, provenance: bad)]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.contains { $0.code == "unavailable_missing_evidence" })
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

    @Test("parameter value ranges and duplicate parameter IDs are validated")
    func parameterSanityValidated() {
        let provenance = StockPluginProvenance.inferred(reason: "fixture")
        let invertedRange = StockPluginParameterMetadata(
            id: "gain",
            displayName: "Gain",
            unit: "dB",
            valueRange: StockPluginValueRange(min: 10, max: -10, defaultValue: nil),
            writeMethod: nil,
            readbackMethod: nil,
            availabilityState: .inferred,
            provenance: provenance
        )
        let outOfRangeDefault = StockPluginParameterMetadata(
            id: "mix",
            displayName: "Mix",
            unit: "%",
            valueRange: StockPluginValueRange(min: 0, max: 100, defaultValue: 250),
            writeMethod: nil,
            readbackMethod: nil,
            availabilityState: .inferred,
            provenance: provenance
        )
        let duplicate = StockPluginParameterMetadata(
            id: "mix",
            displayName: "Mix Copy",
            unit: nil,
            valueRange: nil,
            writeMethod: nil,
            readbackMethod: nil,
            availabilityState: .inferred,
            provenance: provenance
        )
        let entries = [
            makeStockPluginEntry(
                id: "logic.stock.effect.gain",
                state: .inferred,
                provenance: provenance,
                parameters: [invertedRange, outOfRangeDefault, duplicate]
            ),
        ]

        let issues = StockPluginCatalogValidator.validate(entries).issues
        #expect(issues.filter { $0.code == "invalid_value_range" }.count == 2)
        #expect(issues.contains { $0.code == "duplicate_parameter_id" })
    }
}

@Suite("Stock plugin intelligence — catalog and census")
struct StockPluginCatalogTests {
    @Test("deterministic census yields a fully inferred, valid catalog")
    func deterministicCatalogIsFullyInferred() {
        let snapshot = StockPluginCatalog.defaultSnapshot(census: .deterministic())

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.catalogSource == "static_catalog")
        #expect(snapshot.pluginCount == StockPluginCatalog.seedCount)
        #expect(snapshot.entries.count == StockPluginCatalog.seedCount)
        #expect(snapshot.entries.allSatisfy { $0.availabilityState == .inferred })
        #expect(snapshot.entries.allSatisfy { $0.knownPresets.isEmpty })
        #expect(snapshot.entries.map(\.id) == snapshot.entries.map(\.id).sorted())
        #expect(snapshot.validation.isValid, "deterministic catalog should validate: \(snapshot.validation.issues)")
        #expect(snapshot.entries.contains { $0.id == "logic.stock.effect.gain" })
        #expect(snapshot.entries.contains { $0.id == "logic.stock.instrument.alchemy" })
        #expect(snapshot.entries.contains { $0.id == "logic.stock.midi_fx.scripter" })
    }

    @Test("census overlay produces every injectable truth state with provenance")
    func censusOverlayProducesAllStates() throws {
        let census = censusFixture(
            verified: ["logic.stock.effect.gain"],
            observed: ["logic.stock.effect.compressor"],
            mismatched: ["logic.stock.effect.channel_eq"],
            unavailable: ["logic.stock.effect.silververb"],
            manifests: [
                "logic.stock.effect.limiter": StockPluginLocalManifest(
                    sourcePath: "/Applications/Logic Pro.app/Contents/Resources/Plug-In Settings/Limiter",
                    presetNames: ["Drum Limiter", "Vocal Limiter"]
                ),
            ]
        )
        let snapshot = StockPluginCatalog.defaultSnapshot(census: census)
        #expect(snapshot.validation.isValid, "overlaid catalog should validate: \(snapshot.validation.issues)")

        let verified = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.gain" })
        #expect(verified.availabilityState == .verified)
        #expect(verified.provenance.evidence.contains("plugin_identity_readback"))

        let observed = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.compressor" })
        #expect(observed.availabilityState == .observed)
        #expect(observed.provenance.method == "ax_menu_observation")

        let mismatched = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.channel_eq" })
        #expect(mismatched.availabilityState == .readbackMismatch)
        #expect(mismatched.provenance.evidence.contains("plugin_identity_readback_mismatch"))

        let unavailable = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.silververb" })
        #expect(unavailable.availabilityState == .unavailable)
        #expect(unavailable.insertPaths.isEmpty)
        #expect(unavailable.safeWriteCapabilities == StockPluginSafeWriteCapability.none)
        #expect(unavailable.provenance.evidence.contains("absence_checked"))

        let manifested = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.limiter" })
        #expect(manifested.availabilityState == .manifested)
        #expect(manifested.knownPresets == ["Drum Limiter", "Vocal Limiter"])
        #expect((manifested.provenance.sourcePath?.hasSuffix("Plug-In Settings/Limiter"))!)
        #expect(manifested.provenance.evidence.contains("factory_plugin_settings_folder"))
        #expect(manifested.provenance.evidence.contains("factory_preset_filenames"))
    }

    @Test("verified overlay keeps factory presets with merged provenance")
    func verifiedOverlayKeepsFactoryPresets() throws {
        let census = censusFixture(
            verified: ["logic.stock.effect.gain"],
            manifests: [
                "logic.stock.effect.gain": StockPluginLocalManifest(
                    sourcePath: "/Applications/Logic Pro.app/Contents/Resources/Plug-In Settings/Gain",
                    presetNames: ["#default", "Convert To Mono"]
                ),
            ]
        )
        let snapshot = StockPluginCatalog.defaultSnapshot(census: census)

        let gain = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.gain" })
        #expect(gain.availabilityState == .verified)
        #expect(gain.knownPresets == ["#default", "Convert To Mono"])
        #expect(gain.provenance.evidence.contains("plugin_identity_readback"))
        #expect(gain.provenance.evidence.contains("factory_preset_filenames"))
        #expect(snapshot.validation.isValid,
                "verified entries carrying factory presets must validate: \(snapshot.validation.issues)")
    }

    @Test("factory preset probing keeps bounded sorted names without full-directory storage")
    func boundedFactoryPresetNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stock-plugin-presets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for filename in ["Zed.pst", "Alpha.pst", "Beta.pst", "Gamma.pst", "ignore.txt"] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(filename).path,
                contents: Data("preset".utf8)
            )
        }

        let names = StockPluginCatalog.boundedFactoryPresetNames(
            in: directory.path,
            maxDirectoryEntries: 100,
            maxNames: 3
        )
        #expect(names == ["Alpha", "Beta", "Gamma"])

        let entryCapped = StockPluginCatalog.boundedFactoryPresetNames(
            in: directory.path,
            maxDirectoryEntries: 1,
            maxNames: 12
        )
        #expect(entryCapped.count <= 1)
    }

    @Test("contradictory census evidence fails loudly and never yields verified")
    func censusConflictSurfaced() throws {
        let census = censusFixture(
            verified: ["logic.stock.effect.gain"],
            mismatched: ["logic.stock.effect.gain"]
        )
        let snapshot = StockPluginCatalog.defaultSnapshot(census: census)

        let gain = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.gain" })
        #expect(gain.availabilityState == .readbackMismatch,
                "contradiction must resolve to the non-claiming state")
        #expect(!snapshot.validation.isValid)
        #expect(snapshot.validation.issues.contains { $0.code == "census_conflict" })
    }

    @Test("production snapshot never claims more than manifested")
    func productionSnapshotIsConservative() {
        let snapshot = StockPluginCatalog.productionSnapshot
        let states = Set(snapshot.entries.map(\.availabilityState))

        #expect(snapshot.validation.isValid, "production catalog should validate: \(snapshot.validation.issues)")
        #expect(states.subtracting([.inferred, .manifested]).isEmpty,
                "production census must not fabricate live evidence; saw \(states)")
        #expect(snapshot.entries.contains { $0.id == "logic.stock.effect.gain" })
    }

    @Test("insertable write capabilities match the live insert allowlist")
    func insertOnlyMatchesInsertAllowlist() {
        let snapshot = StockPluginCatalog.defaultSnapshot(census: .deterministic())
        // T5: Compressor is now `parameter_write_readback` (its `threshold` is
        // verified-writable via AX), while still being insertable. Gain and
        // Channel EQ remain `insert_only`. The insert allowlist is the union.
        let insertable = snapshot.entries.filter {
            $0.safeWriteCapabilities == .insertOnly || $0.safeWriteCapabilities == .parameterWriteReadback
        }

        #expect(Set(insertable.map(\.id)) == [
            "logic.stock.effect.channel_eq",
            "logic.stock.effect.compressor",
            "logic.stock.effect.gain",
        ])
        for entry in insertable {
            #expect(
                AccessibilityChannel.pluginInsertSpec(named: entry.displayName) != nil,
                "\(entry.displayName) must be accepted by the insert_plugin allowlist"
            )
        }
        let compressor = snapshot.entries.first { $0.id == "logic.stock.effect.compressor" }
        #expect(compressor?.safeWriteCapabilities == .parameterWriteReadback,
                "Compressor threshold is verified-writable (T5)")
        let nonInsertable = snapshot.entries.first { $0.id == "logic.stock.effect.chromaverb" }
        #expect(nonInsertable?.safeWriteCapabilities == StockPluginSafeWriteCapability.none)
        #expect(AccessibilityChannel.pluginInsertSpec(named: "ChromaVerb") == nil)
    }

    @Test("search matches id, name, category, and type case-insensitively")
    func searchSemantics() {
        let snapshot = StockPluginCatalog.defaultSnapshot(census: .deterministic())

        #expect(StockPluginCatalog.search(query: "", snapshot: snapshot).count == snapshot.entries.count)
        #expect(StockPluginCatalog.search(query: "REVERB", snapshot: snapshot)
            .contains { $0.id == "logic.stock.effect.chromaverb" })
        #expect(StockPluginCatalog.search(query: "midi_effect", snapshot: snapshot)
            .allSatisfy { $0.type == .midiEffect })
        #expect(StockPluginCatalog.search(query: "vintage b3", snapshot: snapshot)
            .contains { $0.id == "logic.stock.instrument.vintage_b3" })
        #expect(StockPluginCatalog.search(query: "no-such-plugin-xyz", snapshot: snapshot).isEmpty)
    }
}

@Suite("Stock plugin intelligence — resources")
struct StockPluginResourceTests {
    @Test("MCP resources expose stock plugin list, detail, search, census, and capabilities")
    func stockPluginResources() async throws {
        let list = try await stockPluginResourceObject("logic://stock-plugins")
        #expect(list["schema_version"] as? Int == 1)
        #expect(!(((list["entries"] as? [[String: Any]])?.isEmpty)!))
        #expect(((list["validation"] as? [String: Any])?["is_valid"] as? Bool)!)

        let detail = try await stockPluginResourceObject("logic://stock-plugins/logic.stock.effect.gain")
        #expect((detail["entry"] as? [String: Any])?["id"] as? String == "logic.stock.effect.gain")
        #expect((detail["entry"] as? [String: Any])?["known_presets"] as? [String] != nil)

        let search = try await stockPluginResourceObject("logic://stock-plugins/search?query=gain")
        #expect(((search["entries"] as? [[String: Any]])?.contains { $0["id"] as? String == "logic.stock.effect.gain" })!)

        let census = try await stockPluginResourceObject("logic://stock-plugins/census")
        #expect(census["catalog_source"] as? String != nil)
        #expect(census["logic_version"] != nil)
        #expect((census["entries_by_state"] as? [String: Int]) != nil)

        let capabilities = try await stockPluginResourceObject("logic://stock-plugins/capabilities")
        #expect(((capabilities["truth_labels"] as? [String])?.contains("verified"))!)
        #expect(((capabilities["catalog_entry_fields"] as? [String])?.contains("known_presets"))!)
        #expect(((capabilities["resources"] as? [String])?.contains("logic://stock-plugins"))!)
        #expect((capabilities["production_reachable_states"] as? [String]) == ["inferred", "manifested"])
        #expect(((capabilities["census_injectable_states"] as? [String])?.contains("readback_mismatch"))!)
        #expect(capabilities["preset_directory_entry_scan_cap"] as? Int == StockPluginCatalog.maxFactoryPresetDirectoryEntries)
    }

    @Test("stock plugin URI routing fails closed on malformed inputs")
    func stockPluginRoutingFailsClosed() async {
        let malformed = [
            "logic://stock-plugins?query=gain",
            "logic://stock-plugins/%63ensus",
            "logic://stock-plugins/search?qu%65ry=gain",
            "logic://stock-plugins/search?query=%ZZ",
            "logic://stock-plugins/search/extra",
            "logic://stock-plugins/search?other=x",
            "logic://stock-plugins/search?query=gain&query=compressor",
            "logic://stock-plugins/logic.stock.effect.gain?x=1",
            "logic://stock-plugins/logic.stock.effect.gain/extra",
            "logic://stock-plugins/unknown.plugin.id",
            "logic://stock-plugins/census?x=1",
            "logic://stock-plugins//census",
            "logic://stock-plugins/census/",
            "logic://stock-plugins/census#fragment",
            "logic://stock-plugins/capabilities#fragment",
            "logic://stock-plugins/search?query=gain#fragment",
            "logic://stock-plugins/logic.stock.effect.gain#fragment",
        ]
        for uri in malformed {
            #expect(await stockPluginResourceThrows(uri), "expected fail-closed read for \(uri)")
        }
    }

    @Test("search query is percent-decoded exactly once")
    func searchQuerySingleDecode() async throws {
        let search = try await stockPluginResourceObject("logic://stock-plugins/search?query=a%252Bb")
        #expect(search["query"] as? String == "a%2Bb")

        let plus = try await stockPluginResourceObject("logic://stock-plugins/search?query=a%2Bb")
        #expect(plus["query"] as? String == "a+b")
    }

    @Test("search with empty or missing query returns the full catalog")
    func searchEmptyQueryReturnsAll() async throws {
        let missing = try await stockPluginResourceObject("logic://stock-plugins/search")
        let empty = try await stockPluginResourceObject("logic://stock-plugins/search?query=")
        let list = try await stockPluginResourceObject("logic://stock-plugins")

        let total = (list["entries"] as? [[String: Any]])?.count
        #expect(total != nil)
        #expect((missing["entries"] as? [[String: Any]])?.count == total)
        #expect((empty["entries"] as? [[String: Any]])?.count == total)
    }
}
