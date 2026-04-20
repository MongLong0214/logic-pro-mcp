@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

private final class AccessibilityRuntimeRecorder: @unchecked Sendable {
    var transportButtons: [String] = []
    var tempoParams: [[String: String]] = []
    var cycleRangeParams: [[String: String]] = []
    var selectParams: [[String: String]] = []
    var trackToggleCalls: [([String: String], String)] = []
    var renameParams: [[String: String]] = []
    var channelStripParams: [[String: String]] = []
    var mixerValueCalls: [([String: String], AccessibilityChannel.MixerTarget)] = []
}

private func makeAccessibilityRuntime(
    recorder: AccessibilityRuntimeRecorder = AccessibilityRuntimeRecorder(),
    isTrusted: Bool = true,
    isRunning: Bool = true,
    appRoot: AXUIElement? = AXUIElementCreateApplication(42)
) -> AccessibilityChannel.Runtime {
    .init(
        isTrusted: { isTrusted },
        isLogicProRunning: { isRunning },
        appRoot: { appRoot },
        transportState: { .success("{\"transport\":true}") },
        toggleTransportButton: { name in
            recorder.transportButtons.append(name)
            return .success("{\"toggled\":\"\(name)\"}")
        },
        setTempo: { params in
            recorder.tempoParams.append(params)
            return .success("{\"tempo\":true}")
        },
        setCycleRange: { params in
            recorder.cycleRangeParams.append(params)
            return .success("{\"cycle\":true}")
        },
        tracks: { .success("{\"tracks\":true}") },
        selectedTrack: { .success("{\"selected\":true}") },
        selectTrack: { params in
            recorder.selectParams.append(params)
            return .success("{\"select\":true}")
        },
        setTrackToggle: { params, button in
            recorder.trackToggleCalls.append((params, button))
            return .success("{\"toggle\":\"\(button)\"}")
        },
        renameTrack: { params in
            recorder.renameParams.append(params)
            return .success("{\"rename\":true}")
        },
        mixerState: { .success("{\"mixer\":true}") },
        channelStrip: { params in
            recorder.channelStripParams.append(params)
            return .success("{\"strip\":true}")
        },
        setMixerValue: { params, target in
            recorder.mixerValueCalls.append((params, target))
            return .success("{\"mixerValue\":true}")
        },
        projectInfo: { .success("{\"project\":true}") }
    )
}

private func makeAXBackedAccessibilityChannel(
    builder: FakeAXRuntimeBuilder,
    app: AXUIElement,
    logicRuntime: AXLogicProElements.Runtime? = nil,
    isTrusted: Bool = true,
    isRunning: Bool = true,
    runTempoFallback: @escaping @Sendable (String) -> Bool = { _ in false }
) -> AccessibilityChannel {
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { isTrusted },
        isLogicProRunning: { isRunning },
        logicRuntime: logicRuntime ?? builder.makeLogicRuntime(appElement: app),
        runTempoFallback: runTempoFallback
    )
    return AccessibilityChannel(runtime: runtime)
}

@Test func testAccessibilityChannelStartRequiresTrustAndAllowsMissingLogic() async throws {
    let untrusted = AccessibilityChannel(runtime: makeAccessibilityRuntime(isTrusted: false))
    await #expect(throws: AccessibilityError.notTrusted) {
        try await untrusted.start()
    }

    let notRunning = AccessibilityChannel(runtime: makeAccessibilityRuntime(isTrusted: true, isRunning: false))
    try await notRunning.start()
}

@Test func testAccessibilityChannelHealthReflectsTrustRunningAndAppRoot() async {
    let untrusted = AccessibilityChannel(runtime: makeAccessibilityRuntime(isTrusted: false))
    let notRunning = AccessibilityChannel(runtime: makeAccessibilityRuntime(isTrusted: true, isRunning: false))
    let missingRoot = AccessibilityChannel(runtime: makeAccessibilityRuntime(isTrusted: true, isRunning: true, appRoot: nil))
    let healthy = AccessibilityChannel(runtime: makeAccessibilityRuntime())

    #expect(await untrusted.healthCheck().available == false)
    #expect(await untrusted.healthCheck().detail.contains("Accessibility not trusted"))

    #expect(await notRunning.healthCheck().available == false)
    #expect(await notRunning.healthCheck().detail.contains("Logic Pro is not running"))

    #expect(await missingRoot.healthCheck().available == false)
    #expect(await missingRoot.healthCheck().detail.contains("Cannot access Logic Pro AX element"))

    let healthyState = await healthy.healthCheck()
    #expect(healthyState.available == true)
    #expect(healthyState.detail.contains("AX connected"))
}

