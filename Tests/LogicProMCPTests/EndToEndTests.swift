import Foundation
import MCP
import Testing
@testable import LogicProMCP

// MARK: - E2E Test Helpers

private let e2eText = sharedToolText
private let e2eResourceText = sharedResourceText
private let e2eJSON = sharedJSONObject
private let e2eJSONArray = sharedJSONArray

private func makeE2EHandlers(
    pollerRuntime: StatePoller.Runtime = .production
) async -> LogicProServerHandlers {
    let server = LogicProServer(pollerRuntime: pollerRuntime)
    return await server.makeHandlers()
}

private func e2eCall(
    _ handlers: LogicProServerHandlers,
    tool: String,
    command: String,
    params: [String: Value] = [:]
) async -> CallTool.Result {
    var args: [String: Value] = ["command": .string(command)]
    if !params.isEmpty {
        args["params"] = .object(params)
    }
    return await handlers.callTool(CallTool.Parameters(name: tool, arguments: args))
}

typealias ServerStartRecorder = SharedServerStartRecorder

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §1 Tool Dispatch: Transport (10 tests)
// ═══════════════════════════════════════════════════════════════════════

// P1-1 (D1): `get_state` is NOT a tool command — transport reads are served by
// the logic://transport/state resource (see ResourceSchemaTests). The tool must
// REJECT it as unknown, not appear alive via a non-empty error string.
@Test func testE2ETransportGetStateRejectedAsUnknownCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "get_state")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

@Test func testE2ETransportPlayDispatchesWithoutCrash() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "play")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETransportStopDispatchesWithoutCrash() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "stop")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETransportRecordDispatchesWithoutCrash() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "record")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETransportSetTempoRequiresParams() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "set_tempo")
    let text = e2eText(r)
    #expect(r.isError!)
    #expect(text.contains("invalid_params"))
    #expect(!text.isEmpty)
}

@Test func testE2ETransportSetTempoWithValue() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "set_tempo", params: ["tempo": .string("120")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETransportGotoPositionWithBar() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "goto_position", params: ["bar": .int(5)])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETransportToggleCycle() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "toggle_cycle")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETransportToggleMetronome() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "toggle_metronome")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETransportUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "nonexistent")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §2 Tool Dispatch: Tracks (10 tests)
// ═══════════════════════════════════════════════════════════════════════

// P1-1 (D1): track reads are served by logic://tracks. get_tracks/get_selected
// are not tool commands and must be rejected as unknown (false-green guard).
@Test func testE2ETracksGetTracksRejectedAsUnknownCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "get_tracks")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

@Test func testE2ETracksGetSelectedRejectedAsUnknownCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "get_selected")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

@Test func testE2ETracksSelectRequiresIndex() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "select")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETracksSelectWithIndex() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "select", params: ["index": .string("0")])
    #expect(!e2eText(r).isEmpty)
}

// P1-1 (D1): `mute`/`solo` are the production commands (old set_* names were
// stale). With no live Logic the channel chain exhausts, so the wire must be a
// structured HC envelope (success key present), never an "Unknown command".
@Test func testE2ETracksMuteIsStructuredNotUnknown() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "mute", params: ["index": .string("0"), "enabled": .string("true")])
    let text = e2eText(r)
    #expect(!text.contains("Unknown"))
    let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    #expect(obj?["success"] != nil, "mute must produce a structured HC envelope, got: \(text)")
}

@Test func testE2ETracksSoloIsStructuredNotUnknown() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "solo", params: ["index": .string("0"), "enabled": .string("true")])
    let text = e2eText(r)
    #expect(!text.contains("Unknown"))
    let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    #expect(obj?["success"] != nil, "solo must produce a structured HC envelope, got: \(text)")
}

@Test func testE2ETracksRenameWithParams() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "rename", params: ["index": .string("0"), "name": .string("Lead")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETracksCreateAudioDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "create_audio")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETracksCreateInstrumentDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "create_instrument")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETracksSetInstrumentRejectsMissingSelector() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "set_instrument", params: ["index": .int(0)])
    #expect(r.isError!)
}

@Test func testE2ETracksResolvePathRequiresPath() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "resolve_path")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Missing 'path'"))
}

@Test func testE2ETracksLibraryCommandsDispatch() async {
    let h = await makeE2EHandlers()
    let listResult = await e2eCall(h, tool: "logic_tracks", command: "list_library")
    let scanResult = await e2eCall(h, tool: "logic_tracks", command: "scan_library")
    let pluginResult = await e2eCall(
        h,
        tool: "logic_tracks",
        command: "scan_plugin_presets",
        params: ["submenuOpenDelayMs": .string("300")]
    )
    #expect(!e2eText(listResult).isEmpty)
    #expect(!e2eText(scanResult).isEmpty)
    #expect(!e2eText(pluginResult).isEmpty)
}

