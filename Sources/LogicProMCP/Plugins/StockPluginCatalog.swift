import Foundation

enum StockPluginTruthState: String, Codable, CaseIterable, Sendable {
    case verified
    case observed
    case manifested
    case inferred
    case unavailable
    case readbackMismatch = "readback_mismatch"
}

enum StockPluginType: String, Codable, Sendable {
    case effect
    case instrument
    case midiEffect = "midi_effect"
    case utility
    case metering
}

enum StockPluginSafeWriteCapability: String, Codable, Sendable {
    case none
    case insertOnly = "insert_only"
    case parameterWriteUnverified = "parameter_write_unverified"
    case parameterWriteReadback = "parameter_write_readback"
}

struct StockPluginProvenance: Codable, Sendable, Equatable {
    let source: String
    let method: String
    let observedAt: String?
    let logicVersion: String?
    let locale: String?
    let sourcePath: String?
    let inferenceReason: String?
    let evidence: [String]

    enum CodingKeys: String, CodingKey {
        case source
        case method
        case observedAt = "observed_at"
        case logicVersion = "logic_version"
        case locale
        case sourcePath = "source_path"
        case inferenceReason = "inference_reason"
        case evidence
    }

    static func inferred(reason: String) -> Self {
        Self(
            source: "static_catalog",
            method: "logic_stock_plugin_schema",
            observedAt: nil,
            logicVersion: nil,
            locale: nil,
            sourcePath: nil,
            inferenceReason: reason,
            evidence: []
        )
    }

    static func unavailable(method: String, observedAt: String, logicVersion: String?, locale: String?) -> Self {
        Self(
            source: "local_census",
            method: method,
            observedAt: observedAt,
            logicVersion: logicVersion,
            locale: locale,
            sourcePath: nil,
            inferenceReason: nil,
            evidence: ["absence_checked"]
        )
    }

    static func manifested(
        sourcePath: String,
        method: String,
        observedAt: String,
        logicVersion: String?,
        locale: String,
        evidence: [String]
    ) -> Self {
        Self(
            source: "local_logic_app",
            method: method,
            observedAt: observedAt,
            logicVersion: logicVersion,
            locale: locale,
            sourcePath: sourcePath,
            inferenceReason: nil,
            evidence: evidence
        )
    }

    static func verified(
        source: String,
        method: String,
        observedAt: String,
        logicVersion: String?,
        locale: String?,
        evidence: [String]
    ) -> Self {
        Self(
            source: source,
            method: method,
            observedAt: observedAt,
            logicVersion: logicVersion,
            locale: locale,
            sourcePath: nil,
            inferenceReason: nil,
            evidence: evidence
        )
    }
}

struct StockPluginValueRange: Codable, Sendable, Equatable {
    let min: Double
    let max: Double
    let defaultValue: Double?

    enum CodingKeys: String, CodingKey {
        case min
        case max
        case defaultValue = "default_value"
    }
}

struct StockPluginParameterMetadata: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let unit: String?
    let valueRange: StockPluginValueRange?
    let writeMethod: String?
    let readbackMethod: String?
    let availabilityState: StockPluginTruthState
    let provenance: StockPluginProvenance

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case unit
        case valueRange = "value_range"
        case writeMethod = "write_method"
        case readbackMethod = "readback_method"
        case availabilityState = "availability_state"
        case provenance
    }
}

struct StockPluginInsertPath: Codable, Sendable, Equatable {
    let path: [String]
    let availabilityState: StockPluginTruthState
    let provenance: StockPluginProvenance

    enum CodingKeys: String, CodingKey {
        case path
        case availabilityState = "availability_state"
        case provenance
    }
}

struct StockPluginSlotSupport: Codable, Sendable, Equatable {
    let audio: Bool
    let instrument: Bool
    let midiFX: Bool
    let aux: Bool
    let stereo: Bool?
    let mono: Bool?

