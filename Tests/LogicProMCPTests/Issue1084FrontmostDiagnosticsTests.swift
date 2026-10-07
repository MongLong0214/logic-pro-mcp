@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// #1084: pure owned probes only; these tests never post a live key or open a dialog.
private let ownershipLogicBundle = "com.apple.logic10"
private let ownershipHostileBundles = [
    "sk-live-secret", "ghp_secret", "com.fake.sk-live-secret", "com.fake.ghp_secret",
    "/Users/private/secret.logicx", "com.fake.\nsecret", String(repeating: "a", count: 256) + ".fake",
]
private func ownershipWindow(_ pid: Int, layer: Int = 0) -> [String: Any] {
    [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
     kCGWindowName as String: "/Users/private/secret.logicx",
     kCGWindowOwnerName as String: "private owner title"]
}
private func ownershipReading(_ pid: Int = 4242, focused: pid_t? = nil,
                              bundle: String? = ownershipLogicBundle) -> ProcessUtils.KeyboardOwnershipObservation {
    ProcessUtils.keyboardOwnershipObservation(windows: [ownershipWindow(pid)],
                                              focusedApplicationPID: focused, bundleIDForPID: { _ in bundle })
}
private final class OwnershipProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [ProcessUtils.KeyboardOwnershipObservation]
    private var _samples = 0
    private var _posts = 0
    private var _activations = 0
    init(_ readings: [ProcessUtils.KeyboardOwnershipObservation]) { self.readings = readings }
    func read() -> ProcessUtils.KeyboardOwnershipObservation {
        lock.lock(); defer { lock.unlock() }
        _samples += 1
        return readings.count > 1 ? readings.removeFirst() : readings[0]
    }
    func post() -> Bool { lock.lock(); defer { lock.unlock() }; _posts += 1; return true }
    func activate() -> Bool { lock.lock(); defer { lock.unlock() }; _activations += 1; return true }
    var counts: (samples: Int, posts: Int, activations: Int) {
        lock.lock(); defer { lock.unlock() }; return (_samples, _posts, _activations)
    }
}
private actor OwnershipRefusalChannel: Channel {
    nonisolated let id: ChannelID
    let payload: String
    init(id: ChannelID, payload: String) { self.id = id; self.payload = payload }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "owned ownership fixture") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult { .error(payload) }
}
// A thin AX test channel executes the real goto helper with owned seams; it does not exercise
// AccessibilityChannel's production activation default. No canned completed goto is substituted.
private actor OwnershipAXGotoChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    let runtime: AXLogicProElements.Runtime
    let probe: OwnershipProbe
    private var operations: [String] = []
    init(runtime: AXLogicProElements.Runtime, probe: OwnershipProbe) {
        self.runtime = runtime
        self.probe = probe
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "owned helper-delegating fixture") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        operations.append(operation)
        if operation == "transport.get_state" {
            return .error("owned pre-position read unavailable")
        }
        guard operation == "transport.goto_position" else {
            Issue.record("post-refusal operation must not execute: \(operation)")
            return .error("owned unexpected operation")
        }
        let probe = probe
        return await AccessibilityChannel.gotoPositionViaBarSlider(
            params: params, runtime: runtime, isFrontmost: { false },
            activateLogic: { false }, sleepMicros: { _ in }, observeFrontmost: { probe.read() })
    }
    func recordedOperations() -> [String] { operations }
}
private final class OwnershipFollowupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }; calls[name, default: 0] += 1
    }
    var total: Int { lock.lock(); defer { lock.unlock() }; return calls.values.reduce(0, +) }
}

private func ownershipPayload(_ reading: ProcessUtils.KeyboardOwnershipObservation) -> String {
    HonestContract.encodeStateC(error: .axWriteFailed, hint: "owned fixture", extras: [
        "frontmost_preparation": "activation_timed_out",
        "frontmost_observation": reading.diagnostic,
        "write_attempted": false, "safe_to_retry": true,
    ])
}

