@preconcurrency import ApplicationServices
import Foundation
import Testing
import MCP
@testable import LogicProMCP

// v3.1.2 P0-2 regression — record_sequence used to verify track creation by
// polling `cache.getTracks().count` for 2s. The StatePoller runs every 3s
// (ServerConfig.statePollingIntervalNs), so the cache literally could not
// reflect the new track inside the verification window — every successful
// import false-failed on the first call (witnessed live 3×).
//
// The fix moves verification to a direct AX read (`allTrackHeaders().count`),
// removing the cache from the verification critical path entirely. These
// tests cover the dispatcher's new error-message wording (so the cache-poll
// path can never silently regress back) and verify the cache contents do not
// influence the verification outcome.

private actor RecordingMockChannel: Channel {
    nonisolated let id: ChannelID
    var importCalls: Int = 0
    let importResult: ChannelResult
    let gotoRuntime: AXLogicProElements.Runtime?
    let dialogOutput: String?
    let gotoResult: ChannelResult?
    var transportReadbacks: [ChannelResult]
    var operations: [String] = []
    var rawGotoResult: ChannelResult?

    init(id: ChannelID, importResult: ChannelResult,
         gotoRuntime: AXLogicProElements.Runtime? = nil, dialogOutput: String? = nil,
         gotoResult: ChannelResult? = nil,
         transportReadbacks: [ChannelResult] = []) {
        self.id = id
        self.importResult = importResult
        self.gotoRuntime = gotoRuntime
        self.dialogOutput = dialogOutput
        self.gotoResult = gotoResult
        self.transportReadbacks = transportReadbacks
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        operations.append(operation)
        if operation == "transport.get_state", !transportReadbacks.isEmpty {
            return transportReadbacks.count > 1 ? transportReadbacks.removeFirst() : transportReadbacks[0]
        }
        if operation == "transport.goto_position", let gotoResult {
            rawGotoResult = gotoResult
            return gotoResult
        }
        if operation == "transport.goto_position", let gotoRuntime, let dialogOutput {
            let result = await AccessibilityChannel.gotoPositionViaBarSlider(
                params: params, runtime: gotoRuntime, isFrontmost: { true },
                activateLogic: { false }, sleepMicros: { _ in },
                executeDialogScript: { _ in .success(dialogOutput) },
                reconcileAfterDialogExecutionFailure: { false }, createDialogIssuanceLedger: { nil })
            rawGotoResult = result
            return result
        }
        if operation == "midi.import_file" {
            importCalls += 1
            return importResult
        }
        // transport.goto_position is a precondition; succeed silently.
        return .success("ok")
    }

    func healthCheck() async -> ChannelHealth { .healthy(detail: "mock") }
}

private func recordSequencePosition(
    _ value: String?, components: [TransportPositionComponent] = TransportPositionComponent.allCases
) throws -> ChannelResult {
    var state = TransportState()
    if let value {
        state.position = value
        state.positionReadback = TransportPositionReadback(value: value, observedComponents: components)
    }
    state.lastUpdated = Date(timeIntervalSince1970: 0)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return .success(String(decoding: try encoder.encode(state), as: UTF8.self))
}

@Test func testRecordSequenceRejectsActualUnsafeGotoBeforeImport() async throws {
    let builder = FakeAXRuntimeBuilder()
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 4242 }, ax: builder.makeAXRuntime(),
        executeAppleScript: { _ in Issue.record("native script must not run"); return .error("inert") },
        onScreenWindowList: { nil },
        postPopupMenuEscape: { Issue.record("native escape must not run") })
    let channel = RecordingMockChannel(
        id: .accessibility, importResult: .error("bounded unexpected import"),
        gotoRuntime: runtime,
        dialogOutput: #"{"result":"DIALOG_SUBMISSION_ISSUED: Return may have been sent (AX error)"}"#,
        transportReadbacks: [try recordSequencePosition("2.1.1.1"), try recordSequencePosition("1.1.1.1")])
    let router = ChannelRouter()
    await router.register(channel)
    let cache = StateCache()
    await cache.updateDocumentState(true)
    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["notes": minimalNoteSpec()], router: router, cache: cache,
        trackHeaderCount: { Issue.record("unverified position must not discover import tracks"); return 0 },
        trackNameAt: { _ in Issue.record("unverified position must not read track names"); return nil },
        readRegions: { Issue.record("unverified position must not read import regions"); return .success([]) },
        settleReadback: { Issue.record("unverified position must not settle import") })
    let raw = try #require(await channel.rawGotoResult)
    #expect(raw.isSuccess)
    let rawObject = try #require(sharedJSONObject(raw.message))
    #expect(rawObject["state"] as? String == "B")
    #expect(try #require(rawObject["fallback_unsafe"] as? Bool))
    #expect(!(try #require(rawObject["safe_to_retry"] as? Bool)))
    #expect(await channel.importCalls == 0)
    #expect(!(await channel.operations).contains("midi.import_file"))
    #expect(try #require(result.isError))
    let text = sharedToolText(result)
    let prefix = "record_sequence failed to reset playhead to bar 1 (required for accurate import): "
    #expect(text.hasPrefix(prefix))
    let diagnostic = try #require(sharedJSONObject(String(text.dropFirst(prefix.count))))
    #expect(diagnostic["reason"] as? String == "readback_unavailable")
    #expect(diagnostic["dialog_input_target"] as? String == "unknown")
    #expect(try #require(diagnostic["fallback_unsafe"] as? Bool))
    #expect(builder.setCalls.isEmpty)
    #expect(builder.actionCalls.isEmpty)
}

