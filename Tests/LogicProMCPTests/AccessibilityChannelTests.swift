@preconcurrency import ApplicationServices
import Dispatch
import Foundation
import Testing
@testable import LogicProMCP

private func decodeAccessibilityJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

private final class MIDIRegionReadbackSequence: @unchecked Sendable {
    private var values: [AccessibilityChannel.MIDIImportRegionReadback]
    private let lock = NSLock()

    init(_ values: [AccessibilityChannel.MIDIImportRegionReadback]) {
        self.values = values
    }

    func next() -> AccessibilityChannel.MIDIImportRegionReadback {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return .success([]) }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private func midiRegionForImport(trackIndex: Int) -> RegionInfo {
    RegionInfo(
        name: "Imported MIDI",
        trackIndex: trackIndex,
        startBar: 1,
        endBar: 2,
        kind: "midi",
        rawHelp: nil
    )
}

private final class AccessibilityRuntimeRecorder: @unchecked Sendable {
    var transportButtons: [String] = []
    var tempoParams: [[String: String]] = []
    var cycleRangeParams: [[String: String]] = []
    var selectParams: [[String: String]] = []
    var trackToggleCalls: [([String: String], String)] = []
    var renameParams: [[String: String]] = []
    var channelStripParams: [[String: String]] = []
    var mixerValueCalls: [([String: String], AccessibilityChannel.MixerTarget)] = []
    var importedMIDIPaths: [String] = []
}

private final class ControlBarMouseRecorder: @unchecked Sendable {
    var mouseEvents: [(type: CGEventType, point: CGPoint, clickCount: Int64)] = []
    var keyEvents: [CGKeyCode] = []
    var unicodeEvents: [UniChar] = []
    var sleeps: [useconds_t] = []
    var onMouseEvent: ((CGEventType, CGPoint, Int64) -> Void)?
    var onKeyEvent: ((CGKeyCode) -> Void)?
    var onUnicodeScalar: ((UniChar) -> Void)?

    func runtime() -> AXMouseHelper.Runtime {
        AXMouseHelper.Runtime(
            postMouseEvent: { type, point, clickCount in
                self.mouseEvents.append((type, point, clickCount))
                self.onMouseEvent?(type, point, clickCount)
                return true
            },
            postKeyEvent: { keyCode in
                self.keyEvents.append(keyCode)
                self.onKeyEvent?(keyCode)
                return true
            },
            postUnicodeScalar: { scalar in
                self.unicodeEvents.append(scalar)
                self.onUnicodeScalar?(scalar)
                return true
            },
            sleepMicros: { micros in
                self.sleeps.append(micros)
            }
        )
    }
}

private final class TrackRenameSession: @unchecked Sendable {
    var editing = false
    var typed = ""
    var renamePressed = false
    var selectionCommitted = false
}

private final class BlockingExecuteProbe: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func waitUntilEntered(timeout: DispatchTimeInterval = .seconds(5)) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func unblock() {
        release.signal()
    }

    func block() {
        entered.signal()
        release.wait()
    }
}

private final class HealthCheckCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChannelHealth?

    func set(_ value: ChannelHealth) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func isReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }

    func get() -> ChannelHealth? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func waitUntilHealthCheckReady(
    _ completion: HealthCheckCompletion,
    timeoutNanoseconds: UInt64 = 500_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000
) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if completion.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return completion.isReady()
}

private func makeProcessRuntime(isRunning: Bool = true) -> ProcessUtils.Runtime {
    ProcessUtils.Runtime(
        logicProPID: { 4242 },
        fallbackLogicProPID: { 4242 },
        logicProRunning: { isRunning },
        activateLogicPro: { true },
        logicProBundleURL: { nil }
    )
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
        projectInfo: { .success("{\"project\":true}") },
        markers: { .success("[{\"name\":\"Intro\"}]") },
        importMIDIFile: { path in
            recorder.importedMIDIPaths.append(path)
            return .success("{\"imported\":\"\(path)\"}")
        }
    )
}

private func makeAXBackedAccessibilityChannel(
    builder: FakeAXRuntimeBuilder,
    app: AXUIElement,
    logicRuntime: AXLogicProElements.Runtime? = nil,
    isTrusted: Bool = true,
    isRunning: Bool = true,
    controlBarMouseRuntime: AXMouseHelper.Runtime = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { _ in false },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    ),
    trackRenameMouseRuntime: AXMouseHelper.Runtime = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { _ in false },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    ),
    processRuntime: ProcessUtils.Runtime = makeProcessRuntime(),
    runTempoFallback: @escaping @Sendable (String) -> Bool = { _ in false }
) -> AccessibilityChannel {
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { isTrusted },
        isLogicProRunning: { isRunning },
        logicRuntime: logicRuntime ?? builder.makeLogicRuntime(appElement: app),
        controlBarMouseRuntime: controlBarMouseRuntime,
        trackRenameMouseRuntime: trackRenameMouseRuntime,
        processRuntime: processRuntime,
        runTempoFallback: runTempoFallback
    )
    return AccessibilityChannel(runtime: runtime)
}

/// #107: a logic runtime whose AXIncrement/AXDecrement move a slider by one
/// ~10-raw-unit detent (clamped to AXMin/AXMax), so the closed-loop nudge
/// writer (`mixer.set_volume`/`set_pan`) converges against a fake AX tree.
private func nudgeResponsiveLogicRuntime(_ builder: FakeAXRuntimeBuilder, app: AXUIElement) -> AXLogicProElements.Runtime {
    builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            let number: @Sendable (String) -> Double? = { attr in
                if let n = builder.attributeValue(element, attr) as? NSNumber { return n.doubleValue }
                return builder.attributeValue(element, attr) as? Double
            }
            let delta: Double = (action == (kAXIncrementAction as String)) ? 10
                : ((action == (kAXDecrementAction as String)) ? -10 : 0)
            guard delta != 0, let cur = number(kAXValueAttribute as String) else { return true }
            let lo = number(kAXMinValueAttribute as String) ?? -1e9
            let hi = number(kAXMaxValueAttribute as String) ?? 1e9
            builder.setAttribute(element, kAXValueAttribute as String, Swift.min(Swift.max(cur + delta, lo), hi))
            return true
        }
    )
}

