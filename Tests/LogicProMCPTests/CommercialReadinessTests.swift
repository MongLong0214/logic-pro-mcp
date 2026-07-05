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

    #expect(!(result.isError!))
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

    #expect(!(result.isError!))
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
    #expect(result.isError!)
    #expect(toolText(result).contains("Unknown transport command"))
}

@Test func testNavigateDispatcherGotoMarkerByNameUsesCachedMarker() async {
    // v3.1.10 (boomer P1-1) — name-based goto resolves the marker from
    // cache, then routes via `transport.goto_position` using the
    // marker's `position` string. Pre-v3.1.10 routed via the keycmd
    // `nav.goto_marker` (CC 38) which ignores params and just fires the
    // "go to next marker" hotkey — making name-based goto a silent
    // no-op relative to the named marker.
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()
    await cache.updateMarkers([MarkerState(id: 7, name: "Verse", position: "7.1.1.1")])

    let result = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["name": .string("ver")],
        router: router,
        cache: cache
    )

    #expect(!(result.isError!))
    let ops = await ax.executedOps
    #expect(ops.first?.0 == "transport.goto_position")
    #expect(ops.first?.1["position"] == "7.1.1.1")
}

@Test func testNavigateDispatcherGotoMarkerByIndexUsesCachedPosition() async {
    // v3.1.10 (boomer P1-1) — index-based goto also resolves from cache
    // and routes via position when the marker is present.
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)
    let cache = StateCache()
    await cache.updateMarkers([
        MarkerState(id: 0, name: "Intro", position: "1.1.1.1"),
        MarkerState(id: 1, name: "Verse", position: "5.1.1.1"),
        MarkerState(id: 2, name: "Chorus", position: "9.1.1.1"),
    ])

    let result = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["index": .int(2)],
        router: router,
        cache: cache
    )

    #expect(!(result.isError!))
    let ops = await ax.executedOps
    #expect(ops.first?.0 == "transport.goto_position")
    #expect(ops.first?.1["position"] == "9.1.1.1")
}

