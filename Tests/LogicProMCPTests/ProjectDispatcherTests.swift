import Foundation
import Testing
import MCP
@testable import LogicProMCP

// v3.1.2 P0-3 — project lifecycle ops (`new` / `open` / `close`) must
// invalidate the cache on success so the next resource read / name-based
// routing decision sees the fresh project state instead of the previous
// project's stale 38 tracks lingering for >60s (the entire pre-fix bug:
// StatePoller runs every 3s, but until it overwrote, every consumer saw the
// old project's data).

private func projectMockChannel(_ id: ChannelID) -> MockChannel {
    MockChannel(id: id)
}

private func seedCacheWithStaleProject(_ cache: StateCache) async {
    // Pre-load the cache with tracks/regions/markers that mirror "previous
    // project" state. After a successful lifecycle command the cache must
    // come back empty.
    await cache.updateTracks([
        TrackState(id: 0, name: "Old Drums", type: .softwareInstrument),
        TrackState(id: 1, name: "Old Bass", type: .softwareInstrument),
    ])
    await cache.updateRegions([
        RegionState(
            id: "leftover-1",
            name: "leftover region",
            trackIndex: 0,
            startPosition: "1 1 1 1",
            endPosition: "4 1 1 1",
            length: "3 0 0 0"
        )
    ])
    await cache.updateMarkers([
        MarkerState(id: 0, name: "leftover marker", position: "1.1.1.1")
    ])
    var info = await cache.getProject()
    info.name = "Old Project"
    await cache.updateProject(info)
}

@Test func testProjectNewClearsCacheOnSuccess() async {
    let router = ChannelRouter()
    let appleScript = projectMockChannel(.appleScript)
    await router.register(appleScript)

    let cache = StateCache()
    await seedCacheWithStaleProject(cache)
    // Confirm the seed actually landed before the call so the post-condition
    // assertion can't accidentally pass on an already-empty cache.
    let preTracks = await cache.getTracks().count
    #expect(preTracks == 2, "seed precondition")

    let result = await ProjectDispatcher.handle(
        command: "new",
        params: [:],
        router: router,
        cache: cache
    )
    #expect(!(sharedToolText(result).isEmpty))

    let postTracks = await cache.getTracks().count
    let postRegions = await cache.getRegions().count
    let postMarkers = await cache.getMarkers().count
    let postProjectName = await cache.getProject().name
    #expect(postTracks == 0, "new must clear stale tracks")
    #expect(postRegions == 0, "new must clear stale regions")
    #expect(postMarkers == 0, "new must clear stale markers")
    #expect(postProjectName.isEmpty, "new must clear stale project info")
}

@Test func testProjectCloseClearsCacheOnSuccess() async {
    let router = ChannelRouter()
    let appleScript = projectMockChannel(.appleScript)
    await router.register(appleScript)

    let cache = StateCache()
    await seedCacheWithStaleProject(cache)

    // close requires `confirmed: true` to bypass the destructive-policy
    // confirmation prompt — without it the dispatcher returns the prompt
    // and never reaches the router.
    let result = await ProjectDispatcher.handle(
        command: "close",
        params: ["saving": .string("no"), "confirmed": .bool(true)],
        router: router,
        cache: cache
    )
    #expect(!(sharedToolText(result).isEmpty))

    let postTracks = await cache.getTracks().count
    #expect(postTracks == 0, "close must clear cache so resources don't lie about a closed project")
}

@Test func testProjectNewLeavesCacheUntouchedOnFailure() async {
    // Failure path: if AppleScript channel reports an error, the cache must
    // be left as-is. Otherwise a transient AppleScript hiccup would wipe
    // the user's actual project state from the cache.
    actor AlwaysFailChannel: Channel {
        nonisolated let id: ChannelID = .appleScript
        func start() async throws {}
        func stop() async {}
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            .error("AppleScript channel failed (mock)")
        }
        func healthCheck() async -> ChannelHealth { .healthy(detail: "mock") }
    }
    let router = ChannelRouter()
    await router.register(AlwaysFailChannel())

    let cache = StateCache()
    await seedCacheWithStaleProject(cache)

    _ = await ProjectDispatcher.handle(
        command: "new",
        params: [:],
        router: router,
        cache: cache
    )

    let postTracks = await cache.getTracks().count
    #expect(
        postTracks == 2,
        "failed project.new must NOT clear the cache — only success triggers invalidation"
    )
}
