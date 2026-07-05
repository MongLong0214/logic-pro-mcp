import Foundation
import Testing
@testable import LogicProMCP

/// B1 (#11) — logic://mixer provenance. A duplicate-and-readback harness must
/// be able to decide from the wire whether the strip values are trustworthy.
@Suite struct MixerProvenanceTests {

    // MARK: - mixerDataSource (pure)

    @Test func testDataSourceAxPollWhenFresh() {
        let now = Date()
        #expect(ResourceHandlers.mixerDataSource(fetchedAt: now.addingTimeInterval(-1), now: now) == "ax_poll")
    }

    @Test func testDataSourceAtThresholdIsAxPoll() {
        let now = Date()
        #expect(ResourceHandlers.mixerDataSource(fetchedAt: now.addingTimeInterval(-5.0), now: now) == "ax_poll")
    }

    @Test func testDataSourceCacheStaleWhenOld() {
        let now = Date()
        #expect(ResourceHandlers.mixerDataSource(fetchedAt: now.addingTimeInterval(-10), now: now) == "cache_stale")
    }

    @Test func testDataSourceNotVisibleWhenNeverPolled() {
        #expect(ResourceHandlers.mixerDataSource(fetchedAt: .distantPast, now: Date()) == "mixer_not_visible")
    }

    // MARK: - lastFeedbackAgeMs (shared helper, B1 + write-envelope parity)

    @Test func testLastFeedbackAgeMsNilWhenNoFeedback() {
        #expect(MCUConnectionState().lastFeedbackAgeMs() == nil)
    }

    @Test func testLastFeedbackAgeMsClampsAndMeasures() {
        let now = Date()
        var conn = MCUConnectionState()
        conn.lastFeedbackAt = now.addingTimeInterval(-2.0)
        let ms = conn.lastFeedbackAgeMs(now: now)
        #expect(ms != nil)
        #expect((ms ?? 0) >= 1900 && (ms ?? 0) <= 2100)
    }

    @Test func testLastFeedbackAgeMsClampsFutureToZero() {
        let now = Date()
        var conn = MCUConnectionState()
        conn.lastFeedbackAt = now.addingTimeInterval(5.0) // future (clock jump)
        #expect(conn.lastFeedbackAgeMs(now: now) == 0)
    }

    // MARK: - logic://mixer envelope

    @Test func testMixerEnvelopeHasProvenanceTripletAndAlias() async throws {
        let cache = StateCache()
        var conn = MCUConnectionState()
        conn.isConnected = true
        conn.registeredAsDevice = true
        conn.lastFeedbackAt = Date()
        await cache.updateMCUConnection(conn)
        var strip = ChannelStripState(trackIndex: 0)
        strip.volume = 0.5
        await cache.updateChannelStrips([strip]) // advances mixerFetchedAt → fresh
        let router = ChannelRouter()

        let result = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router)
        let text = try #require(result.contents.first?.text)
        let json = try sharedParseJSON(text) as! [String: Any]

        // data_source present and fresh (just polled).
        #expect(json["data_source"] as? String == "ax_poll")
        // Full MCU triplet (parity with write envelopes).
        #expect((json["mcu_connected"] as? Bool)!)
        #expect((json["mcu_registered"] as? Bool)!)
        #expect(json["mcu_last_feedback_age_ms"] is Int || json["mcu_last_feedback_age_ms"] is Double)
        // `registered` retained as a one-release alias of mcu_registered.
        #expect((json["registered"] as? Bool)!)
        #expect((json["registered"] as? Bool) == (json["mcu_registered"] as? Bool))
        #expect((json["strips"] as? [[String: Any]])?.count == 1)
    }

    @Test func testMixerEnvelopeNotVisibleWhenNeverPolled() async throws {
        let cache = StateCache()
        var conn = MCUConnectionState()
        conn.isConnected = false
        await cache.updateMCUConnection(conn)
        // No updateChannelStrips → mixerFetchedAt stays .distantPast.
        let router = ChannelRouter()

        let result = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router)
        let text = try #require(result.contents.first?.text)
        let json = try sharedParseJSON(text) as! [String: Any]
        #expect(json["data_source"] as? String == "mixer_not_visible")
        #expect(json["mcu_last_feedback_age_ms"] is NSNull)
    }

    // MARK: - B2: logic://mixer/{strip} envelope parity

    @Test func testMixerStripEnvelopeHasProvenance() async throws {
        let cache = StateCache()
        var strip = ChannelStripState(trackIndex: 2)
        strip.volume = 0.6
        await cache.updateChannelStrips([strip])
        let router = ChannelRouter()

        let result = try await ResourceHandlers.read(uri: "logic://mixer/2", cache: cache, router: router)
        let text = try #require(result.contents.first?.text)
        let json = try sharedParseJSON(text) as! [String: Any]
        #expect(json["data_source"] as? String == "ax_poll")
        #expect(json["cache_age_sec"] != nil)
        let stripJSON = json["strip"] as? [String: Any]
        #expect(stripJSON?["trackIndex"] as? Int == 2)
    }

    @Test func testMixerStripMissingReturnsTypedOutOfRange() async throws {
        // #200: a missing channel strip returns a typed index_out_of_range body
        // (classifiable + recoverable), not a thrown JSON-RPC error.
        let cache = StateCache()
        let router = ChannelRouter()
        let result = try await ResourceHandlers.read(uri: "logic://mixer/9", cache: cache, router: router)
        let obj = sharedJSONObject(sharedResourceText(result))
        #expect(!((obj?["success"] as? Bool)!))
        #expect(obj?["error"] as? String == "index_out_of_range")
        #expect(obj?["requested_index"] as? Int == 9)
        #expect(obj?["collection"] as? String == "channel strip")
    }
}
