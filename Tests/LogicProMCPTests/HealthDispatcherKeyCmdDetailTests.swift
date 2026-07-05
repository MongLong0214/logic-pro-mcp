import Foundation
import Testing
@testable import LogicProMCP

// T7: SystemDispatcher health detail (audited matrix + orphan ops)
// Verifies the MIDIKeyCommands channel `healthCheck()` detail string carries
// every contract piece required by PRD-issue1-keycmd-port-routing §3 AC-5.
// All tests use a started channel (available=true, ready=false) to inspect
// the post-start manualValidationRequired branch where the new copy lives.

private func t7StoreURL(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("t7-\(tag)-\(UUID().uuidString)")
        .appendingPathExtension("json")
}

private func t7StartedChannel(tag: String) async throws -> ChannelHealth {
    let store = ManualValidationStore(fileURL: t7StoreURL(tag))
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport, approvalStore: store)
    try await channel.start()
    return await channel.healthCheck()
}

@Test func testKeyCmdChannelDetailIncludesPortStatus() async throws {
    let health = try await t7StartedChannel(tag: "port-status")
    #expect(health.detail.contains("LogicProMCP-KeyCmd-Internal"))
}

@Test func testKeyCmdChannelDetailIncludesManualLearnHint() async throws {
    let health = try await t7StartedChannel(tag: "manual-learn")
    #expect(health.detail.contains("Manual MIDI Learn required"))
    #expect(health.detail.contains("docs/SETUP.md"))
}

@Test func testKeyCmdChannelDetailMentionsCoverageMatrix() async throws {
    let health = try await t7StartedChannel(tag: "coverage")
    // v3.1.7: detail now points at SETUP.md §4 (the matrix lives there) and
    // names the actual fallback channels rather than the dispatcher prefix
    // strings. Both forms answer the same caller question — "where do I
    // look to figure out which ops require a manual binding?"
    #expect(health.detail.contains("docs/SETUP.md"))
    #expect(health.detail.contains("AX/MCU/AppleScript/CGEvent fallback"))
}

@Test func testKeyCmdChannelDetailListsKeycmdOnlyOps() async throws {
    let health = try await t7StartedChannel(tag: "keycmd-only")
    // The full remaining keycmd-only/channel-only set must be surfaced in the
    // runtime health detail so an LLM agent reading channel state knows exactly
    // which ops will fail without a binding. v3.7.x removes nav.set_zoom_level
    // from this list because logic_navigate.set_zoom has an Accessibility path.
    #expect(health.detail.contains("Effectively keycmd-only"))
    #expect(health.detail.contains("transport.capture_recording"))
    #expect(health.detail.contains("edit.duplicate"))
    #expect(health.detail.contains("edit.normalize"))
    #expect(health.detail.contains("edit.toggle_step_input"))
    #expect(health.detail.contains("nav.goto_marker"))
    #expect(health.detail.contains("nav.delete_marker"))
    #expect(!health.detail.contains("nav.set_zoom_level"))
    #expect(health.detail.contains("project.bounce"))
}

@Test func testKeyCmdChannelDetailListsOrphanOps() async throws {
    let health = try await t7StartedChannel(tag: "orphan")
    #expect(health.detail.contains("automation.set_mode"))
    #expect(health.detail.contains("note.up_semitone"))
    #expect(health.detail.contains("note.up_octave"))
    #expect(health.detail.contains("note.down_semitone"))
    #expect(health.detail.contains("note.down_octave"))
    #expect(health.detail.contains("view.toggle_smart_controls"))
    #expect(health.detail.contains("view.toggle_plugin_windows"))
    #expect(health.detail.contains("view.toggle_automation"))
    #expect(health.detail.contains("CC 57"))
    #expect(health.detail.contains("automation.toggle_view"))
    #expect(health.detail.contains("CC 85"))
    #expect(health.detail.contains("track.create_stack"))
}

@Test func testKeyCmdChannelDetailUnderOneKB() async throws {
    let health = try await t7StartedChannel(tag: "size")
    let byteCount = health.detail.utf8.count
    #expect(byteCount < 1024, "detail length \(byteCount) bytes exceeds 1024 budget")
}

@Test func testKeyCmdChannelVerificationStatusUnchanged() async throws {
    let health = try await t7StartedChannel(tag: "vstatus")
    #expect(health.verificationStatus == .manualValidationRequired)
}

@Test func testKeyCmdChannelAvailableReadyUnchanged() async throws {
    let health = try await t7StartedChannel(tag: "ar")
    #expect(health.available)
    #expect(!(health.ready))
}
