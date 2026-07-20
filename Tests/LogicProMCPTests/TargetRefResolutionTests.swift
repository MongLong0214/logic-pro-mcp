import Foundation
import MCP
import Testing
@testable import LogicProMCP

// ADR-002 (#285, part of #308): `target_ref` resolution extended from
// `logic_tracks rename` to ALL track / mixer / plugin mutations behind
// `FeatureFlags.adr002TargetRef`. These synthetic, deterministic tests lock in:
//   * the shared `TargetRefResolver` resolution + fail-closed matrix,
//   * per-command-family wiring (flag-on resolves the correct index),
//   * the #308 wrong-target negative guarantees (never a wrong-target mutation).

private actor RecordingChannel: Channel {
    // #353: `.stateB` returns a `verified:false` success so a rename's dispatcher
    // guard treats it as unverified (State B). Default `.stateA` keeps every other
    // test byte-identical.
    enum Envelope: Sendable { case stateA, stateB }

    nonisolated let id: ChannelID
    private let succeeds: Bool
    private let envelope: Envelope
    private(set) var executedOps: [(String, [String: String])] = []

    init(id: ChannelID, succeeds: Bool = true, envelope: Envelope = .stateA) {
        self.id = id
        self.succeeds = succeeds
        self.envelope = envelope
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        guard succeeds else { return .error("synthetic failure") }
        switch envelope {
        case .stateA:
            return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
        case .stateB:
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: ["operation": operation]
            ))
        }
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "target-ref recording channel")
    }
}

@Suite(.serialized)
struct TargetRefResolutionTests {
    // Every op touched here has `.accessibility` first in its routing chain
    // except track.set_automation (.mcu) and track.duplicate (.midiKeyCommands),
    // so recorders on this union observe every routed write.
    private static let recorderIDs: [ChannelID] =
        [.accessibility, .mcu, .midiKeyCommands, .cgEvent, .scripter]

    private func makeRouter(succeeds: Bool = true) async -> (ChannelRouter, [RecordingChannel]) {
        let channels = Self.recorderIDs.map { RecordingChannel(id: $0, succeeds: succeeds) }
        let router = ChannelRouter()
        for channel in channels { await router.register(channel) }
        return (router, channels)
    }

    private func allOps(_ channels: [RecordingChannel]) async -> [(String, [String: String])] {
        var out: [(String, [String: String])] = []
        for channel in channels { out.append(contentsOf: await channel.executedOps) }
        return out
    }

    private func opParams(
        _ channels: [RecordingChannel],
        _ operation: String
    ) async -> [String: String]? {
        await allOps(channels).first(where: { $0.0 == operation })?.1
    }

    private func boundTrack(
        index: Int = 2,
        name: String = "Bass"
    ) async -> (TargetRegistry, StateCache, TargetReference) {
        let registry = TargetRegistry()
        let descriptor = TargetDescriptor(trackIndex: index, trackName: name)
        let reference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let cache = StateCache()
        await cache.updateTracks([
            TrackState(id: 0, name: "Kick", type: .audio),
            TrackState(id: 1, name: "Snare", type: .audio),
            TrackState(id: index, name: name, type: .audio),
        ])
        return (registry, cache, reference)
    }

    private func errorCode(_ result: CallTool.Result) -> String? {
        sharedJSONObject(sharedToolText(result))?["error"] as? String
    }

    private func echoedTargetRef(_ result: CallTool.Result) -> String? {
        sharedJSONObject(sharedToolText(result))?["target_ref"] as? String
    }

    private func dummyInvalid() -> CallTool.Result {
        toolInvalidParamsResult("resolver-test: explicit index required")
    }

    // MARK: - Resolver unit: positive resolution