@Test(arguments: ["dialog_ok", "route_state_a", "already_at_target"])
func testRecordSequenceVerifiesPositionBeforeImport(_ mode: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 4242 }, ax: builder.makeAXRuntime(),
        executeAppleScript: { _ in Issue.record("native script prohibited"); return .error("inert") },
        onScreenWindowList: { nil }, postPopupMenuEscape: { Issue.record("native escape prohibited") })
    let channel = RecordingMockChannel(
        id: .accessibility, importResult: .success("imported"),
        gotoRuntime: runtime, dialogOutput: #"{"result":"OK"}"#,
        gotoResult: mode == "route_state_a" ? .success(HonestContract.encodeStateA()) : nil,
        transportReadbacks: [try recordSequencePosition(mode == "already_at_target" ? "1.1.1.1" : "2.1.1.1"),
                             try recordSequencePosition("1.1.1.1")])
    let router = ChannelRouter()
    await router.register(channel)
    let cache = StateCache()
    await cache.updateDocumentState(true)
    let counts = SequentialIntBox([1, 2])
    let regions = SequentialRegionReadBox([
        .success([]), .success([makeRegion(trackIndex: 1, startBar: 1, endBar: 2)])])
    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["notes": minimalNoteSpec()], router: router, cache: cache,
        trackHeaderCount: { counts.next() }, trackNameAt: { $0 == 1 ? "Imported Piano" : nil },
        readRegions: { regions.next() }, settleReadback: {})
    #expect(!(try #require(result.isError)))
    let object = recordSequenceJSONObject(result)
    #expect(try #require(object["verified"] as? Bool))
    #expect(object["target_track_index"] as? Int == 1)
    #expect(await channel.importCalls == 1)
    if mode == "already_at_target" {
        #expect(await channel.operations == ["transport.get_state", "midi.import_file"])
        #expect(await channel.rawGotoResult == nil)
    } else {
        #expect(await channel.operations == ["transport.get_state", "transport.goto_position", "transport.get_state", "midi.import_file"])
        let raw = try #require(await channel.rawGotoResult)
        #expect(sharedJSONObject(raw.message)?["state"] as? String == (mode == "dialog_ok" ? "B" : "A"))
    }
    #expect(builder.setCalls.isEmpty)
    #expect(builder.actionCalls.isEmpty)
}

@Test(arguments: ["wrong_position", "partial_after", "display_default", "missing_before", "missing_after",
                  "input_issued", "state_a_unsafe", "state_a_mismatch"])