/// #107: build a Logic-12-style track-header rail (AXList id="Track Headers")
/// with one header carrying a "Volume" fader (range/value) and a pan slider
/// (empty desc, "0 Pan" value-indicator child). Returns the fader + pan.
@discardableResult
private func attachTrackHeaderRail(
    _ builder: FakeAXRuntimeBuilder,
    window: AXUIElement,
    siblings: [AXUIElement],
    baseID: Int,
    volume: (value: Double, min: Double, max: Double),
    pan: (value: Double, min: Double, max: Double)
) -> (volume: AXUIElement, pan: AXUIElement) {
    let rail = builder.element(baseID)
    builder.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
    let header = builder.element(baseID + 1)
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    let volumeSlider = builder.element(baseID + 2)
    builder.setAttribute(volumeSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(volumeSlider, kAXDescriptionAttribute as String, "Volume")
    builder.setAttribute(volumeSlider, kAXValueAttribute as String, volume.value)
    builder.setAttribute(volumeSlider, kAXMinValueAttribute as String, volume.min)
    builder.setAttribute(volumeSlider, kAXMaxValueAttribute as String, volume.max)
    let panSlider = builder.element(baseID + 3)
    builder.setAttribute(panSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(panSlider, kAXDescriptionAttribute as String, "")
    builder.setAttribute(panSlider, kAXValueAttribute as String, pan.value)
    builder.setAttribute(panSlider, kAXMinValueAttribute as String, pan.min)
    builder.setAttribute(panSlider, kAXMaxValueAttribute as String, pan.max)
    let panIndicator = builder.element(baseID + 4)
    builder.setAttribute(panIndicator, kAXRoleAttribute as String, "AXValueIndicator")
    builder.setAttribute(panIndicator, kAXDescriptionAttribute as String, "0 Pan")
    builder.setChildren(panSlider, [panIndicator])
    builder.setChildren(header, [volumeSlider, panSlider])
    builder.setChildren(rail, [header])
    builder.setChildren(window, siblings + [rail])
    return (volumeSlider, panSlider)
}

private func makeSetInstrumentFixture() -> (
    builder: FakeAXRuntimeBuilder,
    app: AXUIElement,
    firstHeader: AXUIElement,
    secondHeader: AXUIElement,
    category: AXUIElement,
    preset: AXUIElement
) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(20_000)
    let window = builder.element(20_001)
    let trackList = builder.element(20_002)
    let firstHeader = builder.element(20_003)
    let firstName = builder.element(20_004)
    let secondHeader = builder.element(20_005)
    let secondName = builder.element(20_006)
    let browser = builder.element(20_007)
    let categoryList = builder.element(20_008)
    let presetList = builder.element(20_009)
    let category = builder.element(20_010)
    let preset = builder.element(20_011)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [trackList, browser])

    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [firstHeader, secondHeader])

    builder.setAttribute(firstHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(firstHeader, kAXTitleAttribute as String, "Kick")
    builder.setAttribute(firstHeader, kAXSelectedAttribute as String, true)
    builder.setChildren(firstHeader, [firstName])
    builder.setAttribute(firstName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(firstName, kAXValueAttribute as String, "Kick")

    builder.setAttribute(secondHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(secondHeader, kAXTitleAttribute as String, "Bass Track")
    builder.setAttribute(secondHeader, kAXSelectedAttribute as String, false)
    builder.setChildren(secondHeader, [secondName])
    builder.setAttribute(secondName, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(secondName, kAXValueAttribute as String, "Bass Track")

    builder.setAttribute(browser, kAXRoleAttribute as String, kAXBrowserRole as String)
    builder.setAttribute(browser, kAXDescriptionAttribute as String, "Library")
    builder.setChildren(browser, [categoryList, presetList])

    builder.setAttribute(categoryList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setChildren(categoryList, [category])
    builder.setAttribute(presetList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setChildren(presetList, [preset])

    builder.setAttribute(category, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(category, kAXValueAttribute as String, "Bass")
    builder.setAttribute(category, kAXPositionAttribute as String, axPoint(120, 120))
    builder.setAttribute(category, kAXSizeAttribute as String, axSize(90, 22))
    builder.setAttribute(category, kAXParentAttribute as String, categoryList)

    builder.setAttribute(preset, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(preset, kAXValueAttribute as String, "Sub Bass")
    builder.setAttribute(preset, kAXPositionAttribute as String, axPoint(300, 120))
    builder.setAttribute(preset, kAXSizeAttribute as String, axSize(120, 22))
    builder.setAttribute(preset, kAXParentAttribute as String, presetList)

    builder.setAttribute(categoryList, kAXSelectedChildrenAttribute as String, [category])
    builder.setAttribute(presetList, kAXSelectedChildrenAttribute as String, [preset])

    return (builder, app, firstHeader, secondHeader, category, preset)
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

    #expect(!(await untrusted.healthCheck().available))
    #expect(await untrusted.healthCheck().detail.contains("Accessibility not trusted"))

    #expect(!(await notRunning.healthCheck().available))
    #expect(await notRunning.healthCheck().detail.contains("Logic Pro is not running"))

    #expect(!(await missingRoot.healthCheck().available))
    #expect(await missingRoot.healthCheck().detail.contains("Cannot access Logic Pro AX element"))

    let healthyState = await healthy.healthCheck()
    #expect(healthyState.available)
    #expect(healthyState.detail.contains("AX connected"))
}

@Test func testAccessibilityHealthCheckDoesNotWaitBehindBlockingExecute() async {
    let probe = BlockingExecuteProbe()
    let base = makeAccessibilityRuntime()
    let runtime = AccessibilityChannel.Runtime(
        isTrusted: base.isTrusted,
        isLogicProRunning: base.isLogicProRunning,
        appRoot: base.appRoot,
        transportState: base.transportState,
        toggleTransportButton: base.toggleTransportButton,
        setTempo: base.setTempo,
        setCycleRange: base.setCycleRange,
        tracks: {
            probe.block()
            return .success("[]")
        },
        selectedTrack: base.selectedTrack,
        selectTrack: base.selectTrack,
        setTrackToggle: base.setTrackToggle,
        renameTrack: base.renameTrack,
        mixerState: base.mixerState,
        channelStrip: base.channelStrip,
        setMixerValue: base.setMixerValue,
        projectInfo: base.projectInfo,
        markers: base.markers,
        importMIDIFile: base.importMIDIFile,
        logicRuntime: base.logicRuntime
    )
    let channel = AccessibilityChannel(runtime: runtime)
    let healthCompletion = HealthCheckCompletion()

    let executeTask = Task.detached(priority: .userInitiated) {
        await channel.execute(operation: "track.get_tracks", params: [:])
    }
    #expect(probe.waitUntilEntered())

    let healthTask = Task.detached(priority: .userInitiated) {
        healthCompletion.set(await channel.healthCheck())
    }

    let finishedWhileExecuteBlocked = await waitUntilHealthCheckReady(healthCompletion)
    probe.unblock()
    _ = await executeTask.value
    _ = await healthTask.value

    #expect(finishedWhileExecuteBlocked)
    let health = healthCompletion.get()
    #expect(health!.available)
    #expect(health!.detail.contains("AX connected"))
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
        ("transport.toggle_count_in", [:]),
        ("transport.play", [:]),
        ("transport.stop", [:]),
        ("transport.record", [:]),
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
        ("nav.get_markers", [:]),
        ("project.get_info", [:]),
    ]

    for (operation, params) in operations {
        let result = await channel.execute(operation: operation, params: params)
        #expect(result.isSuccess, "Expected \(operation) to route through runtime")
    }

    #expect(recorder.transportButtons == ["Cycle", "Metronome", "CountIn", "Play", "Stop", "Record"])
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

@Test func testAccessibilityChannelMIDIImportValidatesManagedTempPathBeforeRuntimeImport() async throws {
    let recorder = AccessibilityRuntimeRecorder()
    let channel = AccessibilityChannel(runtime: makeAccessibilityRuntime(recorder: recorder))
    let tempFile = try SMFWriter.temporaryMIDIFile()
    try Data([0x4d, 0x54, 0x68, 0x64]).write(to: tempFile.fileURL)
    defer { SMFWriter.cleanupTemporaryMIDIFile(tempFile) }

    let missing = await channel.execute(operation: "midi.import_file", params: [:])
    let invalid = await channel.execute(operation: "midi.import_file", params: ["path": "/tmp/not-managed.mid"])
    let valid = await channel.execute(operation: "midi.import_file", params: ["path": tempFile.fileURL.path])

    #expect(!missing.isSuccess)
    #expect(missing.message.contains("requires 'path'"))
    #expect(!invalid.isSuccess)
    #expect(invalid.message.contains("server-managed LogicProMCP temp .mid"))
    #expect(valid.isSuccess)
    #expect(recorder.importedMIDIPaths == [tempFile.fileURL.path])
}

@Test func testAccessibilityChannelFastValidationErrorsCoverDeepOperationsWithoutTouchingUI() async {
    let channel = AccessibilityChannel(runtime: makeAccessibilityRuntime())
    let cases: [(operation: String, params: [String: String], expected: String)] = [
        ("transport.goto_position", [:], "goto_position requires"),
        ("transport.goto_position", ["position": "01:02:03:04"], "cannot handle timecode"),
        ("project.save_as", [:], "Missing 'path'"),
        ("project.save_as", ["path": "relative.logicx"], "absolute .logicx"),
        ("track.set_instrument", [:], "Missing path"),
        ("track.set_instrument", ["path": "Bass"], "at least 2 segments"),
        ("plugin.insert", [:], "explicit 'track'"),
        ("plugin.insert", ["track": "0"], "explicit 'slot'"),
        ("plugin.insert", ["track": "0", "slot": "1"], "unsupported plugin"),
    ]

    for testCase in cases {
        let result = await channel.execute(operation: testCase.operation, params: testCase.params)
        #expect(!result.isSuccess, "Expected \(testCase.operation) to fail validation")
        #expect(result.message.contains(testCase.expected), "Expected \(result.message) to contain \(testCase.expected)")
    }
}

@Test func testAccessibilityChannelReturnsExpectedUnimplementedAndUnsupportedErrors() async {
    let channel = AccessibilityChannel(runtime: makeAccessibilityRuntime())

    let expectations: [(String, String)] = [
        // v3.1.2 P2-1: track.set_color now returns a State C envelope with
        // `error:"not_implemented"` instead of a plain free-form string.
        ("track.set_color", "\"error\":\"not_implemented\""),
        ("mixer.set_send", "Send adjustment not yet implemented via AX"),
        ("mixer.set_input", "I/O routing not yet implemented via AX"),
        ("mixer.set_output", "I/O routing not yet implemented via AX"),
        ("mixer.toggle_eq", "EQ toggle not yet implemented via AX"),
        ("mixer.reset_strip", "Strip reset not yet implemented via AX"),
        // Issue #143: rename_marker now returns a State C envelope with
        // `error:"not_implemented"` (+ a create+delete workaround hint)
        // instead of a plain free-form string, so the router surfaces it
        // verbatim instead of re-wrapping it as `channels_exhausted`.
        ("nav.rename_marker", "\"error\":\"not_implemented\""),
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

// Issue #143 — `nav.rename_marker` short-circuits inside the operation
// switch (it never touches the AX tree), so the default runtime suffices.
// It must emit an explicit State C `not_implemented` envelope with a
// create+delete workaround hint — NOT a free-form string that the router
// would re-wrap as `channels_exhausted` (which conflates "feature not built"
// with "all channels failed").
@Test func testRenameMarkerReturnsNotImplementedEnvelope() async {
    let channel = AccessibilityChannel(runtime: makeAccessibilityRuntime())

    let result = await channel.execute(
        operation: "nav.rename_marker",
        params: ["index": "2", "name": "Big Chorus"]
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "not_implemented")
    let hint = obj["hint"] as? String ?? ""
    #expect(hint.contains("delete_marker"), "expected create+delete workaround hint, got: \(hint)")
    #expect(hint.contains("create_marker"), "expected create+delete workaround hint, got: \(hint)")

    // `not_implemented` is in `terminalErrorCodes`, so the router classifies
    // this as terminal and surfaces it verbatim (no `channels_exhausted`).
    #expect(
        HonestContract.isTerminalStateC(result.message),
        "rename_marker State C must be terminal so the router skips fallback"
    )
}

@Test func testAccessibilityChannelAXBackedRegionReadReturnsParsedRegions() async throws {
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

@Test func testAccessibilityChannelAXBackedRegionsRecognizeTracksContentsAndFilterOffscreen() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(900)
    let window = builder.element(901)
    let headerRail = builder.element(902)
    let header0 = builder.element(903)
    let header1 = builder.element(904)
    let contentGroup = builder.element(905)
    let visibleMIDI = builder.element(906)
    let offscreenAudio = builder.element(907)
    let visibleDrummer = builder.element(908)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, contentGroup])
    builder.setAttribute(window, kAXPositionAttribute as String, axPoint(0, 0))
    builder.setAttribute(window, kAXSizeAttribute as String, axSize(1_200, 400))

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "Tracks header")
    builder.setChildren(headerRail, [header0, header1])

    builder.setAttribute(header0, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(header0, kAXPositionAttribute as String, axPoint(0, 100))
    builder.setAttribute(header0, kAXSizeAttribute as String, axSize(200, 40))

    builder.setAttribute(header1, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(header1, kAXPositionAttribute as String, axPoint(0, 160))
    builder.setAttribute(header1, kAXSizeAttribute as String, axSize(200, 40))

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "Tracks contents")
    builder.setChildren(contentGroup, [visibleMIDI, offscreenAudio, visibleDrummer])

    builder.setAttribute(visibleMIDI, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(visibleMIDI, kAXDescriptionAttribute as String, "MIDI Region")
    builder.setAttribute(visibleMIDI, kAXHelpAttribute as String, "Region starts at 1 bars and ends at 2 bars, MIDI region.")
    builder.setAttribute(visibleMIDI, kAXPositionAttribute as String, axPoint(240, 108))
    builder.setAttribute(visibleMIDI, kAXSizeAttribute as String, axSize(320, 24))

    builder.setAttribute(offscreenAudio, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(offscreenAudio, kAXDescriptionAttribute as String, "Audio Region")
    builder.setAttribute(offscreenAudio, kAXHelpAttribute as String, "Region starts at 33 bars and ends at 34 bars, audio region.")
    builder.setAttribute(offscreenAudio, kAXPositionAttribute as String, axPoint(2_500, 108))
    builder.setAttribute(offscreenAudio, kAXSizeAttribute as String, axSize(320, 24))

    builder.setAttribute(visibleDrummer, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(visibleDrummer, kAXDescriptionAttribute as String, "Session Player Region")
    builder.setAttribute(visibleDrummer, kAXHelpAttribute as String, "Region starts at 9 bars and ends at 13 bars, Session Player region.")
    builder.setAttribute(visibleDrummer, kAXPositionAttribute as String, axPoint(260, 168))
    builder.setAttribute(visibleDrummer, kAXSizeAttribute as String, axSize(360, 24))

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let result = await channel.execute(operation: "region.get_regions", params: [:])

    #expect(result.isSuccess)

    let regions = try JSONDecoder().decode([RegionInfo].self, from: Data(result.message.utf8))
    #expect(regions.count == 2)
    #expect(regions[0].name == "MIDI Region")
    #expect(regions[0].trackIndex == 0)
    #expect(regions[0].startBar == 1)
    #expect(regions[0].endBar == 2)
    #expect(regions[0].kind == "midi")
    #expect(regions[1].name == "Session Player Region")
    #expect(regions[1].trackIndex == 1)
    #expect(regions[1].startBar == 9)
    #expect(regions[1].endBar == 13)
    #expect(regions[1].kind == "drummer")
}

@Test func testAccessibilityChannelAXBackedRegionsMissingContentGroupIncludesHint() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(950)
    let window = builder.element(951)
    let headerRail = builder.element(952)
    let projectGroup = builder.element(953)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, projectGroup])

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "Tracks header")

    builder.setAttribute(projectGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(projectGroup, kAXDescriptionAttribute as String, "Project")

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let result = await channel.execute(operation: "region.get_regions", params: [:])

    #expect(!result.isSuccess)
    #expect(result.message.contains("Track Content group not found"))
    #expect(result.message.contains("Tracks header"))
    #expect(result.message.contains("Recovery hint"))
}

@Test func testAccessibilityChannelAXBackedRegionReadAcceptsPluralTracksContentsLabel() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(70)
    let window = builder.element(71)
    let headerRail = builder.element(72)
    let trackHeader = builder.element(73)
    let contentGroup = builder.element(74)
    let region = builder.element(75)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, contentGroup])

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "Tracks header")
    builder.setChildren(headerRail, [trackHeader])

    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXPositionAttribute as String, axPoint(0, 100))
    builder.setAttribute(trackHeader, kAXSizeAttribute as String, axSize(200, 40))

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "Tracks contents")
    builder.setChildren(contentGroup, [region])

    builder.setAttribute(region, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(region, kAXDescriptionAttribute as String, "Imported Idea")
    builder.setAttribute(region, kAXHelpAttribute as String, "Region starts at bar 1 and ends at bar 2, MIDI region.")
    builder.setAttribute(region, kAXPositionAttribute as String, axPoint(240, 108))
    builder.setAttribute(region, kAXSizeAttribute as String, axSize(320, 24))

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let result = await channel.execute(operation: "region.get_regions", params: [:])

    #expect(result.isSuccess)

    let regions = try JSONDecoder().decode([RegionInfo].self, from: Data(result.message.utf8))
    #expect(regions.count == 1)
    #expect(regions[0].name == "Imported Idea")
    #expect(regions[0].trackIndex == 0)
    #expect(regions[0].startBar == 1)
    #expect(regions[0].endBar == 2)
    #expect(regions[0].kind == "midi")
}

@Test func testAccessibilityChannelAXBackedRegionReadAcceptsNumericBeforeBarEnglishHelp() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(76)
    let window = builder.element(77)
    let headerRail = builder.element(78)
    let trackHeader = builder.element(79)
    let contentGroup = builder.element(80)
    let region = builder.element(81)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [headerRail, contentGroup])

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "Tracks header")
    builder.setChildren(headerRail, [trackHeader])

    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXPositionAttribute as String, axPoint(0, 100))
    builder.setAttribute(trackHeader, kAXSizeAttribute as String, axSize(200, 40))

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "Tracks contents")
    builder.setChildren(contentGroup, [region])

    builder.setAttribute(region, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(region, kAXDescriptionAttribute as String, "Imported Idea")
    builder.setAttribute(
        region,
        kAXHelpAttribute as String,
        "Region starts at 1 bar  and ends at 2 bars , MIDI region."
    )
    builder.setAttribute(region, kAXPositionAttribute as String, axPoint(240, 108))
    builder.setAttribute(region, kAXSizeAttribute as String, axSize(320, 24))

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let result = await channel.execute(operation: "region.get_regions", params: [:])

    #expect(result.isSuccess)

    let regions = try JSONDecoder().decode([RegionInfo].self, from: Data(result.message.utf8))
    #expect(regions.count == 1)
    #expect(regions[0].name == "Imported Idea")
    #expect(regions[0].trackIndex == 0)
    #expect(regions[0].startBar == 1)
    #expect(regions[0].endBar == 2)
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

    // set_tempo locates the tempo AXSlider. In this fixture the slider has no
    // AX position/size, so defaultSetTempo takes the geometry-free "slider-direct"
    // branch (blind setAttribute + confirm, readback unavailable) → State B. The
    // slider-increment mismatch path (#189) is exercised hermetically in
    // testSetTempoSliderIncrementMismatchFailsClosed below.
    let tempoResult = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "132.0"])
    #expect(tempoResult.isSuccess)
    #expect(!tempoResult.message.contains("element_not_found"))
    #expect(tempoResult.message.contains("\"requested\":132"))
    #expect(tempoResult.message.contains("\"via\":\"slider-direct\""))

    let cycleMissing = await channel.execute(operation: "transport.set_cycle_range", params: [:])
    #expect(!cycleMissing.isSuccess)
    #expect(cycleMissing.message.contains("\"error\":\"invalid_params\""))

    let cycleUnsupported = await channel.execute(
        operation: "transport.set_cycle_range",
        params: ["start": "1.1.1.1", "end": "9.1.1.1"]
    )
    // With the fake AX tree (no transport bar cycle fields) and osascript
    // fallback unavailable in unit tests, the handler must fail closed with a
    // specific structured envelope rather than a free-form string.
    #expect(!cycleUnsupported.isSuccess)
    #expect(cycleUnsupported.message.contains("\"error\":\"not_implemented\""))
    #expect(cycleUnsupported.message.contains("\"requested\""))
    #expect(cycleUnsupported.message.contains("\"observed\""))
    #expect(cycleUnsupported.message.contains("\"scanned_landmarks\""))
}

