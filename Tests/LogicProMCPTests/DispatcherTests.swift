import Testing
import Foundation
@testable import LogicProMCP

// MARK: - MixerDispatcher

@Test func testMixerDispatcherSetVolume() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "set_volume",
        params: ["track": .int(2), "value": .double(0.7)],
        router: router, cache: cache
    )
    #expect(!result.isError!)

    let ops = await mcu.executedOps
    #expect(ops[0].0 == "mixer.set_volume")
    #expect(ops[0].1["index"] == "2")
    #expect(ops[0].1["volume"] == "0.7")
}

@Test func testMixerDispatcherSetPluginParam() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)
    let cache = StateCache()

    let result = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(1), "insert": .int(0), "param": .int(3), "value": .double(0.5)],
        router: router, cache: cache
    )
    #expect(!result.isError!)
}

@Test func testMixerDispatcherUnknown() async {
    let router = ChannelRouter()
    let cache = StateCache()
    let result = await MixerDispatcher.handle(command: "nonexistent", params: [:], router: router, cache: cache)
    #expect(result.isError!)
}

// MARK: - TrackDispatcher

@Test func testTrackDispatcherMuteUsesEnabled() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)
    let cache = StateCache()

    _ = await TrackDispatcher.handle(
        command: "mute",
        params: ["index": .int(3), "enabled": .bool(true)],
        router: router, cache: cache
    )

    let ops = await mcu.executedOps
    #expect(ops[0].1["enabled"] == "true") // not "muted"
}

@Test func testTrackDispatcherSetAutomation() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)
    let cache = StateCache()

    let result = await TrackDispatcher.handle(
        command: "set_automation",
        params: ["index": .int(1), "mode": .string("touch")],
        router: router, cache: cache
    )
    #expect(!result.isError!)
}

// MARK: - EditDispatcher

@Test func testEditDispatcherToggleStepInput() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)
    let cache = StateCache()

    let result = await EditDispatcher.handle(command: "toggle_step_input", params: [:], router: router, cache: cache)
    #expect(!result.isError!)
}

// MARK: - ProjectDispatcher + DestructivePolicy

@Test func testProjectDispatcherQuitRequiresConfirmation() async {
    let router = ChannelRouter()
    let cache = StateCache()

    let result = await ProjectDispatcher.handle(command: "quit", params: [:], router: router, cache: cache)
    // Should return confirmation_required, not actually quit
    #expect(!result.isError!)
    if case .text(let text, _, _) = result.content.first {
        #expect(text.contains("confirmation_required"))
    }
}

@Test func testProjectDispatcherSaveNoConfirmation() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)
    let cache = StateCache()

    let result = await ProjectDispatcher.handle(command: "save", params: [:], router: router, cache: cache)
    // Save is L1 — should execute immediately (no confirmation)
    #expect(!result.isError!)
}

// MARK: - MIDIDispatcher

@Test func testMIDIDispatcherStepInput() async {
    let router = ChannelRouter()
    let coreMidi = MockChannel(id: .coreMIDI)
    await router.register(coreMidi)
    let cache = StateCache()

    let result = await MIDIDispatcher.handle(
        command: "step_input",
        params: ["note": .int(60), "duration": .string("1/4")],
        router: router, cache: cache
    )
    #expect(!result.isError!)
}