@Test func ownershipSnapshotPreservesFirstNormalOrModalAndSkipsFloating() {
    let windows = [ownershipWindow(99, layer: 3), ownershipWindow(77, layer: 8), ownershipWindow(4242)]
    let observed = ProcessUtils.keyboardOwnershipObservation(
        windows: windows, focusedApplicationPID: 4242,
        bundleIDForPID: { $0 == 4242 ? ownershipLogicBundle : "com.apple.finder" })
    #expect(!observed.isReady)
    #expect(observed.reason == .keyboardOwnerNotLogic)
    #expect(observed.keyboardOwnerPID == 77)
    #expect(observed.keyboardWindowLayer == 8)
    #expect(observed.diagnostic["title"] == nil)
    #expect(observed.diagnostic["path"] == nil)
    #expect(observed.diagnostic["raw_error"] == nil)
    let floating = ProcessUtils.keyboardOwnershipObservation(
        windows: [windows[0], windows[2]], focusedApplicationPID: nil,
        bundleIDForPID: { _ in ownershipLogicBundle })
    #expect(floating.isReady)
    #expect(floating.keyboardOwnerPID == 4242)
    #expect(floating.keyboardWindowLayer == 0)
}

@Test func ownershipSnapshotPreservesStrictBundleAndNilFocusPolicy() {
    #expect(ownershipReading(focused: nil).isReady)
    #expect(ownershipReading(focused: nil).focusRead == .unavailable)
    #expect(!ownershipReading(bundle: nil).isReady)
    #expect(ownershipReading(bundle: nil).reason == .keyboardBundleUnavailable)
    #expect(!ownershipReading(bundle: "com.apple.finder").isReady)
    #expect(ownershipReading(focused: 77).reason == .focusedApplicationMismatch)
    let absent = ProcessUtils.keyboardOwnershipObservation(
        windows: [], focusedApplicationPID: nil, bundleIDForPID: { _ in
            Issue.record("absent window must not read a bundle"); return ownershipLogicBundle
        })
    #expect(absent.reason == .keyboardWindowAbsent)
    #expect(!absent.isReady)
    let missingOwner = ProcessUtils.keyboardOwnershipObservation(
        windows: [[kCGWindowLayer as String: 0]], focusedApplicationPID: nil,
        bundleIDForPID: { _ in Issue.record("missing owner must not read a bundle"); return ownershipLogicBundle })
    #expect(missingOwner.reason == .keyboardOwnerUnavailable)
    #expect(!missingOwner.isReady)
    for bundle in ownershipHostileBundles + ["com..fake"] {
        #expect(ProcessUtils.KeyboardOwnershipObservation.diagnosticBundleID(bundle) == nil)
        let reading = ownershipReading(bundle: bundle)
        #expect(!reading.isReady)
        #expect(reading.reason == .keyboardOwnerNotLogic)
        #expect(reading.diagnostic["keyboard_owner_bundle_id"] == nil)
    }
}

@Test func ownershipSnapshotReadsWindowListBeforeFocusExactlyOnce() {
    var order: [String] = []
    let reading = ProcessUtils.keyboardOwnershipObservation(
        windowList: { order.append("windows"); return [ownershipWindow(4242)] },
        focusedPID: { order.append("focus"); return 4242 },
        bundleIDForPID: { _ in order.append("bundle"); return ownershipLogicBundle })
    #expect(reading.isReady)
    #expect(order == ["windows", "focus", "bundle"])
    order.removeAll()
    let unread = ProcessUtils.keyboardOwnershipObservation(
        windowList: { order.append("windows"); return nil },
        focusedPID: { order.append("unexpected focus"); return 4242 },
        bundleIDForPID: { _ in order.append("unexpected bundle"); return ownershipLogicBundle })
    #expect(order == ["windows"])
    #expect(unread.reason == .windowListUnavailable)
    #expect(unread.focusRead == .notAttempted)
}

