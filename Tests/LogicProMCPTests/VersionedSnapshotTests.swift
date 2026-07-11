import Foundation
import Testing
@testable import LogicProMCP

@Suite("ADR-006 versioned snapshot")
struct VersionedSnapshotTests {
    @Test func snapshotPreservesFields() {
        let observedAt = ContinuousClock.now
        let snapshot = VersionedSnapshot(
            projectEpoch: 7,
            sectionRevision: 11,
            observedAt: observedAt,
            source: .axLive,
            completeness: .partial,
            fingerprint: "tracks:v7",
            value: ["Kick", "Snare"]
        )

        #expect(snapshot.projectEpoch == 7)
        #expect(snapshot.sectionRevision == 11)
        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.source == .axLive)
        #expect(snapshot.completeness == .partial)
        #expect(snapshot.fingerprint == "tracks:v7")
        #expect(snapshot.value == ["Kick", "Snare"])
    }

    @Test func etagIsStableForFingerprint() {
        let observedAt = ContinuousClock.now
        let first = makeSnapshot(fingerprint: "same", observedAt: observedAt)
        let second = makeSnapshot(fingerprint: "same", observedAt: observedAt + .seconds(1))
        let different = makeSnapshot(fingerprint: "different", observedAt: observedAt)

        #expect(first.etag == first.fingerprint)
        #expect(first.etag == second.etag)
        #expect(first.etag != different.etag)
    }

    @Test func cacheAgeMillisUsesObservedAt() {
        let observedAt = ContinuousClock.now
        let snapshot = makeSnapshot(fingerprint: "age", observedAt: observedAt)

        #expect(snapshot.cacheAgeMillis(now: observedAt) == 0)
        #expect(snapshot.cacheAgeMillis(now: observedAt + .milliseconds(1_234)) == 1_234)
        #expect(snapshot.cacheAgeMillis(now: observedAt - .milliseconds(1)) == 0)
    }

    @Test func sourceAndCompletenessRoundTrip() throws {
        let sources: [StateSource] = [.axLive, .appleScript, .mcuEcho, .coreMIDI, .cache, .unknown]
        let completeness: [Completeness] = [.complete, .partial, .unknown]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decodedSources = try decoder.decode([StateSource].self, from: encoder.encode(sources))
        let decodedCompleteness = try decoder.decode(
            [Completeness].self,
            from: encoder.encode(completeness)
        )

        #expect(decodedSources.map(\.rawValue) == [
            "axLive",
            "appleScript",
            "mcuEcho",
            "coreMIDI",
            "cache",
            "unknown",
        ])
        #expect(decodedCompleteness.map(\.rawValue) == ["complete", "partial", "unknown"])
    }

    @Test func cacheSectionsAreComplete() {
        #expect(CacheSectionID.allCases.map(\.rawValue) == [
            "transport",
            "tracks",
            "mixer",
            "project",
            "pluginInventory",
            "libraryInventory",
        ])
    }

    @Test func versionedCacheFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR006_VERSIONED_CACHE"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr006VersionedCache)
    }

    private func makeSnapshot(
        fingerprint: String,
        observedAt: ContinuousClock.Instant
    ) -> VersionedSnapshot<String> {
        VersionedSnapshot(
            projectEpoch: 1,
            sectionRevision: 2,
            observedAt: observedAt,
            source: .cache,
            completeness: .complete,
            fingerprint: fingerprint,
            value: "value"
        )
    }
}
