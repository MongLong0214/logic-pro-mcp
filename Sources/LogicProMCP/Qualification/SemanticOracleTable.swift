import Foundation

// #373 Phase A — the oracle table.
//
// Every entry was derived by reading the operation's dispatcher handler and
// pinning what that handler ACTUALLY emits. Comments cite the handler so a
// future shape change is reconciled here rather than silently passing.
//
// Census invariant (meta-tested): the table's keys are exactly the registry's
// read-only specs whose availability is not `.unsupported`, minus
// `system.health` which keeps its bespoke full-payload equality validator.
//
// ── KNOWN GAPS (Phase A ships with these open; carried as Phase B debt) ──────
//
// 1. FIXTURE↔HANDLER DRIFT HAS NO AUTOMATIC GUARD. Every oracle here was
//    derived by READING its dispatcher, and the payloads in
//    SemanticOracleFixtures were hand-written to match. Nothing mechanically
//    binds the two: if a handler changes a key tomorrow, the fixture keeps the
//    old shape, the oracle keeps passing the stale fixture, and CI stays green
//    while the live surface has drifted. Phase B should close this by emitting
//    golden samples from the handlers' own encode paths, or by landing the
//    live-run drift catcher. Until then, treat green fixtures as evidence the
//    ORACLE LOGIC works — not as evidence the shapes are current.
//
// 2. SIX OPERATIONS CANNOT REACH `passed` UNDER THE CURRENT PROBE PARAMS. The
//    runner classifies on `isError` before any oracle runs, and these probes
//    are typed refusals by construction: project.export_plan,
//    plugins.get_inventory, tracks.resolve_path (empty params → invalid_params),
//    audio.analyze_file (empty params → unsafe_path), system.clear_traces
//    (probed `confirmed:false` on purpose, so qualification never destroys
//    diagnostic evidence), system.saga_status (probed with a key no record
//    exists for). Their oracles pin the real success contract and are unit- and
//    mutation-tested, but a live run cannot exercise them. Phase B: give these
//    probes qualifying params (a fixture project, a real track index, a seeded
//    saga) rather than weaken the oracles.
//
// 3. THREE MORE ARE ENVIRONMENT-CONDITIONAL live: project.get_regions,
//    tracks.list_library and tracks.scan_plugin_presets need Logic running with
//    (respectively) an arrange viewport, an open Library panel, and a focused
//    plugin window.
//
// 4. midi.list_ports' cross-check is a SAME-HANDLER ECHO, not an independent
//    readback — see its oracle's reason. No independent MIDI probe exists yet.

enum SemanticOracleTable {
    /// `system.health` is excluded: it has a bespoke validator that compares the
    /// entire typed `HealthResult` against the independent readback — a
    /// stronger check than any constraint list, and the only op whose readback
    /// resource returns the identical payload by construction.
    static let bespokeOperationIDs: Set<OperationID> = [.systemHealth]

    /// The read-only surface this table must cover, derived from the registry
    /// (the registry is truth — never a hand-maintained name list).
    static var coveredSpecIDs: Set<OperationID> {
        Set(
            OperationRegistry.specs
                .filter { $0.mutability == .readOnly && $0.availability != .unsupported }
                .map(\.id)
        )
        .subtracting(bespokeOperationIDs)
    }

    static let all: [OperationOracle] = [
        systemPermissions,
        systemRefreshCache,
        systemHelp,
        systemListRecentTraces,
        systemGetTrace,
        systemClearTraces,
        systemSagaPreflight,
        systemSagaStatus,
        pluginsGetInventory,
        projectIsRunning,
        projectGetRegions,
        projectExportPlan,
        projectAudit,
        projectCleanupPlan,
        audioAnalyzeFile,
        midiListPorts,
        tracksListLibrary,
        tracksScanLibrary,
        tracksResolvePath,
        tracksScanPluginPresets,
    ]