@Test func frontmostGateCarriesLastDecisiveObservationWithoutResampling() {
    let ready = ownershipReading(focused: 4242)
    let refused = ownershipReading(77, bundle: "com.apple.finder")
    let probe = OwnershipProbe([ready, ready, refused])
    let result = FrontmostGate.prepareObserved(observe: { probe.read() },
                                              activate: { probe.activate() }, sleepMicros: { _ in })
    #expect(result.preparation == .alreadyFrontmost)
    #expect(result.observation?.keyboardOwnerPID == 4242)
    #expect(probe.counts.samples == 2)
    #expect(probe.counts.activations == 0)
    let refusedProbe = OwnershipProbe([ready, refused, ready])
    let activationRefused = FrontmostGate.prepareObserved(observe: { refusedProbe.read() },
                                                          activate: { false }, sleepMicros: { _ in })
    #expect(activationRefused.preparation == .activationRefused)
    #expect(activationRefused.observation?.keyboardOwnerPID == 77)
    #expect(refusedProbe.counts.samples == 2)

    let activatedProbe = OwnershipProbe([refused, ready, ready, refused])
    var waits: [UInt32] = []
    let activated = FrontmostGate.prepareObserved(
        observe: { activatedProbe.read() }, activate: { activatedProbe.activate() },
        sleepMicros: { waits.append($0) })
    #expect(activated.preparation == .activated)
    #expect(activated.observation?.keyboardOwnerPID == 4242)
    #expect(activatedProbe.counts.samples == 3)
    #expect(activatedProbe.counts.activations == 1)
    #expect(waits == [50_000, 50_000])
}

@Test func frontmostGatePreservesTwoConsecutiveTwentyPollFiftyMillisecondOneActivationBound() {
    let refused = ownershipReading(77, bundle: "com.apple.finder")
    let probe = OwnershipProbe([refused])
    var waits: [UInt32] = []
    let result = FrontmostGate.prepareObserved(observe: { probe.read() },
                                              activate: { probe.activate() }, sleepMicros: { waits.append($0) })
    #expect(result.preparation == .activationTimedOut)
    #expect(probe.counts.samples == 21)
    #expect(probe.counts.activations == 1)
    #expect(waits == Array(repeating: 50_000, count: 20))
    #expect(FrontmostGate.requiredObservations == 2)
    #expect(result.observation?.keyboardOwnerPID == 77)
}

@Test func frontmostBoolOnlyFakeHasNoInventedOwnershipObservation() async throws {
    let result = FrontmostGate.prepareObserved(observe: nil, isFrontmost: { false },
                                              activate: { false }, sleepMicros: { _ in })
    #expect(result.preparation == .activationRefused)
    #expect(result.observation == nil)
    #expect(result.diagnosticExtras.isEmpty)

    let b = FakeAXRuntimeBuilder()
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 4242 }, ax: b.makeAXRuntime(),
        executeAppleScript: { _ in Issue.record("dialog script prohibited"); return .error("owned refusal") },
        onScreenWindowList: { nil }, postPopupMenuEscape: { Issue.record("live Escape prohibited") },
        observeFrontmost: { Issue.record("helper must not inherit runtime observer"); return ownershipReading() })
    let ax = await AccessibilityChannel.gotoPositionViaBarSlider(
        params: ["bar": "1"], runtime: runtime, isFrontmost: { false },
        activateLogic: { false }, sleepMicros: { _ in })
    #expect(b.actionCalls.isEmpty)
    #expect(b.setCalls.isEmpty)
    let axObject = try #require(sharedJSONObject(ax.message))
    #expect(axObject["frontmost_observation"] == nil)
    #expect(axObject["frontmost_preparation"] as? String == "activation_refused")

    let cg = await CGEventChannel(runtime: .init(
        isLogicProRunning: { true }, logicProPID: { 4242 },
        postKeyEvent: { _, _, _ in Issue.record("key post prohibited"); return false },
        sleepMicros: { _ in }, isLogicFrontmost: { false }, activateLogic: { false }
    )).execute(operation: "transport.play", params: [:])
    let cgObject = try #require(sharedJSONObject(cg.message))
    #expect(cgObject["frontmost_observation"] == nil)
    #expect(cgObject["frontmost_preparation"] as? String == "activation_refused")
}

