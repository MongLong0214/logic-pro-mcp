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

    static func unavailable(
        method: String,
        observedAt: String,
        logicVersion: String?,
        locale: String?,
        evidence: [String]
    ) -> Self {
        Self(
            source: "live_logic",
            method: method,
            observedAt: observedAt,
            logicVersion: logicVersion,
            locale: locale,
            sourcePath: nil,
            inferenceReason: nil,
            evidence: evidence
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

    static func observed(
        method: String,
        observedAt: String,
        logicVersion: String?,
        locale: String?,
        evidence: [String]
    ) -> Self {
        Self(
            source: "live_logic",
            method: method,
            observedAt: observedAt,
            logicVersion: logicVersion,
            locale: locale,
            sourcePath: nil,
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

    static func readbackMismatch(
        observedAt: String,
        logicVersion: String?,
        locale: String?,
        evidence: [String]
    ) -> Self {
        Self(
            source: "live_logic",
            method: "ax_insert_readback",
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

/// Per-plugin evidence harvested from the local Logic Pro installation.
/// Presence of a factory "Plug-In Settings/<Display Name>" folder is positive,
/// plugin-specific evidence (`manifested`). Absence of a folder is NOT
/// evidence of absence — several real plugins ship presets elsewhere — so the
/// probe only ever upgrades entries and never produces `unavailable`.
struct StockPluginLocalManifest: Sendable, Equatable {
    let sourcePath: String
    let presetNames: [String]
}

struct StockPluginCensus: Sendable, Equatable {
    let observedAt: String
    let logicVersion: String?
    let locale: String
    let logicAppPath: String?
    let verifiedPluginIDs: Set<String>
    let observedPluginIDs: Set<String>
    let readbackMismatchPluginIDs: Set<String>
    let unavailablePluginIDs: Set<String>
    let localManifests: [String: StockPluginLocalManifest]

    init(
        observedAt: String,
        logicVersion: String?,
        locale: String,
        logicAppPath: String?,
        verifiedPluginIDs: Set<String> = [],
        observedPluginIDs: Set<String> = [],
        readbackMismatchPluginIDs: Set<String> = [],
        unavailablePluginIDs: Set<String> = [],
        localManifests: [String: StockPluginLocalManifest] = [:]
    ) {
        self.observedAt = observedAt
        self.logicVersion = logicVersion
        self.locale = locale
        self.logicAppPath = logicAppPath
        self.verifiedPluginIDs = verifiedPluginIDs
        self.observedPluginIDs = observedPluginIDs
        self.readbackMismatchPluginIDs = readbackMismatchPluginIDs
        self.unavailablePluginIDs = unavailablePluginIDs
        self.localManifests = localManifests
    }

    static func production(now: Date = Date()) -> Self {
        let observedAt = ISO8601DateFormatter.cacheFormatter.string(from: now)
        let appPath = "/Applications/Logic Pro.app"
        let appPresent = FileManager.default.fileExists(atPath: appPath)
        let bundle = appPresent ? Bundle(path: appPath) : nil
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return Self(
            observedAt: observedAt,
            logicVersion: version,
            locale: Locale.current.identifier,
            logicAppPath: appPresent ? appPath : nil,
            localManifests: appPresent ? StockPluginCatalog.probeLocalManifests(appPath: appPath) : [:]
        )
    }

    static func deterministic() -> Self {
        Self(
            observedAt: "2026-06-09T00:00:00.000Z",
            logicVersion: nil,
            locale: "en_US",
            logicAppPath: nil
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
            } else if entry.id.range(of: Self.idPattern, options: .regularExpression) == nil {
                issues.append(issue("invalid_id_format", "\(base).id", "plugin id \(entry.id) must match \(Self.idPattern)"))
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
            if !entry.knownPresets.isEmpty && !hasPresetProvenance(entry.provenance) {
                issues.append(issue(
                    "presets_missing_provenance",
                    "\(base).known_presets",
                    "known presets require preset-name evidence in provenance"
                ))
            }
            for (pathIndex, insertPath) in entry.insertPaths.enumerated() {
                if insertPath.path.isEmpty || insertPath.path.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    issues.append(issue(
                        "invalid_insert_path",
                        "\(base).insert_paths[\(pathIndex)].path",
                        "insert path segments must be non-empty"
                    ))
                }
                validateProvenance(
                    insertPath.provenance,
                    state: insertPath.availabilityState,
                    path: "\(base).insert_paths[\(pathIndex)].provenance",
                    issues: &issues
                )
            }
            var seenParameterIDs = Set<String>()
            for (paramIndex, parameter) in entry.parameters.enumerated() {
                if !seenParameterIDs.insert(parameter.id).inserted {
                    issues.append(issue(
                        "duplicate_parameter_id",
                        "\(base).parameters[\(paramIndex)].id",
                        "duplicate parameter id \(parameter.id)"
                    ))
                }
                if let range = parameter.valueRange {
                    if range.min > range.max {
                        issues.append(issue(
                            "invalid_value_range",
                            "\(base).parameters[\(paramIndex)].value_range",
                            "min must be <= max"
                        ))
                    } else if let def = range.defaultValue, def < range.min || def > range.max {
                        issues.append(issue(
                            "invalid_value_range",
                            "\(base).parameters[\(paramIndex)].value_range",
                            "default_value must sit within [min, max]"
                        ))
                    }
                }
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

    static let idPattern = "^logic\\.stock\\.(effect|instrument|midi_fx)\\.[a-z0-9_]+$"

    private static func hasPresetProvenance(_ provenance: StockPluginProvenance) -> Bool {
        provenance.evidence.contains("factory_preset_filenames") ||
            provenance.evidence.contains("preset_names_observed")
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
        case .readbackMismatch:
            if provenance.source.isEmpty ||
                provenance.method.isEmpty ||
                (provenance.observedAt?.isEmpty ?? true) ||
                provenance.evidence.isEmpty {
                issues.append(issue(
                    "mismatch_missing_provenance",
                    path,
                    "readback_mismatch state requires source, method, observed_at, and evidence"
                ))
            }
        case .observed, .manifested, .unavailable:
            if provenance.source.isEmpty ||
                provenance.method.isEmpty ||
                (provenance.observedAt?.isEmpty ?? true) {
                issues.append(issue(
                    "observed_missing_provenance",
                    path,
                    "\(state.rawValue) state requires source, method, and observed_at"
                ))
            }
            if state == .manifested, provenance.sourcePath?.isEmpty ?? true {
                issues.append(issue(
                    "manifested_missing_source_path",
                    path,
                    "manifested state requires the probed source_path"
                ))
            }
            if state == .unavailable, provenance.evidence.isEmpty {
                issues.append(issue(
                    "unavailable_missing_evidence",
                    path,
                    "unavailable state requires absence evidence"
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
    /// Process-wide production snapshot. The census probe (app bundle check +
    /// per-plugin factory settings folders) runs once; resources then serve a
    /// stable, cache-friendly payload with a constant `generated_at`.
    static let productionSnapshot: StockPluginCatalogSnapshot = defaultSnapshot(census: .production())

    /// Cap on factory preset names surfaced per entry, keeping the list
    /// resource payload bounded. The full set remains on disk at the entry's
    /// provenance `source_path`.
    static let maxFactoryPresetNames = 12

    static func defaultSnapshot(census: StockPluginCensus) -> StockPluginCatalogSnapshot {
        let entries = seeds
            .map { buildEntry(seed: $0, census: census) }
            .sorted { $0.id < $1.id }
        let conflicts = censusConflicts(census)
        let entryValidation = StockPluginCatalogValidator.validate(entries)
        let validation = StockPluginValidationResult(
            isValid: entryValidation.isValid && conflicts.isEmpty,
            issues: conflicts + entryValidation.issues
        )
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

    /// Contradictory live evidence for the same plugin must fail loudly, not
    /// be resolved by precedence alone: a plugin cannot be both verified and
    /// readback-mismatched, nor absent yet seen live.
    static func censusConflicts(_ census: StockPluginCensus) -> [StockPluginValidationIssue] {
        let contradictions: [(String, Set<String>, String, Set<String>)] = [
            ("verified", census.verifiedPluginIDs, "readback_mismatch", census.readbackMismatchPluginIDs),
            ("verified", census.verifiedPluginIDs, "unavailable", census.unavailablePluginIDs),
            ("observed", census.observedPluginIDs, "unavailable", census.unavailablePluginIDs),
            ("readback_mismatch", census.readbackMismatchPluginIDs, "unavailable", census.unavailablePluginIDs),
        ]
        var issues: [StockPluginValidationIssue] = []
        for (leftName, left, rightName, right) in contradictions {
            for id in left.intersection(right).sorted() {
                issues.append(StockPluginValidationIssue(
                    code: "census_conflict",
                    path: "census.\(id)",
                    message: "census claims both \(leftName) and \(rightName) for \(id)"
                ))
            }
        }
        return issues
    }

    static func entry(id: String, snapshot: StockPluginCatalogSnapshot = productionSnapshot) -> StockPluginCatalogEntry? {
        snapshot.entries.first { $0.id == id }
    }

    static func search(query: String, snapshot: StockPluginCatalogSnapshot = productionSnapshot) -> [StockPluginCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return snapshot.entries }
        return snapshot.entries.filter { entry in
            entry.id.lowercased().contains(q) ||
                entry.displayName.lowercased().contains(q) ||
                entry.category.lowercased().contains(q) ||
                entry.type.rawValue.contains(q) ||
                entry.limitations.joined(separator: " ").lowercased().contains(q)
        }
    }

    static func capabilities(snapshot: StockPluginCatalogSnapshot = productionSnapshot) -> [String: Any] {
        [
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "logic_version": snapshot.logicVersion ?? NSNull(),
            "catalog_source": snapshot.catalogSource,
            "truth_labels": StockPluginTruthState.allCases.map(\.rawValue),
            "production_reachable_states": [
                StockPluginTruthState.inferred.rawValue,
                StockPluginTruthState.manifested.rawValue,
            ],
            "census_injectable_states": [
                StockPluginTruthState.verified.rawValue,
                StockPluginTruthState.observed.rawValue,
                StockPluginTruthState.readbackMismatch.rawValue,
                StockPluginTruthState.unavailable.rawValue,
            ],
            "state_semantics": [
                "verified": "live insert/readback evidence on this machine",
                "observed": "seen in a live Logic session without full readback",
                "manifested": "per-plugin factory metadata found in the local Logic installation",
                "inferred": "documented stock identity only; verify against the live menu",
                "unavailable": "a live census recorded this plugin as absent",
                "readback_mismatch": "live readback returned a different identity than expected",
            ],
            "id_namespaces": [
                "logic.stock.effect.*",
                "logic.stock.instrument.*",
                "logic.stock.midi_fx.*",
            ],
            "preset_name_cap": maxFactoryPresetNames,
            "safe_write_capabilities": [
                StockPluginSafeWriteCapability.none.rawValue,
                StockPluginSafeWriteCapability.insertOnly.rawValue,
                StockPluginSafeWriteCapability.parameterWriteUnverified.rawValue,
                StockPluginSafeWriteCapability.parameterWriteReadback.rawValue,
            ],
            "resources": [
                "logic://stock-plugins",
                "logic://stock-plugins/{id}",
                "logic://stock-plugins/search?query={query}",
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

    // MARK: - Local installation probe

    /// Factory plug-in settings roots. The app bundle root is authoritative
    /// for the installed Logic version; the shared Application Support root
    /// covers content installed via additional-content downloads.
    static func factorySettingsRoots(appPath: String) -> [String] {
        [
            appPath + "/Contents/Resources/Plug-In Settings",
            "/Library/Application Support/Logic/Plug-In Settings",
        ]
    }

    static func probeLocalManifests(appPath: String) -> [String: StockPluginLocalManifest] {
        let fm = FileManager.default
        let roots = factorySettingsRoots(appPath: appPath)
        var result: [String: StockPluginLocalManifest] = [:]
        for seed in seeds {
            // POSIX paths cannot contain "/" in a single component, so names
            // like "I/O" have no probeable folder; skip rather than letting
            // the separator silently change the probed directory.
            guard !seed.name.contains("/") else { continue }
            for root in roots {
                let folder = root + "/" + seed.name
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let presets = ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
                    .filter { $0.hasSuffix(".pst") }
                    .map { String($0.dropLast(4)) }
                    .sorted()
                result[seed.id] = StockPluginLocalManifest(
                    sourcePath: folder,
                    presetNames: Array(presets.prefix(maxFactoryPresetNames))
                )
                break
            }
        }
        return result
    }

    // MARK: - Seed catalog

    private struct Seed {
        let id: String
        let name: String
        let type: StockPluginType
        let category: String
        let menu: [String]
        let write: StockPluginSafeWriteCapability
        let parameters: [StockPluginParameterMetadata]
        let notes: [String]
    }

    private static func fx(
        _ idSuffix: String,
        _ name: String,
        _ category: String,
        type: StockPluginType = .effect,
        write: StockPluginSafeWriteCapability = .none,
        parameters: [StockPluginParameterMetadata] = [],
        notes: [String] = []
    ) -> Seed {
        Seed(
            id: "logic.stock.effect.\(idSuffix)",
            name: name,
            type: type,
            category: category,
            menu: ["Audio FX", category, name],
            write: write,
            parameters: parameters,
            notes: notes
        )
    }

    private static func inst(_ idSuffix: String, _ name: String, _ category: String, notes: [String] = []) -> Seed {
        Seed(
            id: "logic.stock.instrument.\(idSuffix)",
            name: name,
            type: .instrument,
            category: category,
            menu: ["Instrument", name],
            write: .none,
            parameters: [],
            notes: notes
        )
    }

    private static func midiFX(_ idSuffix: String, _ name: String, notes: [String] = []) -> Seed {
        Seed(
            id: "logic.stock.midi_fx.\(idSuffix)",
            name: name,
            type: .midiEffect,
            category: "MIDI FX",
            menu: ["MIDI FX", name],
            write: .none,
            parameters: [],
            notes: notes
        )
    }

    private static let gainParameters = [
        StockPluginParameterMetadata(
            id: "gain",
            displayName: "Gain",
            unit: "dB",
            valueRange: StockPluginValueRange(min: -96, max: 24, defaultValue: 0),
            writeMethod: nil,
            readbackMethod: nil,
            availabilityState: .inferred,
            provenance: .inferred(reason: "documented Gain parameter range; no write/readback path is claimed")
        ),
    ]

    /// Curated stock catalog seeds. Display names double as probe keys for the
    /// factory settings folders, so they must match Logic's folder spelling
    /// (e.g. "Ringshifter", "DeEsser 2", "Vintage B3").
    private static let seeds: [Seed] = [
        // EQ
        fx("channel_eq", "Channel EQ", "EQ", write: .insertOnly),
        fx("linear_phase_eq", "Linear Phase EQ", "EQ"),
        fx("match_eq", "Match EQ", "EQ"),
        fx("single_band_eq", "Single Band EQ", "EQ"),
        fx("vintage_console_eq", "Vintage Console EQ", "EQ"),
        fx("vintage_graphic_eq", "Vintage Graphic EQ", "EQ"),
        fx("vintage_tube_eq", "Vintage Tube EQ", "EQ"),
        // Dynamics
        fx("adaptive_limiter", "Adaptive Limiter", "Dynamics"),
        fx("compressor", "Compressor", "Dynamics", write: .insertOnly),
        fx("deesser_2", "DeEsser 2", "Dynamics"),
        fx("enveloper", "Enveloper", "Dynamics"),
        fx("expander", "Expander", "Dynamics"),
        fx("limiter", "Limiter", "Dynamics"),
        fx("multipressor", "Multipressor", "Dynamics"),
        fx("noise_gate", "Noise Gate", "Dynamics"),
        // Reverb
        fx("chromaverb", "ChromaVerb", "Reverb"),
        fx("quantec_room_simulator", "Quantec Room Simulator", "Reverb", notes: ["introduced in Logic Pro 11.1; absent on older installs"]),
        fx("silververb", "SilverVerb", "Reverb", notes: ["legacy plugin; may sit in a Legacy submenu depending on Logic version"]),
        fx("space_designer", "Space Designer", "Reverb"),
        // Delay
        fx("delay_designer", "Delay Designer", "Delay"),
        fx("echo", "Echo", "Delay"),
        fx("sample_delay", "Sample Delay", "Delay"),
        fx("stereo_delay", "Stereo Delay", "Delay"),
        fx("tape_delay", "Tape Delay", "Delay"),
        // Modulation
        fx("chorus", "Chorus", "Modulation"),
        fx("ensemble", "Ensemble", "Modulation"),
        fx("flanger", "Flanger", "Modulation"),
        fx("microphaser", "Microphaser", "Modulation"),
        fx("modulation_delay", "Modulation Delay", "Modulation"),
        fx("phaser", "Phaser", "Modulation"),
        fx("ringshifter", "Ringshifter", "Modulation"),
        fx("rotor_cabinet", "Rotor Cabinet", "Modulation"),
        fx("scanner_vibrato", "Scanner Vibrato", "Modulation"),
        fx("spreader", "Spreader", "Modulation"),
        fx("tremolo", "Tremolo", "Modulation"),
        // Distortion
        fx("bitcrusher", "Bitcrusher", "Distortion"),
        fx("chromaglow", "ChromaGlow", "Distortion", notes: ["requires Apple silicon; introduced in Logic Pro 11"]),
        fx("clip_distortion", "Clip Distortion", "Distortion"),
        fx("distortion", "Distortion", "Distortion"),
        fx("distortion_ii", "Distortion II", "Distortion"),
        fx("overdrive", "Overdrive", "Distortion"),
        fx("phase_distortion", "Phase Distortion", "Distortion"),
        // Filter
        fx("autofilter", "AutoFilter", "Filter"),
        fx("evoc_20_filterbank", "EVOC 20 Filterbank", "Filter"),
        fx("fuzz_wah", "Fuzz-Wah", "Filter"),
        fx("spectral_gate", "Spectral Gate", "Filter"),
        // Imaging
        fx("direction_mixer", "Direction Mixer", "Imaging"),
        fx("stereo_spread", "Stereo Spread", "Imaging"),
        // Pitch
        fx("pitch_correction", "Pitch Correction", "Pitch"),
        fx("pitch_shifter", "Pitch Shifter", "Pitch"),
        fx("vocal_transformer", "Vocal Transformer", "Pitch"),
        // Utility
        fx("gain", "Gain", "Utility", type: .utility, write: .insertOnly, parameters: gainParameters,
           notes: ["insert path is a hint unless live Logic evidence upgrades this entry"]),
        fx("io", "I/O", "Utility", type: .utility, notes: ["external hardware insert utility"]),
        fx("test_oscillator", "Test Oscillator", "Utility", type: .utility),
        // Metering
        fx("correlation_meter", "Correlation Meter", "Metering", type: .metering),
        fx("level_meter", "Level Meter", "Metering", type: .metering),
        fx("loudness_meter", "Loudness Meter", "Metering", type: .metering),
        fx("multimeter", "MultiMeter", "Metering", type: .metering),
        fx("tuner", "Tuner", "Metering", type: .metering),
        // Specialized
        fx("exciter", "Exciter", "Specialized"),
        fx("subbass", "SubBass", "Specialized"),
        // Multi Effects
        fx("beat_breaker", "Beat Breaker", "Multi Effects", notes: ["introduced in Logic Pro 11"]),
        fx("phat_fx", "Phat FX", "Multi Effects"),
        fx("remix_fx", "Remix FX", "Multi Effects"),
        fx("step_fx", "Step FX", "Multi Effects"),
        // Amps and Pedals
        fx("amp_designer", "Amp Designer", "Amps and Pedals"),
        fx("bass_amp_designer", "Bass Amp Designer", "Amps and Pedals"),
        fx("pedalboard", "Pedalboard", "Amps and Pedals"),
        // Instruments
        inst("alchemy", "Alchemy", "Synthesizer"),
        inst("drum_kit_designer", "Drum Kit Designer", "Drums"),
        inst("drum_machine_designer", "Drum Machine Designer", "Drums", notes: ["hosted via Drum Machine Designer track stacks"]),
        inst("drum_synth", "Drum Synth", "Drums"),
        inst("efm1", "EFM1", "Synthesizer"),
        inst("es_e", "ES E", "Synthesizer", notes: ["legacy ensemble synth"]),
        inst("es_m", "ES M", "Synthesizer", notes: ["legacy mono synth"]),
        inst("es_p", "ES P", "Synthesizer", notes: ["legacy poly synth"]),
        inst("es1", "ES1", "Synthesizer"),
        inst("es2", "ES2", "Synthesizer"),
        inst("evoc_20_polysynth", "EVOC 20 PolySynth", "Synthesizer"),
        inst("external_instrument", "External Instrument", "Utility"),
        inst("playback", "Playback", "Utility", notes: ["availability varies by Logic version"]),
        inst("quick_sampler", "Quick Sampler", "Sampler"),
        inst("retro_synth", "Retro Synth", "Synthesizer"),
        inst("sample_alchemy", "Sample Alchemy", "Sampler"),
        inst("sampler", "Sampler", "Sampler"),
        inst("sculpture", "Sculpture", "Synthesizer"),
        inst("studio_bass", "Studio Bass", "Bass", notes: ["introduced in Logic Pro 11"]),
        inst("studio_horns", "Studio Horns", "Orchestral"),
        inst("studio_strings", "Studio Strings", "Orchestral"),
        inst("ultrabeat", "Ultrabeat", "Drums", notes: ["legacy drum synth"]),
        inst("vintage_b3", "Vintage B3", "Keyboards"),
        inst("vintage_clav", "Vintage Clav", "Keyboards"),
        inst("vintage_electric_piano", "Vintage Electric Piano", "Keyboards"),
        inst("vintage_mellotron", "Vintage Mellotron", "Keyboards"),
        // MIDI FX
        midiFX("arpeggiator", "Arpeggiator"),
        midiFX("chord_trigger", "Chord Trigger"),
        midiFX("modifier", "Modifier"),
        midiFX("modulator", "Modulator"),
        midiFX("note_repeater", "Note Repeater"),
        midiFX("randomizer", "Randomizer"),
        midiFX("scripter", "Scripter", notes: ["the MCP Scripter channel drives this plugin for parameter writes"]),
        midiFX("transposer", "Transposer"),
        midiFX("velocity_processor", "Velocity Processor"),
    ]

    static var seedCount: Int { seeds.count }

    // MARK: - Census overlay

    private static func buildEntry(seed: Seed, census: StockPluginCensus) -> StockPluginCatalogEntry {
        let resolution = resolve(seedID: seed.id, census: census)

        if resolution.state == .unavailable {
            return StockPluginCatalogEntry(
                id: seed.id,
                displayName: seed.name,
                type: seed.type,
                category: seed.category,
                availabilityState: .unavailable,
                provenance: resolution.provenance,
                insertPaths: [],
                slotSupport: StockPluginSlotSupport(audio: false, instrument: false, midiFX: false, aux: false),
                knownPresets: [],
                parameters: [],
                safeWriteCapabilities: .none,
                limitations: seed.notes + ["recorded as absent by the current census"]
            )
        }

        return StockPluginCatalogEntry(
            id: seed.id,
            displayName: seed.name,
            type: seed.type,
            category: seed.category,
            availabilityState: resolution.state,
            provenance: resolution.provenance,
            insertPaths: [
                StockPluginInsertPath(
                    path: seed.menu,
                    availabilityState: resolution.state,
                    provenance: resolution.provenance
                ),
            ],
            slotSupport: slotSupport(for: seed.type),
            knownPresets: resolution.presetNames,
            parameters: seed.parameters,
            safeWriteCapabilities: seed.write,
            limitations: seed.notes
        )
    }

    private static func slotSupport(for type: StockPluginType) -> StockPluginSlotSupport {
        switch type {
        case .effect, .utility, .metering:
            return StockPluginSlotSupport(audio: true, instrument: false, midiFX: false, aux: true, stereo: true, mono: true)
        case .instrument:
            return StockPluginSlotSupport(audio: false, instrument: true, midiFX: false, aux: false)
        case .midiEffect:
            return StockPluginSlotSupport(audio: false, instrument: false, midiFX: true, aux: false)
        }
    }

    private struct StateResolution {
        let state: StockPluginTruthState
        let provenance: StockPluginProvenance
        let presetNames: [String]
    }

    /// Truth-state precedence: contradiction beats confirmation, live evidence
    /// beats local metadata, local metadata beats static knowledge. A
    /// `readback_mismatch` therefore wins over `verified` — contradictory live
    /// evidence must never be silently upgraded (the conflict is also surfaced
    /// via `censusConflicts`). Only census-injected sets can produce
    /// `verified`, `observed`, `readback_mismatch`, or `unavailable`; the
    /// production probe alone never claims more than `manifested`.
    private static func resolve(seedID: String, census: StockPluginCensus) -> StateResolution {
        if census.readbackMismatchPluginIDs.contains(seedID) {
            return StateResolution(
                state: .readbackMismatch,
                provenance: .readbackMismatch(
                    observedAt: census.observedAt,
                    logicVersion: census.logicVersion,
                    locale: census.locale,
                    evidence: ["plugin_identity_readback_mismatch"]
                ),
                presetNames: []
            )
        }
        if census.verifiedPluginIDs.contains(seedID) {
            let presets = census.localManifests[seedID]?.presetNames ?? []
            var evidence = ["plugin_identity_readback"]
            if !presets.isEmpty { evidence.append("factory_preset_filenames") }
            return StateResolution(
                state: .verified,
                provenance: .verified(
                    source: "live_logic",
                    method: "ax_insert_readback",
                    observedAt: census.observedAt,
                    logicVersion: census.logicVersion,
                    locale: census.locale,
                    evidence: evidence
                ),
                presetNames: presets
            )
        }
        if census.observedPluginIDs.contains(seedID) {
            let presets = census.localManifests[seedID]?.presetNames ?? []
            var evidence = ["menu_item_observed"]
            if !presets.isEmpty { evidence.append("factory_preset_filenames") }
            return StateResolution(
                state: .observed,
                provenance: .observed(
                    method: "ax_menu_observation",
                    observedAt: census.observedAt,
                    logicVersion: census.logicVersion,
                    locale: census.locale,
                    evidence: evidence
                ),
                presetNames: presets
            )
        }
        if census.unavailablePluginIDs.contains(seedID) {
            return StateResolution(
                state: .unavailable,
                provenance: .unavailable(
                    method: "live_census_absence",
                    observedAt: census.observedAt,
                    logicVersion: census.logicVersion,
                    locale: census.locale,
                    evidence: ["absence_checked"]
                ),
                presetNames: []
            )
        }
        if let manifest = census.localManifests[seedID] {
            var evidence = ["factory_plugin_settings_folder"]
            if !manifest.presetNames.isEmpty {
                evidence.append("factory_preset_filenames")
            }
            return StateResolution(
                state: .manifested,
                provenance: .manifested(
                    sourcePath: manifest.sourcePath,
                    method: "factory_plugin_settings_probe",
                    observedAt: census.observedAt,
                    logicVersion: census.logicVersion,
                    locale: census.locale,
                    evidence: evidence
                ),
                presetNames: manifest.presetNames
            )
        }
        return StateResolution(
            state: .inferred,
            provenance: .inferred(reason: "documented Logic stock plugin identity; not verified on this machine in this response"),
            presetNames: []
        )
    }
}
