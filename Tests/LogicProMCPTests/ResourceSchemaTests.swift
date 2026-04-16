import Testing
import Foundation
import MCP
@testable import LogicProMCP

private func resourceText(_ result: ReadResource.Result) -> String {
    guard !result.contents.isEmpty else {
        Issue.record("Expected text resource content")
        return "{}"
    }
    if let text = result.contents[0].text {
        return text
    }
    Issue.record("Expected text resource content")
    return "{}"
}

private func toolText(_ result: CallTool.Result) -> String {
    guard !result.content.isEmpty else {
        Issue.record("Expected text tool content")
        return "{}"
    }
    switch result.content[0] {
    case .text(let text, _, _):
        return text
    default:
        break
    }
    Issue.record("Expected text tool content")
    return "{}"
}

private func normalizedHealthJSON(_ text: String) throws -> [String: Any] {
    var json = try sharedParseJSON(text) as! [String: Any]

    if var cache = json["cache"] as? [String: Any] {
        cache.removeValue(forKey: "transport_age_sec")
        json["cache"] = cache
    }

    if var mcu = json["mcu"] as? [String: Any] {
        mcu.removeValue(forKey: "last_feedback_at")
        json["mcu"] = mcu
    }

    json.removeValue(forKey: "logic_pro_version")
    json.removeValue(forKey: "process")
    return json
}

@Test func testTracksResponseIncludesAutomation() async {
    let cache = StateCache()
    var track = TrackState(id: 0, name: "Vocals", type: .audio)
    track.automationMode = .touch
    await cache.updateTracks([track])
    let router = ChannelRouter()

    let result = try! await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router)
    let json = try! sharedParseJSON(resourceText(result)) as! [[String: Any]]
    #expect(json.count == 1)
    #expect(json[0]["automationMode"] as? String == "touch")
}

@Test func testTracksResponseIncludesTrimAutomationMode() async {
    let cache = StateCache()
    var track = TrackState(id: 0, name: "Lead", type: .audio)
    track.automationMode = .trim
    await cache.updateTracks([track])

    let result = try! await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: ChannelRouter())
    let json = try! sharedParseJSON(resourceText(result)) as! [[String: Any]]
    #expect(json.count == 1)
    #expect(json[0]["automationMode"] as? String == "trim")
}

@Test func testTransportStateResourceIncludesCachedFields() async {
    let cache = StateCache()
    var transport = TransportState()
    transport.isPlaying = true
    transport.isCycleEnabled = true
    transport.tempo = 128.5
    transport.position = "9.1.1.1"
    transport.timePosition = "00:01:23.456"
    await cache.updateTransport(transport)
    let router = ChannelRouter()

    let result = try! await ResourceHandlers.read(uri: "logic://transport/state", cache: cache, router: router)
    let json = try! sharedParseJSON(resourceText(result)) as! [String: Any]
    #expect(json["isPlaying"] as? Bool == true)
    #expect(json["isCycleEnabled"] as? Bool == true)
    #expect(json["tempo"] as? Double == 128.5)
    #expect(json["position"] as? String == "9.1.1.1")
    #expect(json["timePosition"] as? String == "00:01:23.456")
}

@Test func testMixerResponseIncludesMCUStatus() async {
    let cache = StateCache()
    var conn = MCUConnectionState()
    conn.isConnected = true
    conn.registeredAsDevice = true
    await cache.updateMCUConnection(conn)
    var strip = ChannelStripState(trackIndex: 0)
    strip.volume = 0.75
    await cache.updateChannelStrips([strip])
    let router = ChannelRouter()

    let result = try! await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router)
    let json = try! sharedParseJSON(resourceText(result)) as! [String: Any]
    #expect(json["mcu_connected"] as? Bool == true)
    #expect(json["registered"] as? Bool == true)
    #expect((json["strips"] as? [[String: Any]])?.count == 1)
}

@Test func testTrackResourceReturnsRequestedIndex() async {
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 0, name: "Kick", type: .audio),
        TrackState(id: 1, name: "Bass", type: .softwareInstrument),
    ])
    let router = ChannelRouter()

    let result = try! await ResourceHandlers.read(uri: "logic://tracks/1", cache: cache, router: router)
    let json = try! sharedParseJSON(resourceText(result)) as! [String: Any]
    #expect(json["id"] as? Int == 1)
    #expect(json["name"] as? String == "Bass")
    #expect(json["type"] as? String == "software_instrument")
}

