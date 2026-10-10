@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#968 exact-local physical Mixer naming adapter", .serialized)
struct Issue968ExactMixerNameAdapterTests {
    private struct Harness {
        let fixture: Issue968MixerNameWriterTests.Fixture
        let channel: AccessibilityChannel
        let cache: StateCache
        let registry: TargetRegistry
        let project: TargetReference
        let target: TargetReference

        static func make() async throws -> Harness {
            let fixture = try Issue968MixerNameWriterTests.Fixture()
            let runtime = fixture.logic
            let channel = AccessibilityChannel(runtime: .axBacked(isTrusted: { true },
                isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: runtime,
                observationMouseRuntime: fixture.mouse, canPostEvents: { true }))
            let cache = StateCache()
            let registry = TargetRegistry()
            let states = try #require(AccessibilityChannel.defaultGetMixerStates(runtime: runtime, stoppingWhen: { false }).states)
            await cache.updateProject(.init(name: "Session", filePath: fixture.source.bundle.path))
            await cache.updateChannelStrips(states)
            // Use the existing resource capture/issuer on actual typed producer
            // objects. JSON is used only to recover its already-issued refs.
            let resource = try await ResourceHandlers.readMixer(cache: cache, uri: "logic://mixer", targetRegistry: registry)
            let rows = try #require(sharedJSONObject(sharedResourceText(resource))?["strips"] as? [[String: Any]])
            let row = try #require(rows.first { $0["name"] as? String == "Aux" })
            let target = TargetReference(rawValue: try #require(row["mixer_strip_ref"] as? String))
            let snapshot = await registry.currentSnapshot
            let issued = await ProjectReferenceIssuance.issue(cached: await cache.getProject(), registry: registry, snapshot: snapshot)
            guard case .issued(let project) = issued else {
                throw NSError(domain: "actual_project_issuer_failed", code: 1)
            }
            return .init(fixture: fixture, channel: channel, cache: cache, registry: registry, project: project, target: target)
        }

        func apply(expected: String, desired: String, target: TargetReference? = nil,
                   runtime: AXLogicProElements.Runtime? = nil) async -> ExactMixerNameAdapter.Receipt {
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { fixture.authorized })
            return await OperationTraceContext.$current.withValue(context) {
                await ExactMixerNameAdapter.apply(.init(projectReference: project, targetReference: target ?? self.target,
                    expectedBefore: expected, desiredAfter: desired), channel: channel,
                    cache: cache, registry: registry, runtime: runtime ?? fixture.logic)
            }
        }