@Test func testAccessibilityChannelTransportStatePrefersLiveControlBarOverStaleTransportGroup() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(110)
    let window = builder.element(111)
    let staleTransport = builder.element(112)
    let staleCycle = builder.element(113)
    let controlBar = builder.element(114)
    let liveCycle = builder.element(115)
    let liveMetronome = builder.element(116)
    let tempoSlider = builder.element(117)
    let staleCycleDuplicate = builder.element(118)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [staleTransport, controlBar])

    builder.setAttribute(staleTransport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(staleTransport, kAXIdentifierAttribute as String, "Transport")
    builder.setChildren(staleTransport, [staleCycle])
    builder.setAttribute(staleCycle, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(staleCycle, kAXDescriptionAttribute as String, "Cycle")
    builder.setAttribute(staleCycle, kAXValueAttribute as String, NSNumber(value: false))

    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [liveCycle, liveMetronome, tempoSlider, staleCycleDuplicate])
    builder.setAttribute(liveCycle, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(liveCycle, kAXTitleAttribute as String, "Cycle")
    builder.setAttribute(liveCycle, kAXValueAttribute as String, NSNumber(value: true))
    builder.setAttribute(liveMetronome, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(liveMetronome, kAXTitleAttribute as String, "Metronome")
    builder.setAttribute(liveMetronome, kAXValueAttribute as String, NSNumber(value: true))
    builder.setAttribute(tempoSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(tempoSlider, kAXDescriptionAttribute as String, "Tempo")
    builder.setAttribute(tempoSlider, kAXValueAttribute as String, NSNumber(value: 127.0))
    builder.setAttribute(staleCycleDuplicate, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(staleCycleDuplicate, kAXDescriptionAttribute as String, "Cycle")
    builder.setAttribute(staleCycleDuplicate, kAXValueAttribute as String, NSNumber(value: false))

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)

    let result = await channel.execute(operation: "transport.get_state", params: [:])

    #expect(result.isSuccess)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(TransportState.self, from: Data(result.message.utf8))
    #expect(state.isCycleEnabled)
    #expect(state.isMetronomeEnabled)
    #expect(state.tempo == 127.0)
}

@Test func testAccessibilityChannelControlBarToggleUsesMouseClickAndVerifiesReadback() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(120)
    let window = builder.element(121)
    let controlBar = builder.element(122)
    let cycle = builder.element(123)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [cycle])

    builder.setAttribute(cycle, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(cycle, kAXTitleAttribute as String, "Cycle")
    builder.setAttribute(cycle, kAXValueAttribute as String, NSNumber(value: false))
    builder.setAttribute(cycle, kAXPositionAttribute as String, axPoint(100, 200))
    builder.setAttribute(cycle, kAXSizeAttribute as String, axSize(24, 18))

    let mouse = ControlBarMouseRecorder()
    mouse.onMouseEvent = { type, _, _ in
        if type == .leftMouseUp {
            builder.setAttribute(cycle, kAXValueAttribute as String, NSNumber(value: true))
        }
    }
    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        controlBarMouseRuntime: mouse.runtime()
    )

    let result = await channel.execute(operation: "transport.toggle_cycle", params: [:])
    let object = decodeAccessibilityJSON(result.message)

    #expect(result.isSuccess)
    #expect((object["verified"] as? Bool)!)
    #expect(object["action"] as? String == "mouse-click")
    #expect(mouse.mouseEvents.map(\.type) == [.leftMouseDown, .leftMouseUp])
    #expect(builder.actionCalls.isEmpty)
    #expect(((builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue)!)
}

@Test func testAccessibilityChannelControlBarToggleDoesNotTrustNoopAXPress() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(130)
    let window = builder.element(131)
    let controlBar = builder.element(132)
    let cycle = builder.element(133)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [cycle])

    builder.setAttribute(cycle, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(cycle, kAXTitleAttribute as String, "Cycle")
    builder.setAttribute(cycle, kAXValueAttribute as String, NSNumber(value: false))

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)

    let result = await channel.execute(operation: "transport.toggle_cycle", params: [:])
    let object = decodeAccessibilityJSON(result.message)

    #expect(!result.isSuccess)
    #expect(object["error"] as? String == "readback_mismatch")
    #expect(builder.actionCalls.contains { $0.elementID == builder.elementID(cycle) && $0.action == kAXPressAction as String })
    #expect(!(((builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue)!))
}

@Test func testAccessibilityChannelControlBarToggleAcceptsAXPressOnlyAfterReadbackChanges() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(140)
    let window = builder.element(141)
    let controlBar = builder.element(142)
    let cycle = builder.element(143)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [cycle])

    builder.setAttribute(cycle, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(cycle, kAXTitleAttribute as String, "Cycle")
    builder.setAttribute(cycle, kAXValueAttribute as String, NSNumber(value: false))

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            if element == cycle && action == kAXPressAction as String {
                builder.setAttribute(cycle, kAXValueAttribute as String, NSNumber(value: true))
                return true
            }
            return true
        }
    )
    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        logicRuntime: logicRuntime
    )

    let result = await channel.execute(operation: "transport.toggle_cycle", params: [:])
    let object = decodeAccessibilityJSON(result.message)

    #expect(result.isSuccess)
    #expect((object["verified"] as? Bool)!)
    #expect(object["action"] as? String == "axpress")
    #expect(((builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue)!)
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
    #expect(missingButton.message.contains("\"error\":\"element_not_found\""))
    #expect(missingButton.message.contains("transport button 'Metronome' not located"))

    let invalidTempo = await missingTransportChannel.execute(operation: "transport.set_tempo", params: [:])
    #expect(!invalidTempo.isSuccess)
    #expect(invalidTempo.message.contains("\"error\":\"invalid_params\""))
    #expect(invalidTempo.message.contains("requires 'tempo' or 'bpm'"))

    let missingTempoField = await missingTransportChannel.execute(operation: "transport.set_tempo", params: ["tempo": "126"])
    #expect(!missingTempoField.isSuccess)
    #expect(missingTempoField.message.contains("\"error\":\"element_not_found\""))
    #expect(missingTempoField.message.contains("tempo slider not located"))

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
    #expect(pressFailure.message.contains("\"error\":\"ax_write_failed\""))
    #expect(pressFailure.message.contains("AXPress failed on transport button 'Metronome'"))
    #expect(!HonestContract.isTerminalStateC(pressFailure.message))
}

@Test func testAccessibilityChannelAXBackedTempoFallbackCanBeInjected() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(160)
    let window = builder.element(161)
    let controlBar = builder.element(162)
    let trackList = builder.element(163)
    let trackHeader = builder.element(164)
    let barSlider = builder.element(165)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar, trackList])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [barSlider])
    builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXSelectedAttribute as String, true)

    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        runTempoFallback: { tempo in tempo == "126" }
    )

    let result = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "126"])
    #expect(!result.isSuccess)
    #expect(result.message.contains("\"error\":\"readback_unavailable\""))
    #expect(result.message.contains("\"via\":\"keyboard-fallback\""))
    #expect(result.message.contains("\"requested\":126"))
    #expect(result.message.contains("\"track_header_count\":1"))
    #expect(result.message.contains("\"control_bar_found\":true"))
    #expect(result.message.contains("\"control_bar_slider_descriptions\":[\"Bar\"]"))
}

