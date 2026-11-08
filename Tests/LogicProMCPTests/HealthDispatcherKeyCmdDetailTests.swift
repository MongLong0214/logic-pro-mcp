import Foundation
import Testing
@testable import LogicProMCP

// T7: SystemDispatcher health detail (audited matrix + orphan ops)
// Verifies the MIDIKeyCommands channel `healthCheck()` detail string carries
// every contract piece required by PRD-issue1-keycmd-port-routing §3 AC-5.
// All tests use a started channel (available=true, ready=false) to inspect
// the post-start unattendedUnavailable branch where the new copy lives.

private func t7StoreURL(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("t7-\(tag)-\(UUID().uuidString)")
        .appendingPathExtension("json")
}

private actor T7BlockingReadinessTransport: KeyCmdTransportProtocol {
    private var prepared = false
    private var shouldBlockNextReadiness = false
    private var readinessEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func prepare() async throws {
        prepared = true
    }

    func send(_ bytes: [UInt8]) async throws {}

    func blockNextReadiness() {
        shouldBlockNextReadiness = true
        readinessEntered = false
    }

    func waitUntilReadinessEntered() async {
        if readinessEntered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func releaseReadiness() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func readiness() async -> KeyCmdTransportReadiness {
        if shouldBlockNextReadiness {
            shouldBlockNextReadiness = false
            readinessEntered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return KeyCmdTransportReadiness(
            available: prepared,
            detail: prepared ? "blocking transport ready" : "blocking transport unavailable"
        )
    }
}

private func t7StartedChannelInstance(tag: String) async throws -> MIDIKeyCommandsChannel {
    let store = ManualValidationStore(fileURL: t7StoreURL(tag))
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport, approvalStore: store)
    try await channel.start()
    return channel
}

private func t7StartedChannel(tag: String) async throws -> ChannelHealth {
    let channel = try await t7StartedChannelInstance(tag: tag)
    return await channel.healthCheck()
}

@Test func testKeyCmdChannelDetailIncludesPortStatus() async throws {
    let health = try await t7StartedChannel(tag: "port-status")
    #expect(health.detail.contains("LogicProMCP-KeyCmd-Internal"))
}

@Test func testKeyCmdChannelDetailExplainsUnattendedUnavailability() async throws {
    let health = try await t7StartedChannel(tag: "unattended-unavailable")
    #expect(health.detail.contains("unattended execution unavailable"))
    #expect(health.detail.contains("no programmatic setup or outcome readback"))
    #expect(!health.detail.contains("Manual MIDI Learn required"))
}

@Test func testKeyCmdChannelDetailMentionsCoverageMatrix() async throws {
    let health = try await t7StartedChannel(tag: "coverage")
    // The runtime detail names the actual fallback channels and the bounded
    // key-command-only set without offering a manual continuation.
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
    #expect(!health.detail.contains("edit.toggle_step_input"))
    #expect(health.detail.contains("nav.goto_marker"))
    #expect(!health.detail.contains("nav.delete_marker"))
    #expect(!health.detail.contains("nav.set_zoom_level"))
    #expect(!health.detail.contains("project.bounce"))
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

@Test func testKeyCmdChannelVerificationStatusIsUnattendedUnavailable() async throws {
    let health = try await t7StartedChannel(tag: "vstatus")
    #expect(health.verificationStatus == .unattendedUnavailable)
}

@Test func testKeyCmdChannelAvailableReadyUnchanged() async throws {
    let health = try await t7StartedChannel(tag: "ar")
    #expect(health.available)
    #expect(!(health.ready))
}

@Test func testKeyCmdChannelDetailReportsNoProcessLocalVerifiedBindingsInitially() async throws {
    let health = try await t7StartedChannel(tag: "verified-empty")
    #expect(health.detail.contains("Process-local verified bindings: 0."))
}

@Test func testKeyCmdChannelDetailReportsProcessLocalVerifiedBinding() async throws {
    let channel = try await t7StartedChannelInstance(tag: "verified-one")
    await channel.recordVerifiedBinding(operation: "transport.toggle_metronome")

    let health = await channel.healthCheck()

    #expect(health.detail.contains("Process-local verified bindings: 1 [transport.toggle_metronome]."))
    #expect(!(health.ready))
    #expect(health.verificationStatus == .unattendedUnavailable)
}

@Test func testKeyCmdChannelDetailDoesNotReportNonCatalogAssertion() async throws {
    let channel = try await t7StartedChannelInstance(tag: "verified-non-catalog")
    await channel.recordVerifiedBinding(operation: "not.catalogued")

    let health = await channel.healthCheck()

    #expect(health.detail.contains("Process-local verified bindings: 0."))
    #expect(!health.detail.contains("not.catalogued"))
}

@Test func testKeyCmdChannelStopClearsReportedProcessLocalVerifiedBindings() async throws {
    let channel = try await t7StartedChannelInstance(tag: "verified-stop")
    await channel.recordVerifiedBinding(operation: "transport.toggle_metronome")
    await channel.stop()

    let health = await channel.healthCheck()

    #expect(health.detail.contains("Process-local verified bindings: 0."))
    #expect(!health.detail.contains("[transport.toggle_metronome]"))
}

@Test func testKeyCmdChannelStopDuringReadinessClearsReportedProcessLocalVerifiedBindings() async throws {
    let transport = T7BlockingReadinessTransport()
    let store = ManualValidationStore(fileURL: t7StoreURL("verified-stop-race"))
    let channel = MIDIKeyCommandsChannel(transport: transport, approvalStore: store)
    try await channel.start()
    await channel.recordVerifiedBinding(operation: "transport.toggle_metronome")
    await transport.blockNextReadiness()

    let healthTask = Task { await channel.healthCheck() }
    await transport.waitUntilReadinessEntered()
    await channel.stop()
    await transport.releaseReadiness()
    let health = await healthTask.value

    #expect(health.detail.contains("Process-local verified bindings: 0."))
    #expect(!health.detail.contains("[transport.toggle_metronome]"))
}