    enum CodingKeys: String, CodingKey {
        case audio
        case instrument
        case midiFX = "midi_fx"
        case aux
        case stereo
        case mono
    }

    init(audio: Bool, instrument: Bool, midiFX: Bool, aux: Bool, stereo: Bool? = nil, mono: Bool? = nil) {
        self.audio = audio
        self.instrument = instrument
        self.midiFX = midiFX
        self.aux = aux
        self.stereo = stereo
        self.mono = mono
    }
}

struct StockPluginCatalogEntry: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let type: StockPluginType
    let category: String
    let availabilityState: StockPluginTruthState
    let provenance: StockPluginProvenance
    let insertPaths: [StockPluginInsertPath]
    let slotSupport: StockPluginSlotSupport
    let knownPresets: [String]
    let parameters: [StockPluginParameterMetadata]
    let safeWriteCapabilities: StockPluginSafeWriteCapability
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case type
        case category
        case availabilityState = "availability_state"
        case provenance
        case insertPaths = "insert_paths"
        case slotSupport = "slot_support"
        case knownPresets = "known_presets"
        case parameters
        case safeWriteCapabilities = "safe_write_capabilities"
        case limitations
    }
}

struct StockPluginValidationIssue: Codable, Sendable, Equatable {
    let code: String
    let path: String
    let message: String
}

struct StockPluginValidationResult: Codable, Sendable, Equatable {
    let isValid: Bool
    let issues: [StockPluginValidationIssue]

    enum CodingKeys: String, CodingKey {
        case isValid = "is_valid"
        case issues
    }
}

struct StockPluginCatalogSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let logicVersion: String?
    let locale: String
    let catalogSource: String
    let pluginCount: Int
    let validation: StockPluginValidationResult
    let entries: [StockPluginCatalogEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case logicVersion = "logic_version"
        case locale
        case catalogSource = "catalog_source"
        case pluginCount = "plugin_count"
        case validation
        case entries
    }
}

struct StockPluginCensus: Sendable, Equatable {
    let observedAt: String
    let logicVersion: String?
    let locale: String
    let logicAppPath: String?
    let verifiedPluginIDs: Set<String>
    let observedPluginIDs: Set<String>

    static func production(now: Date = Date()) -> Self {
        let observedAt = ISO8601DateFormatter.cacheFormatter.string(from: now)
        let appPath = "/Applications/Logic Pro.app"
        let bundle = Bundle(path: appPath)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let existingPath = FileManager.default.fileExists(atPath: appPath) ? appPath : nil
        return Self(
            observedAt: observedAt,
            logicVersion: version,
            locale: Locale.current.identifier,
            logicAppPath: existingPath,
            verifiedPluginIDs: [],
            observedPluginIDs: []
        )
    }

    static func deterministic() -> Self {
        Self(
            observedAt: "2026-06-09T00:00:00.000Z",
            logicVersion: nil,
            locale: "en_US",
            logicAppPath: nil,
            verifiedPluginIDs: [],
            observedPluginIDs: []
        )
    }
}

