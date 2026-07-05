import Dispatch
import Foundation
import Testing
@testable import LogicProMCP

private final class BlockingTracksProbe: @unchecked Sendable {
    private let entryLock = NSLock()
    private var entered = false
    private let release = DispatchSemaphore(value: 0)

    func hasEntered() -> Bool {
        entryLock.lock()
        defer { entryLock.unlock() }
        return entered
    }

    func unblock() {
        release.signal()
    }

    func tracksResult() -> ChannelResult {
        entryLock.lock()
        entered = true
        entryLock.unlock()
        release.wait()
        return .success("[]")
    }
}

private actor CompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 5_000_000,
    condition: @escaping @Sendable () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return await condition()
}

private func makeStatePollerAccessibilityRuntime(
    projectInfoResult: ChannelResult,
    transportResult: ChannelResult = .success("{}"),
    tracksResult: ChannelResult = .success("[]"),
    mixerResult: ChannelResult = .success("[]"),
    markersResult: ChannelResult = .success("[]")
) -> AccessibilityChannel.Runtime {
    .init(
        isTrusted: { true },
        isLogicProRunning: { true },
        appRoot: { nil },
        transportState: { transportResult },
        toggleTransportButton: { _ in .success("{}") },
        setTempo: { _ in .success("{}") },
        setCycleRange: { _ in .success("{}") },
        tracks: { tracksResult },
        selectedTrack: { .success("{}") },
        selectTrack: { _ in .success("{}") },
        setTrackToggle: { _, _ in .success("{}") },
        renameTrack: { _ in .success("{}") },
        mixerState: { mixerResult },
        channelStrip: { _ in .success("{}") },
        setMixerValue: { _, _ in .success("{}") },
        projectInfo: { projectInfoResult },
        markers: { markersResult }
    )
}

@Test func testStatePollerUpdatesProjectInfoOnInitialPoll() async throws {
    let cache = StateCache()
    let projectPayload = """
    {"name":"Session A","sampleRate":48000,"bitDepth":24,"tempo":128,"timeSignature":"4/4","trackCount":18,"filePath":null,"lastUpdated":"2026-04-12T00:00:00Z"}
    """
    let channel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .success(projectPayload))
    )
    let poller = StatePoller(
        axChannel: channel,
        cache: cache,
        runtime: .init(hasVisibleWindow: { true })
    )

    await poller.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await poller.stop()

    let project = await cache.getProject()
    #expect(project.name == "Session A")
    #expect(project.sampleRate == 48000)
    #expect(project.trackCount == 18)
    #expect(!(await poller.isRunning))
}

@Test func testStatePollerIgnoresInvalidProjectPayloadsAndChannelErrors() async throws {
    let invalidCache = StateCache()
    let invalidChannel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .success("{invalid-json"))
    )
    let invalidPoller = StatePoller(
        axChannel: invalidChannel,
        cache: invalidCache,
        runtime: .init(hasVisibleWindow: { true })
    )

    await invalidPoller.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await invalidPoller.stop()

    let invalidProject = await invalidCache.getProject()
    #expect(invalidProject.name.isEmpty)

    let errorCache = StateCache()
    let errorChannel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .error("unavailable"))
    )
    let errorPoller = StatePoller(
        axChannel: errorChannel,
        cache: errorCache,
        runtime: .init(hasVisibleWindow: { true })
    )

    await errorPoller.start()
    await errorPoller.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await errorPoller.stop()

    let errorProject = await errorCache.getProject()
    #expect(errorProject.name.isEmpty)
}

@Test func testStatePollerRefreshNowPopulatesTransportTracksAndMixerFallbackState() async throws {
    let cache = StateCache()
    let transportPayload = """
    {"isPlaying":true,"isRecording":false,"isPaused":false,"isCycleEnabled":true,"isMetronomeEnabled":false,"tempo":123.5,"sampleRate":48000,"position":"3.1.1.1","timePosition":"00:00:12.000","lastUpdated":"2026-04-12T00:00:00Z"}
    """
    let tracksPayload = """
    [
      {"id":0,"name":"Audio 1","type":"audio","isMuted":false,"isSoloed":false,"isArmed":false,"isSelected":true,"volume":0.82,"pan":-0.1,"automationMode":"off","color":null},
      {"id":1,"name":"Synth 1","type":"software_instrument","isMuted":false,"isSoloed":false,"isArmed":false,"isSelected":false,"volume":0.74,"pan":0.2,"automationMode":"off","color":null}
    ]
    """
    let mixerPayload = """
    [
      {"trackIndex":0,"volume":0.82,"pan":-0.1,"sends":[],"input":null,"output":null,"eqEnabled":false,"plugins":[]},
      {"trackIndex":1,"volume":0.74,"pan":0.2,"sends":[],"input":null,"output":null,"eqEnabled":false,"plugins":[]}
    ]
    """
    let channel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(
            projectInfoResult: .success("{" + #""name":"Session B","sampleRate":48000,"bitDepth":24,"tempo":123.5,"timeSignature":"4/4","trackCount":2,"filePath":null,"lastUpdated":"2026-04-12T00:00:00Z""# + "}"),
            transportResult: .success(transportPayload),
            tracksResult: .success(tracksPayload),
            mixerResult: .success(mixerPayload)
        )
    )
    let poller = StatePoller(
        axChannel: channel,
        cache: cache,
        runtime: .init(hasVisibleWindow: { true })
    )

    await poller.refreshNow()

    let transport = await cache.getTransport()
    let tracks = await cache.getTracks()
    let strips = await cache.getChannelStrips()
    let project = await cache.getProject()

    #expect(transport.isPlaying)
    #expect(transport.isCycleEnabled)
    #expect(transport.tempo == 123.5)
    #expect(tracks.count == 2)
    #expect(tracks.first?.name == "Audio 1")
    #expect((tracks.first?.isSelected)!)
    #expect(strips.count == 2)
    #expect(strips[1].pan == 0.2)
    #expect(project.name == "Session B")
    #expect(project.trackCount == 2)
}

