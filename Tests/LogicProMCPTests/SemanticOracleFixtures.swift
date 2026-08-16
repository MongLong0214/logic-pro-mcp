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
        .audioAnalyzeSpectrum: SemanticOracleFixture(
            response: """
                {"analysisRef":"audio.analyze_spectrum",\
                "artifactFingerprint":"not_computed_by_dispatcher",\
                "sampleRate":48000,"channelCount":2,"durationSeconds":12.5,\
                "windowsAnalyzed":64,"channelMode":"stereo_energy_average",\
                "complete":true,"bands":[{"centerHz":20.0,"energyDb":-72.0}],\
                "resonances":[{"hz":5001.953125,"gainDb":36.0,"q":8.6,\
                "resolutionLimited":true}],"spectralCentroidHz":2200.0,\
                "frequencyPeaks":[{"frequency_hz":5001.953125,"magnitude":0.5}],\
                "classification":"fullMix","confidence":0.8}
                """,
            readback: health
        ),
        .audioRecommendEQ: SemanticOracleFixture(
            response: """
                {"bands":[{"centerHz":5001.953125,"gainDb":-36.0,"q":8.6,\
                "reason":"resonance_cut"}]}
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

        // ── #373 Phase B1 — verified-write State-A fixtures ──────────────────
        // Each is a faithful State-A payload from the op's `encodeStateA` /
        // `encodeV2StateA` path. `observed` is the DETENT/TOLERANCE-quantized
        // read-back where the handler quantizes (mixer sliders, set_param_verified)
        // — deliberately ≠ `requested` — so the fixtures model the real verified
        // shape, not an idealized requested==observed. Readback is unused (no
        // oracle here cross-checks), so it is a bare `{}`.

        // AccessibilityChannel+Mixer.defaultSetMixerValue (.volume): requested
        // 0.5 lands on the nearest AX detent, observed 0.48 == observed_after.
        .mixerSetVolume: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"mixer.set_volume","track":0,"control":"volume",\
                "requested":0.5,"target_identity":{"track_index":0,"control":"volume"},\
                "observed_before":0.30,"observed_after":0.48,"observed":0.48,\
                "observed_raw":48.0,"target_raw":50.0,"detent_raw_step":10,\
                "verify_source":"ax_slider","write_method":"ax_increment_decrement",\
                "nudge_steps":3,"quantization_note":"nearest representable level"}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+Mixer.defaultSetMixerValue (.pan): centered range.
        .mixerSetPan: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"mixer.set_pan","track":1,"control":"pan",\
                "requested":-0.30,"target_identity":{"track_index":1,"control":"pan"},\
                "observed_before":0.0,"observed_after":-0.28,"observed":-0.28,\
                "observed_raw":36.0,"target_raw":35.0,"detent_raw_step":10,\
                "verify_source":"ax_slider","write_method":"ax_increment_decrement",\
                "nudge_steps":2,"quantization_note":"nearest representable level"}
                """,
            readback: "{}"
        ),
        // MCUChannel.executeSetMasterVolume: track "master" (string), MCU echo.
        // observed is 14-bit-echo-quantized ≈ requested (0.5001 vs 0.5, within
        // 2/16383 ≈ 0.000122) — near, deliberately not equal.
        .mixerSetMasterVolume: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "requested":0.5,"observed":0.5001,"track":"master",\
                "readback_source":"mcu_echo"}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+Tracks.defaultSelectTrack: requested==selected==observed.
        .tracksSelect: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "requested":2,"selected":2,"observed":2}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+Tracks.defaultRenameTrack: observed name == requested.
        .tracksRename: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","track":2,\
                "requested":"Lead Synth","observed":"Lead Synth","via":"ax_set_value"}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+Tracks.defaultSetTrackToggle (Mute): requested==observed bool.
        // Mute's coordinate-free primary is exclusive-select + key 'm' (#106).
        .tracksMute: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","track":1,\
                "button":"Mute","requested":true,"verification_source":"ax_value",\
                "observed":true,"action":"keyboard-mute"}
                """,
            readback: "{}"
        ),
        .tracksSolo: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","track":1,\
                "button":"Solo","requested":true,"verification_source":"ax_value",\
                "observed":true,"action":"keyboard-solo"}
                """,
            readback: "{}"
        ),
        // Arm's coordinate-free path is exclusive-select + a user-assigned
        // "Toggle Track Record Enable" key command (#106; 'r' is transport Record).
        .tracksArm: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","track":1,\
                "button":"Record","requested":true,"verification_source":"ax_value",\
                "observed":true,"action":"keyboard-arm"}
                """,
            readback: "{}"
        ),
        // TrackDispatcher.arm_only: armed==target_track, requested_enabled==observed_enabled.
        .tracksArmOnly: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"track.arm_only","armed":2,"target_track":2,\
                "armedSuccess":true,"requested_enabled":true,"observed_enabled":true,\
                "verification_source":"ax_value","disarmed":[0,1],\
                "unverifiedDisarm":[],"failedDisarm":[],"detail":"track 2 armed"}
                """,
            readback: "{}"
        ),
        // MCUChannel.executeAutomation (fast path): mode == observed_mode.
        .tracksSetAutomation: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "function":"set_automation","track":1,"mode":"read",\
                "observed_mode":"read","write_attempted":false}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+Library.setTrackInstrument: observed preset == requested.
        .tracksSetInstrument: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "requested":"Deep Sub","requested_patch_name":"Deep Sub",\
                "requested_category":"Bass","requested_path":"Bass/Deep Sub",\
                "category":"Bass","preset":"Deep Sub","path":"Bass/Deep Sub",\
                "target_track_index":1,"target_track_name":"Bass",\
                "observed":"Deep Sub","observed_patch_name":"Deep Sub",\
                "verify_source":"library_selected_children","readback_state":"verified"}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+VerifiedPlugins.defaultSetParamVerified (HC v2):
        // hc_schema 2, same-surface write/verify. Compressor Threshold — a real
        // catalog param whose unit is 0..100 (normalized %) with tolerance 1.0, so
        // observed_normalized 60.5 is within the payload's OWN tolerance of the
        // requested 60.0 (|0.5| ≤ 1.0) — exercising the data-driven `.field` bound.
        .pluginsSetParamVerified: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","hc_schema":2,\
                "operation":"logic_plugins.set_param_verified",\
                "target_identity":{"track":0,"insert":0,"plugin_id":"logic.stock.compressor"},\
                "param":"threshold","requested_normalized":60.0,"observed_normalized":60.5,\
                "observed_display":"60.5 %","display_unit":"%","tolerance":1.0,\
                "write_source":"ax_plugin_window","verify_source":"ax_plugin_window"}
                """,
            readback: "{}"
        ),

        // ── #373 Phase B2 — transport + navigate verified State-A fixtures ────
        // Each is a faithful State-A payload from the op's dispatcher/channel
        // `encodeStateA` path. Readback is unused (no B2 oracle cross-checks), so
        // it is a bare `{}`.

        // TransportDispatcher.handleVerifiedTransportCommand(.play) write path:
        // observed_after summary shows isPlaying:true (the State-A gate).
        .transportPlay: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"transport.play","verify_source":"transport_state",\
                "write_attempted":true,"poll_attempts":1,\
                "observed_before":{"isPlaying":false,"isRecording":false,\
                "position":"1.1.1.1","tempo":120},\
                "observed_after":{"isPlaying":true,"isRecording":false,\
                "position":"1.3.1.1","tempo":120},"write_result":{"state":"B"}}
                """,
            readback: "{}"
        ),
        // .record gate: observed_after shows isPlaying && isRecording.
        .transportRecord: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"transport.record","verify_source":"transport_state",\
                "write_attempted":true,"poll_attempts":1,\
                "observed_before":{"isPlaying":false,"isRecording":false,\
                "position":"1.1.1.1","tempo":120},\
                "observed_after":{"isPlaying":true,"isRecording":true,\
                "position":"1.2.1.1","tempo":120},"write_result":{"state":"B"}}
                """,
            readback: "{}"
        ),
        // verifiedStopResult post-write path (stopObservedExtras): FLAT observed_*
        // keys, verify_source ax_transport_state.
        .transportStop: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"transport.stop","requested_state":"stopped",\
                "verify_source":"ax_transport_state","write_attempted":true,\
                "poll_attempts":2,"observed_isPlaying":false,"observed_isRecording":false,\
                "observed_position":"5.1.1.1","observed_time_position":"00:00:08:12",\
                "write_result":{"state":"B"}}
                """,
            readback: "{}"
        ),
        // verifiedPauseResult post-write path: verify_source transport_state.
        .transportPause: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"transport.pause","requested_state":"paused",\
                "verify_source":"transport_state","write_attempted":true,\
                "poll_attempts":1,"observed_isPlaying":false,"observed_isRecording":false,\
                "observed_position":"5.1.1.1","observed_time_position":"00:00:08:12",\
                "write_result":{"state":"B"}}
                """,
            readback: "{}"
        ),
        // clickControlBarCheckbox(Cycle): observed:true == !previous:false.
        .transportToggleCycle: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","button":"Cycle",\
                "control":"사이클","observed":true,"previous":false,\
                "action":"axpress","attempts":["axpress"]}
                """,
            readback: "{}"
        ),
        // clickControlBarCheckbox(Count In).
        .transportToggleCountIn: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","button":"Count In",\
                "control":"카운트 인","observed":true,"previous":false,\
                "action":"axpress","attempts":["axpress"]}
                """,
            readback: "{}"
        ),
        // defaultToggleAutopunch: observed:true == !previous:false, action axpress.
        .transportToggleAutopunch: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","button":"Autopunch",\
                "control":"Autopunch","operation":"transport.toggle_autopunch",\
                "action":"axpress","previous":false,"observed":true,"requested":true}
                """,
            readback: "{}"
        ),
        // toggle_metronome — AX-verified shape (clickControlBarCheckbox). The
        // oracle pins only the channel-independent envelope (the two channel shapes
        // share no non-envelope key); the dispatcher-verified keycmd shape and the
        // no-op/failure rejection are covered by a dedicated engine test.
        .transportToggleMetronome: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","button":"Metronome",\
                "control":"메트로놈 클릭","observed":true,"previous":false,\
                "action":"axpress","attempts":["axpress"]}
                """,
            readback: "{}"
        ),
        // defaultSetTempo (via slider): observed 119.7 within 1.0 BPM of requested 120.
        .transportSetTempo: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "requested":120.0,"observed":119.7,"via":"slider"}
                """,
            readback: "{}"
        ),
        // finalizeGotoPositionResult: observed position == requested (exact landing).
        .transportGotoPosition: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "verification_source":"transport_state","requested":"5.1.1.1",\
                "observed":"5.1.1.1","observed_time_position":"00:00:08:12","via":"dialog"}
                """,
            readback: "{}"
        ),
        // navigate.goto_bar → same finalizeGotoPositionResult shape.
        .navigateGotoBar: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "verification_source":"transport_state","requested":"9.1.1.1",\
                "observed":"9.1.1.1","observed_time_position":"00:00:14:03","via":"dialog"}
                """,
            readback: "{}"
        ),
        // navigate.goto_marker → canonical marker, same finalize shape.
        .navigateGotoMarker: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "verification_source":"transport_state","requested":"12.1.1.1",\
                "observed":"12.1.1.1","observed_time_position":"00:00:22:00","via":"dialog"}
                """,
            readback: "{}"
        ),
        // finalizeCreateMarkerResult (named create): observed_marker_name == requested_name,
        // count delta +1.
        .navigateCreateMarker: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"nav.create_marker","method":"accessibility_menu",\
                "menu_path":"Navigate > Create Marker","sent":true,\
                "marker_count_before_channel":2,"marker_count_after_channel":3,\
                "verification_source":"logic://markers","marker_count_before":2,\
                "marker_count_after":3,"requested_name":"Chorus",\
                "observed_marker_id":2,"observed_marker_name":"Chorus",\
                "observed_marker_position":"12.1.1.1","observed_marker_position_source":"parser"}
            """,
            readback: "{}"
        ),
        // defaultDeleteMarker State A: the settled AX marker-list POSITION multiset
        // exactly matched the pre-write positions with the target occurrence
        // removed. Each sorted position entry is length-prefixed, then the entries
        // join without an ambiguous delimiter.
        .navigateDeleteMarker: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"nav.delete_marker","requested_index":1,\
                "target_name":"Verse","target_position":"5.1.1.1",\
                "prewrite_marker_identities":["5:Intro7:1.1.1.1","5:Verse7:5.1.1.1","6:Chorus8:12.1.1.1"],\
                "target_position_unique":true,"position_evidence_canonical":true,\
                "marker_count_before":3,"write_attempted":true,\
                "readback_settled":true,"marker_count_after":2,\
                "expected_survivor_position_multiset":"7:1.1.1.18:12.1.1.1",\
                "observed_survivor_position_multiset":"7:1.1.1.18:12.1.1.1"}
                """,
            readback: """
                {"source":"ax_live","readable":true,"verified_empty":false,
                "position_multiset":"7:1.1.1.18:12.1.1.1","positions_canonical":true,
                "data":[
                  {"id":0,"name":"Intro","position":"1.1.1.1","position_source":"parser","is_canonical":true},
                  {"id":2,"name":"Chorus","position":"12.1.1.1","position_source":"parser","is_canonical":true}
                ]}
                """
        ),
        // defaultRenameMarker post-write path: observed_name == requested_name.
        .navigateRenameMarker: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"nav.rename_marker","index":1,"previous_name":"Verse",\
                "requested_name":"Bridge","observed_name":"Bridge","write_attempted":true}
                """,
            readback: "{}"
        ),
        // defaultSetZoomLevel (level 8 → target 7/9 ≈ 0.7778): observed within 0.02.
        .navigateSetZoom: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","operation":"nav.set_zoom",\
                "axis":"horizontal","level":8,"requested":0.7777777777777778,\
                "observed_before":0.3333333333333333,"observed":0.7777777777777778,\
                "observed_after":0.7777777777777778,"verify_source":"ax_zoom_slider"}
                """,
            readback: "{}"
        ),

        // ── #373 Phase B3 — project/tracks/system/midi verified State-A fixtures ──
        // Each is a faithful payload from the op's verified path (traced to the
        // dispatcher/channel handler). Readback is unused (no B3 oracle
        // cross-checks), so it is a bare `{}`.

        // AppleScriptChannel.verifiedSaveResult State A: mtime advanced past the
        // save start, so document_path + observed_mtime are present.
        .projectSave: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","operation":"project.save",\
                "method":"applescript","verify_source":"file_mtime","raw":"saved",\
                "document_path":"/Users/qualification/Demo.logicx",\
                "observed_mtime":"1970-01-01T00:00:02Z","previous_mtime":"1970-01-01T00:00:01Z"}
                """,
            readback: "{}"
        ),
        // save_as: the AX-dialog State-A shape (requested/observed/via). The oracle
        // is envelope-only, so it also accepts the AppleScript shape — proven by
        // `saveAsOracleAcceptsBothChannelShapesYetRejectsUnverified`.
        .projectSaveAs: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "requested":"/Users/qualification/Demo.logicx",\
                "observed":"/Users/qualification/Demo.logicx","via":"save-dialog"}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel.openBounceDialogViaMenu BOUNCE_DIALOG_OPENED branch:
        // dialog opened, bounce NOT fired.
        .projectBounce: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","operation":"project.bounce",\
                "requested":"bounce_dialog_open","observed":"bounce_dialog_open",\
                "dialog_opened":true,"bounce_fired":false,"via":"file-menu",\
                "next_action":"Review the Bounce settings in Logic, then confirm and choose the destination."}
                """,
            readback: "{}"
        ),
        // verifyTrackCreation State A: count increased by 1, type "audio".
        .tracksCreateAudio: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","menu_clicked":"새로운 오디오 트랙",\
                "track_count_before":2,"requested_delta":1,"dialog_confirmation_attempted":false,\
                "observed_track_type":"audio","track_type_verification_source":"observed_header",\
                "verification_source":"track_count_delta","track_count_after":3,"observed_delta":1,\
                "observed_track_index":2,"observed_track_name":"Audio 1",\
                "requested_track_type":"audio"}
                """,
            readback: "{}"
        ),
        // type "software_instrument".
        .tracksCreateInstrument: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "menu_clicked":"새로운 소프트웨어 악기 트랙","track_count_before":2,"requested_delta":1,\
                "dialog_confirmation_attempted":true,"observed_track_type":"software_instrument",\
                "track_type_verification_source":"observed_header",\
                "verification_source":"track_count_delta","track_count_after":3,"observed_delta":1,\
                "observed_track_index":2,"observed_track_name":"Inst 1",\
                "requested_track_type":"software_instrument"}
                """,
            readback: "{}"
        ),
        // type "drummer".
        .tracksCreateDrummer: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "menu_clicked":"새로운 Session Player SI 트랙…","track_count_before":2,\
                "requested_delta":1,"dialog_confirmation_attempted":true,\
                "observed_track_type":"drummer","track_type_verification_source":"observed_header",\
                "verification_source":"track_count_delta","track_count_after":3,"observed_delta":1,\
                "observed_track_index":2,"observed_track_name":"Drummer","requested_track_type":"drummer"}
                """,
            readback: "{}"
        ),
        // type "external_midi".
        .tracksCreateExternalMIDI: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","menu_clicked":"새로운 외부 MIDI 트랙",\
                "track_count_before":2,"requested_delta":1,"dialog_confirmation_attempted":false,\
                "observed_track_type":"external_midi","track_type_verification_source":"observed_header",\
                "verification_source":"track_count_delta","track_count_after":3,"observed_delta":1,\
                "observed_track_index":2,"observed_track_name":"External MIDI","requested_track_type":"external_midi"}
                """,
            readback: "{}"
        ),
        // defaultDeleteTrack State A: count decreased by 1 (observed_delta -1).
        .tracksDelete: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","menu_clicked":"트랙 삭제",\
                "track_count_before":3,"requested_delta":-1,"track_count_after":2,"observed_delta":-1}
                """,
            readback: "{}"
        ),
        // record_sequence verified payload — success+verified WITHOUT state:"A"
        // (hand-assembled via jsonToolTextResult): the region read back on the
        // created track matches the expected bar envelope (start 1, end 3).
        .tracksRecordSequence: SemanticOracleFixture(
            response: """
                {"bar":1,"created_track":3,"recorded_to_track":3,"target_track_index":3,\
                "target_track_name":"Inst 1","note_count":4,"method":"smf_import",\
                "instrument":"not-attempted","expected_start_bar":1,"expected_end_bar":3,\
                "verify_source":"ax_region_delta","region_name":"MIDI Region","start_bar":1,\
                "end_bar":3,"region_kind":"midi","success":true,"verified":true}
                """,
            readback: "{}"
        ),
        // SagaWire.storedOutcome .completed → encodeStateA. saga_state completed.
        .systemSagaExecute: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","journal_scope":"session",\
                "journal_persistence":"cleared_on_server_session_end",\
                "journal_survives_process_restart":false,"idempotency_key":"qual-saga-1",\
                "duplicate":false,"saga_state":"completed",\
                "state_history":["draft","validated","running","completed"],\
                "steps":[{"operation_id":"mixer.set_volume","state":"applied"}]}
                """,
            readback: "{}"
        ),
        // saga_cancel .cancelled + verified → encodeStateA. status cancelled.
        .systemSagaCancel: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","journal_scope":"session",\
                "journal_persistence":"cleared_on_server_session_end",\
                "journal_survives_process_restart":false,"idempotency_key":"qual-saga-2",\
                "status":"cancelled","outcome":{"saga_state":"fullyCompensated","verified":true}}
                """,
            readback: "{}"
        ),
        // setup_arm_key .configuredAndVerified → encodeStateA(evidence.extras +
        // chord/command/verified/detail). write_source "gui_assignment".
        .systemSetupArmKey: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","command":"Toggle Track Record Enable",\
                "chord":"⌥⌘R","write_source":"gui_assignment","configuration_write_attempted":true,\
                "verification_mutation_attempted":true,"restored":true,"safe_to_retry":true,\
                "window_opened":true,"search_typed":true,"chord_posted":true,"learn_restored":true,\
                "window_closed":true,"close_confirmed":true,"arm_flip_observed":true,\
                "detail":"Key command assigned via the Key Commands GUI and confirmed by a live record-arm flip."}
                """,
            readback: "{}"
        ),
        // export_support_bundle → encodeStateA({bundle_path, files:[{name,sha256}]}).
        .systemExportSupportBundle: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "bundle_path":"/Users/qualification/Library/Logs/LogicProMCP/support-bundles/20260101-000000-demo",\
                "files":[{"name":"doctor.json",\
                "sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},\
                {"name":"health.json",\
                "sha256":"5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"}]}
                """,
            readback: "{}"
        ),
        // defaultImportMIDIFile State A: track created (delta 1), imported region
        // read back (imported_region_count 1, imported_regions non-empty).
        .midiImportFile: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","requested":"/tmp/logic-pro-mcp/seq.mid",\
                "track_count_before":2,"track_count_after":3,"observed_delta":1,\
                "via":"ax_menu_import","file_open_dialog_seen":true,"tempo_dialog_seen":false,\
                "region_count_before":0,"region_count_after":1,"new_midi_region_count":1,\
                "new_midi_regions":[{"region_name":"seq","track_index":2,"start_bar":1,"end_bar":3,\
                "region_kind":"midi"}],"imported_region_count":1,\
                "imported_regions":[{"region_name":"seq","track_index":2,"start_bar":1,"end_bar":3,\
                "region_kind":"midi"}]}
                """,
            readback: "{}"
        ),
        // mmc_locate bar-path → finalizeGotoPositionResult State A (goto shape).
        .midiMMCLocate: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "verification_source":"transport_state","requested":"5.1.1.1",\
                "observed":"5.1.1.1","observed_time_position":"00:00:08:12","via":"dialog"}
                """,
            readback: "{}"
        ),

        // ── #373 Phase B4 — plugin-insert / export / cleanup / edit fixtures ──
        // Each is a faithful payload from the op's verified path (traced to the
        // dispatcher/channel handler). Readback is unused (no B4 oracle
        // cross-checks a separate readback payload), so it is a bare `{}`.

        // AccessibilityChannel+Plugins.defaultInsertPlugin State A: observed slot
        // name matched the requested spec (spec.matches), so verify_source
        // ax_plugin_slot + the readback name are present.
        .mixerInsertPlugin: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","track":0,"slot":1,\
                "plugin_name":"Gain","observed_plugin_name":"Gain",\
                "verify_source":"ax_plugin_slot"}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+VerifiedPlugins.defaultInsertVerified HC v2 State A:
        // target_identity carries the REQUESTED {track_index,insert,plugin_id};
        // observed_plugin_id/observed_slot are the post-insert readback, gated equal
        // to the request (the RIGHT plugin at the RIGHT slot). plugin_id is the
        // canonical VerifiedPluginCatalog id (logic.stock.effect.gain).
        .pluginsInsertVerified: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","hc_schema":2,\
                "operation":"logic_plugins.insert_verified",\
                "target_identity":{"track_index":0,"insert":1,"plugin_id":"logic.stock.effect.gain"},\
                "observed_plugin_id":"logic.stock.effect.gain","observed_plugin_name":"Gain",\
                "observed_slot":1,"select_trace":{"write_source":"ax_exact_slot_popup"},\
                "write_source":"ax_exact_slot_popup","verify_source":"ax_plugin_inventory"}
                """,
            readback: "{}"
        ),
        // ProjectExportExecutor.aggregate → logic_pro_mcp_export_run.v1, completed
        // fresh run: one project, one bounced+verified artifact (state A,
        // bounce_fired true, on-disk logic_audio evidence). uncertain/failed 0.
        .projectExportRun: SemanticOracleFixture(
            response: """
                {"schema":"logic_pro_mcp_export_run.v1","run_id":"run-1","mode":"run",\
                "confirmed":true,"status":"completed",\
                "output_root":"/Users/qualification/exports","collision_policy":"fail_if_exists",\
                "project_count":1,"artifacts_total":1,"artifacts_verified":1,\
                "artifacts_skipped":0,"artifacts_uncertain":0,"artifacts_failed":0,\
                "projects":[{"index":0,"project_path":"/Users/qualification/a.logicx",\
                "display_name":"a","observed_project_path":"/Users/qualification/a.logicx",\
                "identity_verified":true,"opened":true,\
                "artifacts":[{"kind":"bounce","path":"/Users/qualification/exports/a.wav",\
                "state":"A","verified":true,"bounce_fired":true,"error":null,"reason":null,\
                "evidence":{"exists":true,"file_size_bytes":2400044,"duration_seconds":12.5,\
                "sample_rate":48000,"channel_count":2,"silence_ratio":0.02,"peak_dbfs":-1.0,\
                "verification_status":"pass","verification_reasons":[],"source":"logic_audio"}}]}],\
                "next_safe_action":"verify_artifacts_with_logic_audio"}
                """,
            readback: "{}"
        ),
        // ProjectExportExecutor.aggregate via export_resume → same schema, mode
        // "resume". A completed resume where the artifact was already present and
        // verified: state A, bounce_fired FALSE (skipped, not re-bounced),
        // artifacts_skipped 1 / artifacts_verified 0 — a legitimate completed run
        // with zero verified (the resume idempotency path).
        .projectExportResume: SemanticOracleFixture(
            response: """
                {"schema":"logic_pro_mcp_export_run.v1","run_id":"run-2","mode":"resume",\
                "confirmed":true,"status":"completed",\
                "output_root":"/Users/qualification/exports","collision_policy":"skip_existing",\
                "project_count":1,"artifacts_total":1,"artifacts_verified":0,\
                "artifacts_skipped":1,"artifacts_uncertain":0,"artifacts_failed":0,\
                "projects":[{"index":0,"project_path":"/Users/qualification/a.logicx",\
                "display_name":"a","observed_project_path":"/Users/qualification/a.logicx",\
                "identity_verified":true,"opened":true,\
                "artifacts":[{"kind":"bounce","path":"/Users/qualification/exports/a.wav",\
                "state":"A","verified":true,"bounce_fired":false,"error":null,\
                "reason":"already_present_verified",\
                "evidence":{"exists":true,"file_size_bytes":2400044,"duration_seconds":12.5,\
                "sample_rate":48000,"channel_count":2,"silence_ratio":0.02,"peak_dbfs":-1.0,\
                "verification_status":"pass","verification_reasons":[],"source":"logic_audio"}}]}],\
                "next_safe_action":"verify_artifacts_with_logic_audio"}
                """,
            readback: "{}"
        ),
        // ProjectDispatcher.handleCleanupApply State A: one rename target reached
        // verified State A through the delegated track.rename path (key is `op`, not
        // `operation`). applied/target_track_indices are non-empty.
        .projectCleanupApply: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A","op":"project.cleanup_apply",\
                "step_id":"rename_track_0","tool":"logic_tracks","command":"rename",\
                "target_track_indices":[0],\
                "applied":[{"track_index":0,"new_name":"Lead Synth",\
                "result":"{\\"success\\":true,\\"verified\\":true,\\"state\\":\\"A\\"}"}],\
                "verify_source":"track.rename ax_readback"}
                """,
            readback: "{}"
        ),
        // AccessibilityChannel+Editing.defaultToggleStepInputKeyboard State A: the
        // Step Input Keyboard window open-state flipped (observed_open:true ==
        // !previous_open:false), verified via the live AX window list.
        .editToggleStepInput: SemanticOracleFixture(
            response: """
                {"success":true,"verified":true,"state":"A",\
                "operation":"edit.toggle_step_input","previous_open":false,\
                "observed_open":true,"via":"window-menu"}
                """,
            readback: "{}"
        ),
    ]
}