@Test func testImportMIDIFileFailsClosedWhenSystemEventsAutomationDenied() async throws {
    // #188: when Automation → System Events is not authorized, the import must
    // fail closed with a typed permission error BEFORE the mutation — it must
    // NOT run the import script and abort mid-flight with a bare Apple Events
    // denial.
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicProMCP-se-denied-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { false },
        path: tempFile.path,
        executeScript: { _ in
            Issue.record("import script must not run when System Events automation is denied")
            return .error("should not run")
        },
        trackCount: { 1 },
        regionInfos: { .success([]) },
        deltaPoll: {}
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "permission_denied")
    #expect(obj["permission"] as? String == "automation_system_events")
    #expect(obj["failure_stage"] as? String == "preflight_system_events_permission")
    #expect(!((obj["write_attempted"] as? Bool)!))
    #expect((obj["safe_to_retry"] as? Bool)!)
}

// MARK: - #189 set_tempo slider-increment fail-closed

/// Build a control-bar tempo slider that HAS AX geometry, so defaultSetTempo
/// takes the doubleClick/type path (no-op under the fake mouse runtime), the
/// typed entry "doesn't commit" (value unchanged), and it falls to the
/// slider-increment fallback — the exact #189 path.
private func makeTempoSliderFixture(
    builder: FakeAXRuntimeBuilder,
    tempoValue: Double
) -> (app: AXUIElement, slider: AXUIElement) {
    let app = builder.element(7100)
    let window = builder.element(7101)
    let controlBar = builder.element(7102)
    let tempoSlider = builder.element(7103)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [tempoSlider])
    builder.setAttribute(tempoSlider, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(tempoSlider, kAXDescriptionAttribute as String, "Tempo")
    builder.setAttribute(tempoSlider, kAXValueAttribute as String, NSNumber(value: tempoValue))
    var point = CGPoint(x: 40, y: 12)
    builder.setAttribute(tempoSlider, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &point)!)
    var size = CGSize(width: 60, height: 18)
    builder.setAttribute(tempoSlider, kAXSizeAttribute as String, AXValueCreate(.cgSize, &size)!)
    return (app, tempoSlider)
}

@Test func testSetTempoSliderIncrementMismatchFailsClosed() async {
    // #189 regression: when typed entry doesn't commit and the 10-BPM increment
    // fallback CANNOT land the requested tempo, set_tempo must fail closed with
    // State C `readback_mismatch` — NEVER report success on a readback mismatch.
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeTempoSliderFixture(builder: builder, tempoValue: 120.0)
    // Default fake performAction is a no-op, so the increment never moves the
    // slider; observed stays 120 while 96 was requested.
    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: fixture.app)

    let result = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "96"])

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect(obj["via"] as? String == "slider-increment")
    #expect((obj["requested"] as? Double) == 96)
    #expect((obj["observed"] as? Double) == 120)
    #expect((obj["safe_to_retry"] as? Bool)!)
    // The bug was a State B success envelope; assert it is gone.
    #expect(obj["reason"] == nil)
}

@Test func testSetTempoSliderIncrementExactLandingIsStateA() async {
    // The slider-increment fallback reports success ONLY when the observed value
    // matches the request within tolerance. A nudge-responsive runtime moves the
    // slider +10 per increment, so requesting 130 from 120 lands exactly → State A.
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeTempoSliderFixture(builder: builder, tempoValue: 120.0)
    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: fixture.app,
        logicRuntime: nudgeResponsiveLogicRuntime(builder, app: fixture.app)
    )

    let result = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "130"])

    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["via"] as? String == "slider-increment")
    #expect((obj["requested"] as? Double) == 130)
    #expect((obj["observed"] as? Double) == 130)
    #expect(obj["error"] == nil)
}

@Test func testAccessibilityChannelImportMIDIFileReturnsErrorWhenTrackCountDoesNotIncrease() async throws {
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicProMCP-import-mismatch-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: tempFile.path,
        executeScript: { _ in .success("OK") },
        trackCount: { 3 },
        regionInfos: { .success([]) },
        deltaPoll: {}
    )

    #expect(!result.isSuccess)
    #expect(result.message.contains("\"error\":\"readback_mismatch\""))
    #expect(result.message.contains("did not create a new track"))
    #expect(result.message.contains("\"observed_delta\":0"))
}

@Test func testAccessibilityChannelImportMIDIFileVerifiedWhenTrackCountIncreases() async throws {
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicProMCP-import-verified-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    final class Counter: @unchecked Sendable {
        var values = [2, 3]
        func next() -> Int {
            values.removeFirst()
        }
    }
    let counter = Counter()
    let regions = MIDIRegionReadbackSequence([
        .success([]),
        .success([midiRegionForImport(trackIndex: 2)]),
    ])

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: tempFile.path,
        executeScript: { _ in .success("OK") },
        trackCount: { counter.next() },
        trackNames: { ["Studio Grand", "01 Felt Keys"] },
        regionInfos: { regions.next() },
        deltaPoll: {}
    )

    #expect(result.isSuccess)
    #expect(result.message.contains("\"verified\":true"))
    #expect(result.message.contains("\"observed_delta\":1"))
}

// MARK: - #128 GM Device audibility downgrade

@Test func testGMDeviceLanesAmongNewTracksClassifiesOnlyNewExternalMIDILanes() {
    // Pre-existing GM Device track must NOT trip the gate; only the newly
    // appended lanes are inspected.
    let preExistingGM = AccessibilityChannel.gmDeviceLanesAmongNewTracks(
        names: ["GM Device 1", "01 Felt Keys"],
        beforeCount: 1
    )
    #expect(preExistingGM.isEmpty)

    // A newly appended GM Device lane IS flagged.
    let newGM = AccessibilityChannel.gmDeviceLanesAmongNewTracks(
        names: ["Studio Grand", "GM Device 1", "GM Device 2"],
        beforeCount: 1
    )
    #expect(newGM == ["GM Device 1", "GM Device 2"])

    // A Software Instrument track whose user name happens to contain "midi"
    // (but not the literal lane tokens) must NOT be flagged.
    let benignName = AccessibilityChannel.gmDeviceLanesAmongNewTracks(
        names: ["Studio Grand", "MIDI Bass Lead"],
        beforeCount: 1
    )
    #expect(benignName.isEmpty)

    // External MIDI / External Instrument tokens are flagged too.
    let external = AccessibilityChannel.gmDeviceLanesAmongNewTracks(
        names: ["Studio Grand", "External MIDI 3"],
        beforeCount: 1
    )
    #expect(external == ["External MIDI 3"])
}

@Test func testAccessibilityChannelImportMIDIFileDowngradesToStateBOnGMDeviceLanes() async throws {
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicProMCP-import-gmdevice-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    final class Counter: @unchecked Sendable {
        var values = [1, 7]
        func next() -> Int { values.removeFirst() }
    }
    let counter = Counter()
    let regions = MIDIRegionReadbackSequence([
        .success([]),
        .success([midiRegionForImport(trackIndex: 1)]),
    ])

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: tempFile.path,
        executeScript: { _ in .success("OK TEMPO_SEEN") },
        trackCount: { counter.next() },
        trackNames: {
            ["Studio Grand", "GM Device 1", "GM Device 2", "GM Device 3",
             "GM Device 4", "GM Device 5", "GM Device 6"]
        },
        regionInfos: { regions.next() },
        deltaPoll: {}
    )

    // State B: success but NOT verified — count delta alone is not audible.
    #expect(result.isSuccess, "GM-Device import is a soft success (State B), not a hard failure")
    let obj = decodeAccessibilityJSON(result.message)
    let success = try #require(obj["success"] as? Bool)
    #expect(success)
    let verified = try #require(obj["verified"] as? Bool)
    #expect(!verified)
    #expect(obj["reason"] as? String == "imported_as_gm_device")
    let audible = try #require(obj["audible"] as? Bool)
    #expect(!audible)
    let gmLanes = try #require(obj["gm_device_lanes"] as? [String])
    #expect(gmLanes.count == 6)
    let hint = try #require(obj["hint"] as? String)
    #expect(hint.contains("GM Device"))
    // Dialog-seen flags are surfaced even on the downgrade path.
    let tempoSeen = try #require(obj["tempo_dialog_seen"] as? Bool)
    #expect(tempoSeen)
}

@Test func testAccessibilityChannelImportMIDIFileStateAWhenLanesAreSoftwareInstruments() async throws {
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicProMCP-import-si-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    final class Counter: @unchecked Sendable {
        var values = [1, 2]
        func next() -> Int { values.removeFirst() }
    }
    let counter = Counter()
    let regions = MIDIRegionReadbackSequence([
        .success([]),
        .success([midiRegionForImport(trackIndex: 1)]),
    ])

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: tempFile.path,
        executeScript: { _ in .success("OK") },
        trackCount: { counter.next() },
        trackNames: { ["Studio Grand", "01 Felt Keys"] },
        regionInfos: { regions.next() },
        deltaPoll: {}
    )

    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    let verified = try #require(obj["verified"] as? Bool)
    #expect(verified)
    #expect(obj["reason"] == nil)
    let fileOpenSeen = try #require(obj["file_open_dialog_seen"] as? Bool)
    #expect(fileOpenSeen)
}

// MARK: - #140 file-open dialog poll / dialog_not_found

@Test func testAccessibilityChannelImportMIDIFileReturnsDialogNotFoundWhenSheetNeverAppears() async throws {
    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicProMCP-import-nodialog-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    final class CountSpy: @unchecked Sendable {
        var reads = 0
        func read() -> Int { reads += 1; return 5 }
    }
    let spy = CountSpy()

    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: tempFile.path,
        executeScript: { _ in .success(#"{"result":"DIALOG_NOT_FOUND: file-open sheet did not appear"}"#) },
        trackCount: { spy.read() },
        trackNames: { [] },
        regionInfos: { .success([]) },
        deltaPoll: {}
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "dialog_not_found")
    #expect(obj["missing_element"] as? String == "file_open_sheet")
    let fileOpenSeen = try #require(obj["file_open_dialog_seen"] as? Bool)
    #expect(!fileOpenSeen)
    // dialog_not_found is terminal — the router must not fall through to a
    // vacuous next-channel success.
    #expect(HonestContract.terminalErrorCodes.contains("dialog_not_found"))
    // No track-count delta should be read once we know the dialog never opened:
    // the path keystroke was never issued so there is no import to verify.
    #expect(spy.reads == 1, "only the before-count read should occur on the dialog_not_found path")
}

@Test func testAccessibilityChannelImportMIDIFileMissingFileShortCircuits() async throws {
    let result = await AccessibilityChannel.defaultImportMIDIFile(
        systemEventsAuthorized: { true },
        path: "/tmp/LogicProMCP/does-not-exist-\(UUID().uuidString).mid",
        executeScript: { _ in .success("OK") },
        trackCount: { 0 },
        trackNames: { [] },
        regionInfos: { .success([]) },
        deltaPoll: {}
    )
    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "invalid_params")
}

@Test func testAccessibilityChannelValidatedMIDIImportPathAcceptsManagedTempMID() throws {
    let tempFile = try SMFWriter.temporaryMIDIFile()
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile.fileURL)
    defer { SMFWriter.cleanupTemporaryMIDIFile(tempFile) }

    let validated = AccessibilityChannel.validatedMIDIImportPath(tempFile.fileURL.path)

    #expect(validated == tempFile.fileURL.resolvingSymlinksInPath().standardizedFileURL.path)
}

