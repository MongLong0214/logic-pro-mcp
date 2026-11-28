import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Cold first logic://tracks read (#1603)")
struct ColdFirstTracksReadTests {
    private func fileReader() -> LogicProjectFileReader.Runtime {
        .init(
            currentDocumentPath: { nil },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            readPlistData: { _ in nil },
            mtime: { _ in nil },
            sleep: { _ in }
        )
    }

    private func text(_ result: ReadResource.Result) throws -> [String: Any] {
        try #require(sharedJSONObject(sharedResourceText(result)))
    }

    @Test
    func coldFirstReadWaitsForPopulationAndReturnsRealTracks() async throws {
        let cache = StateCache()
        let populate: @Sendable () async -> Void = {
            await cache.updateTracks([TrackState(id: 0, name: "Drums", type: .audio), TrackState(id: 1, name: "Bass", type: .audio)])
        }
        let result = try await ResourceHandlers.read(
            uri: "logic://tracks", cache: cache, router: ChannelRouter(),
            fileReader: fileReader(), populateColdTracks: populate
        )
        let body = try text(result)
        let data = try #require(body["data"] as? [[String: Any]])
        #expect(data.count == 2)
        #expect(body["reason"] as? String != "no_live_track_read_yet")
    }

    @Test
    func warmCacheDoesNotTriggerPopulation() async throws {
        let cache = StateCache()
        await cache.updateTracks([TrackState(id: 0, name: "Drums", type: .audio)])
        let calls = CallCounter()
        _ = try await ResourceHandlers.read(
            uri: "logic://tracks", cache: cache, router: ChannelRouter(),
            fileReader: fileReader(), populateColdTracks: { await calls.bump() }
        )
        #expect(await calls.value == 0)
    }

    @Test
    func unreadableColdStartStaysMarkedUnreadable() async throws {
        let result = try await ResourceHandlers.read(
            uri: "logic://tracks", cache: StateCache(), router: ChannelRouter(),
            fileReader: fileReader(), populateColdTracks: {}
        )
        let body = try text(result)
        #expect(body["readable"] as? Bool == false)
        #expect(body["verified_empty"] as? Bool == false)
    }

    @Test
    func awaitBoundedReturnsAtBound() async {
        let start = ContinuousClock.now
        await LogicProServer.awaitBounded(seconds: 0.2) { try? await Task.sleep(for: .seconds(30)) }
        #expect(start.duration(to: .now) < .seconds(5))
    }
}

private actor CallCounter { var value = 0; func bump() { value += 1 } }
