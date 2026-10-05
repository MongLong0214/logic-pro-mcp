@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// Owned seams only: no key, AppleScript, TIS selection or screen probe reaches the host.
private final class PostGateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var posts = 0
    private var scripts = 0
    private var selections: [String] = []
    private var sources: [CGEventChannel.InputSourceReading?]
    let failPost: Int
    init(failPost: Int = 0, sources: [CGEventChannel.InputSourceReading?] = []) {
        self.failPost = failPost
        self.sources = sources
    }
    static var ready: ProcessUtils.KeyboardOwnershipObservation {
        ProcessUtils.keyboardOwnershipObservation(
            windows: [[kCGWindowOwnerPID as String: 4242, kCGWindowLayer as String: 0]],
            focusedApplicationPID: 4242, bundleIDForPID: { _ in "com.apple.logic10" })
    }
    func observe() -> ProcessUtils.KeyboardOwnershipObservation {
        lock.lock(); defer { lock.unlock() }
        samples += 1
        // A fresh probe would disagree: diagnostics must retain the decisive second sample.
        return samples <= 2 ? Self.ready : ProcessUtils.keyboardOwnershipObservation(
            windows: [], focusedApplicationPID: nil, bundleIDForPID: { _ in nil })
    }
    func post() -> Bool {
        lock.lock(); defer { lock.unlock() }; posts += 1
        return posts != failPost
    }
    func script() { lock.lock(); defer { lock.unlock() }; scripts += 1 }
    func source() -> CGEventChannel.InputSourceReading? {
        lock.lock(); defer { lock.unlock() }
        guard !sources.isEmpty else { return nil }
        return sources.count > 1 ? sources.removeFirst() : sources[0]
    }
    func select(_ id: String, success: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }; selections.append(id); return success
    }
    var counts: (samples: Int, posts: Int, scripts: Int, selections: [String]) {
        lock.lock(); defer { lock.unlock() }; return (samples, posts, scripts, selections)
    }
}

private actor PostGateChannel: Channel {
    nonisolated let id: ChannelID
    private let run: @Sendable (String, [String: String]) async -> ChannelResult
    private var result: ChannelResult?
    init(id: ChannelID, run: @escaping @Sendable (String, [String: String]) async -> ChannelResult) {
        self.id = id; self.run = run
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "owned post-gate seam") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        let completed = await run(operation, params)
        result = completed
        return completed
    }
    func lastResult() -> ChannelResult? { result }
}

private func postGateDoctor() -> SetupDoctor.Report {
    .init(schema: SetupDoctor.schema, status: .degraded, version: "fixture", installSource: .sourceBuild,
          checks: [], summary: .init(total: 0, passed: 0, failed: 0, warnings: 0, manual: 0,
                                    skipped: 0, durationMs: 0), headline: "owned fixture", fixPlan: [],
          doctorProfile: .core, doctorProfileBasis: "fixture", clientProfile: .terminal,
          clientProfileBasis: "fixture", capabilities: [:])
}

// Execute the real producer through the router, inspect its raw completed event, then export
// that same trace. Expected facts come from the known gate reading, not the channel payload.
private func runPostGate(_ channel: PostGateChannel, operation: String,
                        probe: PostGateProbe) async throws -> ChannelResult {
    let context = OperationTraceContext()
    let id = await OperationTraceStore.shared.start(operationID: operation)
    context.register(id)
    let router = ChannelRouter()
    await router.register(channel)
    _ = await OperationTraceContext.$current.withValue(context) {
        await router.route(operation: operation, params: ["position": "1.1.1.1"])
    }
    let result = try #require(await channel.lastResult())
    #expect(probe.counts.samples == 2)
    let expected: [String: String] = [
        "frontmost_preparation": "already_frontmost", "frontmost_reason": "logic_owns_keyboard",
        "frontmost_focus_read": "read", "frontmost_keyboard_owner_pid": "4242",
        "frontmost_keyboard_owner_bundle_id": "com.apple.logic10",
        "frontmost_keyboard_window_layer": "0", "frontmost_focused_application_pid": "4242",
    ]
    let projected = ChannelRouter.frontmostTraceAttributes(from: result.message)
    #expect(projected == expected)
    let trace = try #require(await OperationTraceStore.shared.trace(id))
    let completed = trace.events.filter { $0.phase == .channelCompleted }
    #expect(completed.count == 1)
    let raw = try #require(completed.first)
    #expect(raw.attributes.filter { $0.key.hasPrefix("frontmost_") } == expected)
    #expect(raw.attributes["outcome"] == (result.isSuccess ? "success" : "error"))
    let input = SupportBundleBuilder.Input(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), serverVersion: "fixture",
        serverCommit: "unknown", logic: .init(version: "12.3", variant: "desktop", locale: "en-US"),
        qualificationReference: "not_available", traces: [trace], doctorReport: postGateDoctor(),
        metadata: .init(process: .init(uptimeSec: 1, memoryMb: 1), channels: []))
    let assembly = try SupportBundleBuilder().assemble(input)
    let bytes = try #require(assembly.files["traces.json"])
    let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let traces = try #require(object["traces"] as? [[String: Any]])
    let events = try #require(traces.first?["events"] as? [[String: Any]])
    let exported = events.compactMap { $0["attributes"] as? [String: String] }
        .first { $0["channel"] == channel.id.rawValue && $0["outcome"] != nil }
    #expect(try #require(exported).filter { $0.key.hasPrefix("frontmost_") } == expected)
    #expect(probe.counts.samples == 2)
    return result
}