@Test func testE2ETracksUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "fly_to_moon")
    #expect(r.isError!)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §3 Tool Dispatch: Mixer (8 tests)
// ═══════════════════════════════════════════════════════════════════════

// P1-1 (D1): mixer reads are served by logic://mixer. get_state is not a tool
// command and must be rejected as unknown (false-green guard).
@Test func testE2EMixerGetStateRejectedAsUnknownCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "get_state")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

@Test func testE2EMixerSetVolumeDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "set_volume", params: ["index": .string("0"), "volume": .string("0.5")])
    #expect(!e2eText(r).isEmpty)
}

// v3.4.5-rc5 (Issues #10/#11) — wire-level E2E. The full
// `tools/call` → MixerDispatcher → ChannelRouter → MCUChannel path has
// two production-visible shapes when MCU is the only channel for a
// mixer write:
//
//   Shape A: MCU healthCheck.unavailable (Logic not running, or virtual
//   port unbridged + zero feedback ever received). Router never enters
//   MCUChannel.execute, so it short-circuits with HC State C
//   `port_unavailable`. The triplet diagnostic isn't appended here
//   because no MCU read happened — adding it would be dishonest.
//
//   Shape B: MCU healthCheck.healthy (some feedback observed at least
//   once) → MCUChannel.execute runs, polls for echo, returns State A or
//   State B with the connection diagnostic triplet. Covered by
//   MCUMixerWriteDiagnosticsTests at the unit level.
//
// Issue #39 — public mixer writes now use AX-local target verification when a
// visible mixer path exists. Environments without live AX access may still
// surface structured fail-closed State C envelopes instead of a verified write.
@Test func testE2EMixerSetVolumeReturnsVerifiedAXOrStructuredFailClosed() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(
        h, tool: "logic_mixer", command: "set_volume",
        params: ["track": .string("0"), "volume": .string("0.5")]
    )
    let text = e2eText(r)
    #expect(!text.isEmpty)
    guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            as? [String: Any] else {
        Issue.record("set_volume must be structured HC JSON, got: \(text)")
        return
    }
    #expect(obj["operation"] as? String == "mixer.set_volume")
    if obj["success"] as? Bool == true {
        #expect((obj["verified"] as? Bool)!)
        #expect(obj["verify_source"] as? String == "ax_slider")
        #expect(obj["target_identity"] is [String: Any])
        #expect(obj["observed_before"] != nil)
        #expect(obj["observed_after"] != nil)
    } else {
        #expect(obj["error"] != nil)
        #expect(obj["hint"] != nil)
    }
}

@Test func testE2EMixerSetPanReturnsVerifiedAXOrStructuredFailClosed() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(
        h, tool: "logic_mixer", command: "set_pan",
        params: ["track": .string("0"), "value": .string("-0.3")]
    )
    let text = e2eText(r)
    guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            as? [String: Any] else {
        Issue.record("set_pan Shape A must be structured HC JSON, got: \(text)")
        return
    }
    #expect(obj["operation"] as? String == "mixer.set_pan")
    if obj["success"] as? Bool == true {
        #expect((obj["verified"] as? Bool)!)
        #expect(obj["verify_source"] as? String == "ax_slider")
        #expect(obj["target_identity"] is [String: Any])
        #expect(obj["observed_before"] != nil)
        #expect(obj["observed_after"] != nil)
    } else {
        #expect(obj["error"] != nil)
        #expect(obj["hint"] != nil)
    }
}

@Test func testE2EMixerSetMasterVolumeShapeAIsStateCChannelsExhausted() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(
        h, tool: "logic_mixer", command: "set_master_volume",
        params: ["volume": .string("0.4")]
    )
    let text = e2eText(r)
    guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            as? [String: Any] else {
        Issue.record("set_master_volume Shape A must be structured HC JSON, got: \(text)")
        return
    }
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "channels_exhausted")
    #expect(obj["operation"] as? String == "mixer.set_master_volume")
    #expect(obj["hint"] != nil)
    #expect(obj["last_error"] != nil)
}

// Regression guard: the previous wire format leaked the free-form
// "All channels exhausted" string, which forced safety harnesses into
// regex-based root-cause detection. This test pins the structured HC
// envelope so any future refactor that reverts the wrap fails loudly.
@Test func testE2EMixerExhaustionNeverEmitsFreeFormString() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(
        h, tool: "logic_mixer", command: "set_volume",
        params: ["track": .string("0"), "volume": .string("0.5")]
    )
    let text = e2eText(r)
    #expect(
        !text.contains("All channels exhausted"),
        "wire must never emit the legacy free-form exhaustion string"
    )
    // Tester P2-4 (rc5 review) — JSONSerialization round-trip is the
    // strongest available wire-shape guard. The previous hasPrefix/hasSuffix
    // check passed for any string starting with `{` and ending with `}`,
    // including multiline JSON-ish strings or arrays embedded in text.
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
    #expect(
        parsed is [String: Any],
        "wire must be a JSON object envelope, got: \(text)"
    )
}

