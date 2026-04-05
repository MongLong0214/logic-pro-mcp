import Testing
@testable import LogicProMCP

// CoreMIDI port creation requires a running WindowServer (not available in headless CI).
// Actual port creation was verified in Phase 0 spike (see docs/spike-results.md).
// These tests verify MIDIPortManager logic without CoreMIDI dependency.

@Test func testMIDIPortManagerStartStopCycle() async throws {
    let manager = MIDIPortManager()
    // stop() on a non-started manager should be safe
    await manager.stop()
    #expect(await manager.portCount == 0)
}

@Test func testMIDIPortManagerPortCountStartsAtZero() async {
    let manager = MIDIPortManager()
    #expect(await manager.portCount == 0)
}

@Test func testMIDIPortManagerGetNonexistentPort() async {
    let manager = MIDIPortManager()
    let port = await manager.getPort(name: "nonexistent")
    #expect(port == nil)
}
