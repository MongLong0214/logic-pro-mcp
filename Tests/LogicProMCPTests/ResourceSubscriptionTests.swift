import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor ResourceNotificationSink {
    private var uris: [String] = []

    func send(uri: String) {
        uris.append(uri)
    }

    func snapshot() -> [String] {
        uris
    }

    func reset() {
        uris.removeAll()
    }
}

private func resourceResult(_ text: String, uri: String) -> ReadResource.Result {
    ReadResource.Result(contents: [.text(text, uri: uri, mimeType: "application/json")])
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() async { lock.withLock { value += 1 } }
    func countNow() -> Int { lock.withLock { value } }
}

@Suite("ResourceSubscription")
struct ResourceSubscriptionTests {
    @Test("subscription_registry_add_remove_cleanup")
    func subscriptionRegistryAddRemoveCleanup() async throws {
        let registry = ResourceSubscriptionRegistry()

        try await registry.subscribe(uri: "logic://tracks")
        #expect(await registry.contains(uri: "logic://tracks"))

        try await registry.unsubscribe(uri: "logic://tracks")
        #expect(!(await registry.contains(uri: "logic://tracks")))

        try await registry.subscribe(uri: "logic://mixer")
        await registry.clear()
        #expect((await registry.subscribedURIs()).isEmpty)
    }