@Test func testAccessibilityChannelValidatedMIDIImportPathRejectsUnregisteredPrefixMID() throws {
    let directory = URL(fileURLWithPath: SMFWriter.temporaryDirectoryPrefix() + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("external.mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: fileURL)

    #expect(AccessibilityChannel.validatedMIDIImportPath(fileURL.path) == nil)
}

@Test func testAccessibilityChannelValidatedMIDIImportPathRejectsAfterCleanup() throws {
    let tempFile = try SMFWriter.temporaryMIDIFile()
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile.fileURL)
    let path = tempFile.fileURL.path
    #expect(AccessibilityChannel.validatedMIDIImportPath(path) != nil)

    SMFWriter.cleanupTemporaryMIDIFile(tempFile)

    #expect(AccessibilityChannel.validatedMIDIImportPath(path) == nil)
}

@Test func testAccessibilityChannelManagedMIDIImportPrefixesMatchSMFWriter() {
    #expect(AccessibilityChannel.managedMIDIImportDirectoryPrefixes() == [SMFWriter.temporaryDirectoryPrefix()])
}

@Test func testAccessibilityChannelValidatedMIDIImportPathRejectsSymlinkEscape() throws {
    let tempFile = try SMFWriter.temporaryMIDIFile()
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicProMCP-outside-\(UUID().uuidString).mid")
    let link = tempFile.directoryURL.appendingPathComponent("link-\(UUID().uuidString).mid")
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: outside)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    defer {
        SMFWriter.cleanupTemporaryMIDIFile(tempFile)
        try? FileManager.default.removeItem(at: outside)
    }

    #expect(AccessibilityChannel.validatedMIDIImportPath(link.path) == nil)
}

@Test func testAccessibilityChannelValidatedMIDIImportPathRejectsControlCharacters() throws {
    let tempFile = try SMFWriter.temporaryMIDIFile()
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempFile.fileURL)
    defer { SMFWriter.cleanupTemporaryMIDIFile(tempFile) }

    #expect(AccessibilityChannel.validatedMIDIImportPath(tempFile.fileURL.path + "\n") == nil)
}

@Test func testAccessibilityChannelAXBackedTempoReturnsErrorWhenAXFieldMissing() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(700)
    let window = builder.element(701)
    let transport = builder.element(702)
    final class FallbackBox: @unchecked Sendable { var called = false }
    let fallbackBox = FallbackBox()
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [transport])
    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")

    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        runTempoFallback: { _ in
            fallbackBox.called = true
            return true
        }
    )

    let result = await channel.execute(operation: "transport.set_tempo", params: ["tempo": "126"])
    #expect(!result.isSuccess)
    #expect(result.message.contains("\"error\":\"element_not_found\""))
    #expect(result.message.contains("tempo slider not located"))
    #expect(result.message.contains("create a software instrument track first"))
    let object = decodeAccessibilityJSON(result.message)
    #expect(object["track_header_count"] as? Int == 0)
    #expect((object["transport_bar_found"] as? Bool)!)
    #expect(!((object["control_bar_found"] as? Bool)!))
    #expect(!((object["dialog_present"] as? Bool)!))
    #expect((object["transport_slider_descriptions"] as? [String]) == [])
    #expect((object["control_bar_checkbox_labels"] as? [String]) == [])
    #expect(!(fallbackBox.called))
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
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXTitleAttribute as String, "Audio Track")
    builder.setAttribute(trackHeader, kAXSelectedAttribute as String, false)

    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "트랙")
    builder.setChildren(trackMenu, [createItem])
    builder.setAttribute(createItem, kAXTitleAttribute as String, "새로운 소프트웨어 악기 트랙")

    builder.setAttribute(createdTrackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(createdTrackHeader, kAXTitleAttribute as String, "Studio Grand")
    builder.setAttribute(createdTrackHeader, kAXDescriptionAttribute as String, "Software Instrument Track")
    builder.setAttribute(createdTrackHeader, kAXSelectedAttribute as String, true)

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
    #expect(result.message.contains("\"observed_track_index\":1"))
    #expect(result.message.contains("\"observed_track_name\":\"Studio Grand\""))
    #expect(result.message.contains("\"observed_track_type\":\"software_instrument\""))
    #expect(result.message.contains("\"track_type_verification_source\":\"menu_clicked\""))
    #expect(result.message.contains("\"verification_source\":\"track_count_delta\""))
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
    #expect(result.message.contains("\"error\":\"ax_write_failed\""))
    #expect(result.message.contains("track count did not increase"))
    #expect(result.message.contains("\"observed_delta\":0"))
}

@Test func testAccessibilityChannelCreateInstrumentReportsDialogPendingWhenModalPersists() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(280)
    let window = builder.element(281)
    let dialog = builder.element(282)
    let menuBar = builder.element(283)
    let trackMenu = builder.element(284)
    let createItem = builder.element(285)
    let trackList = builder.element(286)
    let trackHeader = builder.element(287)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window, dialog])
    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(trackHeader, kAXTitleAttribute as String, "Audio Track")

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

    #expect(result.isSuccess)
    #expect(result.message.contains("\"verified\":false"))
    #expect(result.message.contains("\"reason\":\"retry_exhausted\""))
    #expect(result.message.contains("\"dialog_present\":true"))
    #expect(result.message.contains("\"waiting_for_user\":true"))
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

    // v3.1.8 (Issue #7) — strict allTrackHeaders requires AXLayoutItem role
    // on track row elements (Logic 12 contract). Without this, the strict
    // filter rejects the row to prevent Inspector subtree contamination.
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
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
    // v3.1.8 (Issue #7) — strict allTrackHeaders contract.
    builder.setAttribute(firstHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(secondHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
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

@Test func testAccessibilityChannelTrackRenameFallsBackToTrackMenuAndVerifiesTrackName() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(560)
    let window = builder.element(561)
    let menuBar = builder.element(562)
    let trackMenu = builder.element(563)
    let renameItem = builder.element(564)
    let trackList = builder.element(565)
    let header = builder.element(566)
    let nameField = builder.element(567)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [header])
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(header, kAXDescriptionAttribute as String, "Track 1 “Deluxe Classic”")
    builder.setAttribute(header, kAXSelectedAttribute as String, false)
    builder.setChildren(header, [nameField])
    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    builder.setAttribute(nameField, kAXDescriptionAttribute as String, "Deluxe Classic")
    builder.setAttribute(nameField, kAXValueAttribute as String, 0)

    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
    builder.setChildren(trackMenu, [renameItem])
    builder.setAttribute(renameItem, kAXTitleAttribute as String, "Rename Track")

    let mouseRecorder = ControlBarMouseRecorder()
    let session = TrackRenameSession()
    mouseRecorder.onUnicodeScalar = { scalar in
        guard session.editing, let unicode = UnicodeScalar(scalar) else { return }
        session.typed.append(Character(unicode))
    }
    mouseRecorder.onKeyEvent = { keyCode in
        guard session.editing else { return }
        switch keyCode {
        case 0x24:
            builder.setAttribute(nameField, kAXDescriptionAttribute as String, session.typed)
            builder.setAttribute(header, kAXDescriptionAttribute as String, "Track 1 “\(session.typed)”")
            session.editing = false
        default:
            break
        }
    }

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            if builder.elementID(element) == builder.elementID(header), action == kAXPressAction as String {
                builder.setAttribute(header, kAXSelectedAttribute as String, true)
                session.selectionCommitted = true
                return true
            }
            if builder.elementID(element) == builder.elementID(renameItem), action == kAXPressAction as String {
                session.renamePressed = true
                session.editing = true
                session.typed = ""
                return true
            }
            return true
        }
    )
    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        logicRuntime: logicRuntime,
        trackRenameMouseRuntime: mouseRecorder.runtime()
    )

    let result = await channel.execute(operation: "track.rename", params: ["index": "0", "name": "Track Alpha"])
    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["via"] as? String == "track_menu")
    #expect(obj["observed"] as? String == "Track Alpha")
    #expect(builder.attributeValue(nameField, kAXDescriptionAttribute as String) as? String == "Track Alpha")
    #expect(((builder.attributeValue(header, kAXDescriptionAttribute as String) as? String)?.contains("Track Alpha"))!)
    #expect(session.selectionCommitted)
    #expect(session.renamePressed)
    #expect(mouseRecorder.keyEvents.contains(0x24))
}

@Test func testAccessibilityChannelTrackRenameReturnsReadbackMismatchWhenTrackMenuDoesNotChangeName() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(570)
    let window = builder.element(571)
    let menuBar = builder.element(572)
    let trackMenu = builder.element(573)
    let renameItem = builder.element(574)
    let trackList = builder.element(575)
    let header = builder.element(576)
    let nameField = builder.element(577)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(window, [trackList])
    builder.setAttribute(trackList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackList, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackList, [header])
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(header, kAXDescriptionAttribute as String, "Track 1 “Deluxe Classic”")
    builder.setAttribute(header, kAXSelectedAttribute as String, false)
    builder.setChildren(header, [nameField])
    builder.setAttribute(nameField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    builder.setAttribute(nameField, kAXDescriptionAttribute as String, "Deluxe Classic")
    builder.setAttribute(nameField, kAXValueAttribute as String, 0)

    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
    builder.setChildren(trackMenu, [renameItem])
    builder.setAttribute(renameItem, kAXTitleAttribute as String, "Rename Track")

    let mouseRecorder = ControlBarMouseRecorder()
    let session = TrackRenameSession()
    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            if builder.elementID(element) == builder.elementID(header), action == kAXPressAction as String {
                builder.setAttribute(header, kAXSelectedAttribute as String, true)
                return true
            }
            if builder.elementID(element) == builder.elementID(renameItem), action == kAXPressAction as String {
                session.editing = true
                return true
            }
            return true
        }
    )
    mouseRecorder.onKeyEvent = { keyCode in
        guard session.editing, keyCode == 0x24 else { return }
        session.editing = false
    }
    let channel = makeAXBackedAccessibilityChannel(
        builder: builder,
        app: app,
        logicRuntime: logicRuntime,
        trackRenameMouseRuntime: mouseRecorder.runtime()
    )

    let result = await channel.execute(operation: "track.rename", params: ["index": "0", "name": "Track Beta"])
    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["via"] as? String == "track_menu")
    #expect(obj["observed"] as? String == "Deluxe Classic")
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
    // v3.1.8 (Issue #7) — strict allTrackHeaders contract.
    builder.setAttribute(firstHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(secondHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setAttribute(firstHeader, kAXTitleAttribute as String, "Track 1")
    builder.setAttribute(firstHeader, kAXSelectedAttribute as String, true)
    builder.setAttribute(secondHeader, kAXTitleAttribute as String, "Track 2")
    builder.setAttribute(secondHeader, kAXSelectedAttribute as String, false)

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let selectResult = await channel.execute(operation: "track.select", params: ["index": "1"])
    // v3.1.0 (Ralph-2 / P2-2) — Honest Contract: mismatch-after-retry is
    // State B with `readback_mismatch`, not `retry_exhausted`. The envelope
    // stays success:true so clients branch on `verified`; `readback_mismatch`
    // tells the caller that a different index was observed (vs.
    // `retry_exhausted` which would mean read-back metadata never appeared).
    // `observed` carries the index Logic actually committed.
    #expect(selectResult.isSuccess)
    let obj = try! JSONSerialization.jsonObject(
        with: Data(selectResult.message.utf8), options: []
    ) as! [String: Any]
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["requested"] as? Int == 1)
    #expect(obj["observed"] as? Int == 0)
}