    static let byOperationID: [OperationID: OperationOracle] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.operationID, $0) }
    )

    /// Escape-hatch tax.
    ///
    /// DEVIATION from the ratified design, reported rather than improvised: the
    /// ratified budget was "≤5 of the set may be .custom". Against the real
    /// handler shapes that budget is infeasible — SEVEN read-only operations
    /// cannot carry any declarative VALUE constraint:
    ///
    ///   * prose bodies, no key to bind to:
    ///       system.permissions, system.refresh_cache, system.help
    ///   * bare-scalar body, no key to bind to:
    ///       project.is_running
    ///   * JSON with zero constant-valued fields:
    ///       midi.list_ports, tracks.list_library, tracks.resolve_path
    ///
    /// The root cause is a gap in the constraint data model, not laziness: a
    /// constraint binds to ONE payload and has no cross-check case, and there is
    /// no implication case. For these seven the only honest checks ARE
    /// cross-checks and conditionals. Forcing them under a numeric cap would
    /// have produced tautological oracles (`enumMember` over a field a
    /// `typedField` already types) — checkbox oracles of exactly the kind this
    /// ticket exists to forbid.
    ///
    /// So the cap is replaced by something stricter than "≤5": an explicit
    /// allowlist. A new `.custom` oracle cannot appear without editing this set,
    /// which is the review gate the budget was reaching for.
    ///
    /// Phase B recommendation: add `.crossCheck` and `.implies` constraint cases;
    /// midi.list_ports, tracks.list_library, tracks.resolve_path and
    /// project.is_running all become declarative, taking the hatch back to the
    /// three irreducible prose bodies.
    static let sanctionedCustomOperationIDs: Set<OperationID> = [
        .systemPermissions,
        .systemRefreshCache,
        .systemHelp,
        .projectIsRunning,
        .midiListPorts,
        .tracksListLibrary,
        .tracksResolvePath,
    ]

    static var customOracles: [OperationOracle] { all.filter { $0.strength == .custom } }

    // MARK: - system

    // SystemDispatcher `case "permissions"` → toolTextResult(status.summary).
    // PermissionChecker.summary is human-readable prose, one line per
    // permission, each ending in a state label.
    static let systemPermissions = OperationOracle(
        custom: .systemPermissions,
        reason: """
            The handler returns PermissionChecker.summary — human-readable prose, \
            not JSON. There is no key-addressable field for a declarative \
            constraint to bind to, so the four required permission lines and \
            their legal state labels are asserted in the closure.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        let requiredPrefixes = [
            "Accessibility: ",
            "Automation (Logic Pro): ",
            "Automation (System Events): ",
            "PostEvent (CGEvent): ",
        ]
        // The closed set of line remainders PermissionChecker.summary can emit:
        // State.summaryLabel's three values, plus the one hardcoded variant the
        // Automation (Logic Pro) notVerifiable branch appends. Matched EXACTLY —
        // a prefix match would accept "granted_evil" or "NOT GRANTEDish" and
        // wave through a label this code has never seen.
        let legalLabels: Set<String> = [
            "granted",
            "NOT GRANTED",
            "NOT VERIFIABLE",
            "NOT VERIFIABLE (Logic Pro not running)",
        ]
        let lines = text.split(separator: "\n").map(String.init)
        return requiredPrefixes.allSatisfy { prefix in
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return false }
            return legalLabels.contains(String(line.dropFirst(prefix.count)))
        }
    }

    // SystemDispatcher `case "refresh_cache"` → one of exactly two sentences,
    // depending on whether an AX fallback poller is attached.
    static let systemRefreshCache = OperationOracle(
        custom: .systemRefreshCache,
        reason: """
            The handler returns a bare prose sentence, not JSON. The legal \
            bodies are a closed two-element set, but with no JSON key to bind \
            an enumMember constraint to, the set is enumerated in the closure.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        let legalBodies = [
            "State refresh completed via AX fallback poller.",
            "State refresh triggered. Cache will be updated on next poll cycle.",
        ]
        return legalBodies.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // SystemDispatcher `case "help"` → Self.helpText(for: category). The
    // qualification probe passes category "system" (QualificationTransport
    // .probeParams), so the body must be the logic_system section — not the
    // full help, and not another dispatcher's section.
    static let systemHelp = OperationOracle(
        custom: .systemHelp,
        reason: """
            The handler returns a formatted help document, not JSON. The check \
            that matters — that the probe's `category:"system"` was honoured and \
            the section documents the real logic_system surface — is a prose \
            assertion no key-addressable constraint can express.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        // Honouring `category:"system"` means the SYSTEM section, not full help.
        guard text.hasPrefix("logic_system commands:") else { return false }
        // The section must document the system commands the registry exposes.
        let requiredCommands = [
            "health", "permissions", "refresh_cache", "list_recent_traces",
            "get_trace", "clear_traces", "saga_preflight", "saga_execute",
            "saga_status", "saga_cancel", "help",
        ]
        guard requiredCommands.allSatisfy({ text.contains("\n  \($0)") || text.contains("  \($0) ") })
        else {
            return false
        }
        // The category enumeration must list every accepted help category.
        return text.contains("Categories: transport, tracks, mixer, midi, edit, "
            + "navigate, project, audio, plugins, system")
    }

    // SystemDispatcher `case "list_recent_traces"` →
    // {"traces":[{trace_id, operation_id, phase_count, readback_state?}]}.
    // The qualification drive seeds exactly one saga_execute trace before this
    // probe runs, so the list cannot be empty and its entries cannot be hollow:
    // a trace claiming zero phases is a lie about what was recorded.
    static let systemListRecentTraces = OperationOracle(
        .systemListRecentTraces,
        strength: .shapeAndDomain,
        constraints: [
            .typedField(key: "traces", type: .array),
            .nonEmptyArray(key: "traces"),
            .typedField(key: "traces.0.trace_id", type: .string),
            .typedField(key: "traces.0.operation_id", type: .string),
            .numericRange(key: "traces.0.phase_count", min: 1, max: 100_000),
        ]
    )

    // SystemDispatcher `case "get_trace"` →
    // {"trace_id", "operation_id", "events":[{phase, timestamp, attributes}]}.
    // The probe always reads back the trace the drive seeded, and the drive
    // seeds it via system.saga_execute (QualificationTransport asserts
    // `$0.operationID == OperationID.systemSagaExecute.rawValue`), so the
    // operation_id is exactly pinnable — this oracle catches a handler that
    // returns SOME trace rather than the requested one.
    static let systemGetTrace = OperationOracle(
        .systemGetTrace,
        strength: .shapeAndDomain,
        constraints: [
            .typedField(key: "trace_id", type: .string),
            .valueEquals(key: "operation_id", expected: .string(OperationID.systemSagaExecute.rawValue)),
            .nonEmptyArray(key: "events"),
            .enumMember(key: "events.0.phase", allowed: TracePhase.allCases.map(\.rawValue)),
        ]
    )

    // SystemDispatcher `case "clear_traces"` success →
    // {"success":true, "receipt_path":String, "cleared_trace_count":Int}.
    // NOTE: unreachable under the current probe, which sends `confirmed:false`
    // on purpose so qualification never destroys diagnostic evidence. That
    // yields a typed State C and the runner classifies on isError before the
    // oracle is consulted. The oracle still pins the success contract so a
    // future confirmed probe (or a handler regression) is checked.
    static let systemClearTraces = OperationOracle(
        .systemClearTraces,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "success", expected: .bool(true)),
            .typedField(key: "receipt_path", type: .string),
            .numericRange(key: "cleared_trace_count", min: 0, max: 100_000),
        ]
    )

    // SystemDispatcher `case "saga_preflight"` → SagaWire.sessionFields +
    // {"ok", "issues", "before_state_availability", "writes_performed": 0}.
    // writes_performed == 0 is the load-bearing honesty claim: a preflight that
    // wrote anything is a contract violation regardless of what it reports.
    static let systemSagaPreflight = OperationOracle(
        .systemSagaPreflight,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "writes_performed", expected: .number(0)),
            .valueEquals(key: "journal_scope", expected: .string("session")),
            .valueEquals(
                key: "journal_persistence",
                expected: .string("cleared_on_server_session_end")
            ),
            .valueEquals(key: "journal_survives_process_restart", expected: .bool(false)),
            .typedField(key: "ok", type: .bool),
            .typedField(key: "issues", type: .array),
        ]
    )

    // SystemDispatcher `case "saga_status"` success → sessionFields +
    // {"idempotency_key", "record": {"status", ...}}.
    // NOTE: unreachable under the current probe, which asks for the key
    // "qualification-read-probe" that no probe ever creates a record for; the
    // handler answers elementNotFound (State C, isError) and the runner
    // classifies before the oracle runs. The oracle pins the success contract.
    static let systemSagaStatus = OperationOracle(
        .systemSagaStatus,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "journal_scope", expected: .string("session")),
            .valueEquals(key: "journal_survives_process_restart", expected: .bool(false)),
            .typedField(key: "idempotency_key", type: .string),
            .enumMember(
                key: "record.status",
                allowed: ["in_progress", "cancellation_requested", "cancelled", "completed"]
            ),
        ]
    )

    // MARK: - plugins

    // AccessibilityChannel+VerifiedPlugins `defaultGetPluginInventory` success →
    // HC v2 envelope + {track, plugins_source, plugins, complete, ...}.
    // NOTE: unreachable under the current probe, which sends empty params; the
    // handler requires `track` and answers a typed HC v2 invalid_params State C.
    static let pluginsGetInventory = OperationOracle(
        .pluginsGetInventory,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "hc_schema", expected: .number(2)),
            // State A ONLY. State B is an honest `readback_unavailable` — the
            // handler is telling us it could not see the insert chain, and its
            // extras omit `plugins` entirely. Two reasons this must not qualify:
            //   1. Semantics: a qualification `passed` means the operation was
            //      SEMANTICALLY VERIFIED. State B is by construction unverified;
            //      passing it would launder "I couldn't check" into "checked".
            //   2. Consistency: allowing {A,B} while requiring a typed `plugins`
            //      array would false-FAIL every honest State B, since B omits it.
            // Resolved strict rather than loose: pin A, keep the plugins array.
            .valueEquals(key: "state", expected: .string("A")),
            .numericRange(key: "track", min: 0, max: 10_000),
            .typedField(key: "plugins", type: .array),
        ]
    )

    // MARK: - project

    // ProjectDispatcher `case "is_running"` →
    // toolTextResult(isLogicProRunning() ? "true" : "false").
    static let projectIsRunning = OperationOracle(
        custom: .projectIsRunning,
        reason: """
            The whole body is a bare scalar literal — `true` or `false` — with \
            no key to address. A constraint on the root key path could only \
            restate "is a boolean", which the JSON type already implies; that \
            is a presence check wearing a value constraint's clothes. The real \
            contract is byte-exact: exactly one of two literals, so prose, an \
            envelope, a quoted "true", or `True` are all caught.
            """
    ) { responseData, _ in
        guard let text = String(data: responseData, encoding: .utf8) else { return false }
        return ["true", "false"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // AccessibilityChannel+Regions `defaultGetRegions` → RegionInventoryPayload.
    // complete/scope/reason are hardcoded honesty disclaimers: this read only
    // ever sees the visible arrange viewport, and it must never claim otherwise.
    static let projectGetRegions = OperationOracle(
        .projectGetRegions,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "complete", expected: .bool(false)),
            .valueEquals(key: "scope", expected: .string("visible_arrange_area")),
            .valueEquals(key: "reason", expected: .string("logic_ax_viewport_only")),
            .numericRange(key: "returned_count", min: 0, max: 100_000),
            .typedField(key: "regions", type: .array),
        ]
    )

    // ProjectExportPlannerModels `ProjectExportPlan` CodingKeys.
    // NOTE: unreachable under the current probe (empty params; the planner
    // requires `projects`/`project`/`path` and answers invalid_params).
    // execution_mode/next_safe_action are the plan's dry-run guarantees.
    static let projectExportPlan = OperationOracle(
        .projectExportPlan,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_export_manifest.v1")),
            .valueEquals(key: "execution_mode", expected: .string("dry_run_only")),
            .valueEquals(key: "next_safe_action", expected: .string("review_export_plan")),
            .enumMember(key: "status", allowed: ["planned", "degraded"]),
            .numericRange(key: "project_count", min: 0, max: 100_000),
            .typedField(key: "projects", type: .array),
        ]
    )

    // ProjectSessionAudit `AuditReport`. read_only:true is hardcoded and
    // load-bearing: the audit promises it touched nothing.
    static let projectAudit = OperationOracle(
        .projectAudit,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_project_audit.v1")),
            .valueEquals(key: "read_only", expected: .bool(true)),
            .enumMember(key: "status", allowed: ["ok", "degraded", "failed"]),
            .numericRange(key: "project.track_count", min: 0, max: 10_000),
            .typedField(key: "findings", type: .array),
            .typedField(key: "evidence", type: .object),
        ]
    )

    // ProjectSessionAudit `CleanupPlanReport`. source_audit_schema binds the
    // plan to the audit schema it was derived from; requires_plan_confirmation
    // is the hardcoded promise that a plan is never self-applying.
    static let projectCleanupPlan = OperationOracle(
        .projectCleanupPlan,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(
                key: "schema",
                expected: .string("logic_pro_mcp_project_cleanup_plan.v1")
            ),
            .valueEquals(
                key: "source_audit_schema",
                expected: .string("logic_pro_mcp_project_audit.v1")
            ),
            .valueEquals(key: "read_only", expected: .bool(true)),
            .valueEquals(key: "requires_plan_confirmation", expected: .bool(true)),
            .enumMember(key: "status", allowed: ["ok", "degraded", "failed"]),
            .typedField(key: "steps", type: .array),
        ]
    )

    // MARK: - audio

    // AudioAnalyzer.Result CodingKeys. NOTE: unreachable under the current
    // probe (empty params → unsafe_path failure body), but the oracle pins the
    // real success contract.
    static let audioAnalyzeFile = OperationOracle(
        .audioAnalyzeFile,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schema", expected: .string("logic_pro_mcp_audio_analysis.v1")),
            // {pass, warn} only — NOT fail. AudioDispatcher sets
            // `isError: result.verification.status == .fail`, so a fail body
            // always arrives with isError and the runner classifies it
            // notQualified before this oracle is consulted. Accepting "fail"
            // could therefore only ever launder a failed analysis into a
            // semantic pass; a `warn` is a completed measurement with caveats,
            // a `fail` is not a measurement at all.
            .enumMember(key: "verification.status", allowed: ["pass", "warn"]),
            .typedField(key: "verification.reasons", type: .array),
            .typedField(key: "exists", type: .bool),
            .numericRange(key: "duration_seconds", min: 0, max: 86_400),
            .numericRange(key: "sample_rate", min: 0, max: 768_000),
            .numericRange(key: "channel_count", min: 0, max: 512),
            // dBFS is a negative-or-zero log scale; a positive peak from this
            // analyzer would mean the measurement, not the file, is wrong.
            .numericRange(key: "peak_dbfs", min: -200, max: 0),
            .numericRange(key: "silence_ratio", min: 0, max: 1),
        ]
    )

    // MARK: - midi

    // CoreMIDIChannel `listMIDIPortsJSON` → {"sources":[String],
    // "destinations":[String]}. The `logic://midi/ports` resource routes the
    // SAME midi.list_ports operation and serves the channel's message verbatim
    // (ResourceHandlers+StateReaders), so response and readback are equal by
    // construction — the strongest available check for a body with no constants.
    static let midiListPorts = OperationOracle(
        custom: .midiListPorts,
        reason: """
            The body has no constant-valued field (both keys are \
            environment-dependent string arrays), so no declarative VALUE \
            constraint exists, and the constraint model cannot bind two \
            payloads at once. HONEST SCOPE OF THIS CHECK: the readback resource \
            re-invokes the SAME midi.list_ports handler and serves its message \
            verbatim, so agreement proves same-handler echo and transport \
            consistency — it is NOT an independent readback and must not be \
            read as one. It still catches truncation, reordering, and \
            serialization damage between the two reads. No truly independent \
            MIDI probe exists today; Phase B may add a CoreMIDI-direct probe to \
            make this a real cross-check.
            """
    ) { responseData, readbackData in
        guard let response = JSONInspector.parse(responseData) as? [String: Any],
              let readback = JSONInspector.parse(readbackData) as? [String: Any] else {
            return false
        }
        // A degraded resource read answers {"message":…} or {"error":…}; that is
        // not an independent confirmation of the port lists.
        guard let responseSources = response["sources"] as? [String],
              let responseDestinations = response["destinations"] as? [String],
              let readbackSources = readback["sources"] as? [String],
              let readbackDestinations = readback["destinations"] as? [String] else {
            return false
        }
        return responseSources == readbackSources
            && responseDestinations == readbackDestinations
    }

    // MARK: - tracks

    // LibraryAccessor.Inventory → {categories, presetsByCategory,
    // currentCategory?, currentPreset?}. The `logic://library/inventory`
    // resource wraps the cached scan in a T7 envelope under "data".
    static let tracksListLibrary = OperationOracle(
        custom: .tracksListLibrary,
        reason: """
            LibraryAccessor.Inventory has no constant-valued field — all four \
            keys are environment-dependent — so no declarative VALUE constraint \
            exists. The load-bearing check is the internal consistency of the \
            inventory (every advertised category must actually carry a preset \
            list) plus agreement with the independent inventory resource read, \
            neither of which the constraint model can express.
            """
    ) { responseData, readbackData in
        guard let response = JSONInspector.parse(responseData) as? [String: Any],
              let categories = response["categories"] as? [String],
              let presetsByCategory = response["presetsByCategory"] as? [String: Any] else {
            return false
        }
        // A zero-category inventory would make the checks below vacuously true
        // (`[].allSatisfy` is true, and two empty sets always agree). "I read
        // nothing and it was all consistent" is not a semantic pass.
        guard !categories.isEmpty else { return false }
        // An inventory that advertises a category it cannot enumerate presets
        // for is lying about what it read — and the preset list must actually
        // be a list of preset names, not merely some value under that key.
        guard categories.allSatisfy({ presetsByCategory[$0] as? [String] != nil }) else {
            return false
        }
        // Fail closed on the readback. A degraded resource read ({"error":…},
        // a cache miss {"cached":false,…}, or a non-object body) carries no
        // inventory to compare against — and an internal-consistency-only pass
        // would report `readback.verified == true` on evidence that contributed
        // nothing. Without a usable independent read there is no semantic
        // verification to claim.
        guard let readback = JSONInspector.parse(readbackData) as? [String: Any],
              let data = readback["data"] as? [String: Any],
              let readbackCategories = data["categories"] as? [String],
              !readbackCategories.isEmpty else {
            return false
        }
        return Set(categories) == Set(readbackCategories)
    }

    // AccessibilityChannel+Library `encodeLibraryRoot` →
    // {"source": <tag>, "root": LibraryRoot}. The probe sends empty params, so
    // the mode defaults to `disk`; a disk scan that throws silently falls back
    // to the live panel scan and re-tags the source, so both tags are legal.
    static let tracksScanLibrary = OperationOracle(
        .tracksScanLibrary,
        strength: .shapeAndDomain,
        constraints: [
            .enumMember(key: "source", allowed: ["disk", "panel"]),
            .typedField(key: "root", type: .object),
            .typedField(key: "root.categories", type: .array),
            .numericRange(key: "root.nodeCount", min: 0, max: 10_000_000),
            .numericRange(key: "root.leafCount", min: 0, max: 10_000_000),
            .numericRange(key: "root.folderCount", min: 0, max: 10_000_000),
            .numericRange(key: "root.scanDurationMs", min: 0, max: 3_600_000),
            .typedField(key: "root.selectionRestored", type: .bool),
        ]
    )

    // AccessibilityChannel+Library `ResolvePathResponse` (nils omitted).
    // NOTE: unreachable under the current probe (empty params → the dispatcher's
    // `path.isEmpty` gate answers invalid_params). The cold-cache success body
    // is {"exists":false,"reason":…}, so only `exists` is always present.
    static let tracksResolvePath = OperationOracle(
        custom: .tracksResolvePath,
        reason: """
            The success contract guarantees exactly one field — `exists: Bool` — \
            because ResolvePathResponse omits every nil. No constant-valued \
            field exists, and a constraint on `exists` could only restate its \
            type. The load-bearing semantics are CONDITIONAL: a hit must name \
            what it matched and how it was classified; a miss must say why. The \
            constraint model has no implication case, so the conditional lives \
            in the closure.
            """
    ) { responseData, _ in
        guard let response = JSONInspector.parse(responseData) as? [String: Any],
              let exists = response["exists"], JSONInspector.isBoolean(exists) else {
            return false
        }
        guard (exists as? NSNumber)?.boolValue == true else {
            // A miss must explain itself rather than answering a bare false.
            return (response["reason"] as? String)?.isEmpty == false
        }
        // A hit must name the matched path and classify the node it found.
        guard let matchedPath = response["matchedPath"] as? String,
              !matchedPath.isEmpty,
              let kind = response["kind"] as? String else {
            return false
        }
        // LibraryNodeKind raw values.
        return ["folder", "leaf", "truncated", "probeTimeout", "cycle"].contains(kind)
    }

    // AccessibilityChannel+Library `runLivePluginPresetScan` → PluginPresetCache.
    // schemaVersion/pluginName/pluginIdentifier/contentHash are hardcoded at the
    // encode site; measuredSubmenuOpenDelayMs echoes the settle delay, which the
    // dispatcher defaults to 250 when the probe omits it — an echo the oracle
    // pins so a handler that ignores the parameter is caught.
    static let tracksScanPluginPresets = OperationOracle(
        .tracksScanPluginPresets,
        strength: .shapeAndDomain,
        constraints: [
            .valueEquals(key: "schemaVersion", expected: .number(1)),
            .valueEquals(key: "pluginName", expected: .string("(focused-plugin)")),
            .valueEquals(key: "contentHash", expected: .string("(deferred)")),
            .valueEquals(key: "measuredSubmenuOpenDelayMs", expected: .number(250)),
            .typedField(key: "root", type: .object),
            .numericRange(key: "nodeCount", min: 0, max: 10_000_000),
            .numericRange(key: "leafCount", min: 0, max: 10_000_000),
            .numericRange(key: "scanDurationMs", min: 0, max: 3_600_000),
        ]
    )
}