@Test func axGotoRefusalCarriesOwnSnapshotAndActuatesNothing() async throws {
    let b = FakeAXRuntimeBuilder()
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 4242 }, ax: b.makeAXRuntime(),
        executeAppleScript: { _ in Issue.record("dialog script prohibited"); return .error("owned refusal") },
        onScreenWindowList: { nil }, postPopupMenuEscape: { Issue.record("live Escape prohibited") })
    let probe = OwnershipProbe([ownershipReading(77, bundle: "com.apple.finder")])
    let result = await AccessibilityChannel.gotoPositionViaBarSlider(
        params: ["bar": "1"], runtime: runtime, isFrontmost: { Issue.record("Bool must not resample"); return true },
        activateLogic: { false }, sleepMicros: { _ in }, observeFrontmost: { probe.read() })
    #expect(b.actionCalls.isEmpty)
    #expect(b.setCalls.isEmpty)
    #expect(probe.counts.samples == 1)
    let object = try #require(sharedJSONObject(result.message))
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(object["frontmost_preparation"] as? String == "activation_refused")
    let reading = try #require(object["frontmost_observation"] as? [String: Any])
    #expect(reading["reason"] as? String == "keyboard_owner_not_logic")
}

@Test(arguments: ["transport.play", "transport.goto_position"])
func cgMappedAndGotoRefusalsCarryOwnSnapshotAndPostZero(_ operation: String) async throws {
    let probe = OwnershipProbe([ownershipReading(77, bundle: "com.apple.finder")])
    let runtime = CGEventChannel.Runtime(
        isLogicProRunning: { true }, logicProPID: { 4242 },
        postKeyEvent: { _, _, _ in probe.post() }, sleepMicros: { _ in },
        isLogicFrontmost: { Issue.record("Bool must not resample"); return true },
        activateLogic: { false }, observeFrontmost: { probe.read() })
    let result = await CGEventChannel(runtime: runtime).execute(operation: operation, params: ["position": "1.1.1.1"])
    #expect(probe.counts.posts == 0)
    #expect(probe.counts.samples == 1)
    let object = try #require(sharedJSONObject(result.message))
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(object["events_posted"] as? Int == 0)
    let reading = try #require(object["frontmost_observation"] as? [String: Any])
    #expect(reading["keyboard_owner_pid"] as? Int == 77)
}

@Test func routerOwnershipProjectionRejectsTitlesPathsRawErrorsAndMalformedTypes() throws {
    let malformed: [Any] = [true, "77", 2_147_483_648 as Int64, 77.5]
    for value in malformed {
        let object: [String: Any] = [
            "frontmost_preparation": "activation_timed_out",
            "frontmost_observation": [
                "reason": "focused_application_mismatch", "focus_read": "read",
                "keyboard_owner_pid": value, "focused_application_pid": value,
                "keyboard_window_layer": "8", "keyboard_owner_bundle_id": "/Users/private/secret.logicx",
                "title": "private title", "raw_error": "private error",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let attributes = ChannelRouter.frontmostTraceAttributes(from: String(decoding: data, as: UTF8.self))
        #expect(attributes == [
            "frontmost_preparation": "activation_timed_out",
            "frontmost_reason": "focused_application_mismatch", "frontmost_focus_read": "read",
        ])
    }
    let hostile = #"{"frontmost_preparation":"private title","frontmost_observation":{"reason":"private title","focus_read":"private error","keyboard_owner_bundle_id":"com.fake.\nsecret","unknown":"private path"}}"#
    #expect(ChannelRouter.frontmostTraceAttributes(from: hostile).isEmpty)
    for bundle in ownershipHostileBundles {
        let data = try JSONSerialization.data(withJSONObject: [
            "frontmost_observation": [
                "reason": "keyboard_owner_not_logic", "focus_read": "unavailable",
                "keyboard_owner_bundle_id": bundle,
            ],
        ])
        let attributes = ChannelRouter.frontmostTraceAttributes(from: String(decoding: data, as: UTF8.self))
        #expect(attributes == ["frontmost_reason": "keyboard_owner_not_logic",
                               "frontmost_focus_read": "unavailable"])
    }
}

