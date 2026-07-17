import Foundation
@testable import LogicProMCP

// #373 Phase A — realistic per-operation payloads.
//
// Each entry is a faithful sample of what the operation's dispatcher actually
// emits (shapes read from the handlers, not invented). One source of truth,
// used three ways:
//   1. happy-path assertions — the oracle passes a realistic payload;
//   2. the mutation harness — every constraint is corrupted and must fail;
//   3. QualificationRunnerTests' canned drive responses, so the runner's
//      classification counts are exercised against the same shapes.
//
// `customMutants` carries hand-written corruptions for `.custom` oracles, whose
// checks the generic mutator cannot derive from a constraint list.

/// What a hand-written corruption is meant to prove. Counting mutants is
/// gameable — four garbage strings would "cover" an oracle while proving only
/// that it rejects garbage. The harness requires each KIND, so every custom
/// oracle must demonstrate it rejects a payload that parses perfectly well and
/// is merely WRONG.
enum CustomMutantKind: String, CaseIterable {
    /// Unparseable or structurally absent — proves the oracle rejects noise.
    case malformed
    /// Parses fine, well-formed, violates a load-bearing semantic clause.
    case wellFormedButWrong
    /// Response is fine; the readback disagrees with it. Only meaningful for
    /// oracles that actually compare the two payloads.
    case readbackDivergence
}

struct CustomMutant {
    let kind: CustomMutantKind
    let response: String
    /// Replaces the fixture readback — required for `.readbackDivergence`.
    let readbackOverride: String?

    init(_ kind: CustomMutantKind, _ response: String, readbackOverride: String? = nil) {
        self.kind = kind
        self.response = response
        self.readbackOverride = readbackOverride
    }
}

struct SemanticOracleFixture {
    let response: String
    let readback: String
    /// Corruptions that MUST make the oracle fail. Only required for `.custom`
    /// oracles; declarative oracles are mutated generically from constraints.
    let customMutants: [CustomMutant]

    init(response: String, readback: String, customMutants: [CustomMutant] = []) {
        self.response = response
        self.readback = readback
        self.customMutants = customMutants
    }

    var responseData: Data { Data(response.utf8) }
    var readbackData: Data { Data(readback.utf8) }
}

enum SemanticOracleFixtures {
    static let health = """
        {"logic_pro_running":true,"logic_pro_version":"11.2",\
        "logic_pro_bundle_id":"com.apple.logic10","logic_pro_variant":"desktop",\
        "logic_pro_ui_locale":"en-US","process_metadata_resolved":true,\
        "logic_pro_variants":[]}
        """

    static let operationsCatalog = """
        {"schema_version":1,"generated_at":"1970-01-01T00:16:40Z",\
        "operation_count":1,"operations":[]}
        """

    static let seededTraceID = "lpmcp_00000000-0000-0000-0000-000000000000"

    static let systemHelpText = """
        logic_system commands:
          health            -> {} — Channel status + cache info
          permissions       -> {} — macOS permission status
          refresh_cache     -> {} — Force AX re-poll
          export_support_bundle -> { dir?: String } — Write privacy-safe local diagnostics
          list_recent_traces -> { limit?: Int } — List recent in-process operation traces
          get_trace         -> { trace_id: String } — Read one in-process operation trace
          clear_traces      -> { confirmed: Bool } — Clear diagnostic evidence
          saga_preflight    -> { steps: [step], idempotency_key: String } — writes 0
          saga_execute      -> { steps: [step], idempotency_key: String } — Execute ordered steps
          saga_status       -> { idempotency_key: String } — Read the session journal
          saga_cancel       -> { idempotency_key: String } — Request cancellation
          help              -> { category: String } — Param docs per category

        Categories: transport, tracks, mixer, midi, edit, navigate, project, audio, plugins, system

        Read health via resource: logic://system/health
        """

