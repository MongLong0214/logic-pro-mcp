import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #200: concrete indexed resource templates (`logic://tracks/{i}`,
/// `logic://mixer/{i}`, `logic://tracks/{i}/regions`) used to fail on empty /
/// out-of-range project state with a raw JSON-RPC `-32602` (or, for regions, a
/// live-route hang). They now return a typed, classifiable `index_out_of_range`
/// resource body the client can recover from.
@Suite("Issue200 indexed template empty-state")
struct Issue200IndexedTemplateEmptyStateTests {
    private func obj(_ r: ReadResource.Result) -> [String: Any]? {
        sharedJSONObject(sharedResourceText(r))
    }

    @Test("logic://tracks/{i} out of range returns a typed index_out_of_range body, not -32602")
    func trackOutOfRangeTyped() async throws {
        let result = try await ResourceHandlers.read(
            uri: "logic://tracks/0", cache: StateCache(), router: ChannelRouter()
        )
        let o = obj(result)
        #expect((o?["success"] as? Bool)! == false)
        #expect(o?["error"] as? String == "index_out_of_range")
        #expect(o?["requested_index"] as? Int == 0)
        #expect(o?["available_count"] as? Int == 0)
        #expect(o?["collection"] as? String == "track")
        #expect((o?["hint"] as? String)?.contains("parent collection") == true)
    }

    @Test("logic://mixer/{i} out of range returns a typed index_out_of_range body")
    func mixerOutOfRangeTyped() async throws {
        let result = try await ResourceHandlers.read(
            uri: "logic://mixer/0", cache: StateCache(), router: ChannelRouter()
        )
        let o = obj(result)
        #expect((o?["success"] as? Bool)! == false)
        #expect(o?["error"] as? String == "index_out_of_range")
        #expect(o?["requested_index"] as? Int == 0)
        #expect(o?["collection"] as? String == "channel strip")
    }

    @Test("a negative index is also a typed body, never a raw -32602")
    func negativeIndexTyped() async throws {
        let result = try await ResourceHandlers.read(
            uri: "logic://tracks/-1", cache: StateCache(), router: ChannelRouter()
        )
        let o = obj(result)
        #expect(o?["error"] as? String == "index_out_of_range")
        #expect(o?["requested_index"] as? Int == -1)
    }

    @Test("mixer out-of-range reports the ACTUAL trackIndex set, not a misleading 0..<N range")
    func mixerReportsActualAvailableIndices() async throws {
        // Mixer strips are keyed by trackIndex, which can be non-contiguous. A
        // gap index (1) between real strips {0, 2, 4} must report the true valid
        // set so a client doesn't infer "0..<3" and skip strip 4.
        let cache = StateCache()
        await cache.updateChannelStrips([
            ChannelStripState(trackIndex: 0),
            ChannelStripState(trackIndex: 2),
            ChannelStripState(trackIndex: 4),
        ])
        let result = try await ResourceHandlers.read(
            uri: "logic://mixer/1", cache: cache, router: ChannelRouter()
        )
        let o = obj(result)
        #expect(o?["error"] as? String == "index_out_of_range")
        #expect(o?["requested_index"] as? Int == 1)
        #expect(o?["available_count"] as? Int == 3)
        let available = o?["available_indices"] as? [Int]
        #expect(available == [0, 2, 4], "must report the actual trackIndex set, got: \(String(describing: available))")
    }

    @Test("index_out_of_range is a terminal, classifiable error code")
    func indexOutOfRangeTerminal() {
        #expect(HonestContract.FailureError.indexOutOfRange.rawValue == "index_out_of_range")
        #expect(HonestContract.terminalErrorCodes.contains("index_out_of_range"))
    }
}