    @Test("unchanged_poll_emits_no_notification")
    func unchangedPollEmitsNoNotification() async throws {
        let registry = ResourceSubscriptionRegistry()
        let notifier = ResourceUpdateNotifier(registry: registry)
        let sink = ResourceNotificationSink()
        let cache = StateCache()
        let router = ChannelRouter()

        try await registry.subscribe(uri: "logic://tracks")
        await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])
        await notifier.publishChangedResources(cacheKeys: [.tracks], cache: cache, router: router) { uri in
            await sink.send(uri: uri)
        }
        await sink.reset()

        await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])
        await notifier.publishChangedResources(cacheKeys: [.tracks], cache: cache, router: router) { uri in
            await sink.send(uri: uri)
        }

        #expect(await sink.snapshot() == [])
    }

    @Test("changed_payload_emits_single_coalesced_notification")
    func changedPayloadEmitsSingleCoalescedNotification() async throws {
        let registry = ResourceSubscriptionRegistry()
        let notifier = ResourceUpdateNotifier(registry: registry)
        let sink = ResourceNotificationSink()
        let cache = StateCache()
        let router = ChannelRouter()

        try await registry.subscribe(uri: "logic://tracks")
        await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])
        await notifier.publishChangedResources(cacheKeys: [.tracks], cache: cache, router: router) { uri in
            await sink.send(uri: uri)
        }
        await sink.reset()

        await cache.updateTracks([
            TrackState(id: 0, name: "Kick", type: .audio),
            TrackState(id: 1, name: "Bass", type: .audio),
        ])
        await notifier.publishChangedResources(cacheKeys: [.tracks, .tracks], cache: cache, router: router) { uri in
            await sink.send(uri: uri)
        }

        #expect(await sink.snapshot() == ["logic://tracks"])
    }

    @Test("volatile_fields_excluded_from_change_hash")
    func volatileFieldsExcludedFromChangeHash() throws {
        let first = #"{"cache_age_sec":0.01,"fetched_at":"2026-07-07T00:00:00Z","ax_occluded":false,"data":{"tracks":[{"id":0,"name":"Kick","fetched_at":"2026-07-07T00:00:00Z"}]}}"#
        let second = #"{"cache_age_sec":99.9,"fetched_at":"2026-07-07T00:01:39Z","ax_occluded":true,"data":{"tracks":[{"id":0,"name":"Kick","fetched_at":"2026-07-07T00:01:39Z"}]}}"#

        #expect(try ResourceContentHasher.stableDataHash(fromResourceText: first) == ResourceContentHasher.stableDataHash(fromResourceText: second))
    }

    @Test("audit_fallback_volatile_fields_excluded_from_change_hash")
    func auditFallbackVolatileFieldsExcludedFromChangeHash() throws {
        let first = #"{"schema":"logic_pro_mcp_project_audit.v1","generated_at":"2026-07-07T00:00:00Z","status":"degraded","project":{"name":"Song"},"findings":[{"id":"external_midi","severity":"warn"}]}"#
        let second = #"{"schema":"logic_pro_mcp_project_audit.v1","generated_at":"2026-07-07T00:01:39Z","status":"degraded","project":{"name":"Song"},"findings":[{"id":"external_midi","severity":"warn"}]}"#
        let changed = #"{"schema":"logic_pro_mcp_project_audit.v1","generated_at":"2026-07-07T00:01:39Z","status":"ok","project":{"name":"Song"},"findings":[]}"#

        #expect(try ResourceContentHasher.stableDataHash(fromResourceText: first) == ResourceContentHasher.stableDataHash(fromResourceText: second))
        #expect(try ResourceContentHasher.stableDataHash(fromResourceText: first) != ResourceContentHasher.stableDataHash(fromResourceText: changed))
    }

    @Test("mixer_fallback_volatile_fields_excluded_from_change_hash")
    func mixerFallbackVolatileFieldsExcludedFromChangeHash() throws {
        let first = #"{"cache_age_sec":0.1,"data_source":"ax_poll","fetched_at":"2026-07-07T00:00:00Z","mcu_last_feedback_age_ms":10,"strips":[{"trackIndex":0,"name":"Kick","volume":0.7,"cache_age_sec":0.2,"mcu_last_feedback_age_ms":11}]}"#
        let second = #"{"cache_age_sec":99.9,"data_source":"ax_poll","fetched_at":"2026-07-07T00:01:39Z","mcu_last_feedback_age_ms":500,"strips":[{"trackIndex":0,"name":"Kick","volume":0.7,"cache_age_sec":30.0,"mcu_last_feedback_age_ms":600}]}"#
        let changed = #"{"cache_age_sec":99.9,"data_source":"ax_poll","fetched_at":"2026-07-07T00:01:39Z","mcu_last_feedback_age_ms":500,"strips":[{"trackIndex":0,"name":"Kick","volume":0.8,"cache_age_sec":30.0,"mcu_last_feedback_age_ms":600}]}"#

        #expect(try ResourceContentHasher.stableDataHash(fromResourceText: first) == ResourceContentHasher.stableDataHash(fromResourceText: second))
        #expect(try ResourceContentHasher.stableDataHash(fromResourceText: first) != ResourceContentHasher.stableDataHash(fromResourceText: changed))
    }

    /// #1079 review R3: publishing reads each subscribed resource back from Logic, and a background
    /// cycle must not start such a read once the user is editing. The stop is asked before each
    /// read; after the first read it answers true, so the second resource is not read and the
    /// publication reports that it stopped. Mutation this kills: the stop not asked. The control is
    /// the same publication with a stop that never answers true.
    @Test("a publication stops before the next resource read once told to, and says so")
    func aPublicationStopsBeforeTheNextRead() async throws {
        for stopAfterFirst in [true, false] {
            let registry = ResourceSubscriptionRegistry()
            let notifier = ResourceUpdateNotifier(registry: registry)
            try await registry.subscribe(uri: "logic://tracks")
            try await registry.subscribe(uri: "logic://project/info")
            let reads = ReadCounter()
            let completed = await notifier.publishChangedResources(
                cacheKeys: [.tracks, .project],
                cache: StateCache(),
                router: ChannelRouter(),
                readResource: { uri, _, _ in
                    await reads.bump()
                    return resourceResult(#"{"data":{}}"#, uri: uri)
                },
                stopBeforeEachRead: { stopAfterFirst && reads.countNow() >= 1 }
            ) { _ in }
            if stopAfterFirst {
                #expect(reads.countNow() == 1, "read \(reads.countNow()) resources after the stop")
                #expect(!completed)
            } else {
                #expect(reads.countNow() == 2)
                #expect(completed)
            }
        }
    }

    @Test("unsubscribe_during_read_suppresses_notify_and_hash_update")
    func unsubscribeDuringReadSuppressesNotifyAndHashUpdate() async throws {
        let registry = ResourceSubscriptionRegistry()
        let notifier = ResourceUpdateNotifier(registry: registry)
        let sink = ResourceNotificationSink()
        let cache = StateCache()
        let router = ChannelRouter()
        let payload = #"{"data":{"tracks":[{"id":0,"name":"Kick"}]}}"#

        try await registry.subscribe(uri: "logic://tracks")
        await notifier.publishChangedResources(
            cacheKeys: [.tracks],
            cache: cache,
            router: router,
            readResource: { uri, _, _ in
                try await registry.unsubscribe(uri: uri)
                return resourceResult(payload, uri: uri)
            }
        ) { uri in
            await sink.send(uri: uri)
        }

        #expect(await sink.snapshot() == [])

        try await registry.subscribe(uri: "logic://tracks")
        await notifier.publishChangedResources(
            cacheKeys: [.tracks],
            cache: cache,
            router: router,
            readResource: { uri, _, _ in resourceResult(payload, uri: uri) }
        ) { uri in
            await sink.send(uri: uri)
        }

        #expect(await sink.snapshot() == ["logic://tracks"])
    }

    @Test("initialize_subscribe_change_emits_resource_updated_frame")
    func initializeSubscribeChangeEmitsResourceUpdatedFrame() async throws {
        let server = LogicProServer()
        let transport = MCPProtocolProbeTransport()
        try await server.startProtocolProbe(transport: transport)
        defer { Task { await server.stopProtocolProbe() } }

        await transport.queueJSON(probeInitializeFrame(id: 1))
        _ = try await waitForProbeResponse(transport, id: 1)

        await transport.queueJSON(probeRequestFrame(
            id: 2,
            method: "resources/subscribe",
            params: #"{"uri":"logic://tracks"}"#
        ))
        _ = try await waitForProbeResponse(transport, id: 2)

        await server.replaceTracksForTesting([TrackState(id: 0, name: "Kick", type: .audio)])
        await server.publishResourceChangesForTesting([.tracks])

        let notification = try await waitForProbeNotification(
            transport,
            method: "notifications/resources/updated"
        )
        let params = try #require(notification["params"] as? [String: Any])
        #expect(params["uri"] as? String == "logic://tracks")
    }
}