@Test func testE2EMixerSetPanDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "set_pan", params: ["index": .string("0"), "value": .string("0.3")])
    #expect(!e2eText(r).isEmpty)
}

// P1-1 (D1): single-strip reads are served by logic://mixer/{strip}.
// get_channel_strip is not a tool command and must be rejected as unknown.
@Test func testE2EMixerGetChannelStripRejectedAsUnknownCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "get_channel_strip", params: ["index": .string("0")])
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

@Test func testE2EMixerSetVolumeRequiresParams() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "set_volume")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMixerResetStripDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "reset_strip", params: ["index": .string("0")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMixerToggleEQDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "toggle_eq", params: ["index": .string("0")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMixerUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "explode")
    #expect(r.isError!)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §4 Tool Dispatch: MIDI (8 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EMIDISendNoteDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "send_note", params: ["note": .string("60"), "duration_ms": .string("50")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDISendCCDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "send_cc", params: ["controller": .string("7"), "value": .string("100")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDISendChordDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "send_chord", params: ["notes": .string("60,64,67"), "duration_ms": .string("50")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDIProgramChangeDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "send_program_change", params: ["program": .string("42")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDIPitchBendDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "send_pitch_bend", params: ["value": .string("8192")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDIListPortsDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "list_ports")
    #expect(r.isError != true)
    #expect(e2eText(r).contains("midi.list_ports"))
}

@Test func testE2EMIDIStepInputDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "step_input", params: ["note": .string("60"), "duration": .string("1/4")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDIUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "send_smoke_signals")
    #expect(r.isError!)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §5 Tool Dispatch: Edit (6 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EEditUndoDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_edit", command: "undo")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EEditRedoDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_edit", command: "redo")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EEditCopyDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_edit", command: "copy")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EEditPasteDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_edit", command: "paste")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EEditQuantizeDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_edit", command: "quantize", params: ["value": .string("1/16")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EEditUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_edit", command: "time_travel")
    #expect(r.isError!)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §6 Tool Dispatch: Navigate (5 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2ENavigateGotoBarDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_navigate", command: "goto_bar", params: ["bar": .int(1)])
    #expect(!e2eText(r).isEmpty)
}

// P1-1 (D1): markers are served by logic://markers. get_markers is not a tool
// command and must be rejected as unknown (false-green guard).
@Test func testE2ENavigateGetMarkersRejectedAsUnknownCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_navigate", command: "get_markers")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

@Test func testE2ENavigateCreateMarkerDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_navigate", command: "create_marker")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ENavigateZoomToFitDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_navigate", command: "zoom_to_fit")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ENavigateUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_navigate", command: "teleport")
    #expect(r.isError!)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §7 Tool Dispatch: Project (8 tests)
// ═══════════════════════════════════════════════════════════════════════

// P1-1 (D1): project info is served by logic://project/info. get_info is not a
// tool command and must be rejected as unknown (false-green guard).
@Test func testE2EProjectGetInfoRejectedAsUnknownCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "get_info")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown"))
}

@Test func testE2EProjectOpenInvalidPathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("/nonexistent/path.logicx")])
    #expect(r.isError!)
}

@Test func testE2EProjectOpenMissingPathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open")
    #expect(r.isError!)
}

@Test func testE2EProjectOpenNonLogicxFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("/tmp/file.txt")])
    #expect(r.isError!)
}

@Test func testE2EProjectSaveDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "save")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EProjectCloseDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "close", params: ["saving": .string("no")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EProjectIsRunningDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "is_running")
    let text = e2eText(r)
    #expect(!text.isEmpty)
    // Returns "true" or "false" string — both are valid
    #expect(text == "true" || text == "false" || text.contains("running"))
}

@Test func testE2EProjectExportPlanReturnsDryRunManifest() async throws {
    let h = await makeE2EHandlers()
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let project = tempRoot.appendingPathComponent("E2E Export.logicx", isDirectory: true)
    let outputRoot = tempRoot.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

    let r = await e2eCall(
        h,
        tool: "logic_project",
        command: "export_plan",
        params: [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
        ]
    )

    #expect(r.isError != true)
    let json = try #require(e2eJSON(e2eText(r)))
    #expect(json["schema"] as? String == "logic_pro_mcp_export_manifest.v1")
    #expect(json["execution_mode"] as? String == "dry_run_only")
    #expect(json["project_count"] as? Int == 1)
    let projects = try #require(json["projects"] as? [[String: Any]])
    let steps = try #require(projects.first?["workflow_steps"] as? [[String: Any]])
    #expect(steps.allSatisfy { ($0["executed"] as? Bool) == .some(false) })
}