@Test func testNavigateDispatcherGotoMarkerColdCacheReturnsElementNotFound() async {
    // H-2 (2026-05-08 enterprise review): pre-v3.4.0 the cold-cache
    // index path fell back to `nav.goto_marker` (CC 38 keycmd), which
    // is Logic's "go to next marker" hotkey — it ignored the requested
    // index and silently advanced to whatever marker comes next.
    // BREAKING since v3.4.0: cold-cache index returns State C
    // `element_not_found` so callers learn the cache was cold instead
    // of getting wrong-target navigation. Caller should refresh cache
    // and retry, or supply `name` instead.
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let result = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["index": .int(3)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    let text = toolText(result)
    #expect(text.contains("\"error\":\"element_not_found\""))
    #expect(text.contains("not found in cached marker list"))
    #expect(text.contains("system.refresh_cache"))
    // Critical: the legacy CC 38 keycmd must NOT have been invoked.
    let ops = await keyCmd.executedOps
    #expect(ops.isEmpty, "Cold-cache index must not advance the marker pointer via CC 38")
}

@Test func testNavigateDispatcherGotoMarkerColdCacheNameReturnsElementNotFound() async {
    // H-2 — name-based cold-cache also returns the structured State C
    // envelope so the caller can programmatically detect the cache-cold
    // condition (was a free-form "No marker found matching" string).
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let result = await NavigateDispatcher.handle(
        command: "goto_marker",
        params: ["name": .string("Verse")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    let text = toolText(result)
    #expect(text.contains("\"error\":\"element_not_found\""))
    #expect(text.contains("no marker matching name 'Verse'"))
    #expect(text.contains("system.refresh_cache"))
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

    #expect(!(result.isError!))
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
    #expect(result.isError!)
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

    #expect(!(result.isError!))
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

    #expect(!(result.isError!))
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

    #expect(!(result.isError!))
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
    #expect(result.isError!)
    #expect(toolText(result).contains("Unknown MIDI command"))
}

@Test func testProjectDispatcherOpenRejectsRelativePath() async {
    let result = await ProjectDispatcher.handle(
        command: "open",
        params: ["path": .string("relative/song.logicx")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError!)
    #expect(toolText(result).contains("existing absolute .logicx"))
}

@Test func testProjectDispatcherSaveAsRejectsInvalidExtension() async {
    let result = await ProjectDispatcher.handle(
        command: "save_as",
        params: ["path": .string("/tmp/song.txt")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError!)
    #expect(toolText(result).contains("absolute .logicx"))
}

@Test func testSystemDispatcherHelpReturnsTransportDocs() async {
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("transport")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(!(result.isError!))
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

        #expect(!(result.isError!), "Expected help(\(testCase.category)) to succeed")
        #expect(toolText(result).contains(testCase.expected))
    }
}

@Test func testSystemHelpUnknownCategoryReturnsTypedError() async {
    // #219: a present-but-unrecognized category must NOT silently fall back to
    // full help. It returns a typed unknown_category State C listing the valid
    // categories so a client can detect a typo.
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("bogus")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError!)
    let json = (try? JSONSerialization.jsonObject(with: Data(toolText(result).utf8))) as? [String: Any]
    #expect(json?["error"] as? String == "unknown_category")
    #expect(!((json?["success"] as? Bool)!))
    #expect(json?["requested_category"] as? String == "bogus")
    let valid = json?["valid_categories"] as? [String]
    #expect((valid?.contains("transport"))!)
    #expect((valid?.contains("all"))!)
    // It must NOT leak the full help text on the error path.
    #expect(!toolText(result).contains("logic_transport  — Transport control"))
}

@Test func testSystemHelpAbsentCategoryStillReturnsFullHelp() async {
    // Regression guard: omitting `category` remains the full-help contract.
    let result = await SystemDispatcher.handle(
        command: "help",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(!(result.isError!))
    #expect(toolText(result).contains("Logic Pro MCP"))
}

@Test func testValidHelpCategoriesStayInLockstepWithHelpText() async {
    // Every accepted category (except "all") must map to a category-specific
    // section; "all" must map to the overview. Prevents drift between the
    // accepted set and the helpText switch.
    for category in SystemDispatcher.validHelpCategories {
        let result = await SystemDispatcher.handle(
            command: "help",
            params: ["category": .string(category)],
            router: ChannelRouter(),
            cache: StateCache()
        )
        #expect(!(result.isError!), "Accepted category \(category) must succeed")
        if category == "all" {
            #expect(toolText(result).contains("Logic Pro MCP"))
        } else {
            #expect(toolText(result).contains("logic_\(category) commands"))
        }
    }
}

@Test func testSystemHelpEnumeratesEveryRegisteredResourceAndTemplate() async {
    // The help overview is an LLM-facing capability-discovery surface: it must
    // ENUMERATE every registered resource/template, not merely claim the count.
    // Guards the union-merge drift class where counts are bumped but list lines
    // are left behind (e.g. project audit / stock-instruments / session-players).
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("all")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(!(result.isError!))
    let text = toolText(result)
    for uri in ResourceProvider.resources.map(\.uri) {
        #expect(text.contains(uri), "logic_system help overview omits registered resource \(uri)")
    }
    for template in ResourceProvider.templates.map(\.uriTemplate) {
        #expect(text.contains(template), "logic_system help overview omits registered template \(template)")
    }
}

@Test func testSystemDispatcherPermissionsReturnsSummary() async {
    let result = await SystemDispatcher.handle(
        command: "permissions",
        params: [:],
        router: ChannelRouter(),
        cache: StateCache()
    )

    #expect(!(result.isError!))
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

    #expect(!(result.isError!))
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
    #expect(result.isError!)
    #expect(toolText(result).contains("Unknown system command"))
}

@Test func testPermissionStatusSummaryListsMissingPermissions() {
    let status = PermissionChecker.PermissionStatus(accessibility: false, automationLogicPro: false)
    #expect(!(status.allGranted))
    #expect(status.summary.contains("Accessibility: NOT GRANTED"))
    #expect(status.summary.contains("Automation (Logic Pro): NOT GRANTED"))
}

@Test func testPermissionStatusSummaryMarksAutomationAsNotVerifiableWhenLogicIsNotRunning() {
    let status = PermissionChecker.PermissionStatus(
        accessibilityState: .granted,
        automationState: .notVerifiable
    )
    #expect(!(status.automationLogicPro))
    #expect(status.summary.contains("Automation (Logic Pro): NOT VERIFIABLE"))
    #expect(status.summary.contains("Launch Logic Pro once"))
}

@Test func testStatePollerStartStopLifecycle() async {
    // Use the fast-test runtime so the polling loop doesn't wait 3s per cycle.
    // With `.fastTest`, the sleep is 1µs and hasVisibleWindow always returns
    // true — the test exercises the start/stop state machine without dragging
    // in live AX queries or the production interval.
    let poller = StatePoller(
        axChannel: AccessibilityChannel(),
        cache: StateCache(),
        runtime: .fastTest
    )
    await poller.start()
    #expect(await poller.isRunning)
    await poller.stop()
    #expect(!(await poller.isRunning))
}

@Test func testCoreMIDIChannelAftertouchAcceptsValueAlias() async {
    let channel = CoreMIDIChannel(engine: MockCoreMIDIEngine(active: true))
    let result = await channel.execute(
        operation: "midi.send_aftertouch",
        params: ["value": "91", "channel": "2"]
    )
    #expect(result.isSuccess)
    #expect(result.message.contains("Aftertouch 91"))
}

@Test func testCoreMIDIChannelPitchBendAcceptsAbsoluteCenterValue() async {
    let channel = CoreMIDIChannel(engine: MockCoreMIDIEngine(active: true))
    let result = await channel.execute(
        operation: "midi.send_pitch_bend",
        params: ["value": "8192", "channel": "1"]
    )
    #expect(result.isSuccess)
    #expect(result.message.contains("Pitch bend 8192"))
}

@Test func testCoreMIDIChannelGotoPositionRequiresFallback() async {
    let channel = CoreMIDIChannel(engine: MockCoreMIDIEngine(active: true))
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
    #expect(!(health.available))
    #expect(health.detail.contains("not initialized"))
}
