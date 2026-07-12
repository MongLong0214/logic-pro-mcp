import Foundation
import MCP
import Testing
@testable import LogicProMCP

// ADR-002 (#285, part of #308): `target_ref` resolution extended from
// `logic_tracks rename` to ALL track / mixer / plugin mutations behind
// `FeatureFlags.adr002TargetRef`. These synthetic, deterministic tests lock in:
//   * the shared `TargetRefResolver` resolution + fail-closed matrix,
//   * per-command-family wiring (flag-on resolves the correct index),
//   * flag-off byte-identity (target_ref ignored, explicit index required),
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

    // MARK: - Resolver unit: flag-off byte-identity

    @Test
    func testResolverFlagOffIgnoresTargetRefAndUsesIndex() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let outcome = await TargetRefResolver.resolveMutationIndex(
                ["target_ref": .string(reference.rawValue), "index": .int(5)],
                targetRegistry: registry,
                cache: cache,
                operation: "track.delete",
                invalidIndexResult: dummyInvalid()
            )
            guard case .success(let resolved) = outcome else {
                Issue.record("expected success")
                return
            }
            #expect(resolved.index == 5)
            #expect(resolved.reference == nil)
        }
    }

    @Test
    func testResolverFlagOffTargetRefWithoutIndexFailsInvalidParams() async {
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
            #expect(errorCode(result) == "invalid_params")
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

    // MARK: - Track dispatcher wiring (flag on resolves; flag off byte-identical)

    @Test
    func testTrackSelectFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
        }
    }

    @Test
    func testTrackSelectFlagOffIgnoresTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "select",
                params: ["index": .int(1), "target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            // target_ref (which points at 2) is ignored; explicit index 1 wins.
            #expect(await opParams(channels, "track.select") == ["index": "1"])
        }
    }

    @Test
    func testTrackSelectFlagOnStaleReferenceFailsClosedNoWrite() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
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
            #expect(result.isError == true)
            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testTrackDeleteFlagOnStaleReferenceFailsClosedBeforeSelectSideEffect() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
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
            #expect(result.isError == true)
            #expect(errorCode(result) == "stale_target_reference")
            // The pre-delete track.select side effect must NOT have fired.
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testTrackDeleteFlagOnResolvesTargetRefToSelectIndex() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "delete",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
            #expect(await allOps(channels).contains(where: { $0.0 == "track.delete" }))
        }
    }

    @Test
    func testTrackDuplicateFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "duplicate",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "track.select") == ["index": "2"])
            #expect(await allOps(channels).contains(where: { $0.0 == "track.duplicate" }))
        }
    }

    @Test
    func testTrackMuteFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "mute",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "track.set_mute") == ["index": "2", "enabled": "true"])
        }
    }

    @Test
    func testTrackMuteFlagOffRequiresIndex() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "mute",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == true)
            #expect(errorCode(result) == "invalid_params")
            #expect(await allOps(channels).isEmpty)
        }
    }

    @Test
    func testTrackArmOnlyFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "arm_only",
                params: ["target_ref": .string(reference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "track.set_arm") == ["index": "2", "enabled": "true"])
        }
    }

    @Test
    func testTrackSetAutomationFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "set_automation",
                params: ["target_ref": .string(reference.rawValue), "mode": .string("read")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "track.set_automation") == ["index": "2", "mode": "read"])
        }
    }

    @Test
    func testTrackSetInstrumentFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "set_instrument",
                params: ["target_ref": .string(reference.rawValue), "path": .string("/x.patch")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "track.set_instrument") == ["index": "2", "path": "/x.patch"])
        }
    }

    @Test
    func testTrackRenameFlagOnResolvesTargetRefAndEchoesTrackRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (router, channels) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "rename",
                params: ["target_ref": .string(reference.rawValue), "name": .string("Sub Bass")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(sharedJSONObject(sharedToolText(result))?["track_ref"] as? String == reference.rawValue)
            #expect(await opParams(channels, "track.rename") == ["index": "2", "name": "Sub Bass"])
        }
    }

    // MARK: - Mixer dispatcher wiring

    @Test
    func testMixerSetVolumeFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "mixer.set_volume") == ["index": "2", "volume": "0.5"])
        }
    }

    @Test
    func testMixerSetVolumeFlagOffIgnoresTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: [
                    "track": .int(1),
                    "value": .double(0.5),
                    "target_ref": .string(reference.rawValue),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "mixer.set_volume") == ["index": "1", "volume": "0.5"])
        }
    }

    @Test
    func testMixerSetPanFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await MixerDispatcher.handle(
                command: "set_pan",
                params: ["target_ref": .string(reference.rawValue), "value": .double(-0.25)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "mixer.set_pan") == ["index": "2", "pan": "-0.25"])
        }
    }

    @Test
    func testMixerSetVolumeFlagOnStaleReferenceFailsClosedNoWrite() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
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
            #expect(result.isError == true)
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
    func testPluginSetParamVerifiedFlagOnResolvesTargetRef() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: verifiedParams(track: nil, targetRef: reference.rawValue),
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await opParams(channels, "plugin.set_param_verified")?["track"] == "2")
        }
    }

    @Test
    func testPluginSetParamVerifiedFlagOffForwardsTrackUnchanged() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let (registry, cache, reference) = await boundTrack(index: 2)
            let (router, channels) = await makeRouter()
            let result = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: verifiedParams(track: 3, targetRef: reference.rawValue),
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            // target_ref (pointing at 2) is ignored; explicit track 3 forwarded.
            #expect(await opParams(channels, "plugin.set_param_verified")?["track"] == "3")
        }
    }

    @Test
    func testPluginSetParamVerifiedFlagOnStaleReferenceFailsClosedNoWrite() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
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
            #expect(result.isError == true)
            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    // MARK: - #353: rebind target_ref on verified server-performed rename

    /// The core regression: renaming a track THROUGH its own target_ref must not
    /// invalidate that ref. Pre-#353 the drift check saw the new live name and
    /// failed the next same-ref op closed; the verified-success rebind keeps it.
    @Test
    func testRenameViaRefThenSecondOpViaSameRefResolves() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (registry, cache, reference) = await boundTrack(index: 2, name: "Bass")
            let (renameRouter, _) = await makeRouter()
            let renameResult = await TrackDispatcher.handle(
                command: "rename",
                params: ["target_ref": .string(reference.rawValue), "name": .string("Sub Bass")],
                router: renameRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(renameResult.isError == false)
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
            #expect(secondOp.isError == false)
            #expect(await opParams(selectChannels, "track.select") == ["index": "2"])
        }
    }

    @Test
    func testRenameViaIndexDoesNotUpdateCache() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (_, cache, _) = await boundTrack(index: 2, name: "Bass")
            let (router, _) = await makeRouter()
            let result = await TrackDispatcher.handle(
                command: "rename",
                params: ["index": .int(2), "name": .string("Sub Bass")],
                router: router,
                cache: cache
            )
            #expect(result.isError == false)
            #expect((await cache.getTracks())[2].name == "Bass")
        }
    }

    /// Regression guard for the intended fail-closed behaviour: a rename made
    /// DIRECTLY in Logic's UI (no server op, no rebind) still invalidates the
    /// ref — the server cannot prove it caused the change.
    @Test
    func testExternalRenameWithoutServerOpStillFailsClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
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
            #expect(result.isError == true)
            #expect(errorCode(result) == "stale_target_reference")
            #expect(await allOps(channels).isEmpty)
        }
    }

    /// A State B (unverified) rename must NOT rebind — identity is not proven.
    /// Once the cache reflects the (unverified) new name, the ref fails closed.
    @Test
    func testRenameStateBUnverifiedDoesNotRebind() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
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
            #expect(renameResult.isError == true)

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
            #expect(secondOp.isError == true)
            #expect(errorCode(secondOp) == "stale_target_reference")
            #expect(await allOps(selectChannels).isEmpty)
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