@Test func testE2EProjectUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "reformat_hard_drive")
    #expect(r.isError!)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §8 Tool Dispatch: System (7 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2ESystemHelpReturnsComprehensiveOutput() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "help")
    let text = e2eText(r)
    #expect(text.contains("Logic Pro MCP"))
    #expect(text.contains("logic_transport"))
    #expect(text.contains("logic_tracks"))
    #expect(text.contains("logic_mixer"))
    #expect(text.contains("logic_midi"))
    #expect(text.contains("logic_edit"))
    #expect(text.contains("logic_navigate"))
    #expect(text.contains("logic_project"))
    #expect(text.contains("logic_system"))
}

@Test func testE2ESystemHealthReturnsValidJSON() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "health")
    let text = e2eText(r)
    let json = e2eJSON(text)
    #expect(json != nil, "Health response must be valid JSON")
    #expect(json?["logic_pro_running"] != nil)
    #expect(json?["logic_pro_version"] != nil)
    #expect(json?["channels"] != nil)
    #expect(json?["mcu"] != nil)
    #expect(json?["cache"] != nil)
    #expect(json?["permissions"] != nil)
    let permissions = json?["permissions"] as? [String: Any]
    #expect(permissions?["post_event_access"] != nil)
    let process = json?["process"] as? [String: Any]
    #expect(process?["memory_mb"] != nil)
    #expect(process?["cpu_percent"] != nil)
    #expect(process?["uptime_sec"] != nil)
}

@Test func testE2ESystemHealthChannelsArrayIsComplete() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "health")
    let json = e2eJSON(e2eText(r))
    let channels = json?["channels"] as? [[String: Any]]
    #expect(channels != nil)
    // Without starting channels, the health report may have 0 or 7 channels
    // depending on whether router was initialized with registered channels
    if let channels, !channels.isEmpty {
        for ch in channels {
            #expect(ch["channel"] != nil)
            #expect(ch["available"] != nil)
            #expect(ch["detail"] != nil)
        }
    }
}

@Test func testE2ESystemPermissionsDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "permissions")
    let text = e2eText(r)
    #expect(text.contains("Accessibility:"))
    #expect(text.contains("Automation (Logic Pro):"))
}

@Test func testE2ESystemRefreshDispatches() async {
    let h = await makeE2EHandlers(pollerRuntime: .fastTest)
    let r = await e2eCall(h, tool: "logic_system", command: "refresh_cache")
    #expect(!(r.isError!))
    #expect(e2eText(r).contains("State refresh"))
}

@Test func testE2ESystemCacheStateIsNotAPublicCommand() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "cache_state")
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown system command"))
}

@Test func testE2ESystemUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "self_destruct")
    #expect(r.isError!)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §9 Unknown/Invalid Tool Handling (4 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EUnknownToolNameReturnsError() async {
    // #216: on the wire an unknown tool is rejected at the protocol boundary
    // with JSON-RPC -32602 invalidParams (the SDK registration wrapper throws
    // this before dispatch). `handlers.callTool` itself keeps a defensive
    // "Unknown tool" tool-result for its unreachable internal path.
    let error = LogicProServer.toolCallProtocolError(
        name: "logic_nonexistent",
        arguments: ["command": .string("test")]
    )
    #expect(error == .invalidParams("Unknown tool: logic_nonexistent"))
    #expect(error?.code == -32602)

    let h = await makeE2EHandlers()
    let r = await h.callTool(CallTool.Parameters(name: "logic_nonexistent", arguments: ["command": .string("test")]))
    #expect(r.isError!)
    #expect(e2eText(r).contains("Unknown tool"))
}

@Test func testE2EEmptyToolNameReturnsError() async {
    // #216: an empty tool name is not a registered tool → protocol -32602.
    let error = LogicProServer.toolCallProtocolError(name: "", arguments: ["command": .string("test")])
    #expect(error?.code == -32602)

    let h = await makeE2EHandlers()
    let r = await h.callTool(CallTool.Parameters(name: "", arguments: ["command": .string("test")]))
    #expect(r.isError!)
}

@Test func testKnownToolPassesProtocolBoundary() async {
    // Every registered tool must pass the boundary check (no false -32602).
    for name in ServerCatalog.tools.map(\.name) {
        #expect(
            LogicProServer.toolCallProtocolError(name: name, arguments: ["command": .string("noop")]) == nil,
            "\(name) must not be rejected at the protocol boundary"
        )
    }
}

@Test func testE2EAllDispatchersHandleMissingCommandGracefully() async {
    let h = await makeE2EHandlers()
    let toolNames = [
        "logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
        "logic_edit", "logic_navigate", "logic_project", "logic_system"
    ]
    for name in toolNames {
        let r = await h.callTool(CallTool.Parameters(name: name, arguments: [:]))
        #expect(!e2eText(r).isEmpty, "\(name) should return non-empty for missing command")
    }
}