func testRecordSequenceWithholdsImportWithoutVerifiedPosition(_ mode: String) async throws {
    let builder = FakeAXRuntimeBuilder()
    let runtime = AXLogicProElements.Runtime(
        logicProPID: { 4242 }, ax: builder.makeAXRuntime(),
        executeAppleScript: { _ in Issue.record("native script prohibited"); return .error("inert") },
        onScreenWindowList: { nil }, postPopupMenuEscape: { Issue.record("native escape prohibited") })
    let before: ChannelResult = mode == "missing_before" ? .error("injected unread pre-position")
        : try recordSequencePosition("2.1.1.1")
    let after: ChannelResult
    switch mode {
    case "wrong_position", "state_a_mismatch": after = try recordSequencePosition("3.1.1.1")
    case "partial_after": after = try recordSequencePosition("1.1", components: [.bar, .beat])
    case "display_default": after = try recordSequencePosition(nil)
    case "missing_after": after = .error("injected unread post-position")
    default: after = try recordSequencePosition("1.1.1.1")
    }
    let channel = RecordingMockChannel(
        id: .accessibility, importResult: .error("bounded unexpected import"),
        gotoRuntime: runtime,
        dialogOutput: mode == "input_issued"
            ? #"{"result":"DIALOG_INPUT_ISSUED: POSITION_INPUT_ARMED: position text may have been sent (AX error)"}"#
            : #"{"result":"OK"}"#,
        gotoResult: mode.hasPrefix("state_a") ? .success(HonestContract.encodeStateA(
            extras: mode == "state_a_unsafe" ? ["fallback_unsafe": true, "safe_to_retry": false] : [:])) : nil,
        transportReadbacks: [before, after])
    let router = ChannelRouter()
    await router.register(channel)
    let cache = StateCache()
    await cache.updateDocumentState(true)
    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["notes": minimalNoteSpec()], router: router, cache: cache,
        trackHeaderCount: { Issue.record("unverified position must not discover tracks"); return 0 },
        trackNameAt: { _ in Issue.record("unverified position must not read names"); return nil },
        readRegions: { Issue.record("unverified position must not read regions"); return .success([]) },
        settleReadback: { Issue.record("unverified position must not settle import") })
    #expect(try #require(result.isError))
    #expect(await channel.operations == ["transport.get_state", "transport.goto_position", "transport.get_state"])
    #expect(await channel.importCalls == 0)
    let prefix = "record_sequence failed to reset playhead to bar 1 (required for accurate import): "
    let text = sharedToolText(result)
    #expect(text.hasPrefix(prefix))
    let diagnostic = try #require(sharedJSONObject(String(text.dropFirst(prefix.count))))
    #expect(diagnostic["state"] as? String == "B")
    #expect(!(try #require(diagnostic["verified"] as? Bool)))
    if mode == "input_issued" {
        #expect(diagnostic["verification_withheld"] as? String == "dialog_input_target")
        #expect(diagnostic["dialog_input_boundary"] as? String == "POSITION_INPUT_ARMED")
        #expect(try #require(diagnostic["fallback_unsafe"] as? Bool))
    } else if mode == "state_a_unsafe" {
        #expect(diagnostic["verification_withheld"] as? String == "fallback_unsafe")
    }
    #expect(builder.setCalls.isEmpty)
    #expect(builder.actionCalls.isEmpty)
}

private func minimalNoteSpec() -> Value {
    .string("60,0,500,100,1")
}

private final class SequentialIntBox: @unchecked Sendable {
    private var values: [Int]

    init(_ values: [Int]) {
        self.values = values
    }