        func inverse(_ proof: ExactMixerNameAdapter.OwnedInverse) async -> ExactMixerNameAdapter.Receipt {
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { fixture.authorized })
            return await OperationTraceContext.$current.withValue(context) { await ExactMixerNameAdapter.inverse(proof) }
        }
    }

    @Test func actualIssuedAuxReferenceSurvivesTheOwnedNameAndInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let h = try await Harness.make()
            let result = await h.apply(expected: "Aux", desired: "Return, aux \"α\"")
            #expect(result.status == .applied)
            #expect(result.before == "Aux")
            #expect(result.after == "Return, aux \"α\"")
            #expect(result.survivingReference == h.target)
            #expect(result.rereadRequired)
            #expect(await h.registry.resolve(h.target)?.descriptor.trackName == "Return, aux \"α\"")
            let proof = try #require(result.inverse)
            let restored = await h.inverse(proof)
            #expect(restored.status == .applied)
            #expect(restored.after == "Aux")
            #expect(restored.survivingReference == h.target)
            #expect(await h.registry.resolve(h.target)?.descriptor.trackName == "Aux")
            #expect(AXPluginInstanceIdentity.stripName(h.fixture.source.strips[0], runtime: h.fixture.logic.ax) == "B")
            // A historical cache snapshot is not silently rewritten; the
            // receipt explicitly requires a fresh observation after the write.
            #expect(await h.cache.getChannelStrips().first { $0.name == "Aux" } != nil)
        }
    }

    @Test func anAlreadySatisfiedNameDoesNotGrantAnInverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let h = try await Harness.make()
            let result = await h.apply(expected: "Aux", desired: "Aux")
            #expect(result.status == .alreadySatisfied)
            #expect(result.inverse == nil)
            #expect(!result.rereadRequired)
            #expect(h.fixture.events.isEmpty)
        }
    }

    @Test func anOlderInverseCannotOverwriteTheNewerActualName() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let h = try await Harness.make()
            let first = await h.apply(expected: "Aux", desired: "First")
            let older = try #require(first.inverse)
            let second = await h.apply(expected: "First", desired: "Newer")
            #expect(second.status == .applied)
            let events = h.fixture.events
            let refused = await h.inverse(older)
            #expect(refused.status == .rejectedBeforeWrite)
            #expect(refused.inverse == nil)
            #expect(h.fixture.events == events)
            #expect(AXPluginInstanceIdentity.stripName(h.fixture.source.strips[2], runtime: h.fixture.logic.ax) == "Newer")
        }
    }

    @Test(arguments: ["wrong_kind", "project_epoch", "json_only", "replacement", "invalid_name", "wrong_expected", "cache_project"])
    func preflightRefusesWithoutAnyNativeGesture(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let h = try await Harness.make()
            var target = h.target
            switch change {
            case "wrong_kind":
                let d = TargetDescriptor(trackIndex: 0, trackName: "Aux")
                target = await h.registry.bind(kind: .track, descriptor: d, fingerprint: d.fingerprint)
            case "project_epoch": await h.registry.bumpProjectEpoch()
            case "json_only":
                let states = await h.cache.getChannelStrips()
                let decoded = try JSONDecoder().decode([ChannelStripState].self, from: JSONEncoder().encode(states))
                await h.cache.updateChannelStrips(decoded)
            case "replacement":
                let replacement = h.fixture.source.b.element(968_507)
                h.fixture.source.b.setRole(replacement, "AXLayoutItem")
                h.fixture.source.b.setChildren(replacement, h.fixture.originalChildren)
                h.fixture.source.b.setChildren(h.fixture.source.mixer, [h.fixture.source.strips[0], h.fixture.source.strips[1], replacement])
            case "cache_project": await h.cache.updateProject(.init(name: "Other", filePath: "/tmp/other.logicx"))
            default: break
            }
            let result = await h.apply(expected: change == "wrong_expected" ? "Other" : "Aux",
                desired: change == "invalid_name" ? "Bad\u{0000}" : "Changed", target: target)
            #expect(result.status == .rejectedBeforeWrite)
            #expect(result.inverse == nil)
            #expect(h.fixture.events.isEmpty)
        }
    }

    @Test(arguments: ["ack_only", "lost_editor", "authority_lost"])
    func anAttemptWithoutCommittedReadbackCannotGrantAnInverse(change: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let h = try await Harness.make()
            if change == "ack_only" { h.fixture.acknowledgeOnly = true }
            if change == "lost_editor" {
                h.fixture.afterValueSet = { h.fixture.source.b.setChildren(h.fixture.source.strips[2], h.fixture.originalChildren) }
            }
            if change == "authority_lost" { h.fixture.afterEditorAcquisition = { h.fixture.authorized = false } }
            let result = await h.apply(expected: "Aux", desired: "Changed")
            #expect(result.status == .attemptedUnverified)
            #expect(result.inverse == nil)
            #expect(!h.fixture.events.contains("commit"))
            #expect(await h.registry.resolve(h.target)?.descriptor.trackName == "Aux")
        }
    }

    @Test func lostPostWriteAuthorityDoesNotExposeTheEarlierWriterAAsCurrentSuccess() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let h = try await Harness.make()
            // Same physical fake objects, but this seam is only the adapter's
            // independent post-writer read. The actual writer completes first.
            let postRead = h.fixture.source.b.makeLogicRuntime(pid: h.fixture.source.pid, appElement: h.fixture.source.app,
                attributeValueHandler: { _, _ in
                    if h.fixture.events.contains("commit") { h.fixture.authorized = false }
                    return nil
                },
                setAttributeHandler: { _, _, _ in Issue.record("Post-read must not write"); return false },
                performActionHandler: { _, _ in Issue.record("Post-read must not act"); return false },
                executeAppleScript: { _ in Issue.record("No post-read scripting"); return .error("forbidden") })
            let result = await h.apply(expected: "Aux", desired: "Changed", runtime: postRead)
            #expect(h.fixture.events.contains("commit"))
            #expect(result.status == .attemptedUnverified)
            #expect(result.inverse == nil)
            let body = sharedJSONObject(sharedToolText(result.result))
            #expect(body?["state"] as? String == "B")
            let verified = try #require(body?["verified"] as? Bool)
            let attempted = try #require(body?["write_attempted"] as? Bool)
            #expect(!verified)
            #expect(attempted)
            #expect(body?["observed"] as? String == "Changed")
            let isError = try #require(result.result.isError)
            #expect(isError)
            #expect(result.survivingReference == nil)
            #expect(result.rereadRequired)
            #expect(AXPluginInstanceIdentity.stripName(h.fixture.source.strips[2], runtime: h.fixture.logic.ax) == "Changed")
        }
    }
}
