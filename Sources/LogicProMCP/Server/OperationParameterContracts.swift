import Foundation
import MCP

/// #957 (ADR-003 remainder): what each command's parameters must be, and which are required, as the
/// dispatchers enforce them today.
///
/// The registry already names each command's parameters (`OperationSpec.allowedParams`), and the
/// opt-in rich schema projects those names (#1093). Value types and required keys were checked only
/// inside the dispatchers, through coercing helpers (`intParamOrNil` takes an integer, an integral
/// number or a string of digits; `stringParam` takes any scalar) and per-command refusals, and the
/// registry recorded none of it.
///
/// A rule here is a claim about the running dispatcher, not a second validator:
/// - `enforced(kind, sample)`: a value outside `kind` is refused before any channel runs. `sample`
///   is a value the dispatcher accepts for this parameter.
/// - `unconstrained(reason)`: the dispatcher coerces, defaults or ignores a value of another type,
///   so the schema states nothing about the parameter's type.
///
/// A required group is satisfied by any one of its keys. When every group is satisfied with
/// samples, the dispatcher routes the call. When a group is missing, it refuses before any channel
/// runs. `Issue957ParameterContractCensusTests` drives every dispatcher to check each of these
/// claims, so a rule that states more than the runtime enforces fails a test.
enum ParamKind: String, Sendable, Equatable {
    /// `intParamOrNil` / the MIDI dispatcher's `strictInt`: an integer, an integral number, or a
    /// string of digits.
    case integer
    /// `doubleParamOrNil`: a number or a numeric string.
    case number
    /// `stringParam`: a string, number or boolean, read as text.
    case scalar
    /// A raw `.stringValue` read: a string only.
    case string
    /// `strictBoolParam`: a JSON boolean only.
    case boolean
    /// `boolParamOrNil`: a boolean, "true"/"false"/"yes"/"no"/"1"/"0", or 0/1.
    case booleanLike
    /// A JSON object.
    case object
    /// A list given as a JSON array or as a comma-separated string.
    case listOrString
    /// A JSON array.
    case array
    /// A named value (string) or a number, as `step_input`'s duration takes either.
    case stringOrInteger

    /// The JSON schema for values of this kind. It admits every value the dispatcher accepts and
    /// may admit some it refuses (a string that is not a number, for `integer`), so the schema
    /// never refuses a request the server would take.
    var schema: Value {
        switch self {
        case .integer:
            return .object(["anyOf": .array([.object(["type": "integer"]), .object(["type": "string"])])])
        case .number:
            return .object(["anyOf": .array([.object(["type": "number"]), .object(["type": "string"])])])
        case .scalar:
            return .object(["type": .array(["string", "number", "boolean"])])
        case .string:
            return .object(["type": "string"])
        case .boolean:
            return .object(["type": "boolean"])
        case .booleanLike:
            return .object(["type": .array(["boolean", "string", "integer"])])
        case .object:
            return .object(["type": "object"])
        case .listOrString:
            return .object(["type": .array(["array", "string"])])
        case .array:
            return .object(["type": "array"])
        case .stringOrInteger:
            return .object(["type": .array(["string", "integer"])])
        }
    }

    /// A value of a JSON type this kind does not admit, which the census sends to show a refusal.
    var outsideValue: Value {
        switch self {
        case .object, .array, .listOrString, .boolean:
            return .int(7)
        default:
            return .object(["not": "this kind"])
        }
    }
}

struct ParamRule: Sendable, Equatable {
    let kind: ParamKind?
    let sample: Value?
    let reason: String?
    /// The only values the dispatcher takes, read from the dispatcher's own list, never typed here.
    let allowed: [String]?

    /// `allowed`, when given, must be the list the dispatcher checks the value against.
    static func enforced(_ kind: ParamKind, _ sample: Value, allowed: [String]? = nil) -> ParamRule {
        ParamRule(kind: kind, sample: sample, reason: nil, allowed: allowed)
    }