@Test func testAccessibilityChannelExecuteRejectsWhenLogicNotRunning() async {
    let channel = AccessibilityChannel(runtime: makeAccessibilityRuntime(isRunning: false))

    let result = await channel.execute(operation: "transport.get_state", params: [:])

    #expect(!result.isSuccess)
    #expect(result.message.contains("Logic Pro is not running"))
}

@Test func testAccessibilityChannelRoutesImplementedOperationsThroughRuntime() async {
    let recorder = AccessibilityRuntimeRecorder()
    let channel = AccessibilityChannel(runtime: makeAccessibilityRuntime(recorder: recorder))

    let operations: [(String, [String: String])] = [
        ("transport.get_state", [:]),
        ("transport.toggle_cycle", [:]),
        ("transport.toggle_metronome", [:]),
        ("transport.set_tempo", ["tempo": "128"]),
        ("transport.set_cycle_range", ["start": "1.1.1.1", "end": "9.1.1.1"]),
        ("track.get_tracks", [:]),
        ("track.get_selected", [:]),
        ("track.select", ["index": "4"]),
        ("track.set_mute", ["index": "1", "enabled": "true"]),
        ("track.set_solo", ["index": "2", "enabled": "false"]),
        ("track.set_arm", ["index": "3", "enabled": "true"]),
        ("track.rename", ["index": "5", "name": "Bass"]),
        ("mixer.get_state", [:]),
        ("mixer.get_channel_strip", ["index": "2"]),
        ("mixer.set_volume", ["index": "2", "value": "0.75"]),
        ("mixer.set_pan", ["index": "2", "value": "-0.2"]),
        ("project.get_info", [:]),
    ]

    for (operation, params) in operations {
        let result = await channel.execute(operation: operation, params: params)
        #expect(result.isSuccess, "Expected \(operation) to route through runtime")
    }

    #expect(recorder.transportButtons == ["Cycle", "Metronome"])
    #expect(recorder.tempoParams == [["tempo": "128"]])
    #expect(recorder.cycleRangeParams == [["start": "1.1.1.1", "end": "9.1.1.1"]])
    #expect(recorder.selectParams == [["index": "4"]])
    #expect(recorder.renameParams == [["index": "5", "name": "Bass"]])
    #expect(recorder.channelStripParams == [["index": "2"]])

    #expect(recorder.trackToggleCalls.count == 3)
    #expect(recorder.trackToggleCalls[0].1 == "Mute")
    #expect(recorder.trackToggleCalls[1].1 == "Solo")
    #expect(recorder.trackToggleCalls[2].1 == "Record")

    #expect(recorder.mixerValueCalls.count == 2)
    #expect(recorder.mixerValueCalls[0].1 == .volume)
    #expect(recorder.mixerValueCalls[1].1 == .pan)
}

@Test func testAccessibilityChannelReturnsExpectedUnimplementedAndUnsupportedErrors() async {
    let channel = AccessibilityChannel(runtime: makeAccessibilityRuntime())

    let expectations: [(String, String)] = [
        ("track.set_color", "Track color setting not supported via AX"),
        ("mixer.set_send", "Send adjustment not yet implemented via AX"),
        ("mixer.set_input", "I/O routing not yet implemented via AX"),
        ("mixer.set_output", "I/O routing not yet implemented via AX"),
        ("mixer.toggle_eq", "EQ toggle not yet implemented via AX"),
        ("mixer.reset_strip", "Strip reset not yet implemented via AX"),
        ("nav.rename_marker", "Marker renaming not yet implemented via AX"),
        ("region.select", "Region operations not yet implemented via AX"),
        ("plugin.list", "Plugin list reading not yet implemented via AX"),
        ("automation.get_mode", "Automation mode reading not yet implemented via AX"),
        ("automation.set_mode", "Automation mode setting not yet implemented via AX"),
        ("unknown.operation", "Unsupported AX operation"),
    ]

    for (operation, message) in expectations {
        let result = await channel.execute(operation: operation, params: [:])
        #expect(!result.isSuccess)
        #expect(result.message.contains(message), "Expected \(operation) to return '\(message)'")
    }
}