private func postGateCG(_ runtime: CGEventChannel.Runtime) -> PostGateChannel {
    let cg = CGEventChannel(runtime: runtime)
    return PostGateChannel(id: .cgEvent) { await cg.execute(operation: $0, params: $1) }
}

extension OperationTraceTests {
    @Test func issue1110AXDrivenDialogRetainsGateSnapshotInTraceAndBundle() async throws {
        let probe = PostGateProbe()
        let b = FakeAXRuntimeBuilder()
        let runtime = AXLogicProElements.Runtime(
            logicProPID: { 4242 }, ax: b.makeAXRuntime(),
            executeAppleScript: { _ in Issue.record("unexpected runtime script"); return .error("fixture") },
            onScreenWindowList: { [] }, postPopupMenuEscape: { Issue.record("unexpected Escape") })
        let channel = PostGateChannel(id: .accessibility) { _, params in
            await AccessibilityChannel.gotoPositionViaBarSlider(
                params: params, runtime: runtime, isFrontmost: { Issue.record("Bool resample"); return false },
                activateLogic: { Issue.record("unexpected activation"); return false }, sleepMicros: { _ in },
                observeFrontmost: { probe.observe() },
                executeDialogScript: { _ in probe.script(); return .success(#"{"result":"OK"}"#) },
                createDialogIssuanceLedger: { nil })
        }
        let result = try await runPostGate(channel, operation: "transport.goto_position", probe: probe)
        #expect(result.isSuccess)
        #expect(probe.counts.scripts == 1)
        #expect(b.actionCalls.isEmpty)
        #expect(b.setCalls.isEmpty)
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "B")
        #expect(object["dialog_cleanup"] as? String == "closed")
        #expect(try #require(object["write_attempted"] as? Bool))
        #expect(try #require(object["dialog_submission_attempted"] as? Bool))
    }

    @Test(arguments: ["baseline_unread", "opener_failed", "later_post_failed"])
    func issue1110CGGotoOutcomesRetainGateSnapshotInTraceAndBundle(_ mode: String) async throws {
        let probe = PostGateProbe(failPost: mode == "opener_failed" ? 1 : (mode == "later_post_failed" ? 3 : 0))
        let screen = GotoDialogScreen(pid: 4242, listReadable: mode != "baseline_unread")
        let runtime = CGEventChannel.Runtime(
            isLogicProRunning: { true }, logicProPID: { 4242 },
            postKeyEvent: screen.observing { _, _, _ in probe.post() }, sleepMicros: { _ in },
            isLogicFrontmost: { Issue.record("Bool resample"); return false },
            activateLogic: { Issue.record("unexpected activation"); return false },
            observeFrontmost: { probe.observe() }, onScreenWindowList: { screen.windows() })
        let result = try await runPostGate(postGateCG(runtime), operation: "transport.goto_position", probe: probe)
        #expect(!result.isSuccess)
        #expect(probe.counts.posts == (mode == "baseline_unread" ? 0 : (mode == "opener_failed" ? 1 : 3)))
        #expect(screen.keysTypedBeforeDialogShown == 0)
        if mode == "baseline_unread" {
            let object = try #require(sharedJSONObject(result.message))
            #expect(object["state"] as? String == "C")
            #expect(object["error"] as? String == "dialog_not_found")
            #expect(object["events_posted"] as? Int == 0)
            #expect(!(try #require(object["write_attempted"] as? Bool)))
            #expect(try #require(object["safe_to_retry"] as? Bool))
        } else {
            // The legacy error makes no claim about partial delivery or retry safety.
            let object = try #require(sharedJSONObject(result.message))
            #expect(object["message"] as? String == "Failed to post CGEvent sequence for transport.goto_position")
            #expect(object["state"] == nil)
            #expect(object["events_posted"] == nil)
            #expect(object["write_attempted"] == nil)
            #expect(object["safe_to_retry"] == nil)
        }
    }

    @Test(arguments: [false, true])
    func issue1110MappedPostFailureRetainsGateAndOriginalSourceRestoration(_ switched: Bool) async throws {
        let original = CGEventChannel.InputSourceReading(id: "fixture.original", isASCIICapable: false)
        let layout = CGEventChannel.InputSourceReading(id: "com.apple.keylayout.ABC", isASCIICapable: true)
        let probe = PostGateProbe(failPost: 1, sources: switched ? [original, layout, original] : [layout])
        let runtime = CGEventChannel.Runtime(
            isLogicProRunning: { true }, logicProPID: { 4242 },
            postKeyEvent: { _, _, _ in probe.post() }, sleepMicros: { _ in },
            observeFrontmost: { probe.observe() }, currentInputSource: { probe.source() },
            asciiCapableLayoutID: { "com.apple.keylayout.ABC" },
            selectInputSource: { probe.select($0, success: true) }, layoutLetter: { _, _ in "r" },
            layoutIsEnabled: { _ in true })
        let result = try await runPostGate(postGateCG(runtime), operation: "transport.record", probe: probe)
        #expect(!result.isSuccess)
        #expect(probe.counts.posts == 1)
        #expect(probe.counts.selections == (switched ? ["com.apple.keylayout.ABC", "fixture.original"] : []))
        let object = try #require(sharedJSONObject(result.message))
        let message = try #require(object["message"] as? String)
        #expect(message.hasPrefix("Failed to post CGEvent for transport.record"))
        if switched { #expect(message.contains("reads fixture.original again")) }
        #expect(object["state"] == nil)
        #expect(object["events_posted"] == nil)
        #expect(object["write_attempted"] == nil)
        #expect(object["safe_to_retry"] == nil)
    }

    @Test(arguments: ["source_unread", "source_id_unread", "no_layout", "wrong_letter",
                      "letter_unread", "select_failed", "switch_unread", "switch_wrong"])
    func issue1110InputRefusalRetainsGateSnapshotWithoutPosting(_ mode: String) async throws {
        let original = CGEventChannel.InputSourceReading(id: mode == "source_id_unread" ? nil : "fixture.original",
                                                       isASCIICapable: false)
        let wrong = CGEventChannel.InputSourceReading(id: "fixture.wrong", isASCIICapable: true)
        let sources: [CGEventChannel.InputSourceReading?] = mode == "source_unread" ? [nil]
            : (mode == "switch_unread" ? [original, nil, original]
               : (mode == "switch_wrong" ? [original, wrong, original] : [original]))
        let probe = PostGateProbe(sources: sources)
        let runtime = CGEventChannel.Runtime(
            isLogicProRunning: { true }, logicProPID: { 4242 },
            postKeyEvent: { _, _, _ in probe.post() }, sleepMicros: { _ in },
            observeFrontmost: { probe.observe() }, currentInputSource: { probe.source() },
            asciiCapableLayoutID: { mode == "no_layout" ? nil : "com.apple.keylayout.ABC" },
            selectInputSource: { probe.select($0, success: mode != "select_failed") },
            layoutLetter: { _, _ in mode == "letter_unread" ? nil : (mode == "wrong_letter" ? "x" : "r") },
            layoutIsEnabled: { _ in true })
        let result = try await runPostGate(postGateCG(runtime), operation: "transport.record", probe: probe)
        #expect(!result.isSuccess)
        #expect(probe.counts.posts == 0)
        let expectedSelections = ["switch_unread", "switch_wrong"].contains(mode)
            ? ["com.apple.keylayout.ABC", "fixture.original"]
            : (mode == "select_failed" ? ["com.apple.keylayout.ABC"] : [])
        #expect(probe.counts.selections == expectedSelections)
        let object = try #require(sharedJSONObject(result.message))
        #expect(object["state"] as? String == "C")
        #expect(object["error"] as? String == "not_supported")
        #expect(object["events_posted"] as? Int == 0)
        #expect(!(try #require(object["write_attempted"] as? Bool)))
        #expect(try #require(object["safe_to_retry"] as? Bool))
        let failures = ["source_id_unread": "source_id_unreadable", "no_layout": "no_ascii_capable_layout",
                        "wrong_letter": "layout_types_another_letter", "letter_unread": "layout_types_another_letter",
                        "select_failed": "select_failed", "switch_unread": "switch_not_verified",
                        "switch_wrong": "switch_not_verified"]
        #expect(object["input_source_switch_failure"] as? String == failures[mode])
    }
}