enum StockPluginCatalogValidator {
    static func validate(_ entries: [StockPluginCatalogEntry]) -> StockPluginValidationResult {
        var issues: [StockPluginValidationIssue] = []
        var seen = Set<String>()

        for (index, entry) in entries.enumerated() {
            let base = "entries[\(index)]"
            if entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue("missing_id", base, "plugin entry id is required"))
            }
            if !seen.insert(entry.id).inserted {
                issues.append(issue("duplicate_id", "\(base).id", "duplicate plugin id \(entry.id)"))
            }
            validateProvenance(
                entry.provenance,
                state: entry.availabilityState,
                path: "\(base).provenance",
                issues: &issues
            )
            if entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue("missing_display_name", "\(base).display_name", "display name is required"))
            }
            if entry.insertPaths.isEmpty && entry.availabilityState != .unavailable {
                issues.append(issue("missing_insert_path", "\(base).insert_paths", "available entries need insert path hints"))
            }
            for (pathIndex, insertPath) in entry.insertPaths.enumerated() {
                validateProvenance(
                    insertPath.provenance,
                    state: insertPath.availabilityState,
                    path: "\(base).insert_paths[\(pathIndex)].provenance",
                    issues: &issues
                )
            }
            for (paramIndex, parameter) in entry.parameters.enumerated() {
                validateProvenance(
                    parameter.provenance,
                    state: parameter.availabilityState,
                    path: "\(base).parameters[\(paramIndex)].provenance",
                    issues: &issues
                )
                if parameter.availabilityState == .verified,
                   (parameter.readbackMethod?.isEmpty ?? true) || !parameter.provenance.evidence.contains("parameter_readback") {
                    issues.append(issue(
                        "verified_parameter_missing_readback",
                        "\(base).parameters[\(paramIndex)]",
                        "verified parameters require readback method and parameter_readback evidence"
                    ))
                }
            }
        }
        return StockPluginValidationResult(isValid: issues.isEmpty, issues: issues)
    }

    private static func validateProvenance(
        _ provenance: StockPluginProvenance,
        state: StockPluginTruthState,
        path: String,
        issues: inout [StockPluginValidationIssue]
    ) {
        switch state {
        case .verified:
            if provenance.source.isEmpty ||
                provenance.method.isEmpty ||
                (provenance.observedAt?.isEmpty ?? true) ||
                provenance.evidence.isEmpty {
                issues.append(issue(
                    "verified_missing_provenance",
                    path,
                    "verified state requires source, method, observed_at, and evidence"
                ))
            }
        case .observed, .manifested, .unavailable, .readbackMismatch:
            if provenance.source.isEmpty ||
                provenance.method.isEmpty ||
                (provenance.observedAt?.isEmpty ?? true) {
                issues.append(issue(
                    "observed_missing_provenance",
                    path,
                    "\(state.rawValue) state requires source, method, and observed_at"
                ))
            }
        case .inferred:
            if provenance.inferenceReason?.isEmpty ?? true {
                issues.append(issue(
                    "inferred_missing_reason",
                    path,
                    "inferred state requires inference_reason"
                ))
            }
        }
    }

    private static func issue(_ code: String, _ path: String, _ message: String) -> StockPluginValidationIssue {
        StockPluginValidationIssue(code: code, path: path, message: message)
    }
}

enum StockPluginCatalog {
    static func defaultSnapshot(census: StockPluginCensus = .production()) -> StockPluginCatalogSnapshot {
        let entries = defaultEntries(census: census).sorted { $0.id < $1.id }
        let validation = StockPluginCatalogValidator.validate(entries)
        return StockPluginCatalogSnapshot(
            schemaVersion: 1,
            generatedAt: census.observedAt,
            logicVersion: census.logicVersion,
            locale: census.locale,
            catalogSource: census.logicAppPath == nil ? "static_catalog" : "static_catalog+local_logic_app",
            pluginCount: entries.count,
            validation: validation,
            entries: entries
        )
    }

    static func entry(id: String, snapshot: StockPluginCatalogSnapshot = defaultSnapshot()) -> StockPluginCatalogEntry? {
        snapshot.entries.first { $0.id == id }
    }

