import Dispatch
import Foundation
import Testing
@testable import LogicProMCP

/// Mirrors the blocking AX probe used by StatePollerTests, but records each
/// entry so the test can place a newer tracks value between the AX read and
/// the conditional cache write on every poll cycle.
private final class Issue289BlockingTracksProbe: @unchecked Sendable {
    private let entryLock = NSLock()
    private var entryCount = 0
    private let release = DispatchSemaphore(value: 0)

    func hasEntered(_ expectedCount: Int) -> Bool {
        entryLock.lock()
        defer { entryLock.unlock() }
        return entryCount >= expectedCount
    }

    func unblock() {
        release.signal()
    }

    func tracksResult() -> ChannelResult {
        entryLock.lock()
        entryCount += 1
        entryLock.unlock()
        release.wait()
        return .success("[]")
    }
}

private func issue289WaitUntil(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
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

@Suite("Issue289PollerReadiness")
struct Issue289PollerReadinessTests {
    @Test("rejected tracks writes still keep the document open")
    func staleTracksWritesDoNotCountAsDocumentPollFailures() async throws {
        let blocker = Issue289BlockingTracksProbe()
        let cache = StateCache()
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
                projectInfo: { .error("unavailable") },
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
        for cycle in 1...3 {
            #expect(try await issue289WaitUntil { blocker.hasEntered(cycle) })
            // The tracks read is now in flight. This newer write advances the
            // section version, so releasing the AX result must reject it.
            await cache.updateTracks([
                TrackState(id: 0, name: "Newer tracks \(cycle)", type: .audio)
            ])
            blocker.unblock()
        }

        // Entry into cycle four proves the first three cycles completed. With
        // the old `return await update(...)`, all three would have counted as
        // failures and `failureThreshold` would already have closed the doc.
        #expect(try await issue289WaitUntil { blocker.hasEntered(4) })
        await poller.stopImmediately()

        // Release the in-flight cycle after making it stale too, so cleanup
        // cannot let an accepted fourth write mask the old behavior.
        await cache.updateTracks([
            TrackState(id: 0, name: "Newer tracks 4", type: .audio)
        ])
        blocker.unblock()

        #expect(try await issue289WaitUntil {
            await cache.droppedStaleWriteCount(for: .tracks) >= 4
        })
        #expect(await cache.getHasDocument())
        #expect(await cache.droppedStaleWriteCount(for: .tracks) > 0)
    }
}
