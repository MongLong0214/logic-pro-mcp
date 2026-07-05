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

    init(id: ChannelID, importResult: ChannelResult) {
        self.id = id
        self.importResult = importResult
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        if operation == "midi.import_file" {
            importCalls += 1
            return importResult
        }
        // transport.goto_position is a precondition; succeed silently.
        return .success("ok")
    }

    func healthCheck() async -> ChannelHealth { .healthy(detail: "mock") }
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