    static func search(query: String, snapshot: StockPluginCatalogSnapshot = defaultSnapshot()) -> [StockPluginCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snapshot.entries }
        return snapshot.entries.filter { entry in
            entry.id.lowercased().contains(q) ||
                entry.displayName.lowercased().contains(q) ||
                entry.category.lowercased().contains(q) ||
                entry.limitations.joined(separator: " ").lowercased().contains(q)
        }
    }

    static func capabilities(snapshot: StockPluginCatalogSnapshot = defaultSnapshot()) -> [String: Any] {
        [
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "logic_version": snapshot.logicVersion ?? NSNull(),
            "catalog_source": snapshot.catalogSource,
            "truth_labels": StockPluginTruthState.allCases.map(\.rawValue),
            "safe_write_capabilities": [
                StockPluginSafeWriteCapability.none.rawValue,
                StockPluginSafeWriteCapability.insertOnly.rawValue,
                StockPluginSafeWriteCapability.parameterWriteUnverified.rawValue,
                StockPluginSafeWriteCapability.parameterWriteReadback.rawValue,
            ],
            "resources": [
                "logic://stock-plugins",
                "logic://stock-plugins/{id}",
                "logic://stock-plugins/search?query=<text>",
                "logic://stock-plugins/census",
                "logic://stock-plugins/capabilities",
            ],
            "catalog_entry_fields": [
                "id",
                "display_name",
                "type",
                "category",
                "availability_state",
                "provenance",
                "insert_paths",
                "slot_support",
                "known_presets",
                "parameters",
                "safe_write_capabilities",
                "limitations",
            ],
            "write_side_behavior": "unchanged; discovery resources are read-only",
            "validation": [
                "is_valid": snapshot.validation.isValid,
                "issue_count": snapshot.validation.issues.count,
            ],
        ]
    }

    private static func defaultEntries(census: StockPluginCensus) -> [StockPluginCatalogEntry] {
        let base = StockPluginProvenance.inferred(reason: "Logic stock plugin identity documented by project catalog; not live verified in this response")
        let manifested: StockPluginProvenance? = census.logicAppPath.map {
            StockPluginProvenance.manifested(
                sourcePath: $0,
                method: "logic_app_bundle_metadata",
                observedAt: census.observedAt,
                logicVersion: census.logicVersion,
                locale: census.locale,
                evidence: ["logic_app_bundle_present"]
            )
        }

        return [
            entry(
                id: "logic.stock.effect.channel_eq",
                displayName: "Channel EQ",
                type: .effect,
                category: "EQ",
                path: ["Audio FX", "EQ", "Channel EQ"],
                slotSupport: StockPluginSlotSupport(audio: true, instrument: false, midiFX: false, aux: true, stereo: true, mono: true),
                provenance: overlayProvenance(id: "logic.stock.effect.channel_eq", census: census, fallback: manifested ?? base),
                fallbackState: manifested == nil ? .inferred : .manifested,
                limitations: ["parameter names and readback are not verified by this catalog"]
            ),
            entry(
                id: "logic.stock.effect.compressor",
                displayName: "Compressor",
                type: .effect,
                category: "Dynamics",
                path: ["Audio FX", "Dynamics", "Compressor"],
                slotSupport: StockPluginSlotSupport(audio: true, instrument: false, midiFX: false, aux: true, stereo: true, mono: true),
                provenance: overlayProvenance(id: "logic.stock.effect.compressor", census: census, fallback: manifested ?? base),
                fallbackState: manifested == nil ? .inferred : .manifested,
                limitations: ["model and parameter mapping are not verified by this catalog"]
            ),
            entry(
                id: "logic.stock.effect.gain",
                displayName: "Gain",
                type: .utility,
                category: "Utility",
                path: ["Audio FX", "Utility", "Gain"],
                slotSupport: StockPluginSlotSupport(audio: true, instrument: false, midiFX: false, aux: true, stereo: true, mono: true),
                provenance: overlayProvenance(id: "logic.stock.effect.gain", census: census, fallback: manifested ?? base),
                fallbackState: manifested == nil ? .inferred : .manifested,
                parameters: [
                    StockPluginParameterMetadata(
                        id: "gain",
                        displayName: "Gain",
                        unit: "dB",
                        valueRange: StockPluginValueRange(min: -96, max: 24, defaultValue: 0),
                        writeMethod: nil,
                        readbackMethod: nil,
                        availabilityState: .inferred,
                        provenance: base
                    ),
                ],
                safeWriteCapabilities: .insertOnly,
                limitations: ["insert path is a hint unless live Logic evidence upgrades this entry"]
            ),
            entry(
                id: "logic.stock.effect.limiter",
                displayName: "Limiter",
                type: .effect,
                category: "Dynamics",
                path: ["Audio FX", "Dynamics", "Limiter"],
                slotSupport: StockPluginSlotSupport(audio: true, instrument: false, midiFX: false, aux: true, stereo: true, mono: true),
                provenance: overlayProvenance(id: "logic.stock.effect.limiter", census: census, fallback: manifested ?? base),
                fallbackState: manifested == nil ? .inferred : .manifested,
                limitations: ["parameter control is not claimed"]
            ),
            unavailableEntry(
                id: "logic.stock.effect.legacy.silververb",
                displayName: "SilverVerb",
                category: "Reverb",
                census: census
            ),
        ]
    }

    private static func overlayProvenance(
        id: String,
        census: StockPluginCensus,
        fallback: StockPluginProvenance
    ) -> StockPluginProvenance {
        if census.verifiedPluginIDs.contains(id) {
            return .verified(
                source: "live_logic",
                method: "ax_insert_readback",
                observedAt: census.observedAt,
                logicVersion: census.logicVersion,
                locale: census.locale,
                evidence: ["plugin_identity_readback"]
            )
        }
        if census.observedPluginIDs.contains(id) {
            return StockPluginProvenance(
                source: "live_logic",
                method: "ax_menu_observation",
                observedAt: census.observedAt,
                logicVersion: census.logicVersion,
                locale: census.locale,
                sourcePath: nil,
                inferenceReason: nil,
                evidence: ["menu_item_observed"]
            )
        }
        return fallback
    }

    private static func state(for provenance: StockPluginProvenance, fallback: StockPluginTruthState) -> StockPluginTruthState {
        if provenance.source == "live_logic", provenance.method == "ax_insert_readback" { return .verified }
        if provenance.source == "live_logic" { return .observed }
        if provenance.source == "local_logic_app" { return .manifested }
        return fallback
    }

    private static func entry(
        id: String,
        displayName: String,
        type: StockPluginType,
        category: String,
        path: [String],
        slotSupport: StockPluginSlotSupport,
        provenance: StockPluginProvenance,
        fallbackState: StockPluginTruthState,
        parameters: [StockPluginParameterMetadata] = [],
        safeWriteCapabilities: StockPluginSafeWriteCapability = .none,
        knownPresets: [String] = [],
        limitations: [String]
    ) -> StockPluginCatalogEntry {
        let availabilityState = state(for: provenance, fallback: fallbackState)
        return StockPluginCatalogEntry(
            id: id,
            displayName: displayName,
            type: type,
            category: category,
            availabilityState: availabilityState,
            provenance: provenance,
            insertPaths: [
                StockPluginInsertPath(
                    path: path,
                    availabilityState: availabilityState,
                    provenance: provenance
                ),
            ],
            slotSupport: slotSupport,
            knownPresets: knownPresets,
            parameters: parameters,
            safeWriteCapabilities: safeWriteCapabilities,
            limitations: limitations
        )
    }

    private static func unavailableEntry(
        id: String,
        displayName: String,
        category: String,
        census: StockPluginCensus
    ) -> StockPluginCatalogEntry {
        let provenance = StockPluginProvenance.unavailable(
            method: "default_catalog_absence_marker",
            observedAt: census.observedAt,
            logicVersion: census.logicVersion,
            locale: census.locale
        )
        return StockPluginCatalogEntry(
            id: id,
            displayName: displayName,
            type: .effect,
            category: category,
            availabilityState: .unavailable,
            provenance: provenance,
            insertPaths: [],
            slotSupport: StockPluginSlotSupport(audio: false, instrument: false, midiFX: false, aux: false),
            knownPresets: [],
            parameters: [],
            safeWriteCapabilities: .none,
            limitations: ["not available in the current supported stock-plugin catalog"]
        )
    }
}