@Test func testTrackResourceRejectsMissingIndex() async {
    let cache = StateCache()
    await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])
    let router = ChannelRouter()

    await #expect(throws: MCPError.self) {
        try await ResourceHandlers.read(uri: "logic://tracks/99", cache: cache, router: router)
    }
}

@Test func testTracksAndProjectResourcesReturnEmptyDataWhenNoDocumentOpen() async throws {
    // Post-hardening: hasDocument gate was removed because the StatePoller's
    // view of "document open" can flap during normal Logic UI activity. When
    // hasDocument is false the cache returns its empty-state representation
    // (empty array / empty struct) — clients distinguish this from missing.
    let cache = StateCache()
    let router = ChannelRouter()
    await cache.updateDocumentState(false)

    let tracks = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router)
    #expect(tracks.contents.first?.text?.contains("[") == true)

    let project = try await ResourceHandlers.read(uri: "logic://project/info", cache: cache, router: router)
    #expect(project.contents.first?.text != nil)

    let mixer = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router)
    #expect(mixer.contents.first?.text != nil)
}

@Test func testHealthResponseMCUFields() async {
    let cache = StateCache()
    var conn = MCUConnectionState()
    conn.isConnected = true
    conn.registeredAsDevice = false
    conn.lastFeedbackAt = Date()
    conn.portName = "LogicProMCP-MCU-Internal"
    await cache.updateMCUConnection(conn)
    let router = ChannelRouter()

    let result = await SystemDispatcher.handle(command: "health", params: [:], router: router, cache: cache)
    let json = try! sharedParseJSON(toolText(result)) as! [String: Any]
    let mcu = (json["mcu"] as? [String: Any]) ?? [:]
    let connected = mcu["connected"] as? Bool
    let registered = mcu["registered_as_device"] as? Bool
    let portName = mcu["port_name"] as? String
    let lastFeedbackAt = mcu["last_feedback_at"] as? String
    #expect(connected == true)
    #expect(registered == false)
    #expect(portName == "LogicProMCP-MCU-Internal")
    #expect(lastFeedbackAt != nil)
}

@Test func testHealthResponseProcessFields() async {
    let cache = StateCache()
    let router = ChannelRouter()

    let result = await SystemDispatcher.handle(command: "health", params: [:], router: router, cache: cache)
    let json = try! sharedParseJSON(toolText(result)) as! [String: Any]
    let process = (json["process"] as? [String: Any]) ?? [:]
    let memoryMB = process["memory_mb"] as? Double
    let cpuPercent = process["cpu_percent"] as? Double
    let uptimeSec = process["uptime_sec"] as? Int
    #expect((memoryMB ?? -1) >= 0)
    #expect((cpuPercent ?? -1) >= 0)
    #expect((uptimeSec ?? -1) >= 0)
}

@Test func testMixerResponseIncludesPluginParams() async {
    let cache = StateCache()
    var strip = ChannelStripState(trackIndex: 0)
    strip.plugins = [PluginSlotState(index: 0, name: "Channel EQ", isBypassed: false)]
    await cache.updateChannelStrips([strip])
    let router = ChannelRouter()

    let result = try! await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router)
    let json = try! sharedParseJSON(resourceText(result)) as! [String: Any]
    let strips = (json["strips"] as? [[String: Any]]) ?? []
    let firstStrip = strips.first ?? [:]
    let plugins = (firstStrip["plugins"] as? [[String: Any]]) ?? []
    let firstPlugin = plugins.first ?? [:]
    let pluginName = firstPlugin["name"] as? String
    #expect(plugins.count == 1)
    #expect(pluginName == "Channel EQ")
}

@Test func testProjectInfoResourceIncludesMetadata() async {
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Commercial Mix"
    project.sampleRate = 48000
    project.bitDepth = 32
    project.trackCount = 42
    project.filePath = "/tmp/commercial.logicx"
    await cache.updateProject(project)
    let router = ChannelRouter()

    let result = try! await ResourceHandlers.read(uri: "logic://project/info", cache: cache, router: router)
    let json = try! sharedParseJSON(resourceText(result)) as! [String: Any]
    #expect(json["name"] as? String == "Commercial Mix")
    #expect(json["sampleRate"] as? Int == 48000)
    #expect(json["bitDepth"] as? Int == 32)
    #expect(json["trackCount"] as? Int == 42)
    #expect(json["filePath"] as? String == "/tmp/commercial.logicx")
}

