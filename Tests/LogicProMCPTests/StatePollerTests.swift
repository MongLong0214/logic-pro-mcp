import Foundation
import Testing
@testable import LogicProMCP

private func makeStatePollerAccessibilityRuntime(
    projectInfoResult: ChannelResult
) -> AccessibilityChannel.Runtime {
    .init(
        isTrusted: { true },
        isLogicProRunning: { true },
        appRoot: { nil },
        transportState: { .success("{}") },
        toggleTransportButton: { _ in .success("{}") },
        setTempo: { _ in .success("{}") },
        setCycleRange: { _ in .success("{}") },
        tracks: { .success("{}") },
        selectedTrack: { .success("{}") },
        selectTrack: { _ in .success("{}") },
        setTrackToggle: { _, _ in .success("{}") },
        renameTrack: { _ in .success("{}") },
        mixerState: { .success("{}") },
        channelStrip: { _ in .success("{}") },
        setMixerValue: { _, _ in .success("{}") },
        projectInfo: { projectInfoResult }
    )
}

@Test func testStatePollerUpdatesProjectInfoOnInitialPoll() async throws {
    let cache = StateCache()
    let projectPayload = """
    {"name":"Session A","sampleRate":48000,"bitDepth":24,"tempo":128,"timeSignature":"4/4","trackCount":18,"filePath":null,"lastUpdated":0}
    """
    let channel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .success(projectPayload))
    )
    let poller = StatePoller(axChannel: channel, cache: cache)

    await poller.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await poller.stop()

    let project = await cache.getProject()
    #expect(project.name == "Session A")
    #expect(project.sampleRate == 48000)
    #expect(project.trackCount == 18)
    #expect(await poller.isRunning == false)
}

@Test func testStatePollerIgnoresInvalidProjectPayloadsAndChannelErrors() async throws {
    let invalidCache = StateCache()
    let invalidChannel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .success("{invalid-json"))
    )
    let invalidPoller = StatePoller(axChannel: invalidChannel, cache: invalidCache)

    await invalidPoller.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await invalidPoller.stop()

    let invalidProject = await invalidCache.getProject()
    #expect(invalidProject.name.isEmpty)

    let errorCache = StateCache()
    let errorChannel = AccessibilityChannel(
        runtime: makeStatePollerAccessibilityRuntime(projectInfoResult: .error("unavailable"))
    )
    let errorPoller = StatePoller(axChannel: errorChannel, cache: errorCache)

    await errorPoller.start()
    await errorPoller.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await errorPoller.stop()

    let errorProject = await errorCache.getProject()
    #expect(errorProject.name.isEmpty)
}