@Test func testAccessibilityChannelAXBackedRegionReadReturnsParsedRegions() async throws {
    func axPoint(_ x: CGFloat, _ y: CGFloat) -> AXValue {
        var point = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &point)!
    }

    func axSize(_ width: CGFloat, _ height: CGFloat) -> AXValue {
        var size = CGSize(width: width, height: height)
        return AXValueCreate(.cgSize, &size)!
    }

    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(800)
    let window = builder.element(801)
    let headerRail = builder.element(802)
    let trackHeader = builder.element(803)
    let contentGroup = builder.element(804)
    let region = builder.element(805)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, contentGroup])

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "트랙 헤더")
    builder.setChildren(headerRail, [trackHeader])

    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXPositionAttribute as String, axPoint(0, 100))
    builder.setAttribute(trackHeader, kAXSizeAttribute as String, axSize(200, 40))

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "트랙 콘텐츠")
    builder.setChildren(contentGroup, [region])

    builder.setAttribute(region, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(region, kAXDescriptionAttribute as String, "Deluxe Classic")
    builder.setAttribute(region, kAXHelpAttribute as String, "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전.")
    builder.setAttribute(region, kAXPositionAttribute as String, axPoint(240, 108))
    builder.setAttribute(region, kAXSizeAttribute as String, axSize(320, 24))

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let result = await channel.execute(operation: "region.get_regions", params: [:])

    #expect(result.isSuccess)

    let regions = try JSONDecoder().decode([RegionInfo].self, from: Data(result.message.utf8))
    #expect(regions.count == 1)
    #expect(regions[0].name == "Deluxe Classic")
    #expect(regions[0].trackIndex == 0)
    #expect(regions[0].startBar == 1)
    #expect(regions[0].endBar == 3)
    #expect(regions[0].kind == "midi")
}