    static let byOperationID: [OperationID: SemanticOracleFixture] = [
        .systemPermissions: SemanticOracleFixture(
            response: """
                Accessibility: granted
                Automation (Logic Pro): granted
                Automation (System Events): granted
                PostEvent (CGEvent): granted
                """,
            readback: health,
            customMutants: [
                .init(.malformed, ""),
                .init(.malformed, "{\"state\":\"A\",\"permissions\":[]}"),
                // A permission line silently dropped — reads as a normal
                // summary, but System Events is unaccounted for.
                .init(.wellFormedButWrong, """
                    Accessibility: granted
                    Automation (Logic Pro): granted
                    PostEvent (CGEvent): granted
                    """),
                // A label outside the closed state set.
                .init(.wellFormedButWrong, """
                    Accessibility: probably fine
                    Automation (Logic Pro): granted
                    Automation (System Events): granted
                    PostEvent (CGEvent): granted
                    """),
                // FIX-5 regression guard: a prefix match would have accepted
                // this "granted"-prefixed impostor label.
                .init(.wellFormedButWrong, """
                    Accessibility: granted_evil
                    Automation (Logic Pro): granted
                    Automation (System Events): granted
                    PostEvent (CGEvent): granted
                    """),
            ]
        ),
        .systemRefreshCache: SemanticOracleFixture(
            response: "State refresh completed via AX fallback poller.",
            readback: health,
            customMutants: [
                .init(.malformed, ""),
                .init(.malformed, "{\"state\":\"A\"}"),
                // Plausible prose that is not one of the two legal sentences.
                .init(.wellFormedButWrong, "State refresh maybe happened."),
                // One character short of the real sentence.
                .init(.wellFormedButWrong, "State refresh completed via AX fallback poller"),
            ]
        ),
        .systemHelp: SemanticOracleFixture(
            response: systemHelpText,
            readback: operationsCatalog,
            customMutants: [
                .init(.malformed, ""),
                // Wrong category section — the probe asked for "system", so
                // this is a real help document that ignored the parameter.
                .init(.wellFormedButWrong, "logic_transport commands:\n  play -> {}"),
                // A documented command silently dropped from the section.
                .init(.wellFormedButWrong, systemHelpText.replacingOccurrences(
                    of: "  saga_status       -> { idempotency_key: String } — Read the session journal\n",
                    with: ""
                )),
                // The category enumeration drifted out of lockstep.
                .init(.wellFormedButWrong, systemHelpText.replacingOccurrences(
                    of: "Categories: transport, tracks, mixer, midi, edit, navigate, project, audio, plugins, system",
                    with: "Categories: transport, tracks"
                )),
            ]
        ),
        .systemListRecentTraces: SemanticOracleFixture(
            response: """
                {"traces":[{"trace_id":"\(seededTraceID)",\
                "operation_id":"system.saga_execute","phase_count":2,\
                "readback_state":"C"}]}
                """,
            readback: operationsCatalog
        ),
        .systemGetTrace: SemanticOracleFixture(
            response: """
                {"trace_id":"\(seededTraceID)","operation_id":"system.saga_execute",\
                "events":[{"phase":"request.received","timestamp":"0.0","attributes":{}},\
                {"phase":"result.emitted","timestamp":"1.0","attributes":{}}]}
                """,
            readback: operationsCatalog
        ),
        .systemClearTraces: SemanticOracleFixture(
            response: """
                {"success":true,"receipt_path":"/tmp/logic-pro-mcp/trace-receipt.jsonl",\
                "cleared_trace_count":3}
                """,
            readback: operationsCatalog
        ),
        .systemSagaPreflight: SemanticOracleFixture(
            response: """
                {"journal_scope":"session",\
                "journal_persistence":"cleared_on_server_session_end",\
                "journal_survives_process_restart":false,"ok":true,"issues":[],\
                "before_state_availability":[],"writes_performed":0}
                """,
            readback: health
        ),
        .systemSagaStatus: SemanticOracleFixture(
            response: """
                {"journal_scope":"session",\
                "journal_persistence":"cleared_on_server_session_end",\
                "journal_survives_process_restart":false,\
                "idempotency_key":"qualification-read-probe",\
                "record":{"status":"completed","outcome":{"state":"A"}}}
                """,
            readback: health
        ),
        .pluginsGetInventory: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","hc_schema":2,\
                "operation":"logic_plugins.get_inventory","track":0,\
                "plugins_source":"ax","plugins_fetched_at":"1970-01-01T00:00:00Z",\
                "plugins_unknown_reason":null,"mixer_reveal_attempted":false,\
                "mixer_reveal_strategies":[],"complete":true,"plugins":[]}
                """,
            readback: "{\"channel_strips\":[]}"
        ),
        .projectIsRunning: SemanticOracleFixture(
            response: "true",
            readback: "{\"cache_age_sec\":1.0,\"fetched_at\":null,\"ax_occluded\":false,"
                + "\"source\":\"ax_live\",\"data\":{\"name\":\"Untitled\",\"trackCount\":0}}",
            customMutants: [
                .init(.malformed, ""),
                .init(.malformed, "yes"),
                // Parses as JSON, but a quoted string is not a boolean literal.
                .init(.wellFormedButWrong, "\"true\""),
                // Parses as JSON, but the contract is a bare scalar, not an
                // envelope — a client reading this gets a truthy object either way.
                .init(.wellFormedButWrong, "{\"running\":true}"),
                .init(.wellFormedButWrong, "True"),
            ]
        ),
        .projectGetRegions: SemanticOracleFixture(
            response: """
                {"regions":[{"name":"Audio 1","trackIndex":0,"startBar":1,"endBar":5,\
                "kind":"audio","rawHelp":null}],"complete":false,\
                "scope":"visible_arrange_area","reason":"logic_ax_viewport_only",\
                "returned_count":1,"_debug":{"layoutItems":1,"nonRegion":0}}
                """,
            readback: "{\"cache_age_sec\":1.0,\"fetched_at\":null,\"ax_occluded\":false,"
                + "\"source\":\"ax_live\",\"data\":[]}"
        ),
        .projectExportPlan: SemanticOracleFixture(
            response: """
                {"schema":"logic_pro_mcp_export_manifest.v1","run_id":"run-1",\
                "generated_at":"1970-01-01T00:00:00Z","status":"planned",\
                "execution_mode":"dry_run_only","output_root":"/tmp/exports",\
                "collision_policy":"suffix","naming_policy":"project_name",\
                "project_count":1,"projects":[{"path":"/tmp/a.logicx"}],\
                "required_confirmations":[],"unsupported_or_blocked_steps":[],\
                "baseline_verification":[],"enhancement_path":[],\
                "next_safe_action":"review_export_plan"}
                """,
            readback: "{\"cache_age_sec\":null,\"fetched_at\":null,\"ax_occluded\":false,"
                + "\"source\":\"default\",\"data\":{\"name\":\"Untitled\",\"trackCount\":0}}"
        ),
        .projectAudit: SemanticOracleFixture(
            response: """
                {"schema":"logic_pro_mcp_project_audit.v1","status":"ok",\
                "generated_at":"1970-01-01T00:00:00Z","read_only":true,\
                "project":{"name":"Untitled","sample_rate":48000,"tempo":120,\
                "time_signature":"4/4","track_count":3,"provenance":"ax_live"},\
                "evidence":{"has_document":true,"ax_occluded":false},\
                "findings":[],"cleanup_plan":[]}
                """,
            readback: """
                {"schema":"logic_pro_mcp_project_audit.v1","status":"ok",\
                "generated_at":"1970-01-01T00:00:00Z","read_only":true,\
                "project":{"name":"Untitled","sample_rate":48000,"tempo":120,\
                "time_signature":"4/4","track_count":3,"provenance":"ax_live"},\
                "evidence":{"has_document":true,"ax_occluded":false},\
                "findings":[],"cleanup_plan":[]}
                """
        ),
        .projectCleanupPlan: SemanticOracleFixture(
            response: """
                {"schema":"logic_pro_mcp_project_cleanup_plan.v1",\
                "source_audit_schema":"logic_pro_mcp_project_audit.v1","status":"ok",\
                "generated_at":"1970-01-01T00:00:00Z","read_only":true,\
                "requires_plan_confirmation":true,"steps":[]}
                """,
            readback: """
                {"schema":"logic_pro_mcp_project_cleanup_plan.v1",\
                "source_audit_schema":"logic_pro_mcp_project_audit.v1","status":"ok",\
                "generated_at":"1970-01-01T00:00:00Z","read_only":true,\
                "requires_plan_confirmation":true,"steps":[]}
                """
        ),
        // A successful analysis of a real bounce. NOT the empty-params probe
        // body: that one is `verification.status:"fail"`, and AudioDispatcher
        // sets `isError: status == .fail`, so a fail body can never reach this
        // oracle with isError:false. Pairing a fail body with a qualifying
        // (isError:false) drive would have modelled a state the handler cannot
        // produce — the fixture now models the success the oracle exists to pin.
        .audioAnalyzeFile: SemanticOracleFixture(
            response: """
                {"schema":"logic_pro_mcp_audio_analysis.v1",\
                "path":"/Users/qualification/bounce.wav","exists":true,\
                "format":"wav","duration_seconds":12.5,"sample_rate":48000,\
                "channel_count":2,"frame_count":600000,"file_size_bytes":2400044,\
                "rms_dbfs":-18.2,"peak_dbfs":-1.0,"true_peak_dbfs":-0.9,\
                "loudness_estimate_lufs":-14.2,"loudness_method":"rms_estimate",\
                "silence_ratio":0.02,"non_silent_duration_seconds":12.25,\
                "spectral_centroid_hz":2200.0,\
                "frequency_peaks":[{"frequencyHz":440.0,"magnitude":0.8}],\
                "verification":{"status":"pass","reasons":[]}}
                """,
            readback: health
        ),
        .midiListPorts: SemanticOracleFixture(
            response: """
                {"sources":["IAC Driver Bus 1","Logic Pro Virtual In"],\
                "destinations":["IAC Driver Bus 1"]}
                """,
            readback: """
                {"sources":["IAC Driver Bus 1","Logic Pro Virtual In"],\
                "destinations":["IAC Driver Bus 1"]}
                """,
            customMutants: [
                .init(.malformed, "not json"),
                // Well-formed JSON object, but the contract's keys are absent.
                .init(.wellFormedButWrong, "{\"destinations\":[\"IAC Driver Bus 1\"]}"),
                .init(.wellFormedButWrong, "{\"ports\":[\"IAC Driver Bus 1\"]}"),
                // A truncated port list — the exact damage this echo check
                // exists to catch.
                .init(
                    .readbackDivergence,
                    "{\"sources\":[\"IAC Driver Bus 1\"],\"destinations\":[\"IAC Driver Bus 1\"]}"
                ),
                // Ordering is part of the identity: the resource serves the same
                // handler's bytes, so a reorder means something transformed them.
                .init(
                    .readbackDivergence,
                    "{\"sources\":[\"Logic Pro Virtual In\",\"IAC Driver Bus 1\"],"
                        + "\"destinations\":[\"IAC Driver Bus 1\"]}"
                ),
                // Response is fine; the readback is a degraded resource body.
                .init(
                    .readbackDivergence,
                    """
                    {"sources":["IAC Driver Bus 1","Logic Pro Virtual In"],\
                    "destinations":["IAC Driver Bus 1"]}
                    """,
                    readbackOverride: "{\"error\":\"CoreMIDI client not initialized\"}"
                ),
            ]
        ),
        .tracksListLibrary: SemanticOracleFixture(
            response: """
                {"categories":["Bass","Drum Kit"],\
                "presetsByCategory":{"Bass":["Deep Sub"],"Drum Kit":["SoCal"]},\
                "currentCategory":"Bass","currentPreset":"Deep Sub"}
                """,
            readback: """
                {"cache_age_sec":12.0,"fetched_at":"1970-01-01T00:00:00Z",\
                "ax_occluded":false,"data":{"categories":["Bass","Drum Kit"],\
                "presetsByCategory":{"Bass":["Deep Sub"],"Drum Kit":["SoCal"]},\
                "source":"ax"}}
                """,
            customMutants: [
                .init(.malformed, "not json"),
                // Advertises a category it cannot enumerate presets for.
                .init(
                    .wellFormedButWrong,
                    "{\"categories\":[\"Bass\",\"Ghost\"],\"presetsByCategory\":"
                        + "{\"Bass\":[\"Deep Sub\"]},\"currentCategory\":\"Bass\"}"
                ),
                // presetsByCategory carries the key, but not a preset LIST.
                .init(
                    .wellFormedButWrong,
                    "{\"categories\":[\"Bass\"],\"presetsByCategory\":"
                        + "{\"Bass\":\"Deep Sub\"},\"currentCategory\":\"Bass\"}"
                ),
                // Vacuous: an empty inventory is internally "consistent" and
                // agrees with an empty readback, but verifies nothing.
                .init(
                    .wellFormedButWrong,
                    "{\"categories\":[],\"presetsByCategory\":{}}",
                    readbackOverride: "{\"cache_age_sec\":1.0,\"fetched_at\":null,"
                        + "\"ax_occluded\":false,\"data\":{\"categories\":[]}}"
                ),
                .init(.wellFormedButWrong, "{\"categories\":[\"Bass\",\"Drum Kit\"]}"),
                // Response is internally consistent but disagrees with the read.
                .init(
                    .readbackDivergence,
                    "{\"categories\":[\"Bass\"],\"presetsByCategory\":"
                        + "{\"Bass\":[\"Deep Sub\"]},\"currentCategory\":\"Bass\"}"
                ),
                // Degraded readback (cache miss) must fail closed, not soft-pass
                // on internal consistency alone.
                .init(
                    .readbackDivergence,
                    """
                    {"categories":["Bass","Drum Kit"],\
                    "presetsByCategory":{"Bass":["Deep Sub"],"Drum Kit":["SoCal"]},\
                    "currentCategory":"Bass","currentPreset":"Deep Sub"}
                    """,
                    readbackOverride: "{\"cached\":false,\"note\":\"Run logic_library scan to populate\"}"
                ),
            ]
        ),
        .tracksScanLibrary: SemanticOracleFixture(
            response: """
                {"source":"disk","root":{"generatedAt":"1970-01-01T00:00:00Z",\
                "scanDurationMs":42,"measuredSettleDelayMs":0,"selectionRestored":true,\
                "truncatedBranches":0,"probeTimeouts":0,"cycleCount":0,"nodeCount":3,\
                "leafCount":2,"folderCount":1,"candidatePatchCount":2,\
                "nonApplicablePatchCount":0,"root":{"name":"Library","path":"/",\
                "kind":"folder","children":[]},"categories":["Bass"],\
                "presetsByCategory":{"Bass":["Deep Sub"]},"skippedDirectoryCount":0,\
                "scanWarnings":[]}}
                """,
            readback: """
                {"cache_age_sec":12.0,"fetched_at":"1970-01-01T00:00:00Z",\
                "ax_occluded":false,"data":{"categories":["Bass"],"source":"ax"}}
                """
        ),
        .tracksResolvePath: SemanticOracleFixture(
            response: """
                {"exists":true,"kind":"leaf","matchedPath":"Bass/Deep Sub",\
                "source":"disk","loadable":true}
                """,
            readback: """
                {"cache_age_sec":12.0,"fetched_at":"1970-01-01T00:00:00Z",\
                "ax_occluded":false,"data":{"categories":["Bass"],"source":"ax"}}
                """,
            customMutants: [
                .init(.malformed, "not json"),
                .init(.malformed, "{}"),
                // A hit that cannot say what it matched.
                .init(.wellFormedButWrong, "{\"exists\":true,\"kind\":\"leaf\"}"),
                // A hit that cannot classify the node it found.
                .init(.wellFormedButWrong, "{\"exists\":true,\"matchedPath\":\"Bass/Deep Sub\"}"),
                // A hit classified outside LibraryNodeKind.
                .init(
                    .wellFormedButWrong,
                    "{\"exists\":true,\"kind\":\"mystery\",\"matchedPath\":\"Bass/Deep Sub\"}"
                ),
                // A bare miss with no explanation.
                .init(.wellFormedButWrong, "{\"exists\":false}"),
                // `exists` stringified — NSNumber/String confusion must not pass.
                .init(
                    .wellFormedButWrong,
                    "{\"exists\":\"true\",\"kind\":\"leaf\",\"matchedPath\":\"Bass/Deep Sub\"}"
                ),
            ]
        ),
        .tracksScanPluginPresets: SemanticOracleFixture(
            response: """
                {"schemaVersion":1,"pluginName":"(focused-plugin)",\
                "pluginIdentifier":"(unknown — T6 will resolve via AU registry)",\
                "contentHash":"(deferred)","generatedAt":"1970-01-01T00:00:00Z",\
                "scanDurationMs":18,"measuredSubmenuOpenDelayMs":250,\
                "truncatedBranches":0,"probeTimeouts":0,"cycleCount":0,\
                "nodeCount":2,"leafCount":1,"folderCount":1,\
                "root":{"name":"Setting","path":"","kind":"folder","children":[]}}
                """,
            readback: """
                {"cache_age_sec":12.0,"fetched_at":"1970-01-01T00:00:00Z",\
                "ax_occluded":false,"data":{"categories":["Bass"],"source":"ax"}}
                """
        ),
    ]
}