    func next() -> Int {
        guard !values.isEmpty else { return 0 }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private final class SequentialRegionReadBox: @unchecked Sendable {
    private var values: [TrackDispatcher.RecordSequenceRegionReadback]

    init(_ values: [TrackDispatcher.RecordSequenceRegionReadback]) {
        self.values = values
    }

    func next() -> TrackDispatcher.RecordSequenceRegionReadback {
        guard !values.isEmpty else { return .success([]) }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private func makeRegion(
    name: String = "Imported Idea",
    trackIndex: Int,
    startBar: Int,
    endBar: Int,
    kind: String = "midi",
    rawHelp: String? = nil
) -> RegionInfo {
    RegionInfo(
        name: name,
        trackIndex: trackIndex,
        startBar: startBar,
        endBar: endBar,
        kind: kind,
        rawHelp: rawHelp
    )
}

private func recordSequenceJSONObject(_ result: CallTool.Result) -> [String: Any] {
    let text = sharedToolText(result)
    let data = Data(text.utf8)
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func testRecordSequenceUsesLiveAXNotCache() async {
    // Pre-fill the cache with 2 tracks so that under the OLD cache-poll
    // verification, `tracksBefore = 2` and `tracksAfter` would also stay 2
    // (no live import in this test sandbox), producing the legacy
    // "new track never appeared" cache-poll error.
    //
    // Under the NEW live-AX verification, the cache count is irrelevant —
    // verification reads AXLogicProElements.allTrackHeaders() directly. In a
    // headless sandbox that returns 0, so we expect the new error wording
    // ("live AX still shows N tracks") rather than the old wording. That
    // wording change is the regression tripwire: if anyone reverts the fix,
    // this test fails immediately.
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 0, name: "Old A", type: .softwareInstrument),
        TrackState(id: 1, name: "Old B", type: .softwareInstrument),
    ])
    // record_sequence requires hasDocument == true to even reach the AX
    // verification path; default is true but make the precondition explicit.
    await cache.updateDocumentState(true)

    let router = ChannelRouter()
    let ax = RecordingMockChannel(
        id: .accessibility,
        importResult: .success("imported")
    )
    await router.register(ax)
    let trackCounts = SequentialIntBox([0, 0])

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: [
            "notes": minimalNoteSpec(),
            "bar": .int(1),
        ],
        router: router,
        cache: cache,
        trackHeaderCount: { trackCounts.next() },
        trackNameAt: { _ in nil },
        readRegions: { .success([]) },
        settleReadback: {}
    )
    let text = sharedToolText(result)

    // Either the new error wording (sandbox path, AX returns 0 tracks) or a
    // success (would only happen if a real Logic Pro session is running
    // headlessly during the test — extremely unlikely on CI). Both prove the
    // cache count (which we seeded at 2) is no longer the verification
    // signal. The OLD code would have produced "tracks before: 2, after: 2".
    #expect(
        !text.contains("tracks before: 2, after: 2"),
        "regression: legacy cache-poll error wording must never resurface — got: \(text)"
    )
    #expect(
        text.contains("live AX") || text.contains("created_track"),
        "expected new live-AX error wording or a success payload, got: \(text)"
    )
}

@Test func testRecordSequenceRejectsImportFailureWithImportHandlerWording() async {
    // If the import channel itself fails (State C from AX), the dispatcher
    // must surface that error and never run the verification path. This
    // protects against a future regression where the verification logic
    // accidentally swallows the import failure.
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let router = ChannelRouter()
    let ax = RecordingMockChannel(
        id: .accessibility,
        importResult: .error("State C: ax_write_failed")
    )
    await router.register(ax)

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: [
            "notes": minimalNoteSpec(),
            "bar": .int(1),
        ],
        router: router,
        cache: cache,
        trackHeaderCount: { 0 },
        trackNameAt: { _ in nil },
        readRegions: { .success([]) },
        settleReadback: {}
    )
    let text = sharedToolText(result)
    #expect(
        text.contains("midi.import_file"),
        "import-failure path must surface the import handler error, got: \(text)"
    )
}

@Test func testRecordSequenceSurfacesImportDialogSeenFlags() async throws {
    // #140 — when import_file fails with the new dialog_not_found envelope, the
    // record_sequence import_failure result must lift the dialog-seen flags to
    // its own top level so callers can tell an occluded session (no sheet ever
    // appeared) from a real import miss, rather than only burying them in
    // `detail`.
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let importEnvelope = HonestContract.encodeStateC(
        error: .dialogNotFound,
        hint: "midi.import_file: file-open sheet did not appear",
        extras: [
            "requested": "/tmp/LogicProMCP/x.mid",
            "missing_element": "file_open_sheet",
            "file_open_dialog_seen": false,
            "tempo_dialog_seen": false,
        ]
    )

    let router = ChannelRouter()
    let ax = RecordingMockChannel(id: .accessibility, importResult: .error(importEnvelope))
    await router.register(ax)

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["notes": minimalNoteSpec(), "bar": .int(1)],
        router: router,
        cache: cache,
        trackHeaderCount: { 0 },
        trackNameAt: { _ in nil },
        readRegions: { .success([]) },
        settleReadback: {}
    )
    let obj = recordSequenceJSONObject(result)
    #expect(obj["error"] as? String == "import_failure")
    #expect(obj["import_error"] as? String == "dialog_not_found")
    #expect(obj["missing_element"] as? String == "file_open_sheet")
    let fileOpenSeen = try #require(obj["file_open_dialog_seen"] as? Bool)
    #expect(!fileOpenSeen)
    let tempoSeen = try #require(obj["tempo_dialog_seen"] as? Bool)
    #expect(!tempoSeen)
}