@Test func testE2EAllDispatchersHandleEmptyStringCommandGracefully() async {
    let h = await makeE2EHandlers()
    let toolNames = [
        "logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
        "logic_edit", "logic_navigate", "logic_project", "logic_system"
    ]
    for name in toolNames {
        let r = await e2eCall(h, tool: name, command: "")
        #expect(!e2eText(r).isEmpty, "\(name) should return non-empty for empty command")
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §10 Resource Read Chain (10 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EResourceTransportStateIsValidJSON() async throws {
    let h = await makeE2EHandlers()
    let r = try await h.readResource(.init(uri: "logic://transport/state"))
    let text = e2eResourceText(r)
    let json = e2eJSON(text)
    #expect(json != nil)
    // v3.1.1 (T-9) — transport state now uses the unified envelope:
    // { cache_age_sec, fetched_at, data: { state, has_document } }.
    // Legacy `transport_age_sec` is replaced by `cache_age_sec` at the top.
    #expect(json?.keys.contains("cache_age_sec") == true)
    #expect(json?.keys.contains("fetched_at") == true)
    let data = json?["data"] as? [String: Any]
    #expect(data != nil, "data field must carry the inner state object")
    #expect(data?["state"] != nil)
    #expect(data?["has_document"] != nil)
    let state = data?["state"] as? [String: Any]
    #expect(state?["tempo"] != nil)
}

@Test func testE2EResourceTracksIsValidJSONArray() async throws {
    let h = await makeE2EHandlers()
    let r = try await h.readResource(.init(uri: "logic://tracks"))
    let text = e2eResourceText(r)
    // v3.1.0 (T7) — tracks resource is now wrapped in a cache envelope.
    // Schema: `{cache_age_sec, fetched_at, data: [...]}`. Clients that
    // previously decoded as `[TrackState]` now read `.data`.
    let json = e2eJSON(text)
    #expect(json != nil, "tracks resource must be a JSON object envelope")
    #expect(json?.keys.contains("cache_age_sec") == true)
    #expect(json?.keys.contains("fetched_at") == true)
    #expect(json?["data"] as? [Any] != nil, "data field must be a JSON array of tracks")
}

@Test func testE2EResourceMixerContainsMCUStatus() async throws {
    let h = await makeE2EHandlers()
    let r = try await h.readResource(.init(uri: "logic://mixer"))
    let text = e2eResourceText(r)
    let json = e2eJSON(text)
    #expect(json?["mcu_connected"] != nil)
    #expect(json?["strips"] != nil)
}

@Test func testE2EResourceMIDIPortsIsValidJSON() async throws {
    let h = await makeE2EHandlers()
    let r = try await h.readResource(.init(uri: "logic://midi/ports"))
    let text = e2eResourceText(r)
    #expect(!text.isEmpty)
    let _ = try JSONSerialization.jsonObject(with: Data(text.utf8))
}

@Test func testE2EResourceStockPluginsExposeTruthLabels() async throws {
    let h = await makeE2EHandlers()
    let list = try await h.readResource(.init(uri: "logic://stock-plugins"))
    let detail = try await h.readResource(.init(uri: "logic://stock-plugins/logic.stock.effect.gain"))
    let search = try await h.readResource(.init(uri: "logic://stock-plugins/search?query=gain"))

    let listJSON = e2eJSON(e2eResourceText(list))
    let detailJSON = e2eJSON(e2eResourceText(detail))
    let searchJSON = e2eJSON(e2eResourceText(search))
    #expect(listJSON?["schema_version"] as? Int == 1)
    #expect(((listJSON?["validation"] as? [String: Any])?["is_valid"] as? Bool)!)
    #expect((detailJSON?["entry"] as? [String: Any])?["availability_state"] != nil)
    #expect((searchJSON?["entries"] as? [[String: Any]])?.isEmpty == false)
}

@Test func testE2EResourceWorkflowSkillsExposeValidatedPack() async throws {
    let h = await makeE2EHandlers()
    let list = try await h.readResource(.init(uri: "logic://workflow-skills"))
    let detail = try await h.readResource(.init(uri: "logic://workflow-skills/logic.workflow.plugins.stock_chain_plan"))
    let schema = try await h.readResource(.init(uri: "logic://workflow-skills/schema"))

    let listJSON = e2eJSON(e2eResourceText(list))
    let detailJSON = e2eJSON(e2eResourceText(detail))
    let schemaJSON = e2eJSON(e2eResourceText(schema))
    #expect(listJSON?["workflow_count"] as? Int ?? 0 >= 6)
    #expect(((listJSON?["validation"] as? [String: Any])?["is_valid"] as? Bool)!)
    #expect((detailJSON?["workflow"] as? [String: Any])?["mutation_kind"] as? String == "read_only")
    #expect((schemaJSON?["evidence_levels"] as? [String])?.contains("live_verified") == true)
}

@Test func testE2EResourceStockInstrumentsExposeProvenance() async throws {
    let h = await makeE2EHandlers()
    let instruments = try await h.readResource(.init(uri: "logic://stock-instruments"))
    let detail = try await h.readResource(.init(uri: "logic://stock-instruments/logic.stock.instrument.alchemy"))
    let search = try await h.readResource(.init(uri: "logic://stock-instruments/search?query=sampler"))
    let sessions = try await h.readResource(.init(uri: "logic://session-players/logic.session_player.drummer"))

    let instrumentsJSON = e2eJSON(e2eResourceText(instruments))
    let detailJSON = e2eJSON(e2eResourceText(detail))
    let searchJSON = e2eJSON(e2eResourceText(search))
    let sessionJSON = e2eJSON(e2eResourceText(sessions))
    #expect(instrumentsJSON?["catalog_kind"] as? String == "stock_instruments")
    let validation = try #require(instrumentsJSON?["validation"] as? [String: Any])
    #expect(try #require(validation["is_valid"] as? Bool))
    let detailEntry = try #require(detailJSON?["entry"] as? [String: Any])
    let provenance = try #require(detailEntry["provenance"] as? [[String: Any]])
    #expect(!provenance.isEmpty)
    let searchEntries = try #require(searchJSON?["entries"] as? [[String: Any]])
    #expect(searchEntries.contains { $0["id"] as? String == "logic.stock.instrument.sampler" })
    #expect((sessionJSON?["entry"] as? [String: Any])?["kind"] as? String == "drummer")
}

@Test func testE2EResourceSessionPlanIsDryRunOnly() async throws {
    let h = await makeE2EHandlers()
    let plan = try await h.readResource(.init(uri: "logic://workflow-plans/session?prompt=16-bar%20funk%20in%20E%20minor%20at%20110%20BPM%20with%20drums%2C%20bass%2C%20guitar%2C%20and%20keys"))

    let json = e2eJSON(e2eResourceText(plan))
    #expect(json?["schema"] as? String == SessionPlanGenerator.schema)
    #expect(json?["execution_mode"] as? String == "dry_run_only")
    #expect((json?["parsed_intent"] as? [String: Any])?["tempo_bpm"] as? Int == 110)
    let workflowSteps = try #require(json?["workflow_steps"] as? [[String: Any]])
    #expect(workflowSteps.allSatisfy { ($0["executed"] as? Bool) == .some(false) })

}

@Test func testE2EResourceHealthMatchesToolHealth() async throws {
    let h = await makeE2EHandlers()
    let resourceResult = try await h.readResource(.init(uri: "logic://system/health"))
    let resourceText = e2eResourceText(resourceResult)
    let toolResult = await e2eCall(h, tool: "logic_system", command: "health")
    let toolText = e2eText(toolResult)
    // Both should be valid JSON with same top-level keys
    let resourceJSON = e2eJSON(resourceText)
    let toolJSON = e2eJSON(toolText)
    #expect(resourceJSON != nil)
    #expect(toolJSON != nil)
    #expect(resourceJSON?["logic_pro_running"] != nil)
    #expect(toolJSON?["logic_pro_running"] != nil)
}

@Test func testE2EResourceUnknownURIThrows() async throws {
    let h = await makeE2EHandlers()
    await #expect(throws: MCPError.self) {
        try await h.readResource(.init(uri: "logic://nonexistent"))
    }
}

@Test func testE2EResourceTrackIndexWithNoTracksReturnsTypedOutOfRange() async throws {
    // #200: an indexed-template read on empty/out-of-range project state must
    // return a typed, classifiable body (State C index_out_of_range with the
    // requested index + available count), NOT a raw JSON-RPC -32602 the client
    // can only treat as a protocol error.
    let h = await makeE2EHandlers()
    let result = try await h.readResource(.init(uri: "logic://tracks/0"))
    let obj = sharedJSONObject(sharedResourceText(result))
    #expect((obj?["success"] as? Bool)! == false)
    #expect(obj?["error"] as? String == "index_out_of_range")
    #expect(obj?["requested_index"] as? Int == 0)
    #expect(obj?["available_count"] as? Int == 0)
}

@Test func testE2EResourceTrackIndexNegativeReturnsTypedOutOfRange() async throws {
    // A malformed negative index is out of range too — still a typed body, never
    // a raw -32602, so the indexed-template surface is internally consistent.
    let h = await makeE2EHandlers()
    let result = try await h.readResource(.init(uri: "logic://tracks/-1"))
    let obj = sharedJSONObject(sharedResourceText(result))
    #expect((obj?["success"] as? Bool)! == false)
    #expect(obj?["error"] as? String == "index_out_of_range")
    #expect(obj?["requested_index"] as? Int == -1)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §11 Server Composition & Catalog (5 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EServerCatalogHas10Tools() async {
    let snapshot = await LogicProServer().compositionSnapshot()
    #expect(snapshot.toolNames.count == 10)
    let expected = Set(["logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
                        "logic_edit", "logic_navigate", "logic_project", "logic_audio", "logic_system",
                        "logic_plugins"])
    #expect(Set(snapshot.toolNames) == expected)
}

@Test func testE2EServerCatalogAdvertisesAllResources() async {
    let snapshot = await LogicProServer().compositionSnapshot()
    #expect(snapshot.resourceURIs.count >= 16)
    let uris = Set(snapshot.resourceURIs)
    let expectedResources: Set<String> = [
        "logic://system/health",
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://markers",
        "logic://project/info",
        "logic://project/audit",
        "logic://project/cleanup-plan",
        "logic://midi/ports",
        "logic://mcu/state",
        "logic://library/inventory",
        "logic://stock-plugins",
        "logic://stock-plugins/census",
        "logic://stock-plugins/capabilities",
        "logic://stock-instruments",
        "logic://session-players",
        "logic://workflow-skills",
        "logic://workflow-skills/schema",
    ]
    #expect(expectedResources.isSubset(of: uris))
}

@Test func testE2EServerCatalogAdvertisesAllTemplates() async {
    let snapshot = await LogicProServer().compositionSnapshot()
    let expectedTemplates: Set<String> = [
        "logic://tracks/{index}",
        "logic://tracks/{index}/regions",
        "logic://mixer/{strip}",
        "logic://stock-plugins/{id}",
        "logic://stock-plugins/search?query={query}",
        "logic://stock-instruments/{id}",
        "logic://stock-instruments/search?query={query}",
        "logic://session-players/{id}",
        "logic://workflow-plans/session?prompt={prompt}",

        "logic://workflow-skills/{id}",
        "logic://workflow-skills/search?query={query}",
    ]
    #expect(expectedTemplates.isSubset(of: Set(snapshot.templateURIs)))
}

@Test func testE2EServerCatalogHas7Channels() async {
    let snapshot = await LogicProServer().compositionSnapshot()
    #expect(snapshot.channelIDs.count == 7)
    let expected: Set<ChannelID> = [.mcu, .midiKeyCommands, .scripter, .coreMIDI, .accessibility, .cgEvent, .appleScript]
    #expect(Set(snapshot.channelIDs) == expected)
}

@Test func testE2EToolSchemasHaveLogicPrefix() {
    for tool in ServerCatalog.tools {
        #expect(!tool.name.isEmpty)
        #expect(tool.name.hasPrefix("logic_"), "\(tool.name) missing prefix")
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §12 Concurrent Safety (4 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EConcurrent20ToolCallsAreSafe() async {
    let h = await makeE2EHandlers()
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<20 {
            group.addTask {
                let tools = ["logic_system", "logic_transport", "logic_tracks", "logic_mixer"]
                let cmds = ["help", "get_state", "get_tracks", "get_state"]
                let idx = i % tools.count
                let r = await e2eCall(h, tool: tools[idx], command: cmds[idx])
                #expect(!e2eText(r).isEmpty)
            }
        }
    }
}

@Test func testE2EConcurrent16ResourceReadsAreSafe() async throws {
    let h = await makeE2EHandlers()
    try await withThrowingTaskGroup(of: Void.self) { group in
        let uris = ["logic://transport/state", "logic://tracks", "logic://mixer", "logic://system/health"]
        for i in 0..<16 {
            let uri = uris[i % uris.count]
            group.addTask { let r = try await h.readResource(.init(uri: uri)); #expect(!e2eResourceText(r).isEmpty) }
        }
        try await group.waitForAll()
    }
}

@Test func testE2EConcurrentMixedToolsAndResourcesAreSafe() async throws {
    let h = await makeE2EHandlers()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<10 {
            group.addTask {
                let _ = await e2eCall(h, tool: "logic_system", command: "health")
            }
            group.addTask {
                let _ = try await h.readResource(.init(uri: "logic://system/health"))
            }
        }
        try await group.waitForAll()
    }
}

@Test func testE2EConcurrentAllToolsSameCommand() async {
    let h = await makeE2EHandlers()
    let tools = ["logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
                 "logic_edit", "logic_navigate", "logic_project", "logic_system"]
    await withTaskGroup(of: Void.self) { group in
        for tool in tools {
            group.addTask {
                let r = await e2eCall(h, tool: tool, command: "help")
                #expect(!e2eText(r).isEmpty)
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §13 Lifecycle Scenarios (5 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2ELifecycleFullStartServeShutdown() async throws {
    let rec = ServerStartRecorder()
    let server = LogicProServer(runtimeOverrides: .init(
        startPorts: { await rec.record("startPorts") },
        registerChannels: { await rec.record("registerChannels") },
        startChannels: { await rec.record("startChannels"); return .init(started: [.accessibility, .coreMIDI, .mcu], failures: [:], degraded: [:]) },
        startPoller: { await rec.record("startPoller") },
        registerHandlers: { await rec.record("registerHandlers") },
        serve: { await rec.record("serve") },
        stopPoller: { await rec.record("stopPoller") },
        stopChannels: { await rec.record("stopChannels") },
        stopPorts: { await rec.record("stopPorts") }
    ))
    try await server.start()
    #expect(await rec.snapshot() == ["startPorts", "registerChannels", "startChannels", "startPoller", "registerHandlers", "serve", "stopPoller", "stopChannels", "stopPorts"])
}

@Test func testE2ELifecycleDegradedContinues() async throws {
    let rec = ServerStartRecorder()
    let server = LogicProServer(runtimeOverrides: .init(
        startPorts: { await rec.record("startPorts") },
        registerChannels: { await rec.record("registerChannels") },
        startChannels: { return .init(started: [.coreMIDI], failures: [:], degraded: [.accessibility: "Not trusted"]) },
        startPoller: { await rec.record("startPoller") },
        registerHandlers: { await rec.record("registerHandlers") },
        serve: { await rec.record("serve") },
        stopPoller: { await rec.record("stopPoller") },
        stopChannels: { await rec.record("stopChannels") },
        stopPorts: { await rec.record("stopPorts") }
    ))
    try await server.start()
    #expect(await rec.snapshot().contains("serve"))
}

@Test func testE2ELifecycleCriticalFailureAbortsAndCleans() async {
    let rec = ServerStartRecorder()
    let server = LogicProServer(runtimeOverrides: .init(
        startPorts: { await rec.record("startPorts") },
        registerChannels: { await rec.record("registerChannels") },
        startChannels: { return .init(started: [], failures: [.mcu: "MIDI unavailable"], degraded: [:]) },
        stopChannels: { await rec.record("stopChannels") },
        stopPorts: { await rec.record("stopPorts") }
    ))
    await #expect(throws: LogicProServer.StartupError.self) { try await server.start() }
    let events = await rec.snapshot()
    #expect(events.contains("stopChannels"))
    #expect(events.contains("stopPorts"))
    #expect(!events.contains("serve"))
}

@Test func testE2ELifecycleMultipleDegradedChannels() async throws {
    let server = LogicProServer(runtimeOverrides: .init(
        startPorts: {},
        registerChannels: {},
        startChannels: { .init(started: [.appleScript], failures: [:], degraded: [.accessibility: "Not trusted", .mcu: "Port busy", .coreMIDI: "No client"]) },
        startPoller: {},
        registerHandlers: {},
        serve: {},
        stopPoller: {},
        stopChannels: {},
        stopPorts: {}
    ))
    try await server.start()
}

@Test func testE2ELifecycleServeThrowsCleansUp() async {
    let rec = ServerStartRecorder()
    struct ServeError: Error {}
    let server = LogicProServer(runtimeOverrides: .init(
        startPorts: { await rec.record("startPorts") },
        registerChannels: {},
        startChannels: { .init(started: [.coreMIDI], failures: [:], degraded: [:]) },
        startPoller: { await rec.record("startPoller") },
        registerHandlers: {},
        serve: { throw ServeError() },
        stopPoller: { await rec.record("stopPoller") },
        stopChannels: { await rec.record("stopChannels") },
        stopPorts: { await rec.record("stopPorts") }
    ))
    do { try await server.start() } catch {}
    let events = await rec.snapshot()
    #expect(events.contains("stopPoller"))
    #expect(events.contains("stopChannels"))
    #expect(events.contains("stopPorts"))
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §14 Input Validation at MCP Boundary (5 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EProjectOpenWithControlCharacterPathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("/tmp/evil\n.logicx")])
    #expect(r.isError!)
}

@Test func testE2EProjectOpenWithRelativePathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("relative/song.logicx")])
    #expect(r.isError!)
}

@Test func testE2EProjectOpenWithDevPathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("/dev/null.logicx")])
    #expect(r.isError!)
}

@Test func testE2ETracksSelectWithNonNumericIndexHandled() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "select", params: ["index": .string("abc")])
    let text = e2eText(r)
    #expect(!text.isEmpty)
}

@Test func testE2EMixerSetVolumeWithNonNumericValueHandled() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "set_volume", params: ["index": .string("abc"), "volume": .string("not_a_number")])
    #expect(!e2eText(r).isEmpty)
}