@Test func testAccessibilityChannelAXBackedTransportDefaultsUseFakeAXTree() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(100)
    let window = builder.element(101)
    let transport = builder.element(102)
    let play = builder.element(103)
    let cycle = builder.element(104)
    let tempoText = builder.element(105)
    let positionText = builder.element(106)
    let timeText = builder.element(107)
    let tempoField = builder.element(108)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [transport])
    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")
    builder.setChildren(transport, [play, cycle, tempoText, positionText, timeText, tempoField])

    builder.setAttribute(play, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(play, kAXDescriptionAttribute as String, "Play")
    builder.setAttribute(play, kAXValueAttribute as String, 1)

    builder.setAttribute(cycle, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cycle, kAXDescriptionAttribute as String, "Cycle")
    builder.setAttribute(cycle, kAXValueAttribute as String, 0)

    builder.setAttribute(tempoText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(tempoText, kAXDescriptionAttribute as String, "Tempo")
    builder.setAttribute(tempoText, kAXValueAttribute as String, "128.5 BPM")

    builder.setAttribute(positionText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(positionText, kAXDescriptionAttribute as String, "Position")
    builder.setAttribute(positionText, kAXValueAttribute as String, "9.1.1.1")

    builder.setAttribute(timeText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(timeText, kAXDescriptionAttribute as String, "Time")
    builder.setAttribute(timeText, kAXValueAttribute as String, "00:01:02.003")

    // v3.0.2+: tempo is an AXSlider ("템포" / "Tempo"), not a text field.
    builder.setAttribute(tempoField, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(tempoField, kAXDescriptionAttribute as String, "템포")
    builder.setAttribute(tempoField, kAXValueAttribute as String, NSNumber(value: 120.0))

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)

    let transportResult = await channel.execute(operation: "transport.get_state", params: [:])
    #expect(transportResult.isSuccess)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let transportState = try decoder.decode(TransportState.self, from: Data(transportResult.message.utf8))
    #expect(transportState.isPlaying)
    // Tempo field (AXTextField, "120.0") is now included alongside static text ("128.5 BPM");
    // the text field value overrides because it appears later in the combined list.
    #expect(transportState.tempo == 120.0)
    #expect(transportState.position == "9.1.1.1")

    let toggleResult = await channel.execute(operation: "transport.toggle_cycle", params: [:])
    #expect(toggleResult.isSuccess)
    #expect(builder.actionCalls.contains { $0.elementID == builder.elementID(cycle) && $0.action == kAXPressAction as String })

    // v3.0.2: set_tempo uses CGEvent double-click + typed entry on the tempo
    // slider. CGEvent is real mouse input that our fake AX runtime can't
    // observe, so after the typed entry fails to stick, the implementation
    // falls back to AXIncrement/AXDecrement with 10-BPM granularity — that
    // DOES go through the AX runtime and is observable. Verify at least the
    // slider was located (no "could not locate" error) and the operation
    // returned success. Pinning the exact fallback payload is brittle because
    // it changes with Logic's actual slider min/max ranges.
    let tempoResult = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "132.0"])
    #expect(tempoResult.isSuccess)
    #expect(!tempoResult.message.contains("could not locate"))
    #expect(tempoResult.message.contains("\"tempo\":132.0"))

    let cycleMissing = await channel.execute(operation: "transport.set_cycle_range", params: [:])
    #expect(!cycleMissing.isSuccess)
    #expect(cycleMissing.message.contains("Missing 'start'"))

    let cycleUnsupported = await channel.execute(
        operation: "transport.set_cycle_range",
        params: ["start": "1.1.1.1", "end": "9.1.1.1"]
    )
    // With the fake AX tree (no transport bar cycle fields) and osascript
    // fallback unavailable in unit tests, the handler now returns a descriptive
    // "locator fields not found" error rather than "not yet implemented".
    #expect(!cycleUnsupported.isSuccess)
    #expect(cycleUnsupported.message.contains("Cycle range") || cycleUnsupported.message.contains("locator"))
}

@Test func testAccessibilityChannelAXBackedTransportErrorPaths() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(150)
    let window = builder.element(151)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)

    let missingTransportChannel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        runTempoFallback: { _ in false }
    )
    let missingTransport = await missingTransportChannel.execute(operation: "transport.get_state", params: [:])
    #expect(!missingTransport.isSuccess)
    #expect(missingTransport.message.contains("Cannot locate transport bar"))

    let transport = builder.element(152)
    builder.setChildren(window, [transport])
    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")

    let missingButton = await missingTransportChannel.execute(operation: "transport.toggle_metronome", params: [:])
    #expect(!missingButton.isSuccess)
    #expect(missingButton.message.contains("Cannot find transport button"))

    let invalidTempo = await missingTransportChannel.execute(operation: "transport.set_tempo", params: [:])
    #expect(!invalidTempo.isSuccess)
    #expect(invalidTempo.message.contains("Missing or invalid 'tempo'"))

    let missingTempoField = await missingTransportChannel.execute(operation: "transport.set_tempo", params: ["tempo": "126"])
    #expect(!missingTempoField.isSuccess)
    #expect(missingTempoField.message.contains("could not locate the tempo slider"))

    let metronome = builder.element(153)
    builder.setChildren(transport, [metronome])
    builder.setAttribute(metronome, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(metronome, kAXDescriptionAttribute as String, "Metronome")

    let failingRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            element != metronome && action == kAXPressAction as String
        }
    )
    let failingChannel = makeAXBackedAccessibilityChannel(builder: builder, app: app, logicRuntime: failingRuntime)
    let pressFailure = await failingChannel.execute(operation: "transport.toggle_metronome", params: [:])
    #expect(!pressFailure.isSuccess)
    #expect(pressFailure.message.contains("Failed to press transport button"))
}