    @Test
    func testResolverFlagOnValidReferenceResolvesIndexAndEchoesReference() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                invalidIndexResult: dummyInvalid()
            )
            guard case .success(let resolved) = outcome else {
                Issue.record("expected success")
                return
            }
            #expect(resolved.index == 2)
            #expect(resolved.reference == reference)
        }
    }

    @Test
    func testResolverFlagOnNoTargetRefUsesExplicitIndex() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, _) = await boundTrack()
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["index": .int(3)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.delete",
                invalidIndexResult: dummyInvalid()
            )
            guard case .success(let resolved) = outcome else {
                Issue.record("expected success")
                return
            }
            #expect(resolved.index == 3)
            #expect(resolved.reference == nil)
        }
    }

    @Test
    func testResolverMatchingCrossCheckSucceeds() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue), "index": .int(2)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                invalidIndexResult: dummyInvalid()
            )
            guard case .success(let resolved) = outcome else {
                Issue.record("expected success")
                return
            }
            #expect(resolved.index == 2)
            #expect(resolved.reference == reference)
        }
    }

    // MARK: - PRD-007 Part 2: the DEFAULT path (no override)

    /// Every other test in this file forces the flag through the `@TaskLocal`
    /// override, which SHORT-CIRCUITS the env read entirely — so none of them
    /// can observe the shipped default. These two drive the resolver with no
    /// override at all, which is the only way the promotion to default-ON is
    /// actually load-bearing at the dispatcher level.
    ///
    /// HAZARD: `setenv`/`unsetenv` are process-global and `.serialized` only
    /// orders tests WITHIN a suite — `FeatureFlagsTests` mutates this same
    /// variable in a sibling suite. These are reliable under `--no-parallel`
    /// (what CI runs); do not assume they are safe under a default parallel run.
    private func withTargetRefEnv<Result>(_ value: String?, _ body: () async throws -> Result) async rethrows -> Result {
        let key = "LOGIC_MCP_ADR002_TARGET_REF"
        let previous = ProcessInfo.processInfo.environment[key]
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return try await body()
    }

    @Test("(d) under the shipped default, a target_ref resolves — no override")
    func testResolverDefaultAcceptsTargetRef() async {
        await withTargetRefEnv(nil) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.delete",
                invalidIndexResult: dummyInvalid()
            )
            guard case .success(let resolved) = outcome else {
                Issue.record("expected the default (unset env) to accept target_ref")
                return
            }
            #expect(resolved.index == 2)
            #expect(resolved.reference == reference)
        }
    }

    @Test("(d) the =0 kill-switch still fails a target_ref closed — now the explicit-off path")
    func testResolverKillSwitchEnvRefusesTargetRef() async {
        await withTargetRefEnv("0") {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.delete",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected the =0 kill-switch to fail target_ref closed")
                return
            }
            #expect(errorCode(result) == "target_ref_unavailable")
        }
    }

    @Test
    func testResolverFlagOffTargetRefFailsClosedBeforeIndexFallback() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue), "index": .int(5)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.delete",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected fail-closed target_ref refusal")
                return
            }
            let body = sharedJSONObject(sharedToolText(result)) ?? [:]
            #expect(errorCode(result) == "target_ref_unavailable")
            #expect(body["target_ref"] as? String == reference.rawValue)
            // Bare/force-unwrapped spellings: `as? Bool == false` and
            // `Bool? == true` are DEAD under this toolchain and pass
            // unconditionally. These two assertions were dead — the hint one
            // still pinned the pre-PRD-007 "=1" wording and did not fail when
            // that wording changed.
            let writeAttempted = body["write_attempted"] as! Bool
            #expect(!writeAttempted)
            let hint = body["hint"] as! String
            #expect(hint.contains("LOGIC_MCP_ADR002_TARGET_REF"))
        }
    }

    @Test
    func testResolverFlagOffTargetRefWithoutIndexFailsUnavailable() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack()
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.delete",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(errorCode(result) == "target_ref_unavailable")
        }
    }

    // MARK: - Resolver unit: wrong-target negatives (#308 done-bar)

    @Test
    func testResolverStaleReferenceFailsClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack()
            await registry.bumpTopologyGeneration()
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(errorCode(result) == "stale_target_reference")
        }
    }

    @Test
    func testResolverEmptyAndUnknownReferenceFailClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, _) = await boundTrack()
            for raw in ["   ", "", "trk_not_a_real_reference"] {
                let outcome = await TargetRefResolver.resolveMutationIndex(
                    ["target_ref": .string(raw)],
                    targetRegistry: registry,
                    cache: cache,
                    operation: "track.rename",
                    invalidIndexResult: dummyInvalid()
                )
                guard case .failure(let result) = outcome else {
                    Issue.record("expected failure for '\(raw)'")
                    continue
                }
                #expect(errorCode(result) == "stale_target_reference")
            }
        }
    }

    @Test
    func testResolverWrongKindBindingFailsClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            // A non-track binding (mixer strip) must not satisfy a .track resolve.
            let mixReference = await registry.bind(
                kind: .mixerStrip,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let cache = StateCache()
            await cache.updateTracks([TrackState(id: 2, name: "Bass", type: .audio)])
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(mixReference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                requiredKind: .track,
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(errorCode(result) == "stale_target_reference")
        }
    }

    @Test
    func testResolverMismatchedIndexCrossCheckFailsClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue), "index": .int(1)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(errorCode(result) == "stale_target_reference")
        }
    }

    @Test
    func testResolverNegativeCrossCheckIndexFailsClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue), "index": .int(-1)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(errorCode(result) == "stale_target_reference")
        }
    }

    @Test
    func testResolverDriftedFingerprintFailsClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let reference = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            // The live track at index 2 was renamed out from under the ref.
            let cache = StateCache()
            await cache.updateTracks([TrackState(id: 2, name: "Lead Synth", type: .audio)])
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(errorCode(result) == "stale_target_reference")
        }
    }

    @Test
    func testMutationAfterEpochBumpFailsClosedBeforeWrite() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()

            await registry.bumpProjectEpoch()
            let result = await TrackDispatcher.handle(
                command: "rename",
                params: [
                    "target_ref": .string(reference.rawValue),
                    "name": .string("Wrong Project"),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )

            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testResolverRejectsEpochBumpAfterCacheReadBeforeSuccess() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.rename",
                invalidIndexResult: dummyInvalid(),
                beforeFinalValidation: {
                    await registry.bumpProjectEpoch()
                }
            )

            guard case .failure(let result) = outcome else {
                Issue.record("expected stale target reference")
                return
            }
            #expect(errorCode(result) == "stale_target_reference")
        }
    }

    @Test
    func testResolverFlagOffNegativeIndexFailsInvalidParams() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["index": .int(-1)],
                targetRegistry: nil,
                cache: StateCache(),
                operation: "track.delete",
                invalidIndexResult: dummyInvalid()
            )
            guard case .failure(let result) = outcome else {
                Issue.record("expected failure")
                return
            }
            #expect(errorCode(result) == "invalid_params")
        }
    }

    @Test
    func testTrackSelectFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
        }
    }

    @Test
    func testTrackSelectFlagOffTargetRefFailsClosed() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["index": .int(1), "target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "target_ref_unavailable")
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testTrackSelectFlagOnStaleReferenceFailsClosedNoWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            await registry.bumpTopologyGeneration()
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testTrackDeleteFlagOnStaleReferenceFailsClosedBeforeSelectSideEffect() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            await registry.bumpProjectEpoch()
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "delete",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "stale_target_reference")
            // The pre-delete track.select side effect must NOT have fired.
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testTrackDeleteFlagOnResolvesTargetRefToSelectIndex() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "delete",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
            #expect(await allOps(channels).contains(where: { $0.0 == "track.delete" }))
        }
    }

    @Test
    func testTrackDuplicateFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "duplicate",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
            #expect(await allOps(channels).contains(where: { $0.0 == "track.duplicate" }))
        }
    }

    @Test
    func testTrackMuteFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "mute",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.set_mute") == ["index": "2", "enabled": "true"])
        }
    }

    @Test
    func testTrackMuteFlagOffRejectsTargetRefBeforeIndexValidation() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "mute",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "target_ref_unavailable")
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testTrackArmOnlyFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "arm_only",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.set_arm") == ["index": "2", "enabled": "true"])
        }
    }

    @Test
    func testTrackSetAutomationFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "set_automation",
                params: ["target_ref": .string(reference.rawValue), "mode": .string("read")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.set_automation") == ["index": "2", "mode": "read"])
        }
    }

    @Test
    func testTrackSetInstrumentFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "set_instrument",
                params: ["target_ref": .string(reference.rawValue), "path": .string("/x.patch")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.set_instrument") == ["index": "2", "path": "/x.patch"])
        }
    }

    @Test
    func testTrackRenameFlagOnResolvesTargetRefAndEchoesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "rename",
                params: ["target_ref": .string(reference.rawValue), "name": .string("Sub Bass")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            // rename keeps its pre-uniform `track_ref` alias (G8 backward compat);
            // the other 12 mutations emit only the uniform `target_ref` key.
            #expect(sharedJSONObject(sharedToolText(result))!["track_ref"] as! String == reference.rawValue)
            #expect(await opParams(channels, "track.rename") == ["index": "2", "name": "Sub Bass"])
        }
    }

    // MARK: - Mixer dispatcher wiring

    @Test
    func testMixerSetVolumeFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "mixer.set_volume") == ["index": "2", "volume": "0.5"])
        }
    }

    @Test
    func testMixerSetVolumeFlagOffTargetRefFailsClosedWithoutWrongTargetWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let before = await cache.getTracks().map {
                "\($0.id)|\($0.name)|\($0.volume)|\($0.isSelected)"
            }
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: [
                    "track": .int(1),
                    "value": .double(0.3),
                    "target_ref": .string(reference.rawValue),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "target_ref_unavailable")
            let v2 = try #require(sharedJSONObject(sharedToolText(result))?["write_attempted"] as? Bool)
            #expect(!v2)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await allOps(channels).isEmpty, "neither conflicting track may be written")
            let after = await cache.getTracks().map {
                "\($0.id)|\($0.name)|\($0.volume)|\($0.isSelected)"
            }
            #expect(after == before, "target track and neighbouring track must remain unchanged")
        }
    }

    @Test
    func testMixerSetPanFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_pan",
                params: ["target_ref": .string(reference.rawValue), "value": .double(-0.25)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "mixer.set_pan") == ["index": "2", "pan": "-0.25"])
        }
    }

    @Test
    func testMixerSetVolumeFlagOnStaleReferenceFailsClosedNoWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            await registry.bumpTopologyGeneration()
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    // MARK: - Plugin dispatcher wiring

    private func verifiedParams(track: Int?, targetRef: String?) -> [String: Value] {
        var params: [String: Value] = [
            "insert": .int(0),
            "plugin": .string("logic.stock.gain"),
            "param": .string("gain_db"),
            "value": .double(0.5),
            "unit": .string("db"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string("/tmp/project.logicx"),
        ]
        if let track { params["track"] = .int(track) }
        if let targetRef { params["target_ref"] = .string(targetRef) }
        return params
    }

    @Test
    func testPluginSetParamVerifiedFlagOnResolvesTargetRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: verifiedParams(track: nil, targetRef: reference.rawValue),
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "plugin.set_param_verified")?["track"] == "2")
        }
    }

    @Test
    func testPluginSetParamVerifiedFlagOffTargetRefFailsClosed() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: verifiedParams(track: 3, targetRef: reference.rawValue),
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "target_ref_unavailable")
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testPluginSetParamVerifiedFlagOnStaleReferenceFailsClosedNoWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            await registry.bumpProjectEpoch()
            let (router, channels) = await makeRouter()
            let result = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: verifiedParams(track: nil, targetRef: reference.rawValue),
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    // MARK: - #353: rebind target_ref on verified server-performed rename

    /// The core regression: renaming a track THROUGH its own target_ref must not
    /// invalidate that ref. Pre-#353 the drift check saw the new live name and
    /// failed the next same-ref op closed; the verified-success rebind keeps it.
    @Test
    func testRenameViaRefThenSecondOpViaSameRefResolves() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (renameRouter, _) = await makeRouter()
            let renameResult = await TrackDispatcher.handle(
                command: "rename",
                params: ["target_ref": .string(reference.rawValue), "name": .string("Sub Bass")],
                router: renameRouter,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(renameResult.isError)
            #expect(!v1)
            #expect((await registry.resolve(reference))!.descriptor.trackName == "Sub Bass")
            #expect((await cache.getTracks())[2].name == "Sub Bass")

            let (selectRouter, selectChannels) = await makeRouter()
            let secondOp = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: selectRouter,
                cache: cache,
                targetRegistry: registry
            )
            let v2 = try #require(secondOp.isError)
            #expect(!v2)
            #expect(await opParams(selectChannels, "track.select") == ["index": "2"])
        }
    }

    @Test
    func testRenameViaIndexDoesNotUpdateCache() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (_, cache, _) = await boundTrack(index: 2, name: "Bass")
            let (router, _) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "rename",
                params: ["index": .int(2), "name": .string("Sub Bass")],
                router: router,
                cache: cache
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == nil)
            #expect((await cache.getTracks())[2].name == "Bass")
        }
    }

    /// Regression guard for the intended fail-closed behaviour: a rename made
    /// DIRECTLY in Logic's UI (no server op, no rebind) still invalidates the
    /// ref — the server cannot prove it caused the change.
    @Test
    func testExternalRenameWithoutServerOpStillFailsClosed() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            // User renamed the track in Logic; the cache caught up but no server
            // op / rebind ever ran.
            await cache.updateTracks([
                TrackState(id: 0, name: "Kick", type: .audio),
                TrackState(id: 1, name: "Snare", type: .audio),
                TrackState(id: 2, name: "Renamed In Logic", type: .audio),
            ])
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    /// A State B (unverified) rename must NOT rebind — identity is not proven.
    /// Once the cache reflects the (unverified) new name, the ref fails closed.
    @Test
    func testRenameStateBUnverifiedDoesNotRebind() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let router = ChannelRouter()
            await router.register(RecordingChannel(id: .accessibility, envelope: .stateB))
            let renameResult = await TrackDispatcher.handle(
                command: "rename",
                params: ["target_ref": .string(reference.rawValue), "name": .string("Sub Bass")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            // State B (verified:false) rename surfaces as an error.
            let v1 = try #require(renameResult.isError)
            #expect(v1)

            await cache.updateTracks([
                TrackState(id: 0, name: "Kick", type: .audio),
                TrackState(id: 1, name: "Snare", type: .audio),
                TrackState(id: 2, name: "Sub Bass", type: .audio),
            ])
            let (selectRouter, selectChannels) = await makeRouter()
            let secondOp = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: selectRouter,
                cache: cache,
                targetRegistry: registry
            )
            let v2 = try #require(secondOp.isError)
            #expect(v2)
            #expect(errorCode(secondOp) == "stale_target_reference")
            #expect(await allOps(selectChannels).isEmpty)
        }
    }

    // MARK: - ADR-002 F5: live track-identity cross-check for track/mixer target_ref mutations

    // F1 already makes the live AX track header authoritative over the state
    // cache for the verified-plugin write path. F5 extends the same fail-closed
    // guarantee to the track/mixer `target_ref` mutation-resolution boundary:
    // the reference's bound track name is cross-checked against the LIVE AX
    // header at the bound index immediately before the write target is returned.
    // A mismatch — or an unreadable live name — fails closed with
    // `stale_target_reference`, `write_attempted:false`, and zero write, even
    // when a stale state cache would still (falsely) pass the fingerprint drift
    // check after an out-of-band UI reorder. The explicit-index and flag-off
    // paths never invoke the guard (byte-invariant).

    private func body(_ result: CallTool.Result) -> [String: Any] {
        sharedJSONObject(sharedToolText(result)) ?? [:]
    }

    /// Same-index collision: the cache still holds the bound name at the bound
    /// index (drift check passes), but a live out-of-band reorder put a
    /// different-named track there. The live cross-check must fail closed.
    @Test
    func testTrackTargetRefLiveNameMismatchFailsClosedStaleAndDoesNotWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { $0 == 2 ? "Drums" : "Other" }
            )
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(errorCode(result) == "stale_target_reference")
            let v2 = try #require(body(result)["write_attempted"] as? Bool)
            #expect(!v2)
            #expect(body(result)["expected_track_name"] as? String == "Bass")
            #expect(body(result)["observed_track_name"] as? String == "Drums")
            #expect(await allOps(channels).isEmpty, "no wrong-target write")
        }
    }

    @Test
    func testTrackTargetRefDuplicateNameReorderFailsClosedAndDoesNotWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 1, trackName: "Bass")
            let reference = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let cache = StateCache()
            await cache.updateTracks([
                TrackState(id: 0, name: "Drums", type: .audio),
                TrackState(id: 1, name: "Bass", type: .audio),
                TrackState(id: 2, name: "Bass", type: .audio),
            ])
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "mute",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { idx in [0: "Drums", 1: "Bass", 2: "Bass"][idx] },
                liveTrackNames: { [0: "Drums", 1: "Bass", 2: "Bass"] }
            )
            #expect(errorCode(result) == "stale_target_reference")
            let v1 = try #require(body(result)["write_attempted"] as? Bool)
            #expect(!v1)
            #expect(body(result)["expected_track_name"] as? String == "Bass")
            let v2 = try #require(body(result)["ambiguous_live_track_name"] as? Bool)
            #expect(v2)
            #expect(body(result)["ambiguous_track_indices"] as? [Int] == [2])
            #expect(await allOps(channels).isEmpty, "no wrong-target write")
        }
    }

    /// Mixer `set_volume` is the F5 sibling of the track path.
    @Test
    func testMixerTargetRefLiveNameMismatchFailsClosedStaleAndDoesNotWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { _ in "Lead Synth" }
            )
            #expect(errorCode(result) == "stale_target_reference")
            let v1 = try #require(body(result)["write_attempted"] as? Bool)
            #expect(!v1)
            #expect(await allOps(channels).isEmpty, "no wrong-target write")
        }
    }

    /// F1 parity: an unreadable (nil) live name fails closed, never silently
    /// falling back to the possibly-stale cache.
    @Test
    func testTrackTargetRefUnreadableLiveNameFailsClosedAndDoesNotWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "delete",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { _ in nil },
                liveTrackNames: { nil }
            )
            #expect(errorCode(result) == "stale_target_reference")
            let v1 = try #require(body(result)["write_attempted"] as? Bool)
            #expect(!v1)
            let v2 = try #require((body(result)["what_was_observed"] as? String)?.contains("unreadable"))
            #expect(v2)
            #expect(await allOps(channels).isEmpty, "no wrong-target write, no pre-delete select side effect")
        }
    }

    /// GREEN passthrough: the live header still matches the bound name → resolve
    /// and write proceed exactly as before.
    @Test
    func testTrackTargetRefLiveNameMatchStillResolvesAndWrites() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { _ in "Bass" },
                liveTrackNames: { [2: "Bass"] }
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
        }
    }

    @Test
    func testMixerTargetRefLiveNameMatchStillResolvesAndWrites() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { _ in "Bass" },
                liveTrackNames: { [2: "Bass"] }
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == reference.rawValue)
            #expect(await opParams(channels, "mixer.set_volume") == ["index": "2", "volume": "0.5"])
        }
    }

    /// Byte-invariance of the explicit-index path: no `target_ref` → no binding
    /// → the live guard is NEVER invoked, even with a mismatching probe.
    @Test
    func testExplicitIndexPathIsByteInvariantEvenWithMismatchingLiveProbe() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, _) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["index": .int(2)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { _ in "Totally Different" }
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(echoedTargetRef(result) == nil)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
        }
    }

    /// Byte-invariance of the flag-off path: a supplied `target_ref` fails closed
    /// with `target_ref_unavailable` BEFORE the guard can run, regardless of the
    /// live probe.
    @Test
    func testFlagOffTargetRefIsByteInvariantAndNeverReachesLiveGuard() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: router,
                cache: cache,
                targetRegistry: registry,
                liveTrackName: { _ in "Mismatch" }
            )
            #expect(errorCode(result) == "target_ref_unavailable")
            #expect(await allOps(channels).isEmpty)
        }
    }

    // MARK: - #353: TargetRegistry.rebind unit

    @Test
    func testRebindUnknownReferenceIsNoOp() async {
        let registry = TargetRegistry()
        let unknown = TargetReference(rawValue: "trk_\(UUID().uuidString)")
        await registry.rebind(unknown, to: TargetDescriptor(trackIndex: 5, trackName: "Ghost"))
        // No binding existed, so none was created — never resurrected.
        #expect(await registry.resolve(unknown) == nil)
    }

    @Test
    func testRebindStaleReferenceIsNoOp() async {
        let registry = TargetRegistry()
        let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
        let reference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        await registry.bumpTopologyGeneration()  // binding is now stale/removed
        await registry.rebind(reference, to: TargetDescriptor(trackIndex: 2, trackName: "Sub Bass"))
        // A stale reference must not be rebound back to life.
        #expect(await registry.resolve(reference) == nil)
    }

    @Test
    func testRebindPreservesIdentityFieldsAndUpdatesDescriptor() async {
        let registry = TargetRegistry()
        let old = TargetDescriptor(trackIndex: 2, trackName: "Bass")
        let reference = await registry.bind(
            kind: .track,
            descriptor: old,
            fingerprint: old.fingerprint
        )
        let epochBefore = await registry.currentProjectEpoch
        let generationBefore = await registry.currentTopologyGeneration

        let new = TargetDescriptor(trackIndex: 2, trackName: "Sub Bass")
        await registry.rebind(reference, to: new)

        guard let binding = await registry.resolve(reference) else {
            Issue.record("expected the rebound reference to still resolve")
            return
        }
        // Descriptor + fingerprint adopt the new identity...
        #expect(binding.descriptor == new)
        #expect(binding.observedFingerprint == new.fingerprint)
        // ...while reference / kind / epoch / topology-generation are preserved.
        #expect(binding.reference == reference)
        #expect(binding.kind == .track)
        #expect(binding.projectEpoch == epochBefore)
        #expect(binding.topologyGeneration == generationBefore)
    }
}