    /// `sample`, when given, is a value the dispatcher accepts, used to satisfy a required group.
    static func unconstrained(_ reason: String, sample: Value? = nil) -> ParamRule {
        ParamRule(kind: nil, sample: sample, reason: reason, allowed: nil)
    }

    /// The parameter's schema: its kind's, narrowed to `allowed` when there is a list, and empty
    /// when the rule is unconstrained.
    var schema: Value {
        guard let kind else { return .object([:]) }
        guard let allowed, var object = kind.schema.objectValue else { return kind.schema }
        object["enum"] = .array(allowed.map { .string($0) })
        return .object(object)
    }
}

struct OperationParameterContract: Sendable, Equatable {
    let params: [String: ParamRule]
    /// Each group is satisfied by any one of its keys.
    let required: [[String]]
}

extension OperationRegistry {
    // MARK: - Shared rules

    private static let targetRef = ParamRule.unconstrained(
        "a stable target reference is resolved against the target registry; a stale or ill-formed one answers stale_target_reference")
    private static let projectRef = ParamRule.unconstrained(
        "the project reference is compared with the open project; a mismatch answers its own refusal")
    private static func index(_ sample: Int = 0) -> ParamRule { .enforced(.integer, .int(sample)) }
    private static let port = ParamRule.enforced(.string, .string("midi"), allowed: MIDIDispatcher.validPorts.sorted())
    private static let channel = ParamRule.enforced(.integer, .int(1))
    private static let indexGroup = ["index", "track", "target_ref"]
    private static func pluginWriteRules(_ keys: [String]) -> [String: ParamRule] {
        Dictionary(uniqueKeysWithValues: keys.map {
            ($0, ParamRule.unconstrained("omitted when it does not read; the channel's own schema step then refuses the request"))
        })
    }