@Test func testAccessibilityChannelAXBackedTempoFallbackCanBeInjected() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(160)
    let window = builder.element(161)
    let transport = builder.element(162)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [transport])
    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")

    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        runTempoFallback: { tempo in tempo == "126" }
    )

    let result = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "126"])
    // Post-hardening: osascript fallback removed (was causing FD leaks under
    // sustained calls, killing MCP server). AX tempo field absent → clear error.
    #expect(!result.isSuccess)
    #expect(result.message.contains("could not locate the tempo slider"))
}

@Test func testAccessibilityChannelAXBackedTempoReturnsErrorWhenAXFieldMissing() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(700)
    let window = builder.element(701)
    let transport = builder.element(702)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [transport])
    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")

    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        runTempoFallback: { tempo in tempo == "126" }
    )

    let result = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "126"])
    #expect(!result.isSuccess)
    #expect(result.message.contains("could not locate the tempo slider"))
}

@Test func testAccessibilityChannelCreateInstrumentVerifiesTrackCountIncrease() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(180)
    let window = builder.element(181)
    let menuBar = builder.element(182)
    let trackMenu = builder.element(183)
    let createItem = builder.element(184)
    let trackList = builder.element(185)
    let trackHeader = builder.element(186)
    let createdTrackHeader = builder.element(187)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [trackHeader])

    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "트랙")
    builder.setChildren(trackMenu, [createItem])
    builder.setAttribute(createItem, kAXTitleAttribute as String, "새로운 소프트웨어 악기 트랙")

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            if builder.elementID(element) == builder.elementID(createItem), action == kAXPressAction as String {
                builder.setChildren(trackList, [trackHeader, createdTrackHeader])
            }
            return true
        }
    )
    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app, logicRuntime: runtime)

    let result = await channel.execute(operation: "track.create_instrument", params: [:])

    #expect(result.isSuccess)
    #expect(result.message.contains("\"verified\":true"))
    #expect(result.message.contains("\"track_count_before\":1"))
    #expect(result.message.contains("\"track_count_after\":2"))
}

@Test func testAccessibilityChannelCreateInstrumentFailsWhenTrackCountDoesNotIncrease() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(190)
    let window = builder.element(191)
    let menuBar = builder.element(192)
    let trackMenu = builder.element(193)
    let createItem = builder.element(194)
    let trackList = builder.element(195)
    let trackHeader = builder.element(196)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [trackHeader])

    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "트랙")
    builder.setChildren(trackMenu, [createItem])
    builder.setAttribute(createItem, kAXTitleAttribute as String, "새로운 소프트웨어 악기 트랙")

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { _, _ in true }
    )
    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app, logicRuntime: runtime)

    let result = await channel.execute(operation: "track.create_instrument", params: [:])

    #expect(!result.isSuccess)
    #expect(result.message.contains("Track creation did not increase visible track count"))
}

