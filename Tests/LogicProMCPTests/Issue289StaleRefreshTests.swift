import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue289StaleRefresh")
struct Issue289StaleRefreshTests {
    @Test func currentObservedVersionAppliesWrite() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        let applied = await cache.updateTransport(
            transport(tempo: 123),
            ifCurrent: observed
        )

        #expect(applied)
        #expect((await cache.getTransport()).tempo == 123)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 0)
    }

    @Test func staleSectionRevisionDropsWriteAndPreservesNewerValue() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)
        await cache.updateTransport(transport(tempo: 130))

        let applied = await cache.updateTransport(
            transport(tempo: 90),
            ifCurrent: observed
        )

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 130)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    @Test func staleProjectEpochDropsWriteWhenSectionRevisionStillMatches() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)
        await cache.advanceProjectEpoch()
        let current = await cache.currentVersion(for: .transport)

        #expect(current.sectionRevision == observed.sectionRevision)
        #expect(current.projectEpoch > observed.projectEpoch)

        let applied = await cache.updateTransport(
            transport(tempo: 90),
            ifCurrent: observed
        )

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 120)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    @Test func concurrentWritesFromSameObservationAllowOnlyOne() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        async let first = cache.updateTransport(transport(tempo: 101), ifCurrent: observed)
        async let second = cache.updateTransport(transport(tempo: 202), ifCurrent: observed)
        let results = await [first, second]
        let surviving = await cache.getTransport()

        #expect(results.filter { $0 }.count == 1)
        #expect(results.filter { !$0 }.count == 1)
        #expect(surviving.tempo == 101 || surviving.tempo == 202)
        #expect(await cache.sectionRevision(.transport) == 1)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    private func transport(tempo: Double) -> TransportState {
        var state = TransportState()
        state.tempo = tempo
        state.lastUpdated = Date()
        return state
    }
}
