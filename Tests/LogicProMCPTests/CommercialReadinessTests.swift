import Foundation
import MCP
import Testing
@testable import LogicProMCP

private let toolText = sharedToolText

@Test func testTransportDispatcherGotoPositionBarFormatsBarPosition() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await TransportDispatcher.handle(
        command: "goto_position",
        params: ["bar": .int(9)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError == false)
    let ops = await mcu.executedOps
    #expect(ops.first?.0 == "transport.goto_position")
    #expect(ops.first?.1["position"] == "9.1.1.1")
}

@Test func testTransportDispatcherSetCycleRangeUsesAccessibilityChannel() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TransportDispatcher.handle(
        command: "set_cycle_range",
        params: ["start": .int(2), "end": .int(5)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError == false)
    let ops = await ax.executedOps
    #expect(ops.first?.0 == "transport.set_cycle_range")
    #expect(ops.first?.1["start"] == "2.1.1.1")
    #expect(ops.first?.1["end"] == "5.1.1.1")
}

@Test func testTransportDispatcherUnknownFails() async {
    let result = await TransportDispatcher.handle(
        command: "invalid",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == true)
    #expect(toolText(result).contains("Unknown transport command"))
}

@Test func testNavigateDispatcherGotoMarkerByNameUsesCachedMarker() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)
    let cache = StateCache()
    await cache.updateMarkers([MarkerState(id: 7, name: "Verse", position: "7.1.1.1")])

    let result = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["name": .string("ver")],
        router: router,
        cache: cache
    )

    #expect(result.isError == false)
    let ops = await keyCmd.executedOps
    #expect(ops.first?.0 == "nav.goto_marker")
    #expect(ops.first?.1["index"] == "7")
}

@Test func testNavigateDispatcherRenameMarkerUsesAccessibilityChannel() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await NavigateDispatcher.handle(
        command: "rename_marker",
        params: ["index": .int(3), "name": .string("Hook")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError == false)
    let ops = await ax.executedOps
    #expect(ops.first?.0 == "nav.rename_marker")
    #expect(ops.first?.1["index"] == "3")
    #expect(ops.first?.1["name"] == "Hook")
}