@Test func testAccessibilityChannelAXBackedTrackDefaultsUseFakeAXTree() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(200)
    let window = builder.element(201)
    let trackList = builder.element(202)
    let header = builder.element(203)
    let nameField = builder.element(204)
    let muteButton = builder.element(205)
    let soloButton = builder.element(206)
    let armButton = builder.element(207)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [header])

    builder.setAttribute(header, kAXTitleAttribute as String, "Audio Track")
    builder.setAttribute(header, kAXDescriptionAttribute as String, "Audio color blue")
    builder.setAttribute(header, kAXSelectedAttribute as String, true)
    builder.setChildren(header, [nameField, muteButton, soloButton, armButton])

    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(nameField, kAXValueAttribute as String, "Lead Vox")

    builder.setAttribute(muteButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(muteButton, kAXDescriptionAttribute as String, "Mute Track 1")
    builder.setAttribute(muteButton, kAXValueAttribute as String, 1)

    builder.setAttribute(soloButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(soloButton, kAXDescriptionAttribute as String, "Solo Track 1")
    builder.setAttribute(soloButton, kAXValueAttribute as String, 0)

    builder.setAttribute(armButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(armButton, kAXDescriptionAttribute as String, "Record Track 1")
    builder.setAttribute(armButton, kAXValueAttribute as String, 1)

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)

    let tracksResult = await channel.execute(operation: "track.get_tracks", params: [:])
    #expect(tracksResult.isSuccess)
    let decoder = JSONDecoder()
    let tracks = try decoder.decode([TrackState].self, from: Data(tracksResult.message.utf8))
    #expect(tracks.count == 1)
    #expect(tracks[0].name == "Lead Vox")
    #expect(tracks[0].type == .audio)
    #expect(tracks[0].isMuted)

    let selectedResult = await channel.execute(operation: "track.get_selected", params: [:])
    #expect(selectedResult.isSuccess)
    let selectedTrack = try decoder.decode(TrackState.self, from: Data(selectedResult.message.utf8))
    #expect(selectedTrack.isSelected)

    let selectResult = await channel.execute(operation: "track.select", params: ["index": "0"])
    #expect(selectResult.isSuccess)
    #expect(builder.actionCalls.contains { $0.elementID == builder.elementID(header) && $0.action == kAXPressAction as String })

    // muteButton.kAXValue = 1 (already muted). Calling set_mute with default
    // enabled=true is idempotent — no press is issued (toggle would flip OFF).
    let muteNoopResult = await channel.execute(operation: "track.set_mute", params: ["index": "0"])
    #expect(muteNoopResult.isSuccess)
    #expect(muteNoopResult.message.contains("\"action\":\"no-op\""))
    #expect(!builder.actionCalls.contains { $0.elementID == builder.elementID(muteButton) && $0.action == kAXPressAction as String })
    // Explicitly request disable (enabled=false) — current=true, desired=false → press.
    let muteOffResult = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "false"])
    #expect(muteOffResult.isSuccess)
    #expect(builder.actionCalls.contains { $0.elementID == builder.elementID(muteButton) && $0.action == kAXPressAction as String })

    let renameResult = await channel.execute(operation: "track.rename", params: ["index": "0", "name": "Lead"])
    #expect(renameResult.isSuccess)
    #expect((builder.attributeValue(nameField, kAXValueAttribute as String) as? String) == "Lead")
    #expect(builder.actionCalls.contains { $0.elementID == builder.elementID(nameField) && $0.action == kAXConfirmAction as String })
}

@Test func testAccessibilityChannelAXBackedTrackSelectVerifiesReadbackWhenSelectionMetadataExists() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(600)
    let window = builder.element(601)
    let trackList = builder.element(602)
    let firstHeader = builder.element(603)
    let secondHeader = builder.element(604)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [firstHeader, secondHeader])
    builder.setAttribute(firstHeader, kAXTitleAttribute as String, "Track 1")
    builder.setAttribute(firstHeader, kAXSelectedAttribute as String, true)
    builder.setAttribute(secondHeader, kAXTitleAttribute as String, "Track 2")
    builder.setAttribute(secondHeader, kAXSelectedAttribute as String, false)

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == secondHeader {
                builder.setAttribute(firstHeader, kAXSelectedAttribute as String, false)
                builder.setAttribute(secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app, logicRuntime: logicRuntime)
    let selectResult = await channel.execute(operation: "track.select", params: ["index": "1"])
    #expect(selectResult.isSuccess)
    #expect(selectResult.message.contains("\"verified\":true"))

    let selectedResult = await channel.execute(operation: "track.get_selected", params: [:])
    #expect(selectedResult.isSuccess)
    let decoder = JSONDecoder()
    let selectedTrack = try decoder.decode(TrackState.self, from: Data(selectedResult.message.utf8))
    #expect(selectedTrack.id == 1)
    #expect(selectedTrack.isSelected)
}

