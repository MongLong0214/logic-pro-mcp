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

/// A throwaway factory-settings tree: each path is a file under a fresh temporary directory, and a
/// path ending in `/` is a directory.
private func makeFactoryTree(_ paths: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("stock-plugin-presets-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for path in paths {
        let url = root.appendingPathComponent(path)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            continue
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preset".utf8).write(to: url)
    }
    return root
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

    @Test("verified parameter evidence rejects a missing reverse observation")
    func verifiedParameterEvidenceRequiresBidirectionalObservation() {
        let provenance = StockPluginProvenance.verified(
            source: "release_binary_live_drive",
            method: "logic_plugins.set_param_verified.ax_controls_view_checkbox_press",
            observedAt: "2026-09-02T11:30:17+09:00",
            logicVersion: nil,
            locale: "ko-KR",
            evidence: [
                "operation=logic_plugins.set_param_verified",
                "write_method=ax_controls_view_checkbox_press",
                "observed_transition=0->1",
            ]
        )
        let parameter = StockPluginParameterMetadata(
            id: "limiter_on",
            displayName: "Limiter On",
            unit: "boolean",
            valueRange: StockPluginValueRange(min: 0, max: 1, defaultValue: nil),
            writeMethod: "ax_controls_view_checkbox_press",
            readbackMethod: "ax_controls_view_checkbox_value",
            tolerance: 0,
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
        let rejectedForMissingReverse = issues.contains {
            $0.code == "verified_parameter_missing_write_observation"
        }
        #expect(rejectedForMissingReverse)
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

    @Test("a factory preset walk returns sorted names and says when the entry cap stopped it")
    func factoryPresetWalkIsBounded() throws {
        // Kills the mutant that reports a walk the entry cap stopped as complete.
        let directory = try makeFactoryTree(["Zed.pst", "Alpha.pst", "Beta.pst", "Gamma.pst", "ignore.txt"])

        let walk = StockPluginCatalog.factoryPresets(in: directory.path, maxDirectoryEntries: 100)
        #expect(walk.presets.map(\.name) == ["Alpha", "Beta", "Gamma", "Zed"])
        #expect(walk.complete)

        let capped = StockPluginCatalog.factoryPresets(in: directory.path, maxDirectoryEntries: 1)
        #expect(capped.presets.count <= 1)
        #expect(!capped.complete, "a walk the entry cap stopped must not read as the whole folder")
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
        // Compressor and Channel EQ expose `parameter_write_readback` catalog
        // entries while remaining insertable. Channel EQ's entry records only
        // raw-range/nudge evidence; it does not claim a completed live round
        // trip. The insert allowlist is the union.
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
        let channelEQ = snapshot.entries.first { $0.id == "logic.stock.effect.channel_eq" }
        #expect(channelEQ?.safeWriteCapabilities == .parameterWriteReadback)
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
        let entry = try #require(detail["entry"] as? [String: Any])
        let truncated = try #require(entry["known_presets_truncated"] as? Bool)
        // Gain ships 7 factory settings, under the 12-name cap, and none where Logic is absent.
        #expect(!truncated)
        #expect(detail["factory_presets"] as? [Any] != nil)

        let search = try await stockPluginResourceObject("logic://stock-plugins/search?query=gain")
        #expect(((search["entries"] as? [[String: Any]])?.contains { $0["id"] as? String == "logic.stock.effect.gain" })!)

        let census = try await stockPluginResourceObject("logic://stock-plugins/census")
        #expect(census["catalog_source"] as? String != nil)
        #expect(census["logic_version"] != nil)
        #expect((census["entries_by_state"] as? [String: Int]) != nil)

        let capabilities = try await stockPluginResourceObject("logic://stock-plugins/capabilities")
        #expect(((capabilities["truth_labels"] as? [String])?.contains("verified"))!)
        #expect(((capabilities["catalog_entry_fields"] as? [String])?.contains("known_presets"))!)
        #expect(((capabilities["catalog_entry_fields"] as? [String])?.contains("known_presets_truncated"))!)
        #expect(((capabilities["catalog_entry_fields"] as? [String])?.contains("known_presets_total"))!)
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

/// #1030: the catalog sees every factory preset Apple ships. Each test names the mutant it kills,
/// and none reads the installed Logic -- every root is a temporary directory.
@Suite("Stock plugin intelligence — factory presets")
struct StockPluginFactoryPresetTests {
    @Test("a preset filed in a category subfolder is found, with the subfolder as its category")
    func nestedPresetIsFound() throws {
        // Kills the mutant that restores `.skipsSubdirectoryDescendants` in `factoryPresets(in:)`.
        let root = try makeFactoryTree([
            "ES2/#default.pst",
            "ES2/01 Synth Leads/Lead One.pst",
            "ES2/01 Synth Leads/Deeper/Lead Two.pst",
            "ES2/01 Synth Leads/order.plist",
        ])

        let walk = StockPluginCatalog.factoryPresets(in: root.appendingPathComponent("ES2").path)

        #expect(walk.complete)
        #expect(walk.presets.map(\.name) == ["#default", "Lead One", "Lead Two"])
        #expect(walk.presets.map(\.category) == [nil, "01 Synth Leads", "01 Synth Leads/Deeper"])
    }

    @Test("the Plug-In Settings Internal root is searched, and every root's presets are kept")
    func internalRootIsSearched() throws {
        // Kills the mutant that removes `Plug-In Settings Internal` from `factorySettingsRoots`.
        let tree = try makeFactoryTree([
            "Fake.app/Contents/Resources/Plug-In Settings/Sculpture/#default.pst",
            "Fake.app/Contents/Resources/Plug-In Settings Internal/Sculpture/01 Pads/Glass Pad.pst",
        ])
        let appPath = tree.appendingPathComponent("Fake.app").path

        let manifests = StockPluginCatalog.probeLocalManifests(
            appPath: appPath,
            sharedRoot: tree.appendingPathComponent("no-shared-root").path
        )

        let sculpture = try #require(manifests["logic.stock.instrument.sculpture"])
        #expect(sculpture.sourcePath == appPath + "/Contents/Resources/Plug-In Settings/Sculpture")
        #expect(sculpture.presetNames == ["#default", "Glass Pad"])
        let internalPreset = try #require(sculpture.presets.first { $0.name == "Glass Pad" })
        #expect(internalPreset.folder == appPath + "/Contents/Resources/Plug-In Settings Internal/Sculpture")
        #expect(internalPreset.category == "01 Pads")
    }

    @Test("a list the name cap cuts says it is cut and gives the total")
    func truncationIsReportedWithItsTotal() throws {
        // Kills the mutant that drops the truncation flag in `buildEntry`.
        let thirteen = (1...13).map { "Preset \($0 < 10 ? "0" : "")\($0)" }
        let twelve = Array(thirteen.prefix(12))
        let census = censusFixture(manifests: [
            "logic.stock.effect.limiter": StockPluginLocalManifest(sourcePath: "/fixture/Limiter", presetNames: thirteen),
            "logic.stock.effect.gain": StockPluginLocalManifest(sourcePath: "/fixture/Gain", presetNames: twelve),
        ])
        let snapshot = StockPluginCatalog.defaultSnapshot(census: census)
        #expect(snapshot.validation.isValid, "\(snapshot.validation.issues)")

        let cut = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.limiter" })
        #expect(cut.knownPresets == twelve)
        #expect(cut.knownPresetsTruncated, "13 presets under a cap of 12 must say the list is cut")
        #expect(cut.knownPresetsTotal == 13)
        #expect(StockPluginCatalog.factoryPresets(id: cut.id, census: census).map(\.name) == thirteen)

        let encoded = try #require(ResourceHandlers.jsonObject(cut) as? [String: Any])
        let encodedTruncated = try #require(encoded["known_presets_truncated"] as? Bool)
        #expect(encodedTruncated)
        #expect(encoded["known_presets_total"] as? Int == 13)

        let whole = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.gain" })
        #expect(whole.knownPresets == twelve)
        #expect(!whole.knownPresetsTruncated)
        #expect(whole.knownPresetsTotal == 12)
    }

    @Test("a walk that stopped marks the entry truncated with an unknown total, never a short one")
    func stoppedWalkIsTruncatedWithUnknownTotal() throws {
        // Kills the same mutant as above through the other half of the condition: a walk the
        // entry cap stopped, where the names alone are under the name cap.
        let tree = try makeFactoryTree([
            "Fake.app/Contents/Resources/Plug-In Settings/Limiter/A.pst",
            "Fake.app/Contents/Resources/Plug-In Settings/Limiter/B.pst",
            "Fake.app/Contents/Resources/Plug-In Settings/Limiter/C.pst",
        ])
        let manifests = StockPluginCatalog.probeLocalManifests(
            appPath: tree.appendingPathComponent("Fake.app").path,
            sharedRoot: tree.appendingPathComponent("no-shared-root").path,
            maxDirectoryEntries: 1
        )
        let limiter = try #require(manifests["logic.stock.effect.limiter"])
        #expect(!limiter.scanComplete)

        let snapshot = StockPluginCatalog.defaultSnapshot(census: censusFixture(manifests: manifests))
        let entry = try #require(snapshot.entries.first { $0.id == "logic.stock.effect.limiter" })
        #expect(entry.knownPresetsTruncated)
        #expect(entry.knownPresetsTotal == nil)
    }

    @Test("a stopped walk encodes known_presets_total as a present null in every resource encoding")
    func stoppedWalkEncodesTotalAsNull() throws {
        // Kills the mutant that encodes `knownPresetsTotal` with `encodeIfPresent`, which is what
        // synthesized Codable did: the key vanished where the capabilities promise null.
        let stopped = StockPluginLocalManifest(
            sourcePath: "/fixture/Stopped",
            presets: [StockPluginFactoryPreset(name: "A", category: nil, folder: "/fixture/Stopped")],
            scanComplete: false
        )
        // Manifested, verified and observed entries all carry a manifest's walk.
        let ids = ["logic.stock.effect.limiter", "logic.stock.effect.gain", "logic.stock.effect.compressor"]
        let snapshot = StockPluginCatalog.defaultSnapshot(census: censusFixture(
            verified: ["logic.stock.effect.gain"],
            observed: ["logic.stock.effect.compressor"],
            manifests: Dictionary(uniqueKeysWithValues: ids.map { ($0, stopped) })
        ))
        let promised = try #require(StockPluginCatalog.capabilities(snapshot: snapshot)["catalog_entry_fields"] as? [String])

        // Detail and search encode an entry through `jsonObject`; the list encodes the snapshot.
        let listed = try #require(sharedJSONObject(encodeJSON(snapshot, compact: true))?["entries"] as? [[String: Any]])
        for id in ids {
            let entry = try #require(snapshot.entries.first { $0.id == id })
            #expect(entry.knownPresetsTotal == nil)
            let fromDetail = try #require(ResourceHandlers.jsonObject(entry) as? [String: Any])
            let fromList = try #require(listed.first { $0["id"] as? String == id })
            for encoded in [fromDetail, fromList] {
                #expect(encoded.keys.contains("known_presets_total"), "\(id): the key must be present")
                #expect(encoded["known_presets_total"] is NSNull, "\(id): the value must be null")
                // The encoder is written out by hand, so every promised field is checked present.
                #expect(Set(encoded.keys) == Set(promised))
            }
        }
    }

    @Test("a factory-settings folder with no seed and no exclusion fails")
    func unaccountedFolderFails() throws {
        // Kills the mutant that removes the Studio Piano seed.
        let root = try makeFactoryTree([
            "Studio Piano/Grand.pst",
            "ES2/#default.pst",
            "Auto-Funk/Fat Funk.pst",
            "Not A Plug-In/Anything.pst",
            "CSParameterOrder.plist",
        ])

        let unaccounted = try StockPluginCatalog.unaccountedFactorySettingsFolders(
            roots: [root.path, root.appendingPathComponent("absent-root").path]
        )
        #expect(unaccounted == ["Not A Plug-In"])

        // A root that exists and cannot be listed is not a root with nothing unaccounted in it.
        let notADirectory = root.appendingPathComponent("CSParameterOrder.plist").path
        #expect(throws: (any Error).self) {
            try StockPluginCatalog.unaccountedFactorySettingsFolders(roots: [notADirectory])
        }

        // A name is a seed or an exclusion, never both.
        let seedNames = Set(StockPluginCatalog.defaultSnapshot(census: .deterministic()).entries.map(\.displayName))
        #expect(seedNames.isDisjoint(with: StockPluginCatalog.factorySettingsFolderExclusions.keys))
    }
}
