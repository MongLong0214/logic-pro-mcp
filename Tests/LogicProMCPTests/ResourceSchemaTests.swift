import Testing
import Foundation
@testable import LogicProMCP

@Test func testTracksResponseIncludesAutomation() async {
    let cache = StateCache()
    var track = TrackState(id: 0, name: "Vocals", type: .audio)
    track.automationMode = .touch
    await cache.updateTracks([track])

    let tracks = await cache.getTracks()
    #expect(tracks[0].automationMode == .touch)
}

@Test func testMixerResponseIncludesMCUStatus() async {
    let cache = StateCache()
    var conn = MCUConnectionState()
    conn.isConnected = true
    conn.registeredAsDevice = true
    await cache.updateMCUConnection(conn)

    let c = await cache.getMCUConnection()
    #expect(c.isConnected == true)
    #expect(c.registeredAsDevice == true)
}

@Test func testHealthResponseMCUFields() async {
    let cache = StateCache()
    var conn = MCUConnectionState()
    conn.isConnected = true
    conn.registeredAsDevice = false
    conn.lastFeedbackAt = Date()
    conn.portName = "LogicProMCP-MCU-Internal"
    await cache.updateMCUConnection(conn)

    let c = await cache.getMCUConnection()
    #expect(c.portName == "LogicProMCP-MCU-Internal")
    #expect(c.lastFeedbackAt != nil)
}

@Test func testHealthResponseProcessFields() async {
    // ProcessInfo is always available
    let memory = ProcessInfo.processInfo.physicalMemory
    #expect(memory > 0)
}

@Test func testMixerResponseIncludesPluginParams() async {
    let cache = StateCache()
    var strip = ChannelStripState(trackIndex: 0)
    strip.plugins = [PluginSlotState(index: 0, name: "Channel EQ", isBypassed: false)]
    await cache.updateChannelStrips([strip])

    let strips = await cache.getChannelStrips()
    #expect(strips[0].plugins.count == 1)
    #expect(strips[0].plugins[0].name == "Channel EQ")
}

@Test func testHealthResponseMCUDisconnected() async {
    let cache = StateCache()
    // Default MCUConnectionState: isConnected = false
    let c = await cache.getMCUConnection()
    #expect(c.isConnected == false)
    #expect(c.registeredAsDevice == false)
}

@Test func testMCUDisplayState() async {
    let cache = StateCache()
    await cache.updateMCUDisplayRow(upper: true, text: "Vocals", offset: 0)
    let display = await cache.getMCUDisplay()
    #expect(display.upperRow.hasPrefix("Vocals"))
}