@Test func testAccessibilityChannelSetInstrumentReturnsTargetAndPatchVerificationMetadata() async {
    let fixture = makeSetInstrumentFixture()
    let logicRuntime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == fixture.secondHeader {
                fixture.builder.setAttribute(fixture.firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(fixture.secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )
    let channel = makeAXBackedAccessibilityChannel(
        builder: fixture.builder,
        app: fixture.app,
        logicRuntime: logicRuntime
    )

    let result = await channel.execute(
        operation: "track.set_instrument",
        params: ["index": "1", "path": "Bass/Sub Bass"]
    )

    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["requested_patch_name"] as? String == "Sub Bass")
    #expect(obj["requested_path"] as? String == "Bass/Sub Bass")
    #expect(obj["observed_patch_name"] as? String == "Sub Bass")
    #expect(obj["target_track_index"] as? Int == 1)
    #expect(obj["target_track_name"] as? String == "Bass Track")
    #expect((obj["target_track_selection_verified"] as? Bool)!)
    #expect(obj["target_track_selection_reason"] as? String == "verified")
    #expect(obj["target_track_selection_observed_index"] as? Int == 1)
    #expect(obj["target_track_selection_verify_source"] as? String == "ax_selected")
    #expect(obj["verify_source"] as? String == "library_selected_children")
    #expect(obj["readback_state"] as? String == "verified")
}

@Test func testAccessibilityChannelSetInstrumentTrimsLibraryReadbackPadding() async {
    let fixture = makeSetInstrumentFixture()
    fixture.builder.setAttribute(fixture.preset, kAXValueAttribute as String, "Sub Bass ")
    let logicRuntime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == fixture.secondHeader {
                fixture.builder.setAttribute(fixture.firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(fixture.secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )
    let channel = makeAXBackedAccessibilityChannel(
        builder: fixture.builder,
        app: fixture.app,
        logicRuntime: logicRuntime
    )

    let result = await channel.execute(
        operation: "track.set_instrument",
        params: ["index": "1", "path": "Bass/Sub Bass"]
    )

    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["requested_patch_name"] as? String == "Sub Bass")
    #expect(obj["observed_patch_name"] as? String == "Sub Bass")
    #expect(obj["readback_state"] as? String == "verified")
}

@Test func testAccessibilityChannelSetInstrumentFailsClosedWhenTrackSelectionIsUnverified() async {
    let fixture = makeSetInstrumentFixture()
    let channel = makeAXBackedAccessibilityChannel(builder: fixture.builder, app: fixture.app)

    let result = await channel.execute(
        operation: "track.set_instrument",
        params: ["index": "1", "path": "Bass/Sub Bass"]
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "track_selection_failed")
    #expect(obj["requested_patch_name"] as? String == "Sub Bass")
    #expect(obj["requested_path"] as? String == "Bass/Sub Bass")
    #expect(obj["target_track_index"] as? Int == 1)
    #expect(obj["target_track_name"] as? String == "Bass Track")
    #expect(!((obj["target_track_selection_verified"] as? Bool)!))
    #expect(obj["target_track_selection_reason"] as? String == "readback_mismatch")
    #expect(obj["target_track_selection_observed_index"] as? Int == 0)
    #expect(obj["target_track_selection_verify_source"] as? String == "ax_selected")
    #expect(!fixture.builder.actionCalls.map(\.elementID).contains(fixture.builder.elementID(fixture.category)))
    #expect(!fixture.builder.actionCalls.map(\.elementID).contains(fixture.builder.elementID(fixture.preset)))
}

// MARK: - #131/#135/#141 set_instrument hardening (deterministic guards)

/// Build a set_instrument fixture whose target track (index 1) carries a
/// GM Device signal so `inferTrackType` classifies it as `.externalMIDI`.
/// The library browser is present (panel "open") so the type guard — which
/// runs BEFORE the panel guard — is what fires.
private func makeGMDeviceTargetFixture() -> (builder: FakeAXRuntimeBuilder, app: AXUIElement) {
    let fixture = makeSetInstrumentFixture()
    // Re-label the second header (target index 1) as a GM Device strip. The
    // live SMF-open path names these "GM Device N"; the AX header value is the
    // type signal `inferTrackType` reads.
    fixture.builder.setAttribute(fixture.secondHeader, kAXTitleAttribute as String, "GM Device 5")
    fixture.builder.setAttribute(fixture.secondHeader, kAXDescriptionAttribute as String, "GM Device 5")
    // Also retitle its name static-text child so the readback name matches.
    let secondName = fixture.builder.element(20_006)
    fixture.builder.setAttribute(secondName, kAXValueAttribute as String, "GM Device 5")
    return (fixture.builder, fixture.app)
}

@Test func testSetInstrumentGMDeviceTargetReturnsUnsupportedTrackType() async throws {
    let fixture = makeGMDeviceTargetFixture()
    let secondHeader = fixture.builder.element(20_005)
    let firstHeader = fixture.builder.element(20_003)
    // Selection ladder must commit so the type guard (which runs after
    // selection verification) is reached: mark the target selected on AXPress.
    let runtimeWithSelect = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, _, _ in true },
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == secondHeader {
                fixture.builder.setAttribute(firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )
    let result = await AccessibilityChannel.setTrackInstrument(
        params: ["index": "1", "path": "Electric Piano/Deluxe Classic"],
        runtime: runtimeWithSelect,
        staging: AccessibilityChannel.LibraryPanelStaging(
            isPanelOpen: { _ in true },
            openPanel: { _ in },
            resolvePath: { _ in nil }
        )
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "unsupported_track_type")
    #expect(obj["observed_track_type"] as? String == "external_midi")
    #expect(obj["precondition"] as? String == "wrong_target_type")
    let hint = try #require(obj["hint"] as? String)
    #expect(hint.contains("GM Device"))
    // The misleading legacy error MUST NOT be what we returned.
    #expect(obj["error"] as? String != "ax_write_failed")
}

@Test func testSetInstrumentPanelClosedReturnsLibraryPanelUnavailable() async throws {
    // Standard fixture: target index 1 is a plain track (`.unknown` type), so
    // the type guard passes and the panel precondition is what fires. Force the
    // panel closed and make auto-open a no-op so it stays closed.
    let fixture = makeSetInstrumentFixture()
    let logicRuntime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, _, _ in true },
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == fixture.secondHeader {
                fixture.builder.setAttribute(fixture.firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(fixture.secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )

    let openAttempted = LockedFlag()
    let result = await AccessibilityChannel.setTrackInstrument(
        params: ["index": "1", "path": "Bass/Sub Bass"],
        runtime: logicRuntime,
        staging: AccessibilityChannel.LibraryPanelStaging(
            isPanelOpen: { _ in false },          // panel never open
            openPanel: { _ in openAttempted.set() }, // auto-open is a no-op
            resolvePath: { _ in nil }
        )
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "library_panel_unavailable")
    #expect(obj["precondition"] as? String == "panel_closed")
    let hint = try #require(obj["hint"] as? String)
    #expect(hint.contains("Y"))
    // Auto-open must have been attempted before failing closed.
    #expect(openAttempted.value)
    // Must NOT be the misleading legacy error.
    #expect(obj["error"] as? String != "ax_write_failed")
}

@Test func testSetInstrumentPathNotInCacheReturnsPathNotInLibrary() async {
    // Panel open, target type OK, but the injected cache resolver reports the
    // path is ABSENT → terminal precondition `path_not_in_library` (NOT a nav
    // attempt, NOT ax_write_failed).
    let fixture = makeSetInstrumentFixture()
    let logicRuntime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, _, _ in true },
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == fixture.secondHeader {
                fixture.builder.setAttribute(fixture.firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(fixture.secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )

    let result = await AccessibilityChannel.setTrackInstrument(
        params: ["index": "1", "path": "Bass/Totally Fake Patch"],
        runtime: logicRuntime,
        staging: AccessibilityChannel.LibraryPanelStaging(
            isPanelOpen: { _ in true },
            openPanel: { _ in },
            resolvePath: { _ in false }   // cache says: path does not exist
        )
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "path_not_in_library")
    #expect(obj["precondition"] as? String == "missing_path")
    #expect(obj["error"] as? String != "ax_write_failed")
}

@Test func testSetInstrumentFolderPathFailsClosedBeforeAXNav() async {
    let fixture = makeSetInstrumentFixture()
    fixture.builder.setAttribute(fixture.category, kAXValueAttribute as String, "Synthesizer")
    fixture.builder.setAttribute(fixture.preset, kAXValueAttribute as String, "Bass")
    let logicRuntime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, _, _ in true },
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == fixture.secondHeader {
                fixture.builder.setAttribute(fixture.firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(fixture.secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )

    let result = await AccessibilityChannel.setTrackInstrument(
        params: ["index": "1", "path": "Synthesizer/Bass"],
        runtime: logicRuntime,
        staging: AccessibilityChannel.LibraryPanelStaging(
            isPanelOpen: { _ in true },
            openPanel: { _ in },
            resolvePathKind: { _ in .folder },
            resolvePath: { _ in true }
        )
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "folder_not_preset")
    #expect(obj["precondition"] as? String == "folder_path")
    #expect(obj["requested_path"] as? String == "Synthesizer/Bass")
    #expect(!fixture.builder.actionCalls.map(\.elementID).contains(fixture.builder.elementID(fixture.category)))
    #expect(!fixture.builder.actionCalls.map(\.elementID).contains(fixture.builder.elementID(fixture.preset)))
}

@Test func testLibraryPanelOpenUsesAXViewLibraryMenu() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(30_000)
    let menuBar = builder.element(30_001)
    let viewMenu = builder.element(30_002)
    let libraryItem = builder.element(30_003)

    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(menuBar, [viewMenu])
    builder.setAttribute(viewMenu, kAXTitleAttribute as String, "View")
    builder.setChildren(viewMenu, [libraryItem])
    builder.setAttribute(libraryItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(libraryItem, kAXTitleAttribute as String, "Show Library")

    final class MenuClickBox: @unchecked Sendable { var clicked = false }
    let menuClick = MenuClickBox()
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            if builder.elementID(element) == builder.elementID(libraryItem),
               action == kAXPressAction as String {
                menuClick.clicked = true
            }
            return true
        }
    )

    await AccessibilityChannel.openLibraryPanelViaKeyCommand(runtime: runtime)

    #expect(menuClick.clicked)
}

@Test func testSetInstrumentReopensPanelLeftClosedByFailedNav() async {
    // #222 — a failed finder-column navigation can leave the Library panel
    // closed, poisoning the NEXT set_instrument with a `library_panel_unavailable`
    // it did not cause. After a nav failure the panel must be re-staged to a
    // known-open baseline. Panel is open at the precondition, "closed" by the
    // failed nav, then re-opened on the failure path.
    let fixture = makeSetInstrumentFixture()
    let logicRuntime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, _, _ in true },
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == fixture.secondHeader {
                fixture.builder.setAttribute(fixture.firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(fixture.secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )
    let panelOpen = SequencedBool([true, false, true]) // precondition→open, restage-check→closed, post-open→open
    let openCalls = CallCounter()
    let result = await AccessibilityChannel.setTrackInstrument(
        params: ["index": "1", "path": "Bass/Nonexistent Preset"],
        runtime: logicRuntime,
        staging: AccessibilityChannel.LibraryPanelStaging(
            isPanelOpen: { _ in panelOpen.next() },
            openPanel: { _ in openCalls.inc() },
            resolvePath: { _ in true }   // cache says the path exists → attempt nav
        )
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    // The path genuinely didn't resolve → deterministic ax_write_failed.
    #expect(obj["error"] as? String == "ax_write_failed")
    #expect(obj["precondition"] as? String == "library_nav_failed")
    // No-drift guarantee: the panel was re-staged and is left open.
    #expect((obj["panel_restaged_after_failure"] as? Bool)!)
    #expect((obj["panel_open_after_failure"] as? Bool)!)
    #expect(openCalls.count == 1)
}

@Test func testSetInstrumentNavFailureNeverRetogglesAnAlreadyOpenPanel() async {
    // #222 safety: the Library shortcut is a TOGGLE. When a failed nav leaves the panel still
    // open, the re-stage must NOT re-open it (which would toggle it shut). It
    // must be left open and openPanel must never be called.
    let fixture = makeSetInstrumentFixture()
    let logicRuntime = fixture.builder.makeLogicRuntime(
        appElement: fixture.app,
        setAttributeHandler: { _, _, _ in true },
        performActionHandler: { element, action in
            guard action == kAXPressAction as String else { return true }
            if element == fixture.secondHeader {
                fixture.builder.setAttribute(fixture.firstHeader, kAXSelectedAttribute as String, false)
                fixture.builder.setAttribute(fixture.secondHeader, kAXSelectedAttribute as String, true)
            }
            return true
        }
    )
    let openCalls = CallCounter()
    let result = await AccessibilityChannel.setTrackInstrument(
        params: ["index": "1", "path": "Bass/Nonexistent Preset"],
        runtime: logicRuntime,
        staging: AccessibilityChannel.LibraryPanelStaging(
            isPanelOpen: { _ in true },   // panel stays open throughout
            openPanel: { _ in openCalls.inc() },
            resolvePath: { _ in true }
        )
    )

    #expect(!result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(obj["error"] as? String == "ax_write_failed")
    #expect(!((obj["panel_restaged_after_failure"] as? Bool)!))
    #expect((obj["panel_open_after_failure"] as? Bool)!)
    #expect(openCalls.count == 0, "must never re-toggle an already-open panel shut")
}

private final class SequencedBool: @unchecked Sendable {
    private let lock = NSLock()
    private let seq: [Bool]
    private var idx = 0
    init(_ seq: [Bool]) { self.seq = seq }
    func next() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = idx < seq.count ? seq[idx] : (seq.last ?? false)
        idx += 1
        return value
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func inc() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
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
    // v3.1.8 (Issue #7) — strict allTrackHeaders contract.
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
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

    let missingRenameMenu = await channel.execute(operation: "track.rename", params: ["index": "0", "name": "Lead"])
    #expect(!missingRenameMenu.isSuccess)
    #expect(missingRenameMenu.message.contains("\"error\":\"element_not_found\""))
    #expect(missingRenameMenu.message.contains("Track > Rename Track menu item not found"))

    let missingRenameParams = await channel.execute(operation: "track.rename", params: ["index": "0"])
    #expect(!missingRenameParams.isSuccess)
    #expect(missingRenameParams.message.contains("\"error\":\"invalid_params\""))
    #expect(missingRenameParams.message.contains("track.rename requires 'index'"))

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
    builder.setAttribute(mixer, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setChildren(strip, [fader, pan])
    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(fader, kAXValueAttribute as String, 0.8)
    builder.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(pan, kAXValueAttribute as String, -0.25)
    // #107: writes target the per-track header fader/pan, not the mixer strip.
    let headerControls = attachTrackHeaderRail(
        builder, window: window, siblings: [mixer], baseID: 3_040,
        volume: (value: 173, min: 0, max: 233),
        pan: (value: 64, min: 0, max: 127)
    )

    let channel = makeAXBackedAccessibilityChannel(
        builder: builder, app: app, logicRuntime: nudgeResponsiveLogicRuntime(builder, app: app)
    )
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
    let volumeObj = decodeAccessibilityJSON(volumeResult.message)
    #expect((volumeObj["success"] as? Bool)!)
    #expect((volumeObj["verified"] as? Bool)!)
    #expect(volumeObj["operation"] as? String == "mixer.set_volume")
    #expect(volumeObj["verify_source"] as? String == "ax_slider")
    // Nudge converges to the nearest ~10-raw-unit detent → observed within a detent of 0.5.
    #expect(abs((volumeObj["observed_after"] as? Double ?? -9) - 0.5) < 0.07)
    #expect((volumeObj["target_identity"] as? [String: Any])?["track_index"] as? Int == 0)

    let panResult = await channel.execute(operation: "mixer.set_pan", params: ["index": "0", "value": "-0.5"])
    #expect(panResult.isSuccess)
    let panObj = decodeAccessibilityJSON(panResult.message)
    #expect((panObj["success"] as? Bool)!)
    #expect((panObj["verified"] as? Bool)!)
    #expect(panObj["operation"] as? String == "mixer.set_pan")
    #expect(panObj["verify_source"] as? String == "ax_slider")
    #expect(abs((panObj["observed_after"] as? Double ?? -9) - (-0.5)) < 0.07)
    #expect((panObj["target_identity"] as? [String: Any])?["control"] as? String == "pan")
    _ = headerControls

    let projectResult = await channel.execute(operation: "project.get_info", params: [:])
    #expect(projectResult.isSuccess)
    let project = try decoder.decode(ProjectInfo.self, from: Data(projectResult.message.utf8))
    #expect(project.name == "Song.logicx")
}

@Test func testAccessibilityChannelMixerNormalizesLogic12SliderRanges() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(390)
    let window = builder.element(391)
    let mixer = builder.element(392)
    let strip = builder.element(393)
    let fader = builder.element(394)
    let pan = builder.element(395)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [mixer])
    builder.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(mixer, kAXDescriptionAttribute as String, "믹서")
    builder.setChildren(mixer, [strip])
    builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(strip, [fader, pan])

    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(fader, kAXDescriptionAttribute as String, "볼륨 페이더")
    builder.setAttribute(fader, kAXValueAttribute as String, 70)
    builder.setAttribute(fader, kAXMinValueAttribute as String, 0)
    builder.setAttribute(fader, kAXMaxValueAttribute as String, 233)

    builder.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(pan, kAXDescriptionAttribute as String, "패닝")
    builder.setAttribute(pan, kAXValueAttribute as String, 0)
    builder.setAttribute(pan, kAXMinValueAttribute as String, -64)
    builder.setAttribute(pan, kAXMaxValueAttribute as String, 63)

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let mixerResult = await channel.execute(operation: "mixer.get_state", params: [:])
    #expect(mixerResult.isSuccess)
    let strips = try decoder.decode([ChannelStripState].self, from: Data(mixerResult.message.utf8))
    #expect(strips.count == 1)
    #expect(abs(strips[0].volume - 0.4) < 0.002)
    #expect(strips[0].pan == 0.0)

    let stripResult = await channel.execute(operation: "mixer.get_channel_strip", params: ["index": "0"])
    #expect(stripResult.isSuccess)
    let stripState = try decoder.decode(ChannelStripState.self, from: Data(stripResult.message.utf8))
    #expect(abs(stripState.volume - 0.4) < 0.002)
    #expect(stripState.pan == 0.0)
}

@Test func testAccessibilityChannelMixerWritesUseLogic12RawSliderRanges() async {
    // #107: writes are driven via the per-track header fader/pan with an
    // AXIncrement/AXDecrement nudge (Logic ignores AXValue writes on its
    // faders). The fake rail starts the volume fader at raw 173 (0...233) and
    // pan at the electrical center (64 of 0...127); the responsive runtime
    // moves each by ~10-raw-unit detents so the writer converges.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(396)
    let window = builder.element(397)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    let controls = attachTrackHeaderRail(
        builder, window: window, siblings: [], baseID: 3_960,
        volume: (value: 173, min: 0, max: 233),
        pan: (value: 64, min: 0, max: 127)
    )
    let channel = makeAXBackedAccessibilityChannel(
        builder: builder, app: app, logicRuntime: nudgeResponsiveLogicRuntime(builder, app: app)
    )

    let volumeResult = await channel.execute(operation: "mixer.set_volume", params: ["index": "0", "value": "0.5"])
    #expect(volumeResult.isSuccess)
    let volumeObj = decodeAccessibilityJSON(volumeResult.message)
    #expect((volumeObj["verified"] as? Bool)!)
    #expect(volumeObj["write_method"] as? String == "ax_increment_decrement")
    #expect(abs((volumeObj["observed_after"] as? Double ?? -9) - 0.5) < 0.07)
    // The raw fader actually moved toward the 0.5 target detent (~raw 98).
    let faderRaw = (builder.attributeValue(controls.volume, kAXValueAttribute as String) as? NSNumber)?.doubleValue
        ?? (builder.attributeValue(controls.volume, kAXValueAttribute as String) as? Double) ?? -1
    #expect(faderRaw >= 90 && faderRaw <= 110, "fader raw should land near 98, got \(faderRaw)")

    let panResult = await channel.execute(operation: "mixer.set_pan", params: ["index": "0", "value": "-0.5"])
    #expect(panResult.isSuccess)
    let panObj = decodeAccessibilityJSON(panResult.message)
    #expect((panObj["verified"] as? Bool)!)
    #expect(abs((panObj["observed_after"] as? Double ?? -9) - (-0.5)) < 0.07)
}

@Test func testAccessibilityChannelMixerPopulatesAXPluginSlotsAndSource() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(430)
    let window = builder.element(431)
    let mixer = builder.element(432)
    let strip = builder.element(433)
    let fader = builder.element(434)
    let pan = builder.element(435)
    let emptyAudioSlot = builder.element(436)
    let pluginGroup = builder.element(437)
    let bypass = builder.element(438)
    let open = builder.element(439)
    let menu = builder.element(440)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [mixer])
    builder.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(strip, [fader, pan, emptyAudioSlot, pluginGroup])
    builder.setAttribute(fader, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(fader, kAXDescriptionAttribute as String, "Volume Fader")
    builder.setAttribute(fader, kAXValueAttribute as String, 0.75)
    builder.setAttribute(pan, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(pan, kAXDescriptionAttribute as String, "Pan")
    builder.setAttribute(pan, kAXValueAttribute as String, 0.0)

    builder.setAttribute(emptyAudioSlot, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(emptyAudioSlot, kAXDescriptionAttribute as String, "오디오 플러그인")
    builder.setAttribute(emptyAudioSlot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")

    builder.setAttribute(pluginGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(pluginGroup, kAXDescriptionAttribute as String, "Drum Machine Designer")
    builder.setChildren(pluginGroup, [bypass, open, menu])
    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
    builder.setAttribute(bypass, kAXValueAttribute as String, 0)
    builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(open, kAXDescriptionAttribute as String, "열기")
    builder.setAttribute(menu, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(menu, kAXDescriptionAttribute as String, "목록")

    let channel = makeAXBackedAccessibilityChannel(builder: builder, app: app)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let mixerResult = await channel.execute(operation: "mixer.get_state", params: [:])
    #expect(mixerResult.isSuccess)
    #expect(mixerResult.message.contains("\"plugins_source\":\"ax\""))
    let strips = try decoder.decode([ChannelStripState].self, from: Data(mixerResult.message.utf8))
    #expect(strips[0].pluginsSource == "ax")
    #expect(strips[0].plugins.count == 1)
    #expect(strips[0].plugins[0].index == 0)
    #expect(strips[0].plugins[0].name == "Drum Machine Designer")
    #expect(!(strips[0].plugins[0].isBypassed))
}

@Test func testAccessibilityChannelInsertPluginRejectsOccupiedSlotBeforeMenuSelection() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(450)
    let window = builder.element(451)
    let mixer = builder.element(452)
    let strip = builder.element(453)
    let pluginGroup = builder.element(454)
    let bypass = builder.element(455)
    let open = builder.element(456)
    let menu = builder.element(457)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [mixer])
    builder.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(strip, [pluginGroup])
    builder.setAttribute(pluginGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(pluginGroup, kAXDescriptionAttribute as String, "Compressor")
    builder.setChildren(pluginGroup, [bypass, open, menu])
    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "Bypass")
    builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(open, kAXDescriptionAttribute as String, "Open")
    builder.setAttribute(menu, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(menu, kAXDescriptionAttribute as String, "Menu")

    let result = await AccessibilityChannel.defaultInsertPlugin(
        params: ["track": "0", "slot": "0", "plugin_name": "Gain"],
        runtime: builder.makeLogicRuntime(appElement: app),
        selectPlugin: { _, _, _ in
            Issue.record("occupied slot must fail before menu selection")
            return true
        }
    )

    #expect(!result.isSuccess)
    #expect(result.message.contains("slot_occupied"))
    #expect(builder.actionCalls.isEmpty)
}

@Test func testAccessibilityChannelInsertPluginVerifiesSlotAfterMenuSelection() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(470)
    let window = builder.element(471)
    let mixer = builder.element(472)
    let strip = builder.element(473)
    let emptyAudioSlot = builder.element(474)
    let gainGroup = builder.element(475)
    let bypass = builder.element(476)
    let open = builder.element(477)
    let menu = builder.element(478)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [mixer])
    builder.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(strip, [emptyAudioSlot])
    builder.setAttribute(emptyAudioSlot, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(emptyAudioSlot, kAXDescriptionAttribute as String, "Audio Plugin")
    builder.setAttribute(emptyAudioSlot, kAXHelpAttribute as String, "Audio effect slot. Insert an audio effect.")

    builder.setAttribute(gainGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(gainGroup, kAXDescriptionAttribute as String, "Gain")
    builder.setChildren(gainGroup, [bypass, open, menu])
    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "Bypass")
    builder.setAttribute(bypass, kAXValueAttribute as String, 0)
    builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(open, kAXDescriptionAttribute as String, "Open")
    builder.setAttribute(menu, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(menu, kAXDescriptionAttribute as String, "Menu")

    let result = await AccessibilityChannel.defaultInsertPlugin(
        params: ["track": "0", "slot": "0", "plugin_name": "Gain"],
        runtime: builder.makeLogicRuntime(appElement: app),
        selectPlugin: { spec, _, _ in
            #expect(spec.canonicalName == "Gain")
            builder.setChildren(strip, [gainGroup])
            return true
        }
    )

    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["verify_source"] as? String == "ax_plugin_slot")
    #expect(obj["observed_plugin_name"] as? String == "Gain")
    #expect(builder.actionCalls.map(\.elementID).contains(builder.elementID(emptyAudioSlot)))
}

@Test func testAccessibilityChannelInsertPluginRollsBackWhenReadbackUnavailable() async {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(490)
    let window = builder.element(491)
    let mixer = builder.element(492)
    let strip = builder.element(493)
    let emptyAudioSlot = builder.element(494)
    final class RollbackBox: @unchecked Sendable { var called = false }
    let rollbackBox = RollbackBox()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [mixer])
    builder.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    builder.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    builder.setChildren(mixer, [strip])
    builder.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(strip, [emptyAudioSlot])
    builder.setAttribute(emptyAudioSlot, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(emptyAudioSlot, kAXDescriptionAttribute as String, "Audio Plugin")
    builder.setAttribute(emptyAudioSlot, kAXHelpAttribute as String, "Audio effect slot. Insert an audio effect.")

    let result = await AccessibilityChannel.defaultInsertPlugin(
        params: ["track": "0", "slot": "0", "plugin_name": "Gain"],
        runtime: builder.makeLogicRuntime(appElement: app),
        selectPlugin: { _, _, _ in true },
        rollback: {
            rollbackBox.called = true
            return true
        },
        readbackTimeoutMs: 50
    )

    #expect(result.isSuccess)
    let obj = decodeAccessibilityJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect((obj["rollback_succeeded"] as? Bool)!)
    #expect(rollbackBox.called)
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

    let wrongTrackWrite = await channel.execute(operation: "mixer.set_volume", params: ["index": "2", "value": "0.5"])
    #expect(!wrongTrackWrite.isSuccess)
    #expect(wrongTrackWrite.message.contains("\"error\":\"element_not_found\""))
    #expect(wrongTrackWrite.message.contains("\"track\":2"))
    #expect((builder.attributeValue(fader, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 0.9)

    let missingPan = await channel.execute(operation: "mixer.set_pan", params: ["index": "0", "value": "-0.2"])
    #expect(!missingPan.isSuccess)
    #expect(missingPan.message.contains("\"error\":\"element_not_found\""))
    #expect(missingPan.message.contains("Cannot locate pan control"))

    let projectBuilder = FakeAXRuntimeBuilder()
    let projectApp = projectBuilder.element(330)
    let missingWindowChannel = makeAXBackedAccessibilityChannel(builder: projectBuilder, app: projectApp)
    let missingWindow = await missingWindowChannel.execute(operation: "project.get_info", params: [:])
    #expect(!missingWindow.isSuccess)
    #expect(missingWindow.message.contains("Cannot locate Logic Pro main window"))
}

// MARK: - scan cross-exclusion (library.scan_all ⊥ plugin.scan_presets)

/// One-shot "scan A has entered `runLiveScan` (its flag is already set)" signal.
/// Mirrors the `DispatchSemaphore` handshake used by `BlockingExecuteProbe`, but
/// fires once and never blocks the producer, so it can be raised from the
/// synchronous `hasVisibleWindow` seam WITHOUT holding the actor.
private final class ScanEnteredSignal: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var fired = false

    /// Raise the signal (idempotent). Safe from a `@Sendable` sync closure.
    func fire() {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        entered.signal()
    }

    func waitUntilEntered(timeout: DispatchTimeInterval = .seconds(5)) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }
}

/// Fake Logic runtime whose AX tree exposes an OPEN Library panel with two
/// categories, so `library.scan_all {mode:ax}` clears its preflights
/// (`isLibraryPanelOpen`), enumerates a non-empty root, and reaches the
/// `enumerateTree` settle-suspension. Replicates the proven
/// `makeLibraryPanelFixture` shape from `LibraryAccessorAXRuntimeTests`.
private func makeOpenLibraryPanelLogicRuntime() -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(20_000)
    let window = builder.element(20_001)
    let browser = builder.element(20_002)
    let categoryList = builder.element(20_003)
    let presetList = builder.element(20_004)
    let bass = builder.element(20_005)
    let drums = builder.element(20_006)
    let sub = builder.element(20_007)
    let funky = builder.element(20_008)
    let horizontalScrollBar = builder.element(20_009)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [browser])
    builder.setAttribute(browser, kAXRoleAttribute as String, kAXBrowserRole as String)
    builder.setAttribute(browser, kAXDescriptionAttribute as String, "Library")
    builder.setAttribute(browser, kAXParentAttribute as String, window)
    builder.setChildren(browser, [categoryList, presetList, horizontalScrollBar])

    builder.setAttribute(categoryList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setChildren(categoryList, [bass, drums])
    builder.setAttribute(presetList, kAXRoleAttribute as String, kAXListRole as String)
    builder.setChildren(presetList, [sub, funky])
    builder.setAttribute(horizontalScrollBar, kAXRoleAttribute as String, kAXScrollBarRole as String)
    builder.setAttribute(horizontalScrollBar, kAXOrientationAttribute as String, kAXHorizontalOrientationValue as String)
    builder.setAttribute(horizontalScrollBar, kAXValueAttribute as String, NSNumber(value: 1))

    for (element, value, x, y, parent) in [
        (bass, "Bass", CGFloat(100), CGFloat(100), categoryList),
        (drums, "Drums", CGFloat(100), CGFloat(130), categoryList),
        (sub, "Sub", CGFloat(260), CGFloat(100), presetList),
        (funky, "Funky", CGFloat(260), CGFloat(130), presetList),
    ] {
        builder.setAttribute(element, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(element, kAXValueAttribute as String, value)
        builder.setAttribute(element, kAXPositionAttribute as String, axPoint(x, y))
        builder.setAttribute(element, kAXSizeAttribute as String, axSize(80, 20))
        builder.setAttribute(element, kAXParentAttribute as String, parent)
    }

    builder.setAttribute(categoryList, kAXSelectedChildrenAttribute as String, [bass])
    builder.setAttribute(presetList, kAXSelectedChildrenAttribute as String, [sub])

    return builder.makeLogicRuntime(appElement: app)
}

/// Restores the pre-split cross-exclusion between `library.scan_all` and
/// `plugin.scan_presets` (both traverse Logic's AX tree; running them at the
/// same time launches two simultaneous traversals). Splitting the single
/// `scanInProgress` flag into two independent flags dropped the cross guard;
/// this pins the original truth table.
///
/// Determinism (NOT timing-based): scan A sets `libraryScanInProgress` BEFORE
/// its first suspension (the `enumerateTree` settle-sleep). `hasVisibleWindow` —
/// invoked on the actor right after the flag is set and before any `await` —
/// raises `entered`. Once `entered` is observed, the single-threaded actor can
/// only service the next `execute` after A suspends, at which point A's `defer`
/// (which clears the flag) has NOT run. So B provably observes the flag; the
/// production settle-sleep is merely the suspension window, never a race the
/// test bets on.
@Test("library.scan_all and plugin.scan_presets are mutually exclusive (restored cross-flag guard)")
func testLibraryAndPluginScansAreMutuallyExclusive() async {
    // `runLiveScan` writes `Resources/library-inventory.json` on completion, a
    // fixture other suites read (LibraryDiskScannerTests). Snapshot and restore
    // it so this test leaves the shared file byte-identical (or absent).
    let inventoryURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/library-inventory.json"
    )
    let originalInventory = try? Data(contentsOf: inventoryURL)
    defer {
        if let originalInventory {
            try? originalInventory.write(to: inventoryURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: inventoryURL)
        }
    }

    let entered = ScanEnteredSignal()
    let runtime = AccessibilityChannel.Runtime.axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        hasVisibleWindow: { entered.fire(); return true },
        logicRuntime: makeOpenLibraryPanelLogicRuntime()
    )
    let channel = AccessibilityChannel(runtime: runtime)

    let scanA = Task.detached(priority: .userInitiated) {
        await channel.execute(operation: "library.scan_all", params: ["mode": "ax"])
    }
    #expect(entered.waitUntilEntered())

    // CROSS (the regression): a plugin scan must be refused while a library scan
    // is suspended in-flight. Pre-fix this returned the "no plugin window" error
    // instead, because `pluginScanInProgress` was still false.
    let crossResult = await channel.execute(operation: "plugin.scan_presets", params: [:])
    #expect(!crossResult.isSuccess)
    #expect(crossResult.message.contains("already in progress"))

    // SELF: a second library scan is refused (held before and after the fix;
    // pins the rest of the truth table).
    let selfResult = await channel.execute(operation: "library.scan_all", params: ["mode": "ax"])
    #expect(!selfResult.isSuccess)
    #expect(selfResult.message.contains("already in progress"))

    // A finishes on its own and is not itself the rejected scan.
    let aResult = await scanA.value
    #expect(!aResult.message.contains("already in progress"))
}