@Test func testStatePollerClearsDocumentStateWhenNoVisibleWindow() async {
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Old Session"
    project.trackCount = 3
    await cache.updateProject(project)
    await cache.updateTracks([TrackState(id: 0, name: "Old Track", type: .audio)])

    let channel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .error("unavailable"))
    )
    let poller = StatePoller(
        axChannel: channel,
        cache: cache,
        runtime: .init(hasVisibleWindow: { false })
    )

    // Post-hardening: a single missed window check no longer clears state —
    // 3 consecutive misses are required so transient AX glitches don't make
    // resource reads flap "no document open" during normal Logic UI motion.
    await poller.refreshNow()
    await poller.refreshNow()
    #expect(await cache.getHasDocument()) // still trusts cache after 2 misses
    await poller.refreshNow()
    #expect(!(await cache.getHasDocument())) // 3rd miss clears
}

@Test func testStatePollerPopulatesMarkerCache() async {
    let cache = StateCache()
    let markerPayload = """
    [{"id":0,"name":"Intro","position":"1.1.1.1"},{"id":1,"name":"Verse","position":"9.1.1.1"},{"id":2,"name":"Chorus","position":"25.1.1.1"}]
    """
    let channel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(
            projectInfoResult: .success(#"{"name":"Markers Test","sampleRate":44100,"bitDepth":24,"tempo":120,"timeSignature":"4/4","trackCount":1,"filePath":null,"lastUpdated":"2026-04-16T00:00:00Z"}"#),
            markersResult: .success(markerPayload)
        )
    )
    let poller = StatePoller(
        axChannel: channel,
        cache: cache,
        runtime: .init(hasVisibleWindow: { true })
    )

    await poller.refreshNow()

    let markers = await cache.getMarkers()
    #expect(markers.count == 3)
    #expect(markers[0].name == "Intro")
    #expect(markers[1].name == "Verse")
    #expect(markers[2].position == "25.1.1.1")
}

@Test func testStatePollerClearsMarkersWhenDocumentCloses() async {
    let cache = StateCache()
    await cache.updateMarkers([
        MarkerState(id: 0, name: "Stale", position: "1.1.1.1"),
    ])
    #expect(await cache.getMarkers().count == 1)

    let channel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .error("unavailable"))
    )
    let poller = StatePoller(
        axChannel: channel,
        cache: cache,
        runtime: .init(hasVisibleWindow: { false })
    )

    await poller.refreshNow()
    await poller.refreshNow()
    await poller.refreshNow()

    #expect(await cache.getMarkers().isEmpty)
}

@Test func testStatePollerIgnoresInvalidMarkerPayload() async {
    let cache = StateCache()
    let channel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(
            projectInfoResult: .success(#"{"name":"Bad Markers","sampleRate":44100,"bitDepth":24,"tempo":120,"timeSignature":"4/4","trackCount":1,"filePath":null,"lastUpdated":"2026-04-16T00:00:00Z"}"#),
            markersResult: .success("{invalid-json")
        )
    )
    let poller = StatePoller(
        axChannel: channel,
        cache: cache,
        runtime: .init(hasVisibleWindow: { true })
    )

    await poller.refreshNow()

    #expect(await cache.getMarkers().isEmpty)
}

@Test func testStatePollerImmediateStopDoesNotAwaitBlockedPollCycle() async throws {
    let blocker = BlockingTracksProbe()
    let completion = CompletionProbe()
    let cache = StateCache()
    let projectPayload = """
    {"name":"Blocked Session","sampleRate":48000,"bitDepth":24,"tempo":128,"timeSignature":"4/4","trackCount":1,"filePath":null,"lastUpdated":"2026-04-12T00:00:00Z"}
    """
    let channel = AccessibilityChannel(
        runtime: .init(
            isTrusted: { true },
            isLogicProRunning: { true },
            hasVisibleWindow: { true },
            appRoot: { nil },
            transportState: { .success("{}") },
            toggleTransportButton: { _ in .success("{}") },
            setTempo: { _ in .success("{}") },
            setCycleRange: { _ in .success("{}") },
            tracks: { blocker.tracksResult() },
            selectedTrack: { .success("{}") },
            selectTrack: { _ in .success("{}") },
            setTrackToggle: { _, _ in .success("{}") },
            renameTrack: { _ in .success("{}") },
            mixerState: { .success("[]") },
            channelStrip: { _ in .success("{}") },
            setMixerValue: { _, _ in .success("{}") },
            projectInfo: { .success(projectPayload) },
            markers: { .success("[]") }
        )
    )
    let poller = StatePoller(
        axChannel: channel,
        cache: cache,
        runtime: .init(
            hasVisibleWindow: { true },
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000) }
        )
    )

    await poller.start()
    #expect(try await waitUntil(timeoutNanoseconds: 5_000_000_000) { blocker.hasEntered() })

    let stopTask = Task {
        await poller.stopImmediately()
        await completion.markCompleted()
    }

    #expect(try await waitUntil { await completion.isCompleted() })
    #expect(!(await poller.isRunning))

    blocker.unblock()
    await stopTask.value
}
