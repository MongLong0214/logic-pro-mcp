import Foundation
import Testing
import MCP
@testable import LogicProMCP

// v3.1.0 (T7) — state resources now include `cache_age_sec` + `fetched_at`
// so clients can detect staleness without cross-referencing system health.

private let resourceBody = sharedResourceText

@Test func testTracksResourceHasCacheEnvelope() async throws {
    let cache = StateCache()
    await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])
    let router = ChannelRouter()

    let result = try await ResourceHandlers.read(
        uri: "logic://tracks", cache: cache, router: router
    )
    let obj = try! JSONSerialization.jsonObject(
        with: Data(resourceBody(result).utf8)
    ) as! [String: Any]
    #expect(obj.keys.contains("cache_age_sec"))
    #expect(obj.keys.contains("fetched_at"))
    #expect(obj["data"] is [Any])

    // fetched_at should be an ISO8601 string post-update, and cache_age_sec
    // should be a non-negative number close to 0 (we just wrote the cache).
    let age = obj["cache_age_sec"] as? Double
    #expect(age != nil)
    #expect((age ?? 0) < 5.0, "cache just written, age should be tiny")
    #expect(obj["fetched_at"] as? String != nil)
}

@Test func testTracksResourceCacheAgeIsNullBeforeFirstWrite() async throws {
    let cache = StateCache()
    let router = ChannelRouter()

    let result = try await ResourceHandlers.read(
        uri: "logic://tracks", cache: cache, router: router
    )
    let obj = try! JSONSerialization.jsonObject(
        with: Data(resourceBody(result).utf8)
    ) as! [String: Any]
    // Before any updateTracks() call, the cache timestamp is .distantPast
    // → envelope collapses to null so clients can tell "never populated"
    // from "populated N seconds ago".
    #expect(obj["cache_age_sec"] is NSNull)
    #expect(obj["fetched_at"] is NSNull)
}

@Test func testMixerResourceHasCacheAge() async throws {
    let cache = StateCache()
    await cache.updateChannelStrips([ChannelStripState(trackIndex: 0)])
    let router = ChannelRouter()

    let result = try await ResourceHandlers.read(
        uri: "logic://mixer", cache: cache, router: router
    )
    let obj = try! JSONSerialization.jsonObject(
        with: Data(resourceBody(result).utf8)
    ) as! [String: Any]
    #expect(obj["cache_age_sec"] is Double)
    #expect(obj["fetched_at"] is String)
    #expect(obj["strips"] is [Any])
    #expect(obj["mcu_connected"] != nil)
}