    /// Commands with parameters. A command with none has no entry.
    static let parameterContracts: [OperationID: OperationParameterContract] = {
        var contracts: [String: OperationParameterContract] = [
            // logic_transport
            "transport.set_tempo": .init(params: ["bpm": .enforced(.number, .int(120)), "tempo": .enforced(.number, .int(120))],
                                         required: [["bpm", "tempo"]]),
            "transport.goto_position": .init(params: [
                "bar": index(9),
                "position": .unconstrained("read as text with 1.1.1.1 as the default, so an object or array goes to bar 1"),
            ], required: []),
            "transport.set_cycle_range": .init(params: ["start": index(1), "end": index(4)], required: [["start"], ["end"]]),

            // logic_mixer
            "mixer.set_volume": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "value": .enforced(.number, .double(0.5)), "volume": .enforced(.number, .double(0.5)),
            ], required: [indexGroup, ["value", "volume"]]),
            "mixer.set_pan": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "value": .enforced(.number, .int(0)), "pan": .enforced(.number, .int(0)),
            ], required: [indexGroup, ["value", "pan"]]),
            "mixer.set_master_volume": .init(params: ["value": .enforced(.number, .double(0.5)), "volume": .enforced(.number, .double(0.5))],
                                             required: [["value", "volume"]]),
            "mixer.bank": .init(params: ["direction": .enforced(.scalar, .string("right"), allowed: MixerDispatcher.bankDirections),
                                         "count": index(1)],
                                required: [["direction"]]),
            "mixer.insert_plugin": .init(params: [
                "track": index(), "track_index": index(), "index": index(),
                "slot": index(), "insert": index(),
                "plugin_name": .unconstrained("read as text; one alias that does not read as text is skipped for the next",
                                              sample: .string("Gain")),
                "plugin": .unconstrained("read as text; one alias that does not read as text is skipped for the next"),
                "name": .unconstrained("read as text; one alias that does not read as text is skipped for the next"),
                "confirmed": .enforced(.boolean, .bool(false)),
                "configuration": .unconstrained("read as text and checked by the channel against the strip's menu"),
                "channel_configuration": .unconstrained("read as text and checked by the channel against the strip's menu"),
            ], required: [["track", "track_index", "index"], ["slot", "insert"], ["plugin_name", "plugin", "name"]]),
            "mixer.set_plugin_param": .init(params: [
                "track": index(), "insert": index(0), "param": index(), "value": .enforced(.number, .double(0.5)),
            ], required: [["track"], ["insert"], ["param"], ["value"]]),
            "mixer.set_output_verified": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "destination": .enforced(.object, .object(["kind": "bus", "number": .int(1)])),
                "expected_current": .enforced(.object, .object(["kind": "bus", "number": .int(2)])),
            ], required: [indexGroup, ["destination"]]),

            // logic_navigate
            "navigate.goto_bar": .init(params: ["bar": index(9)], required: [["bar"]]),
            "navigate.goto_marker": .init(params: [
                "index": index(),
                "name": .unconstrained("read as text, and not read at all when an index is given"),
            ], required: [["index", "name"]]),
            "navigate.create_marker": .init(params: [
                "name": .unconstrained("read as text; a value that does not read as text leaves the marker to be named by Logic"),
            ], required: []),
            "navigate.delete_marker": .init(params: ["index": index()], required: [["index"]]),
            "navigate.rename_marker": .init(params: ["index": index(), "name": .enforced(.scalar, .string("Verse"))],
                                       required: [["index"], ["name"]]),
            "navigate.set_zoom": .init(params: [
                "level": .unconstrained("read as text with fit as the default", sample: .string("fit")),
                "direction": .unconstrained("read as text with fit as the default"),
            ], required: [["level", "direction"]]),
            "navigate.toggle_view": .init(params: ["view": .unconstrained("read as text with mixer as the default", sample: .string("mixer"))],
                                     required: [["view"]]),

            // logic_edit
            "edit.quantize": .init(params: [
                "value": .unconstrained("read as text with 1/16 as the default", sample: .string("1/16")),
                "grid": .unconstrained("read as text with 1/16 as the default"),
            ], required: [["value", "grid"]]),

            // logic_midi
            "midi.send_note": .init(params: [
                "note": index(60), "velocity": index(100), "duration_ms": index(200), "channel": channel, "port": port,
            ], required: [["note"]]),
            "midi.send_chord": .init(params: [
                "notes": .enforced(.listOrString, .array([.int(60), .int(64)])), "velocity": index(100),
                "duration_ms": index(200), "channel": channel, "port": port,
            ], required: [["notes"]]),
            "midi.send_cc": .init(params: ["controller": index(7), "value": index(100), "channel": channel, "port": port],
                                  required: [["controller"], ["value"]]),
            "midi.send_program_change": .init(params: ["program": index(1), "channel": channel, "port": port],
                                              required: [["program"]]),
            "midi.send_pitch_bend": .init(params: ["value": index(8192), "channel": channel, "port": port],
                                          required: [["value"]]),
            "midi.send_aftertouch": .init(params: ["value": index(64), "channel": channel, "port": port],
                                          required: [["value"]]),
            "midi.send_sysex": .init(params: [
                "bytes": .unconstrained("an array of bytes or hex text; a value of another type is skipped for data",
                                        sample: .array([.int(0xF0), .int(0x7E), .int(0xF7)])),
                "data": .unconstrained("hex text only, and not read when bytes is given", sample: .string("F0 7E F7")),
            ], required: [["bytes", "data"]]),
            "midi.play_sequence": .init(params: ["notes": .enforced(.string, .string("60,0,200")), "port": port],
                                        required: [["notes"]]),
            "midi.step_input": .init(params: ["note": index(60), "duration": .enforced(.stringOrInteger, .string("1/8"))],
                                     required: [["note"], ["duration"]]),
            "midi.mmc_locate": .init(params: [
                "bar": index(9),
                "time": .unconstrained("not read when a bar is given; alone, a value that is not HH:MM:SS:FF text is refused"),
            ],
                                     required: [["bar", "time"]]),
            "midi.import_file": .init(params: ["path": .enforced(.string, .string("/tmp/lpm-957.mid"))], required: [["path"]]),
            "midi.create_virtual_port": .init(params: ["name": .unconstrained("read as text with Virtual Port as the default")],
                                              required: []),

            // logic_tracks
            "tracks.select": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "name": .unconstrained("read as text, and not read at all when an index is given"),
            ], required: [["index", "track", "name", "target_ref"]]),
            "tracks.delete": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "expected_name": .enforced(.string, .string("Track 1")),
            ], required: [indexGroup, ["expected_name", "target_ref"]]),
            "tracks.duplicate": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "expected_name": .enforced(.string, .string("Track 1")),
            ], required: [indexGroup, ["expected_name", "target_ref"]]),
            "tracks.rename": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "name": .enforced(.scalar, .string("Lead")),
            ], required: [indexGroup, ["name"]]),
            "tracks.set_automation": .init(params: [
                "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                "mode": .enforced(.scalar, .string("read"), allowed: TrackDispatcher.automationModes),
            ], required: [indexGroup, ["mode"]]),
            "tracks.set_instrument": .init(params: [
                "index": index(), "target_ref": targetRef, "project_ref": projectRef,
                "expected_name": .enforced(.string, .string("Track 1")),
                "path": .unconstrained("read as text, and not needed when category and preset are given",
                                       sample: .string("Bass/Electric Bass")),
                "category": .unconstrained("read as text, and not needed when a path is given"),
                "preset": .unconstrained("read as text, and not needed when a path is given"),
            ], required: [["index", "target_ref"], ["path", "category"], ["expected_name", "target_ref"]]),
            "tracks.resolve_path": .init(params: ["path": .enforced(.scalar, .string("Bass/Electric Bass"))], required: [["path"]]),
            "tracks.scan_library": .init(params: ["mode": .unconstrained("read as text; an empty mode leaves the channel's default")],
                                        required: []),
            "tracks.scan_plugin_presets": .init(params: ["submenuOpenDelayMs": index(250)], required: []),
            "tracks.record_sequence": .init(params: [
                "bar": index(9), "notes": .enforced(.string, .string("60:0:480")), "tempo": .enforced(.number, .int(120)),
                "instrument": .unconstrained("read and reported back as ignored; it never selects an instrument"),
                "instrument_path": .unconstrained("read and reported back as ignored; it never selects an instrument"),
            ], required: [["notes"]]),
            "tracks.sort_verified": .init(params: [
                "criterion": .enforced(.scalar, .string("midi_channel"), allowed: TrackSortCriterion.allCases.map(\.rawValue)),
                "expected_order": .enforced(.array, .array([.string("trk:1")])),
                "confirmed": .unconstrained("read only after expected_order resolves to live tracks"),
            ], required: [["criterion"], ["expected_order"]]),

            // logic_system
            "system.help": .init(params: [
                "category": .unconstrained("a value that is not a string skips the unknown-category refusal and returns the full help"),
            ], required: []),
            "system.list_recent_traces": .init(params: ["limit": index(5)], required: []),
            "system.get_trace": .init(params: ["trace_id": .enforced(.string, .string("lpmcp_00000000-0000-0000-0000-000000000957"))],
                                      required: [["trace_id"]]),
            "system.clear_traces": .init(params: ["confirmed": .enforced(.boolean, .bool(true))], required: []),
            "system.export_support_bundle": .init(params: ["dir": .enforced(.string, .string("lpm-957-bundle"))], required: []),
            "system.setup_arm_key": .init(params: [
                "consent": .unconstrained("only the string \"true\" consents; any other value, a JSON true included, reads as no consent"),
            ], required: []),
            "system.setup_control_surface": .init(params: [
                "consent": .unconstrained("only the string \"true\" consents; any other value, a JSON true included, reads as no consent"),
            ], required: []),

            // logic_audio: analysis runs in the server, so a refusal is the reply, not a channel left idle.
            "audio.analyze_file": .init(params: Dictionary(uniqueKeysWithValues: [
                "expected_channel_count", "expected_duration_seconds", "expected_sample_rate", "max_decoded_frames",
                "max_duration_drift_seconds", "max_input_duration_seconds", "max_input_file_size_bytes", "max_peak_dbfs",
                "max_silence_ratio", "maximum_decoded_frames", "maximum_duration_drift_seconds",
                "maximum_input_duration_seconds", "maximum_input_file_size_bytes", "maximum_peak_dbfs",
                "maximum_silence_ratio", "min_duration_seconds", "min_file_size_bytes", "minimum_duration_seconds",
                "minimum_file_size_bytes", "near_silence_dbfs", "near_silence_threshold_dbfs",
            ].map { ($0, ParamRule.unconstrained("a value that does not read as a number leaves the policy's default")) })
                .merging([
                    "output_root": .unconstrained("a value that is not a string is kept as a path no confinement accepts, refused later as unsafe_path"),
                    "path": .unconstrained("read as text; a missing or unreadable path is analyzed and reported as not existing, not refused"),
                ]) { _, new in new },
                required: []),
            "audio.analyze_spectrum": .init(params: ["path": .unconstrained("read as text; the analyzer refuses a path it cannot open",
                                    sample: .string("/tmp/lpm-957-no-such-file.wav"))],
                                            required: [["path"]]),
            "audio.compare_spectra": .init(params: [
                "before_path": .unconstrained("read as text; the analyzer refuses a path it cannot open",
                                    sample: .string("/tmp/lpm-957-no-such-file.wav")),
                "after_path": .unconstrained("read as text; the analyzer refuses a path it cannot open",
                                    sample: .string("/tmp/lpm-957-no-such-file.wav")),
                "output_root": .unconstrained("a value that is not a string is kept as a path no confinement accepts, refused later as unsafe_path"),
            ], required: [["before_path"], ["after_path"]]),
            "audio.recommend_eq": .init(params: [
                "path": .unconstrained("read as text; the analyzer refuses a path it cannot open",
                                    sample: .string("/tmp/lpm-957-no-such-file.wav")),
                "minimum_level": .enforced(.number, .double(0.6)),
            ], required: [["path"]]),

            // logic_plugins: the dispatcher omits a value that does not read, and the channel's own
            // schema step refuses the request, so those refusals come after a channel ran.
            "plugins.get_inventory": .init(params: Dictionary(uniqueKeysWithValues: ["index", "track", "track_index"].map {
                ($0, ParamRule.unconstrained("omitted when it does not read as an integer; the inventory then covers every track"))
            }), required: []),
            "plugins.insert_verified": .init(params: pluginWriteRules(["insert", "slot", "plugin", "plugin_id", "plugin_name", "mode", "project_expected_path", "track"])
                .merging([
                    "expected_name": .unconstrained("compared only when the track reads; with no track the request goes on to the channel"),
                    "target_ref": targetRef, "project_ref": projectRef,
                ]) { _, new in new },
                required: []),
            "plugins.set_eq_band_verified": .init(params: pluginWriteRules(["band", "insert", "mode", "parameter", "project_expected_path", "track", "unit", "value"])
                .merging(["target_ref": targetRef, "project_ref": projectRef]) { _, new in new }, required: []),
            "plugins.set_param_verified": .init(params: pluginWriteRules(["insert", "mode", "param", "plugin", "plugin_id", "plugin_name", "project_expected_path", "track", "unit", "value"])
                .merging(["target_ref": targetRef, "project_ref": projectRef]) { _, new in new }, required: []),

            // logic_project
            "project.bounce": .init(params: ["confirmed": .enforced(.boolean, .bool(false))], required: []),
            "project.quit": .init(params: ["confirmed": .enforced(.boolean, .bool(false))], required: []),
            "project.close": .init(params: [
                "confirmed": .enforced(.boolean, .bool(false)),
                "saving": .unconstrained("read as text with yes as the default"),
            ], required: []),
            "project.open": .init(params: ["confirmed": .enforced(.boolean, .bool(false)), "path": .enforced(.scalar, .string("/tmp/lpm-957.logicx"))],
                                  required: [["path"]]),
            "project.save_as": .init(params: ["confirmed": .enforced(.boolean, .bool(false)), "path": .enforced(.scalar, .string("/tmp/lpm-957.logicx"))],
                                     required: [["path"]]),
            "project.cleanup_apply": .init(params: [
                "confirmed": .enforced(.boolean, .bool(true)),
                "step_id": .unconstrained("read as text; one alias that does not read as text is skipped for the other", sample: .string("s1")),
                "stepId": .unconstrained("read as text; one alias that does not read as text is skipped for the other", sample: .string("s1")),
                "name": .unconstrained("read as text when names is absent"),
                "new_name": .unconstrained("read as text when names is absent"),
                "names": .unconstrained("an array of strings or comma-separated text; checked against the plan step"),
            ], required: [["step_id", "stepId"], ["confirmed"]]),
            "project.inspect_session": .init(params: [
                "snapshot_id": .unconstrained("a value that is not a string is read as no snapshot"),
                "allow_ui_navigation": .enforced(.boolean, .bool(false)),
                "scope": .unconstrained("checked by the inspection request's own parse"),
                "domains": .unconstrained("checked by the inspection request's own parse"),
                "project_ref": projectRef,
            ], required: []),
            "project.plan_session_repair": .init(params: Dictionary(uniqueKeysWithValues: [
                "plan_id", "digest", "snapshot_id", "policy", "names", "on_ambiguity", "allow_create_aux",
                "allow_stack_membership_change", "allow_replace_send",
            ].map { ($0, ParamRule.unconstrained("checked by the repair planner's own parse, which refuses combinations as well as types")) }),
                required: []),

            // logic_system: the saga commands validate their own wire format (they are opted out of
            // the generic unknown-parameter gate).
            "system.saga_preflight": .init(params: ["idempotency_key": .enforced(.string, .string("k-957")), "steps": .enforced(.array, .array([]))],
                                           required: [["idempotency_key"], ["steps"]]),
            "system.saga_execute": .init(params: ["idempotency_key": .enforced(.string, .string("k-957")), "steps": .enforced(.array, .array([]))],
                                         required: [["idempotency_key"], ["steps"]]),
            "system.saga_status": .init(params: ["idempotency_key": .enforced(.string, .string("k-957"))], required: [["idempotency_key"]]),
            "system.saga_cancel": .init(params: ["idempotency_key": .enforced(.string, .string("k-957"))], required: [["idempotency_key"]]),
        ]
        for op in ["export_plan", "export_run", "export_resume"] {
            var params = Dictionary(uniqueKeysWithValues: [
                "artifact", "artifacts", "collision_policy", "kind", "naming_policy", "outputRoot", "output_root",
                "path", "project", "projects",
            ].map { ($0, ParamRule.unconstrained("checked by ProjectExportPlanner.plan, whose refusals are not yet recorded by kind")) })
            if op != "export_plan" { params["confirmed"] = .enforced(.boolean, .bool(false)) }
            contracts["project.\(op)"] = .init(params: params, required: [])
        }
        for (tool, ops) in [("tracks", ["mute", "solo", "arm"])] {
            for op in ops {
                contracts["\(tool).\(op)"] = .init(params: [
                    "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
                    "enabled": .enforced(.booleanLike, .bool(true)),
                ], required: [indexGroup])
            }
        }
        contracts["tracks.arm_only"] = .init(params: [
            "index": index(), "track": index(), "target_ref": targetRef, "project_ref": projectRef,
        ], required: [indexGroup])
        return Dictionary(uniqueKeysWithValues: contracts.map { key, value in
            guard let id = OperationID(rawValue: key) else {
                preconditionFailure("#957 parameter contract names no operation: \(key)")
            }
            return (id, value)
        })
    }()
}