@Test func testNavigateDispatcherToggleViewRejectsUnknownView() async {
    let result = await NavigateDispatcher.handle(
        command: "toggle_view",
        params: ["view": .string("console")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == true)
    #expect(toolText(result).contains("Unknown view"))
}

@Test func testMIDIDispatcherSendChordSerializesArrayNotes() async {
    let router = ChannelRouter()
    let coreMIDI = MockChannel(id: .coreMIDI)
    await router.register(coreMIDI)

    let result = await MIDIDispatcher.handle(
        command: "send_chord",
        params: [
            "notes": .array([.int(60), .int(64), .int(67)]),
            "velocity": .int(90),
            "channel": .int(2),
            "duration_ms": .int(750),
        ],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError == false)
    let ops = await coreMIDI.executedOps
    #expect(ops.first?.0 == "midi.send_chord")
    #expect(ops.first?.1["notes"] == "60,64,67")
    #expect(ops.first?.1["duration_ms"] == "750")
}

@Test func testMIDIDispatcherMMCLocateUsesTimeString() async {
    let router = ChannelRouter()
    let coreMIDI = MockChannel(id: .coreMIDI)
    await router.register(coreMIDI)

    let result = await MIDIDispatcher.handle(
        command: "mmc_locate",
        params: ["time": .string("01:02:03:04")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError == false)
    let ops = await coreMIDI.executedOps
    #expect(ops.first?.0 == "mmc.locate")
    #expect(ops.first?.1["time"] == "01:02:03:04")
}

@Test func testMIDIDispatcherMMCLocateBarUsesTransportRoute() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu)
    await router.register(mcu)

    let result = await MIDIDispatcher.handle(
        command: "mmc_locate",
        params: ["bar": .int(11)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError == false)
    let ops = await mcu.executedOps
    #expect(ops.first?.0 == "transport.goto_position")
    #expect(ops.first?.1["position"] == "11.1.1.1")
}

@Test func testMIDIDispatcherUnknownFails() async {
    let result = await MIDIDispatcher.handle(
        command: "invalid",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == true)
    #expect(toolText(result).contains("Unknown MIDI command"))
}

@Test func testProjectDispatcherOpenRejectsRelativePath() async {
    let result = await ProjectDispatcher.handle(
        command: "open",
        params: ["path": .string("relative/song.logicx")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == true)
    #expect(toolText(result).contains("existing absolute .logicx"))
}

@Test func testProjectDispatcherSaveAsRejectsInvalidExtension() async {
    let result = await ProjectDispatcher.handle(
        command: "save_as",
        params: ["path": .string("/tmp/song.txt")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == true)
    #expect(toolText(result).contains("absolute .logicx"))
}

@Test func testSystemDispatcherHelpReturnsTransportDocs() async {
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("transport")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == false)
    #expect(toolText(result).contains("logic_transport commands"))
}

@Test func testSystemDispatcherHelpCoversAllCategories() async {
    let cases: [(category: String, expected: String)] = [
        ("tracks", "logic_tracks commands"),
        ("mixer", "logic_mixer commands"),
        ("midi", "logic_midi commands"),
        ("edit", "logic_edit commands"),
        ("navigate", "logic_navigate commands"),
        ("project", "logic_project commands"),
        ("system", "logic_system commands"),
        ("all", "Logic Pro MCP"),
    ]

    for testCase in cases {
        let result = await SystemDispatcher.handle(
            command: "help",
            params: ["category": .string(testCase.category)],
            router: ChannelRouter(),
            cache: StateCache()
        )

        #expect(result.isError == false, "Expected help(\(testCase.category)) to succeed")
        #expect(toolText(result).contains(testCase.expected))
    }
}

@Test func testSystemDispatcherPermissionsReturnsSummary() async {
    let result = await SystemDispatcher.handle(
        command: "permissions",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )

    #expect(result.isError == false)
    let text = toolText(result)
    #expect(text.contains("Accessibility:"))
    #expect(text.contains("Automation (Logic Pro):"))
}

@Test func testSystemDispatcherRefreshCacheRecordsToolAccess() async {
    let cache = StateCache()

    let result = await SystemDispatcher.handle(
        command: "refresh_cache",
        params: [:],
        router: ChannelRouter(),
        cache: cache
    )

    #expect(result.isError == false)
    #expect(toolText(result).contains("State refresh triggered"))
    #expect(await cache.timeSinceLastToolAccess() < 1.0)
}

@Test func testSystemDispatcherUnknownFails() async {
    let result = await SystemDispatcher.handle(
        command: "invalid",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == true)
    #expect(toolText(result).contains("Unknown system command"))
}

@Test func testPermissionStatusSummaryListsMissingPermissions() {
    let status = PermissionChecker.PermissionStatus(accessibility: false, automationLogicPro: false)
    #expect(status.allGranted == false)
    #expect(status.summary.contains("Accessibility: NOT GRANTED"))
    #expect(status.summary.contains("Automation (Logic Pro): NOT GRANTED"))
}

@Test func testPermissionStatusSummaryMarksAutomationAsNotVerifiableWhenLogicIsNotRunning() {
    let status = PermissionChecker.PermissionStatus(
        accessibilityState: .granted,
        automationState: .notVerifiable
    )
    #expect(status.automationLogicPro == false)
    #expect(status.summary.contains("Automation (Logic Pro): NOT VERIFIABLE"))
    #expect(status.summary.contains("Launch Logic Pro once"))
}

@Test func testStatePollerStartStopLifecycle() async {
    let poller = StatePoller(axChannel: AccessibilityChannel(), cache: StateCache())
    await poller.start()
    #expect(await poller.isRunning == true)
    await poller.stop()
    #expect(await poller.isRunning == false)
}

@Test func testCoreMIDIChannelAftertouchAcceptsValueAlias() async {
    let channel = CoreMIDIChannel(engine: MIDIEngine())
    let result = await channel.execute(
        operation: "midi.send_aftertouch",
        params: ["value": "91", "channel": "2"]
    )
    #expect(result.isSuccess)
    #expect(result.message.contains("Aftertouch 91"))
}

@Test func testCoreMIDIChannelPitchBendNormalizesSignedValue() async {
    let channel = CoreMIDIChannel(engine: MIDIEngine())
    let result = await channel.execute(
        operation: "midi.send_pitch_bend",
        params: ["value": "-8192", "channel": "1"]
    )
    #expect(result.isSuccess)
    #expect(result.message.contains("Pitch bend 0"))
}

@Test func testCoreMIDIChannelGotoPositionRequiresFallback() async {
    let channel = CoreMIDIChannel(engine: MIDIEngine())
    let result = await channel.execute(
        operation: "transport.goto_position",
        params: ["position": "12.1.1.1"]
    )
    #expect(!result.isSuccess)
    #expect(result.message.contains("use MCU or CGEvent fallback"))
}

@Test func testCoreMIDIChannelHealthCheckInactive() async {
    let channel = CoreMIDIChannel(engine: MIDIEngine())
    let health = await channel.healthCheck()
    #expect(health.available == false)
    #expect(health.detail.contains("not initialized"))
}
