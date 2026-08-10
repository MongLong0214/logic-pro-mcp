import Foundation
import Testing
@testable import LogicProMCP

@Suite("VersionedCacheEnvelope", .serialized)
struct VersionedCacheEnvelopeTests {
    @Test func flagOffEnvelopeIsByteIdentical() {
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
        #expect(ResourceHandlers.wrapWithCacheEnvelope(
            bodyJSON: "{\"x\":1}",
            fetchedAt: nil
        ) == "{\"cache_age_sec\":null,\"fetched_at\":null,\"ax_occluded\":false,\"data\":{\"x\":1}}")
    }

    @Test func flagOnAddsVersionFieldsToStateResources() async throws {
        try await withVersionedCacheFlag(true) {
            let cache = StateCache()
            let registry = TargetRegistry()
            let router = ChannelRouter()
            await registry.bumpProjectEpoch()

            await cache.updateTransport(TransportState())
            await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])
            await cache.updateChannelStrips([ChannelStripState(trackIndex: 0)])
            var project = ProjectInfo()
            project.name = "Envelope Test"
            await cache.updateProject(project)

            for uri in [
                "logic://transport/state",
                "logic://tracks",
                "logic://mixer",
                "logic://project/info",
            ] {
                let result = try await ResourceHandlers.read(
                    uri: uri,
                    cache: cache,
                    router: router,
                    targetRegistry: registry,
                    fileReader: headlessFileReader
                )
                let envelope = try #require(JSONSerialization.jsonObject(
                    with: Data(sharedResourceText(result).utf8)
                ) as? [String: Any])

                #expect((envelope["project_epoch"] as? NSNumber)?.uint64Value == 1)
                #expect((envelope["section_revision"] as? NSNumber)?.uint64Value == 1)
                #expect(envelope["etag"] as? String != nil)
            }
        }
    }

    /// Pins that ADR-006 OFF contributes no envelope fields, against the
    /// SHIPPED default of every other flag (this deliberately does not pin
    /// `adr002TargetRef`, so the baseline tracks what users actually receive).
    ///
    /// #476 — DELIBERATE PIN DIFF: `readable`, `verified_empty` and `reason` are now present.
    /// Before this, a cold `logic://tracks` answered `data: []` with nothing saying it had never
    /// looked, so a consumer reading `data` saw an empty project where one had tracks. The sibling
    /// `logic://markers` already carried these three fields. This is an additive wire change and is
    /// noted rather than hidden; ADR-006 OFF still contributes nothing of its own, which is what
    /// this test exists to pin.
    ///
    /// PRD-007 Part 2 — DELIBERATE PIN DIFF, `"data":[\n\n]` -> `"data":[]`.
    /// The expectation moved because `adr002TargetRef` is now default ON, which
    /// routes `logic://tracks` through the ref-capable `JSONSerialization`
    /// builder instead of the legacy string-concatenation path. The two spell an
    /// empty array differently. The change is whitespace-only and semantically
    /// identical (`[]` and `[\n\n]` both parse to an empty array), but it IS a
    /// byte-level wire change for every caller — noted rather than hidden.
    @Test func flagOffStateResourceEnvelopeIsByteIdentical() async throws {
        try await withVersionedCacheFlag(false) {
            let result = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: StateCache(),
                router: ChannelRouter(),
                targetRegistry: TargetRegistry(),
                fileReader: headlessFileReader
            )

            #expect(sharedResourceText(result) == "{\"cache_age_sec\":null,\"fetched_at\":null,\"ax_occluded\":false,\"readable\":false,\"reason\":\"no_live_track_read_yet\",\"source\":\"default\",\"verified_empty\":false,\"data\":[]}")
        }
    }

    @Test func etagIsStableAndBodySensitive() {
        let body = "{\"x\":1}"

        #expect(ResourceHandlers.etag(of: body) == "bdd3d53c3a0b3fd6")
        #expect(ResourceHandlers.etag(of: body) == ResourceHandlers.etag(of: body))
        #expect(ResourceHandlers.etag(of: body) != ResourceHandlers.etag(of: "{\"x\":2}"))
    }

    @Test func versionedCacheExtrasArePure() {
        let extras = ResourceHandlers.versionedCacheExtras(
            projectEpoch: 7,
            sectionRevision: 11,
            droppedStaleWrites: 5,
            bodyJSON: "{\"x\":1}"
        )

        #expect(extras.count == 4)
        #expect(extras["project_epoch"] as? UInt64 == 7)
        #expect(extras["section_revision"] as? UInt64 == 11)
        #expect(extras["dropped_stale_writes"] as? UInt64 == 5)
        #expect(extras["etag"] as? String == "bdd3d53c3a0b3fd6")

        // Defaulting to zero keeps the key present rather than making it appear only once something
        // has gone wrong: a field that materialises on failure cannot be used to tell "the guard
        // never fired" apart from "this build does not report it".
        let quiet = ResourceHandlers.versionedCacheExtras(
            projectEpoch: 7,
            sectionRevision: 11,
            bodyJSON: "{\"x\":1}"
        )
        #expect(quiet["dropped_stale_writes"] as? UInt64 == 0)
    }

    @Test func sectionRevisionsAdvanceIndependentlyOnAcceptedUpdates() async {
        let cache = StateCache()
        for section in CacheSectionID.allCases {
            #expect(await cache.sectionRevision(section) == 0)
        }

        await cache.updateTransport(TransportState())
        await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])
        await cache.updateTracks([])
        #expect(await cache.sectionRevision(.tracks) == 1)
        await cache.updateTrack(at: 0) { $0.name = "Snare" }
        await cache.selectOnly(trackAt: 0)

        await cache.updateChannelStrips([ChannelStripState(trackIndex: 0)])
        await cache.updateFader(strip: 0, volume: 0.5)
        await cache.updatePan(strip: 0, value: 0.25)

        var project = ProjectInfo()
        project.name = "Revision Test"
        await cache.updateProject(project)

        #expect(await cache.sectionRevision(.transport) == 1)
        #expect(await cache.sectionRevision(.tracks) == 3)
        #expect(await cache.sectionRevision(.mixer) == 3)
        #expect(await cache.sectionRevision(.project) == 1)
        #expect(await cache.sectionRevision(.pluginInventory) == 0)
        #expect(await cache.sectionRevision(.libraryInventory) == 0)

        await cache.clearProjectState()
        #expect(await cache.sectionRevision(.transport) == 2)
        #expect(await cache.sectionRevision(.tracks) == 4)
        #expect(await cache.sectionRevision(.mixer) == 4)
        #expect(await cache.sectionRevision(.project) == 2)
    }

    private var headlessFileReader: LogicProjectFileReader.Runtime {
        .init(
            currentDocumentPath: { nil },
            now: Date.init,
            readPlistData: { _ in nil },
            mtime: { _ in nil },
            sleep: { _ in }
        )
    }

    private func withVersionedCacheFlag<Result>(
        _ enabled: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let key = "LOGIC_MCP_ADR006_VERSIONED_CACHE"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, enabled ? "1" : "0", 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await operation()
    }

    /// Flag-coupling regression (ADR-006 audit): with the versioned cache ON
    /// and target refs OFF, a real project lifecycle transition through the
    /// dispatcher must still advance `project_epoch` — it used to stay frozen
    /// at 0 because the epoch bump was gated on the adr002 flag alone, making
    /// the envelope's cross-project discriminator a constant. The pre-fix
    /// suite could not catch this because it bumped the registry directly.
    ///
    /// PRD-007 Part 2: target refs are now DEFAULT ON, so "off" must be pinned
    /// with the explicit `=0` kill-switch. This test previously spelled it as
    /// `unsetenv` — which after the promotion means ON, silently inverting the
    /// very coupling under test while still passing.
    @Test func lifecycleInvalidationAdvancesEpochWithoutTargetRefFlag() async throws {
        try await withVersionedCacheFlag(true) {
            let adr002Key = "LOGIC_MCP_ADR002_TARGET_REF"
            let previous = ProcessInfo.processInfo.environment[adr002Key]
            setenv(adr002Key, "0", 1)
            defer {
                if let previous {
                    setenv(adr002Key, previous, 1)
                } else {
                    unsetenv(adr002Key)
                }
            }
            #expect(!FeatureFlags.adr002TargetRef)
            #expect(FeatureFlags.adr006VersionedCache)

            let router = ChannelRouter()
            await router.register(MockChannel(id: .accessibility))
            let cache = StateCache()
            let registry = TargetRegistry()
            let epochBefore = await registry.currentProjectEpoch

            _ = await ProjectDispatcher.handle(
                command: "new",
                params: [:],
                router: router,
                cache: cache,
                targetRegistry: registry
            )

            let epochAfter = await registry.currentProjectEpoch
            #expect(epochAfter == epochBefore + 1)

            // And the envelope actually publishes the advanced epoch.
            let result = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: router,
                targetRegistry: registry,
                fileReader: headlessFileReader
            )
            let envelope = try #require(JSONSerialization.jsonObject(
                with: Data(sharedResourceText(result).utf8)
            ) as? [String: Any])
            #expect((envelope["project_epoch"] as? NSNumber)?.uint64Value == epochAfter)
        }
    }
}