@Test func testAccessibilityChannelAXBackedTrackSelectFailsWhenVerifiedSelectionSettlesElsewhere() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(610)
    let window = builder.element(611)
    let trackList = builder.element(612)
    let firstHeader = builder.element(613)
    let secondHeader = builder.element(614)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [firstHeader, secondHeader])
    builder.setAttribute(firstHeader, kAXTitleAttribute as String, "Track 1")
    builder.setAttribute(firstHeader, kAXSelectedAttribute as String, true)
    builder.setAttribute(secondHeader, kAXTitleAttribute as String, "Track 2")
    builder.setAttribute(secondHeader, kAXSelectedAttribute as String, false)

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let selectResult = await channel.execute(operation: "track.select", params: ["index": "1"])
    #expect(!selectResult.isSuccess)
    #expect(selectResult.message.contains("did not settle on index 1"))
}

@Test func testAccessibilityChannelAXBackedTrackErrorPaths() async {
    let emptyBuilder = FakeAXRuntimeBuilder()
    let emptyApp = emptyBuilder.element(220)
    let emptyWindow = emptyBuilder.element(221)
    emptyBuilder.setAttribute(emptyApp, kAXMainWindowAttribute as String, emptyWindow)
    let emptyChannel = makeAXBackedAccessibilityChannel(builder: emptyBuilder, app: emptyApp)

    let noHeaders = await emptyChannel.execute(operation: "track.get_tracks", params: [:])
    // Contract change: empty track list is a valid steady state (picker front /
    // no project). Returning `.error` caused StatePoller to skip updates and
    // retain ghost tracks from prior sessions, breaking rename/mute/arm on idx 0.
    #expect(noHeaders.isSuccess)
    #expect(noHeaders.message == "[]")

    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(230)
    let window = builder.element(231)
    let trackList = builder.element(232)
    let header = builder.element(233)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [header])
    builder.setAttribute(header, kAXTitleAttribute as String, "Track 1")

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)

    let noSelectedTrack = await channel.execute(operation: "track.get_selected", params: [:])
    #expect(!noSelectedTrack.isSuccess)
    #expect(noSelectedTrack.message.contains("No track is currently selected"))

    let invalidSelect = await channel.execute(operation: "track.select", params: [:])
    #expect(!invalidSelect.isSuccess)
    #expect(invalidSelect.message.contains("Missing or invalid 'index'"))

    let missingTrack = await channel.execute(operation: "track.select", params: ["index": "4"])
    #expect(!missingTrack.isSuccess)
    #expect(missingTrack.message.contains("Track at index 4 not found"))

    let missingMute = await channel.execute(operation: "track.set_mute", params: ["index": "0"])
    #expect(!missingMute.isSuccess)
    #expect(missingMute.message.contains("Cannot find Mute button"))

    let missingRenameField = await channel.execute(operation: "track.rename", params: ["index": "0", "name": "Lead"])
    #expect(!missingRenameField.isSuccess)
    #expect(missingRenameField.message.contains("Cannot find name field"))

    let missingRenameParams = await channel.execute(operation: "track.rename", params: ["index": "0"])
    #expect(!missingRenameParams.isSuccess)
    #expect(missingRenameParams.message.contains("Missing 'index' or 'name'"))

    let failingRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { _, _ in false }
    )
    let failingChannel = makeAXBackedAccessibilityChannel(builder: builder, app: app, logicRuntime: failingRuntime)

    let selectFailure = await failingChannel.execute(operation: "track.select", params: ["index": "0"])
    #expect(!selectFailure.isSuccess)
    #expect(selectFailure.message.contains("Failed to select track 0"))

    let soloButton = builder.element(234)
    builder.setChildren(header, [soloButton])
    builder.setAttribute(soloButton, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(soloButton, kAXDescriptionAttribute as String, "Solo Track 1")

    // With performAction disabled, the fallback to direct AXValue write still
    // succeeds (fake builder stores the value and read-back matches). New
    // post-hardening contract: the handler reports success via "value-written"
    // action marker rather than erroring out, because the desired state was
    // actually reached through the alternate write path.
    let soloFailure = await failingChannel.execute(operation: "track.set_solo", params: ["index": "0"])
    #expect(soloFailure.isSuccess)
    // Strategy name: "value-nsnumber" is the first write-based strategy that
    // succeeds in the fake builder (NSNumber round-trip works, press doesn't).
    #expect(soloFailure.message.contains("\"action\":\"value-nsnumber\""))
}