@Test func testRecordSequenceSurfacesSystemEventsAutomationDeniedImportError() async throws {
    let expectedHint = "System Events Automation is denied for the process responsible for launching this server (a launcher-permission gap, not a Logic limitation). Grant it in System Settings > Privacy & Security > Automation, or run the server/harness under a responsible app that already has it (Terminal, iTerm, or your editor). Logic Pro automation being granted is separate and not sufficient."
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let stderr = "execution error: Not authorized to send Apple events to System Events. (-1743)"
    let importEnvelope = HonestContract.encodeStateC(
        error: .systemEventsAutomationDenied,
        hint: expectedHint,
        extras: [
            "osascript_stderr": stderr,
            "file_open_dialog_seen": false,
            "tempo_dialog_seen": false,
        ]
    )

    let router = ChannelRouter()
    let ax = RecordingMockChannel(id: .accessibility, importResult: .error(importEnvelope))
    await router.register(ax)

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["notes": minimalNoteSpec(), "bar": .int(1)],
        router: router,
        cache: cache,
        trackHeaderCount: { 0 },
        trackNameAt: { _ in nil },
        readRegions: { .success([]) },
        settleReadback: {}
    )

    let object = recordSequenceJSONObject(result)
    #expect(object["error"] as? String == "system_events_automation_denied")
    #expect(object["import_error"] as? String == "system_events_automation_denied")
    #expect(object["failure_stage"] as? String == "midi.import_file")
    #expect(object["osascript_stderr"] as? String == stderr)
    let hint = try #require(object["hint"] as? String)
    #expect(hint == expectedHint)
}

@Test func testRecordSequenceFailsClosedOnGMDeviceImportDowngrade() async throws {
    // #128 regression: PR #150 correctly downgraded the lower-level
    // `midi.import_file` result to State B when Logic created GM Device lanes,
    // but `record_sequence` only checked `importResult.isSuccess`. It then
    // verified region readback and re-promoted the take to success, allowing a
    // visually valid but external-MIDI arrangement to reach a silent Bounce.
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let importEnvelope = HonestContract.encodeStateB(
        reason: .importedAsGMDevice,
        extras: [
            "requested": "/tmp/LogicProMCP/seq.mid",
            "track_count_before": 1,
            "track_count_after": 2,
            "observed_delta": 1,
            "audible": false,
            "gm_device_lanes": ["GM Device 1"],
            "imported_lanes": ["GM Device 1"],
            "file_open_dialog_seen": true,
            "tempo_dialog_seen": true,
        ]
    )

    let router = ChannelRouter()
    let ax = RecordingMockChannel(id: .accessibility, importResult: .success(importEnvelope))
    await router.register(ax)

    let trackCounts = SequentialIntBox([1, 2])
    let regionReads = SequentialRegionReadBox([
        .success([]),
        .success([makeRegion(trackIndex: 1, startBar: 1, endBar: 2)]),
    ])

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: ["notes": minimalNoteSpec(), "bar": .int(1)],
        router: router,
        cache: cache,
        trackHeaderCount: { trackCounts.next() },
        trackNameAt: { $0 == 1 ? "GM Device 1" : nil },
        readRegions: { regionReads.next() },
        settleReadback: {}
    )

    let isError = try #require(result.isError)
    #expect(isError)

    let object = recordSequenceJSONObject(result)
    let success = try #require(object["success"] as? Bool)
    #expect(!success)
    let verified = try #require(object["verified"] as? Bool)
    #expect(!verified)
    #expect(object["error"] as? String == "audibility_unverified")
    #expect(object["failure_stage"] as? String == "midi.import_file")
    #expect(object["import_reason"] as? String == "imported_as_gm_device")
    #expect(!((object["audible"] as? Bool)!))
    #expect(object["gm_device_lanes"] as? [String] == ["GM Device 1"])
    // No success-provenance leakage: region readback cannot override the
    // lower-level audible-routing downgrade.
    #expect(object["created_track"] == nil)
    #expect(object["verify_source"] == nil)
    #expect(object["recorded_to_track"] == nil)
}

