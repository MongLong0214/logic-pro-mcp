import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #108: MIDI import_file already verifies via track-count delta; this locks
/// that contract. mmc_locate(bar) now verifies the playhead via the same
/// transport-state read-back as goto_position/goto_bar instead of returning a
/// permanently-unverified State B.
@Suite("Issue108 midi import + mmc_locate")
struct Issue108Tests {
    // MARK: - mmc_locate read-back verification

    private actor StubTransportChannel: Channel {
        nonisolated let id: ChannelID = .accessibility
        let readbackPosition: String
        init(readbackPosition: String) { self.readbackPosition = readbackPosition }
        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> ChannelHealth { .healthy(detail: "stub") }
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            switch operation {
            case "transport.goto_position":
                return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: ["via": "dialog"]))
            case "transport.get_state":
                // Encode a real TransportState with the SAME .iso8601 strategy
                // the dispatcher decodes with — a hand-written fractional-seconds
                // date (".000Z") fails strict .iso8601 decoding on the CI
                // Foundation, making liveTransportState return nil.
                var state = TransportState()
                state.position = readbackPosition
                state.lastUpdated = Date(timeIntervalSince1970: 0)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return .success(String(decoding: (try? encoder.encode(state)) ?? Data(), as: UTF8.self))
            default: return .error("unexpected: \(operation)")
            }
        }
    }

    private func text(_ r: CallTool.Result) -> String {
        sharedToolText(r)
    }
    private func obj(_ r: CallTool.Result) -> [String: Any]? {
        sharedJSONObject(text(r))
    }

    @Test("mmc_locate(bar) verifies the playhead via transport-state read-back")
    func mmcLocateVerifies() async throws {
        let router = ChannelRouter()
        await router.register(StubTransportChannel(readbackPosition: "5.1.1.1"))
        let result = await MIDIDispatcher.handle(
            command: "mmc_locate", params: ["bar": .int(5)], router: router, cache: StateCache()
        )
        let resultIsError = result.isError ?? false
        #expect(!resultIsError)
        let o = try #require(obj(result))
        #expect(try #require(o["verified"] as? Bool))
        #expect(o["verification_source"] as? String == "transport_state")
        #expect(o["observed"] as? String == "5.1.1.1")
    }

    @Test("mmc_locate(bar) fails closed when the playhead does not land")
    func mmcLocateMismatchFailsClosed() async throws {
        let router = ChannelRouter()
        await router.register(StubTransportChannel(readbackPosition: "9.1.1.1"))
        let result = await MIDIDispatcher.handle(
            command: "mmc_locate", params: ["bar": .int(5)], router: router, cache: StateCache()
        )
        let o = try #require(obj(result))
        // Fail-closed mismatch is a State B envelope, so `verified` is present
        // and false (not absent) — require + negate is unambiguously effective.
        #expect(!(try #require(o["verified"] as? Bool)))
        let resultIsError = result.isError ?? false
        #expect(resultIsError)
    }

    @Test("mmc_locate rejects missing bar/time")
    func mmcLocateRejectsMissing() async {
        let result = await MIDIDispatcher.handle(
            command: "mmc_locate", params: [:], router: ChannelRouter(), cache: StateCache()
        )
        let resultIsError = result.isError ?? false
        #expect(resultIsError)
        #expect(text(result).contains("invalid_params") || text(result).contains("requires explicit"))
    }

    // MARK: - import_file track-count-delta read-back contract

    private final class CallCounter: @unchecked Sendable {
        private var values: [Int]; private var index = 0; private let lock = NSLock()
        init(_ values: [Int]) { self.values = values }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = values[min(index, values.count - 1)]; index += 1; return v }
    }

    private func tempMIDIFile() -> String {
        let path = NSTemporaryDirectory() + "issue108-\(UUID().uuidString).mid"
        FileManager.default.createFile(atPath: path, contents: Data([0x4D, 0x54, 0x68, 0x64]))
        return path
    }

    private final class RegionSnapshotBox: @unchecked Sendable {
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

    private func importedRegion(trackIndex: Int = 1) -> RegionInfo {
        RegionInfo(
            name: "Imported MIDI",
            trackIndex: trackIndex,
            startBar: 1,
            endBar: 2,
            kind: "midi",
            rawHelp: nil
        )
    }

    @Test("import_file returns verified State A when a new track and MIDI region appear")
    func importVerifiedOnTrackAndRegionDelta() async {
        let path = tempMIDIFile(); defer { try? FileManager.default.removeItem(atPath: path) }
        let counter = CallCounter([1, 2]) // before=1, after=2
        let regions = RegionSnapshotBox([.success([]), .success([importedRegion()])])
        let result = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: path,
            executeScript: { _ in .success("OK") },
            trackCount: { counter.next() },
            trackNames: { ["Studio Grand", "Imported"] },
            regionInfos: { regions.next() },
            deltaPoll: {}
        )
        #expect(result.isSuccess)
        let o = (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any]
        #expect(o?["observed_delta"] as? Int == 1)
        #expect(o?["track_count_after"] as? Int == 2)
        #expect(o?["imported_region_count"] as? Int == 1)
    }

    @Test("import_file fails closed when a new track appears without a MIDI region")
    func importFailsClosedOnTrackDeltaWithoutRegion() async {
        let path = tempMIDIFile(); defer { try? FileManager.default.removeItem(atPath: path) }
        let counter = CallCounter([1, 2])
        let regions = RegionSnapshotBox([.success([]), .success([])])
        let result = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: path,
            executeScript: { _ in .success("OK") },
            trackCount: { counter.next() },
            trackNames: { ["Studio Grand", "Imported"] },
            regionInfos: { regions.next() },
            deltaPoll: {}
        )
        #expect(!result.isSuccess)
        #expect(result.message.contains("readback_mismatch"))
        #expect(result.message.contains("did not create a verifiable MIDI region"))
        #expect(result.message.contains("\"track_count_after\":2"))
        #expect(result.message.contains("\"region_count_after\":0"))
    }

    @Test("import_file fails closed when no track is created")
    func importFailsClosedOnNoDelta() async {
        let path = tempMIDIFile(); defer { try? FileManager.default.removeItem(atPath: path) }
        let counter = CallCounter([3, 3]) // before==after → no import landed
        let regions = RegionSnapshotBox([.success([]), .success([])])
        let result = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: path,
            executeScript: { _ in .success("OK") },
            trackCount: { counter.next() },
            trackNames: { [] },
            regionInfos: { regions.next() },
            deltaPoll: {}
        )
        #expect(!result.isSuccess)
        #expect(result.message.contains("readback_mismatch"))
        #expect(result.message.contains("did not create a new track"))
        #expect(result.message.contains("\"region_count_after\":0"))
        #expect(result.message.contains("\"new_midi_region_count\":0"))
    }

    @Test("import_file surfaces a typed error when the import menu click fails")
    func importMenuClickError() async {
        let path = tempMIDIFile(); defer { try? FileManager.default.removeItem(atPath: path) }
        let result = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: path,
            executeScript: { _ in .success(#"{"result":"MENU_ERROR: not found"}"#) },
            trackCount: { 1 },
            trackNames: { [] },
            regionInfos: { .success([]) },
            deltaPoll: {}
        )
        #expect(!result.isSuccess)
        #expect(result.message.contains("ax_write_failed"))
    }

    @Test("import_file rejects a nonexistent file with a typed error")
    func importMissingFile() async {
        let result = await AccessibilityChannel.defaultImportMIDIFile(
            systemEventsAuthorized: { true },
            path: "/tmp/LogicProMCP/does-not-exist-\(UUID().uuidString).mid",
            executeScript: { _ in .success("OK") },
            trackCount: { 1 },
            trackNames: { [] },
            regionInfos: { .success([]) },
            deltaPoll: {}
        )
        #expect(!result.isSuccess)
        #expect(result.message.contains("invalid_params"))
        #expect(result.message.contains("file not found"))
    }
}