extension OperationTraceTests {
    @Test func routerCompletedTraceKeepsEachAttemptSnapshotSeparate() async throws {
        let context = OperationTraceContext()
        let id = await OperationTraceStore.shared.start(operationID: "transport.goto_position")
        context.register(id)
        let router = ChannelRouter()
        await router.register(OwnershipRefusalChannel(
            id: .accessibility, payload: ownershipPayload(ownershipReading(77, bundle: "com.apple.finder"))))
        await router.register(OwnershipRefusalChannel(
            id: .cgEvent, payload: ownershipPayload(ownershipReading(focused: 88))))
        _ = await OperationTraceContext.$current.withValue(context) {
            await router.route(operation: "transport.goto_position", params: ["bar": "1"])
        }
        let trace = try #require(await OperationTraceStore.shared.trace(id))
        let completed = trace.events.filter { $0.phase == .channelCompleted }
        #expect(completed.count == 2)
        #expect(completed.first?.attributes["channel"] == ChannelID.accessibility.rawValue)
        #expect(completed.first?.attributes["frontmost_keyboard_owner_pid"] == "77")
        #expect(completed.last?.attributes["channel"] == ChannelID.cgEvent.rawValue)
        #expect(completed.last?.attributes["frontmost_keyboard_owner_pid"] == "4242")
        #expect(completed.last?.attributes["frontmost_focused_application_pid"] == "88")
        #expect(completed.allSatisfy { $0.privacyClasses["frontmost_reason"] == .publicDiagnostic })

        for bundle in ownershipHostileBundles {
            let ownedContext = OperationTraceContext()
            let ownedID = await OperationTraceStore.shared.start(operationID: "transport.goto_position")
            ownedContext.register(ownedID)
            let ownedRouter = ChannelRouter()
            // Feed the untrusted bundle to the Router directly, not through producer sanitization.
            let data = try JSONSerialization.data(withJSONObject: [
                "frontmost_preparation": "activation_refused",
                "frontmost_observation": [
                    "reason": "keyboard_owner_not_logic", "focus_read": "unavailable",
                    "keyboard_owner_bundle_id": bundle,
                ],
            ])
            await ownedRouter.register(OwnershipRefusalChannel(
                id: .accessibility, payload: String(decoding: data, as: UTF8.self)))
            _ = await OperationTraceContext.$current.withValue(ownedContext) {
                await ownedRouter.route(operation: "transport.goto_position", params: ["bar": "1"])
            }
            let ownedTrace = try #require(await OperationTraceStore.shared.trace(ownedID))
            let event = try #require(ownedTrace.events.first { $0.phase == .channelCompleted })
            #expect(event.attributes["frontmost_keyboard_owner_bundle_id"] == nil)
            #expect(event.attributes["frontmost_reason"] == "keyboard_owner_not_logic")
            #expect(!event.attributes.values.contains(bundle))
        }
    }
    @Test func recordSequenceGotoRefusalPreservesDiagnosticsAndSkipsImportDiscovery() async throws {
        let b = FakeAXRuntimeBuilder()
        let axProbe = OwnershipProbe([ownershipReading(77, bundle: "com.apple.finder")])
        let cgProbe = OwnershipProbe([ownershipReading(focused: 88)])
        let logicRuntime = AXLogicProElements.Runtime(
            logicProPID: { 4242 }, ax: b.makeAXRuntime(),
            executeAppleScript: { _ in Issue.record("dialog script prohibited"); return .error("owned refusal") },
            onScreenWindowList: { nil }, postPopupMenuEscape: { Issue.record("live Escape prohibited") })
        let ax = OwnershipAXGotoChannel(runtime: logicRuntime, probe: axProbe)
        let cg = CGEventChannel(runtime: .init(
            isLogicProRunning: { true }, logicProPID: { 4242 },
            postKeyEvent: { _, _, _ in cgProbe.post() }, sleepMicros: { _ in },
            isLogicFrontmost: { false }, activateLogic: { false },
            observeFrontmost: { cgProbe.read() }))
        let router = ChannelRouter()
        await router.register(ax)
        await router.register(cg)
        let cache = StateCache()
        await cache.updateDocumentState(true)
        let followups = OwnershipFollowupProbe()
        let context = OperationTraceContext()
        let id = await OperationTraceStore.shared.start(operationID: "track.record_sequence")
        context.register(id)
        let result = await OperationTraceContext.$current.withValue(context) {
            await TrackDispatcher.handleRecordSequenceSMF(
                params: ["notes": .string("60,0,500,100,1"), "bar": .int(1)],
                router: router, cache: cache, traceID: id,
                trackHeaderCount: { followups.record("headers"); return 0 },
                trackNameAt: { _ in followups.record("name"); return nil },
                readRegions: { followups.record("regions"); return .success([]) },
                settleReadback: { followups.record("settle") })
        }
        let operations = await ax.recordedOperations()
        #expect(operations == ["transport.get_state", "transport.goto_position"])
        #expect(operations.filter { $0 == "midi.import_file" }.count == 0)
        #expect(followups.total == 0)
        #expect(b.actionCalls.isEmpty)
        #expect(b.setCalls.isEmpty)
        #expect(axProbe.counts.samples == 1)
        #expect(cgProbe.counts.samples == 1)
        #expect(cgProbe.counts.posts == 0)
        let isError = try #require(result.isError)
        #expect(isError)
        let text = sharedToolText(result)
        let prefix = "record_sequence failed to reset playhead to bar 1 (required for accurate import): "
        #expect(text.hasPrefix(prefix))
        #expect(sharedJSONObject(text) == nil) // The tool result is plain text, not an outer State C.
        let gotoEnvelope = try #require(sharedJSONObject(String(text.dropFirst(prefix.count))))
        let lastError = try #require(gotoEnvelope["last_error"] as? String)
        let cgEnvelope = try #require(sharedJSONObject(lastError))
        let observation = try #require(cgEnvelope["frontmost_observation"] as? [String: Any])
        #expect(observation["reason"] as? String == "focused_application_mismatch")
        #expect(observation["keyboard_owner_pid"] as? Int == 4242)
        let writeAttempted = try #require(cgEnvelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let trace = try #require(await OperationTraceStore.shared.trace(id))
        // The fresh position pre-read has no ownership actuation receipt. Preserve the exact
        // two goto attempt snapshots independently from that harmless unavailable read.
        let completed = trace.events.filter {
            $0.phase == .channelCompleted && $0.attributes["frontmost_preparation"] != nil
        }
        #expect(completed.count == 2)
        #expect(completed.first?.attributes["channel"] == ChannelID.accessibility.rawValue)
        #expect(completed.first?.attributes["frontmost_keyboard_owner_pid"] == "77")
        #expect(completed.last?.attributes["channel"] == ChannelID.cgEvent.rawValue)
        #expect(completed.last?.attributes["frontmost_focused_application_pid"] == "88")
    }

}