@Test func testRecordSequenceReturnsVerifiedRegionReadbackPayload() async {
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let router = ChannelRouter()
    let ax = RecordingMockChannel(id: .accessibility, importResult: .success("imported"))
    await router.register(ax)

    let trackCounts = SequentialIntBox([1, 2])
    let regionReads = SequentialRegionReadBox([
        .success([]),
        .success([makeRegion(trackIndex: 1, startBar: 1, endBar: 2)]),
    ])

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: [
            "notes": minimalNoteSpec(),
            "bar": .int(1),
        ],
        router: router,
        cache: cache,
        trackHeaderCount: { trackCounts.next() },
        trackNameAt: { $0 == 1 ? "Imported Piano" : nil },
        readRegions: { regionReads.next() },
        settleReadback: {}
    )

    #expect(!(result.isError!))
    let object = recordSequenceJSONObject(result)
    #expect((object["success"] as? Bool)!)
    #expect((object["verified"] as? Bool)!)
    #expect(object["created_track"] as? Int == 1)
    #expect(object["recorded_to_track"] as? Int == 1)
    #expect(object["target_track_index"] as? Int == 1)
    #expect(object["target_track_name"] as? String == "Imported Piano")
    #expect(object["region_name"] as? String == "Imported Idea")
    #expect(object["start_bar"] as? Int == 1)
    #expect(object["end_bar"] as? Int == 2)
    #expect(object["note_count"] as? Int == 1)
    #expect(object["verify_source"] as? String == "ax_region_delta")
}

@Test func testRecordSequenceDistinguishesWrongTrackImport() async {
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let router = ChannelRouter()
    let ax = RecordingMockChannel(id: .accessibility, importResult: .success("imported"))
    await router.register(ax)

    let trackCounts = SequentialIntBox([1, 2])
    let regionReads = SequentialRegionReadBox([
        .success([]),
        .success([makeRegion(trackIndex: 0, startBar: 1, endBar: 2)]),
    ])

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: [
            "notes": minimalNoteSpec(),
            "bar": .int(1),
        ],
        router: router,
        cache: cache,
        trackHeaderCount: { trackCounts.next() },
        trackNameAt: { $0 == 1 ? "Imported Piano" : nil },
        readRegions: { regionReads.next() },
        settleReadback: {}
    )

    #expect(result.isError!)
    let object = recordSequenceJSONObject(result)
    #expect(object["error"] as? String == "wrong_track_import")
    #expect(object["target_track_index"] as? Int == 1)
    #expect(object["observed_track_index"] as? Int == 0)
    #expect(object["observed_region_name"] as? String == "Imported Idea")
}

@Test func testRecordSequenceDistinguishesTimingMismatch() async {
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let router = ChannelRouter()
    let ax = RecordingMockChannel(id: .accessibility, importResult: .success("imported"))
    await router.register(ax)

    let trackCounts = SequentialIntBox([1, 2])
    let regionReads = SequentialRegionReadBox([
        .success([]),
        .success([makeRegion(trackIndex: 1, startBar: 1, endBar: 3)]),
    ])

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: [
            "notes": minimalNoteSpec(),
            "bar": .int(1),
        ],
        router: router,
        cache: cache,
        trackHeaderCount: { trackCounts.next() },
        trackNameAt: { $0 == 1 ? "Imported Piano" : nil },
        readRegions: { regionReads.next() },
        settleReadback: {}
    )

    #expect(result.isError!)
    let object = recordSequenceJSONObject(result)
    #expect(object["error"] as? String == "timing_mismatch")
    #expect(object["region_name"] as? String == "Imported Idea")
    #expect(object["start_bar"] as? Int == 1)
    #expect(object["end_bar"] as? Int == 3)
    #expect(object["expected_end_bar"] as? Int == 2)
}

@Test func testRecordSequenceDistinguishesUnreadableReadback() async {
    let cache = StateCache()
    await cache.updateDocumentState(true)

    let router = ChannelRouter()
    let ax = RecordingMockChannel(id: .accessibility, importResult: .success("imported"))
    await router.register(ax)

    let trackCounts = SequentialIntBox([1, 2])
    let regionReads = SequentialRegionReadBox([
        .success([]),
        .success([makeRegion(trackIndex: 1, startBar: -1, endBar: -1, rawHelp: "MIDI Region")]),
    ])

    let result = await TrackDispatcher.handleRecordSequenceSMF(
        params: [
            "notes": minimalNoteSpec(),
            "bar": .int(1),
        ],
        router: router,
        cache: cache,
        trackHeaderCount: { trackCounts.next() },
        trackNameAt: { $0 == 1 ? "Imported Piano" : nil },
        readRegions: { regionReads.next() },
        settleReadback: {}
    )

    #expect(result.isError!)
    let object = recordSequenceJSONObject(result)
    #expect(object["error"] as? String == "unreadable_readback")
    #expect(object["region_name"] as? String == "Imported Idea")
    #expect(object["start_bar"] as? Int == -1)
    #expect(object["end_bar"] as? Int == -1)
}