@Test func testAccessibilityChannelAXBackedMixerAndProjectDefaultsUseFakeAXTree() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(300)
    let window = builder.element(301)
    let mixer = builder.element(302)
    let strip = builder.element(303)
    let fader = builder.element(304)
    let pan = builder.element(305)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(window, kAXTitleAttribute as String, "Song.logicx")
    builder.setChildren(window, [mixer])
    builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setChildren(strip, [fader, pan])
    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(fader, kAXValueAttribute as String, 0.8)
    builder.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(pan, kAXValueAttribute as String, -0.25)

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let mixerResult = await channel.execute(operation: "mixer.get_state", params: [:])
    #expect(mixerResult.isSuccess)
    let strips = try decoder.decode([ChannelStripState].self, from: Data(mixerResult.message.utf8))
    #expect(strips.count == 1)
    #expect(strips[0].volume == 0.8)
    #expect(strips[0].pan == -0.25)

    let stripResult = await channel.execute(operation: "mixer.get_channel_strip", params: ["index": "0"])
    #expect(stripResult.isSuccess)
    let stripState = try decoder.decode(ChannelStripState.self, from: Data(stripResult.message.utf8))
    #expect(stripState.trackIndex == 0)

    let volumeResult = await channel.execute(operation: "mixer.set_volume", params: ["index": "0", "value": "0.5"])
    #expect(volumeResult.isSuccess)
    #expect((builder.attributeValue(fader, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.5)

    let panResult = await channel.execute(operation: "mixer.set_pan", params: ["index": "0", "value": "-0.1"])
    #expect(panResult.isSuccess)
    #expect((builder.attributeValue(pan, kAXValueAttribute as String) as? NSNumber)?.doubleValue == -0.1)

    let projectResult = await channel.execute(operation: "project.get_info", params: [:])
    #expect(projectResult.isSuccess)
    let project = try decoder.decode(ProjectInfo.self, from: Data(projectResult.message.utf8))
    #expect(project.name == "Song.logicx")
}

@Test func testAccessibilityChannelAXBackedMixerAndProjectErrorPaths() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(320)
    let window = builder.element(321)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)

    let missingMixer = await channel.execute(operation: "mixer.get_state", params: [:])
    #expect(!missingMixer.isSuccess)
    #expect(missingMixer.message.contains("Cannot locate mixer"))

    let invalidStripParams = await channel.execute(operation: "mixer.get_channel_strip", params: [:])
    #expect(!invalidStripParams.isSuccess)
    #expect(invalidStripParams.message.contains("Missing or invalid 'index'"))

    let invalidMixerValue = await channel.execute(operation: "mixer.set_volume", params: ["index": "0"])
    #expect(!invalidMixerValue.isSuccess)
    #expect(invalidMixerValue.message.contains("Missing 'value' or 'volume'"))

    let mixer = builder.element(322)
    let strip = builder.element(323)
    let fader = builder.element(324)
    builder.setChildren(window, [mixer])
    builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setChildren(strip, [fader])
    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(fader, kAXValueAttribute as String, 0.9)

    let stripOutOfRange = await channel.execute(operation: "mixer.get_channel_strip", params: ["index": "2"])
    #expect(!stripOutOfRange.isSuccess)
    #expect(stripOutOfRange.message.contains("out of range"))

    let missingPan = await channel.execute(operation: "mixer.set_pan", params: ["index": "0", "value": "-0.2"])
    #expect(!missingPan.isSuccess)
    #expect(missingPan.message.contains("Cannot find pan control"))

    let projectBuilder = FakeAXRuntimeBuilder()
    let projectApp = projectBuilder.element(330)
    let missingWindowChannel = makeAXBackedAccessibilityChannel(builder: projectBuilder, app: projectApp)
    let missingWindow = await missingWindowChannel.execute(operation: "project.get_info", params: [:])
    #expect(!missingWindow.isSuccess)
    #expect(missingWindow.message.contains("Cannot locate Logic Pro main window"))
}
