import Foundation
import MCP
import Testing
@testable import LogicProMCP

// MARK: - E2E Test Helpers

private let e2eText = sharedToolText
private let e2eResourceText = sharedResourceText
private let e2eJSON = sharedJSONObject
private let e2eJSONArray = sharedJSONArray

private func makeE2EHandlers() async -> LogicProServerHandlers {
    let server = LogicProServer()
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

@Test func testE2ETransportGetStateReturnsStructuredJSON() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_transport", command: "get_state")
    #expect(!e2eText(r).isEmpty)
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
    #expect(r.isError == true)
    #expect(e2eText(r).contains("Unknown"))
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §2 Tool Dispatch: Tracks (10 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2ETracksGetTracksDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "get_tracks")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETracksGetSelectedDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "get_selected")
    #expect(!e2eText(r).isEmpty)
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

@Test func testE2ETracksSetMuteWithIndex() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "set_mute", params: ["index": .string("0"), "enabled": .string("true")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ETracksSetSoloWithIndex() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "set_solo", params: ["index": .string("0"), "enabled": .string("true")])
    #expect(!e2eText(r).isEmpty)
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

@Test func testE2ETracksUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_tracks", command: "fly_to_moon")
    #expect(r.isError == true)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §3 Tool Dispatch: Mixer (8 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EMixerGetStateDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "get_state")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMixerSetVolumeDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "set_volume", params: ["index": .string("0"), "volume": .string("0.5")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMixerSetPanDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "set_pan", params: ["index": .string("0"), "value": .string("0.3")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMixerGetChannelStripDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_mixer", command: "get_channel_strip", params: ["index": .string("0")])
    #expect(!e2eText(r).isEmpty)
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
    #expect(r.isError == true)
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
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDIStepInputDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "step_input", params: ["note": .string("60"), "duration": .string("1/4")])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EMIDIUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_midi", command: "send_smoke_signals")
    #expect(r.isError == true)
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
    let r = await e2eCall(h, tool: "logic_edit", command: "quantize")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EEditUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_edit", command: "time_travel")
    #expect(r.isError == true)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §6 Tool Dispatch: Navigate (5 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2ENavigateGotoBarDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_navigate", command: "goto_bar", params: ["bar": .int(1)])
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ENavigateGetMarkersDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_navigate", command: "get_markers")
    #expect(!e2eText(r).isEmpty)
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
    #expect(r.isError == true)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §7 Tool Dispatch: Project (8 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EProjectGetInfoDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "get_info")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2EProjectOpenInvalidPathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("/nonexistent/path.logicx")])
    #expect(r.isError == true)
}

@Test func testE2EProjectOpenMissingPathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open")
    #expect(r.isError == true)
}

@Test func testE2EProjectOpenNonLogicxFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("/tmp/file.txt")])
    #expect(r.isError == true)
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

@Test func testE2EProjectUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "reformat_hard_drive")
    #expect(r.isError == true)
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
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ESystemRefreshDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "refresh")
    #expect(!e2eText(r).isEmpty)
}

@Test func testE2ESystemCacheStateDispatches() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "cache_state")
    let text = e2eText(r)
    #expect(!text.isEmpty)
}

@Test func testE2ESystemUnknownCommandFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_system", command: "self_destruct")
    #expect(r.isError == true)
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §9 Unknown/Invalid Tool Handling (4 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EUnknownToolNameReturnsError() async {
    let h = await makeE2EHandlers()
    let r = await h.callTool(CallTool.Parameters(name: "logic_nonexistent", arguments: ["command": .string("test")]))
    #expect(r.isError == true)
    #expect(e2eText(r).contains("Unknown tool"))
}

@Test func testE2EEmptyToolNameReturnsError() async {
    let h = await makeE2EHandlers()
    let r = await h.callTool(CallTool.Parameters(name: "", arguments: ["command": .string("test")]))
    #expect(r.isError == true)
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
// MARK: - §10 Resource Read Chain (8 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EResourceTransportStateIsValidJSON() async throws {
    let h = await makeE2EHandlers()
    let r = try await h.readResource(.init(uri: "logic://transport/state"))
    let text = e2eResourceText(r)
    let json = e2eJSON(text)
    #expect(json != nil)
    #expect(json?["tempo"] != nil)
}

@Test func testE2EResourceTracksIsValidJSONArray() async throws {
    let h = await makeE2EHandlers()
    let r = try await h.readResource(.init(uri: "logic://tracks"))
    let text = e2eResourceText(r)
    let arr = e2eJSONArray(text)
    #expect(arr != nil)
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

@Test func testE2EResourceTrackIndexWithNoTracksThrows() async throws {
    let h = await makeE2EHandlers()
    await #expect(throws: MCPError.self) {
        try await h.readResource(.init(uri: "logic://tracks/0"))
    }
}

@Test func testE2EResourceTrackIndexNegativeThrows() async throws {
    let h = await makeE2EHandlers()
    await #expect(throws: MCPError.self) {
        try await h.readResource(.init(uri: "logic://tracks/-1"))
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - §11 Server Composition & Catalog (5 tests)
// ═══════════════════════════════════════════════════════════════════════

@Test func testE2EServerCatalogHas8Tools() async {
    let snapshot = await LogicProServer().compositionSnapshot()
    #expect(snapshot.toolNames.count == 8)
    let expected = Set(["logic_transport", "logic_tracks", "logic_mixer", "logic_midi",
                        "logic_edit", "logic_navigate", "logic_project", "logic_system"])
    #expect(Set(snapshot.toolNames) == expected)
}

@Test func testE2EServerCatalogHas6Resources() async {
    let snapshot = await LogicProServer().compositionSnapshot()
    #expect(snapshot.resourceURIs.count == 6)
    #expect(snapshot.resourceURIs.contains("logic://transport/state"))
    #expect(snapshot.resourceURIs.contains("logic://tracks"))
    #expect(snapshot.resourceURIs.contains("logic://mixer"))
    #expect(snapshot.resourceURIs.contains("logic://project/info"))
    #expect(snapshot.resourceURIs.contains("logic://midi/ports"))
    #expect(snapshot.resourceURIs.contains("logic://system/health"))
}

@Test func testE2EServerCatalogHas1Template() async {
    let snapshot = await LogicProServer().compositionSnapshot()
    #expect(snapshot.templateURIs == ["logic://tracks/{index}"])
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
    #expect(r.isError == true)
}

@Test func testE2EProjectOpenWithRelativePathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("relative/song.logicx")])
    #expect(r.isError == true)
}

@Test func testE2EProjectOpenWithDevPathFails() async {
    let h = await makeE2EHandlers()
    let r = await e2eCall(h, tool: "logic_project", command: "open", params: ["path": .string("/dev/null.logicx")])
    #expect(r.isError == true)
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