@Test func testMIDIPortsResourcePassesThroughRouterListing() async {
    let cache = StateCache()
    let router = ChannelRouter()
    let coreMIDI = MockChannel(id: .coreMIDI)
    await router.register(coreMIDI)

    let result = try! await ResourceHandlers.read(uri: "logic://midi/ports", cache: cache, router: router)

    let json = try! sharedParseJSON(resourceText(result)) as! [String: Any]
    #expect(json["message"] as? String == "Mock: midi.list_ports")
    let ops = await coreMIDI.executedOps
    #expect(ops.count == 1)
    #expect(ops[0].0 == "midi.list_ports")
}

@Test func testHealthResponseMCUDisconnected() async {
    let cache = StateCache()
    let router = ChannelRouter()
    let result = await SystemDispatcher.handle(command: "health", params: [:], router: router, cache: cache)
    let json = try! sharedParseJSON(toolText(result)) as! [String: Any]
    let mcu = (json["mcu"] as? [String: Any]) ?? [:]
    let connected = mcu["connected"] as? Bool
    let registered = mcu["registered_as_device"] as? Bool
    #expect(connected == false)
    #expect(registered == false)
}

@Test func testMCUDisplayState() async {
    let cache = StateCache()
    await cache.updateMCUDisplayRow(upper: true, text: "Vocals", offset: 0)
    let display = await cache.getMCUDisplay()
    #expect(display.upperRow.hasPrefix("Vocals"))
}

@Test func testHealthResponseFullSchema() async {
    let cache = StateCache()
    let router = ChannelRouter()
    let mockChannel = MockChannel(id: .mcu)
    await router.register(mockChannel)

    let result = await SystemDispatcher.handle(command: "health", params: [:], router: router, cache: cache)
    let json = try! sharedParseJSON(toolText(result)) as! [String: Any]
    #expect(json["logic_pro_running"] as? Bool != nil)
    #expect(json["logic_pro_version"] as? String != nil)
    #expect(json["mcu"] as? [String: Any] != nil)
    #expect(json["channels"] as? [[String: Any]] != nil)
    #expect(json["cache"] as? [String: Any] != nil)
    let permissions = json["permissions"] as? [String: Any]
    #expect(permissions != nil)
    #expect(permissions?["accessibility_status"] as? String != nil)
    #expect(permissions?["automation_status"] as? String != nil)
    #expect(permissions?["automation_verifiable"] as? Bool != nil)
    #expect(permissions?["automation_granted"] == nil || permissions?["automation_granted"] as? Bool != nil)
    #expect(json["process"] as? [String: Any] != nil)
}

@Test func testHealthResponseExposesChannelVerificationStatus() async {
    let cache = StateCache()
    let router = ChannelRouter()
    await router.register(MockChannel(id: .midiKeyCommands, healthOverride: .healthy(
        detail: "Preset installation is not verifiable programmatically",
        verificationStatus: .manualValidationRequired
    )))
    await router.register(MockChannel(id: .scripter, healthOverride: .healthy(
        detail: "Scripter insertion is not verifiable programmatically",
        verificationStatus: .manualValidationRequired
    )))

    let result = await SystemDispatcher.handle(command: "health", params: [:], router: router, cache: cache)
    let json = try! sharedParseJSON(toolText(result)) as! [String: Any]
    let channels = (json["channels"] as? [[String: Any]]) ?? []
    let byName: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: channels.compactMap { entry in
        guard let name = entry["channel"] as? String else { return nil }
        return (name, entry)
    })

    #expect(byName["MIDIKeyCommands"]?["verification_status"] as? String == "manual_validation_required")
    #expect(byName["MIDIKeyCommands"]?["ready"] as? Bool == false)
    #expect(byName["Scripter"]?["verification_status"] as? String == "manual_validation_required")
    #expect(byName["Scripter"]?["ready"] as? Bool == false)
}

@Test func testSystemHealthToolMatchesResource() async {
    let cache = StateCache()
    let router = ChannelRouter()
    let mockChannel = MockChannel(id: .mcu)
    await router.register(mockChannel)

    let toolResult = await SystemDispatcher.handle(command: "health", params: [:], router: router, cache: cache)
    let resourceResult = try! await ResourceHandlers.read(uri: "logic://system/health", cache: cache, router: router)
    let toolJSON = try! normalizedHealthJSON(toolText(toolResult))
    let resourceJSON = try! normalizedHealthJSON(resourceText(resourceResult))
    #expect(toolJSON as NSDictionary == resourceJSON as NSDictionary)
}

@Test func testResourceHandlersRejectUnknownURI() async {
    let cache = StateCache()
    let router = ChannelRouter()

    await #expect(throws: MCPError.self) {
        try await ResourceHandlers.read(uri: "logic://unknown/resource", cache: cache, router: router)
    }
}
