import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Controlled cache fixtures exercise the public dispatcher; no host is contacted.
@Suite("Retained canonical repair plans", .serialized)
struct Issue966RetainedPlanTests {
    private func fixture(clock: RepairPlanTestClock? = nil) async throws -> (StateCache, TargetRegistry, String, String) {
        let cache = StateCache(sessionCaptureNow: { clock?.now() ?? .now })
        let registry = TargetRegistry()
        await cache.updateProject(ProjectInfo(name: "Fixture", filePath: "/tmp/Fixture.logicx"))
        await cache.updateTracks([TrackState(id: 0, name: "Original", type: .audio)])
        let result = await ProjectDispatcher.handle(command: "inspect_session", params: [
            "domains": .array([.string("tracks"), .string("strips"), .string("routing")])
        ], router: ChannelRouter(), cache: cache, targetRegistry: registry,
           cleanupAuditFileReader: .unavailable)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let snapshot = try #require(body["snapshot_id"] as? String)
        let tracks = try #require(body["tracks"] as? [String: Any])
        let rows = try #require(tracks["rows"] as? [[String: Any]])
        let reference = try #require(rows.first?["track_ref"] as? String)
        return (cache, registry, snapshot, reference)
    }

    private func policy(reference: String? = nil) -> Value {
        let targets: [Value] = reference.map { [
            .object(["handle": .string("track"), "track_ref": .string($0)])
        ] } ?? []
        return .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                        "targets": .array(targets), "roles": .array([]), "outputs": .array([])])
    }

    private func plan(_ params: [String: Value], cache: StateCache,
                      registry: TargetRegistry) async -> CallTool.Result {
        await ProjectDispatcher.handle(command: "plan_session_repair", params: params,
            router: ChannelRouter(), cache: cache, targetRegistry: registry,
            cleanupAuditFileReader: .unavailable)
    }

    @Test func emptyApprovedScopeProducesOneCanonicalNoChangePlan() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, _) = try await fixture()
            let result = await plan(["snapshot_id": .string(snapshot), "policy": policy()],
                                    cache: cache, registry: registry)
            let isError = try #require(result.isError)
            #expect(!isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["schema"] as? String == "logic_pro_mcp_session_repair_plan.v1")
            #expect(body["baseline_snapshot_id"] as? String == snapshot)
            let readOnly = try #require(body["read_only"] as? Bool)
            #expect(readOnly)
            let confirmation = try #require(body["requires_plan_confirmation"] as? Bool)
            #expect(confirmation)
            let steps = try #require(body["steps"] as? [[String: Any]])
            #expect(steps.isEmpty)
            let digest = try #require(body["digest"] as? String)
            #expect(digest.count == 64)
        }
    }

    @Test func namingPreviewUsesOriginalCaptureAndBlocksAChangedBaseline() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            await cache.updateTracks([TrackState(id: 0, name: "Changed by user", type: .audio)])
            let wanted = "Kick, \"keep literal\" 🎛️"
            let result = await plan([
                "snapshot_id": .string(snapshot), "policy": policy(reference: reference),
                "names": .array([.object(["target": .string("track"), "name": .string(wanted)])])
            ], cache: cache, registry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["baseline_snapshot_id"] as? String == snapshot)
            let steps = try #require(body["steps"] as? [[String: Any]])
            #expect(steps.count == 1)
            let step = try #require(steps.first)
            let before = try #require(step["before"] as? [String: Any])
            let after = try #require(step["after"] as? [String: Any])
            #expect(before["name"] as? String == "Original")
            #expect(after["name"] as? String == wanted)
            let executable = try #require(body["executable"] as? Bool)
            #expect(!executable)
            let reasons = try #require(body["reasons"] as? [String])
            #expect(reasons.contains("snapshot_changed"))
        }
    }

    @Test func canonicalLookupRefusesDigestTamperingAndAnotherCache() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, _) = try await fixture()
            let original = await plan(["snapshot_id": .string(snapshot), "policy": policy()],
                                      cache: cache, registry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(original)))
            let id = try #require(body["plan_id"] as? String)
            let digest = try #require(body["digest"] as? String)
            let retrieved = await plan(["plan_id": .string(id), "digest": .string(digest)],
                                      cache: cache, registry: registry)
            #expect(sharedToolText(retrieved) == sharedToolText(original))
            for (destination, suppliedDigest) in [(cache, String(repeating: "0", count: 64)),
                                                   (StateCache(), digest)] {
                let refused = await plan(["plan_id": .string(id), "digest": .string(suppliedDigest)],
                                         cache: destination, registry: registry)
                let isError = try #require(refused.isError)
                #expect(isError)
                let failure = try #require(sharedJSONObject(sharedToolText(refused)))
                let attempted = try #require(failure["write_attempted"] as? Bool)
                #expect(!attempted)
                #expect(!failure.keys.contains("steps"))
            }
        }
    }

    @Test func aCreativeCompositionSchemaCannotSupplyRepairIntent() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, _) = try await fixture()
            let result = await plan(["snapshot_id": .string(snapshot), "policy": .object([
                "schema": .string("logic_pro_mcp_composition_plan.v1")
            ])], cache: cache, registry: registry)
            let isError = try #require(result.isError)
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "invalid_params")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
            #expect(!body.keys.contains("plan_id"))
        }
    }
    @Test func previewAndDigestBindTheActualCanonicalValues() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            let params: [String: Value] = ["snapshot_id": .string(snapshot),
                "policy": policy(reference: reference), "names": .array([
                    .object(["target": .string("track"), "name": .string("Renamed")])])]
            let original = await plan(params, cache: cache, registry: registry)
            var value = try JSONDecoder().decode(Value.self, from: Data(sharedToolText(original).utf8))
            guard case .object(var fields) = value else { Issue.record("missing plan"); return }
            #expect(fields["steps"] == fields["preview"])
            let digest = try #require(fields.removeValue(forKey: "digest")?.stringValue)
            let id = try #require(fields.removeValue(forKey: "plan_id")?.stringValue)
            value = .object(fields)
            let content = try encodeJSONStrict(value, compact: true)
            let calculated = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == calculated)
            let repeated = await plan(params, cache: cache, registry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(repeated)))
            #expect(body["digest"] as? String == digest)
            #expect(body["plan_id"] as? String != id)
            let executable = try #require(body["executable"] as? Bool)
            #expect(!executable)
            let reasons = try #require(body["reasons"] as? [String])
            #expect(reasons.contains("naming_preservation_adapter_unavailable"))
            #expect(!reasons.contains("target_not_in_snapshot"))
            let inspection = try #require(await cache.retainedInspection(id: snapshot))
            let track = try #require(inspection.capture.tracks.first)
            #expect(track.liveIdentityBacked)
        }
    }

    @Test func invalidLaterNameAndUnknownParametersRefuseTheWholeDraft() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            for extra: [String: Value] in [
                ["names": .array([.object(["target": .string("track"), "name": .string("Good")]),
                                  .object(["target": .string("unknown"), "name": .string("Bad")])])],
                ["create_track": .bool(true)], ["names": .array([.object([
                    "target": .string("track"), "name": .string("")])])]
            ] {
                var params: [String: Value] = ["snapshot_id": .string(snapshot), "policy": policy(reference: reference)]
                params.merge(extra) { _, new in new }
                let refused = await plan(params, cache: cache, registry: registry)
                let isError = try #require(refused.isError)
                #expect(isError)
                let body = try #require(sharedJSONObject(sharedToolText(refused)))
                #expect(!body.keys.contains("plan_id"))
                #expect(!body.keys.contains("steps"))
                let attempted = try #require(body["write_attempted"] as? Bool)
                #expect(!attempted)
            }
        }
    }

    @Test func planLookupDoesNotExtendItsBaselineLifetime() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let clock = RepairPlanTestClock()
            let (cache, registry, snapshot, _) = try await fixture(clock: clock)
            clock.advance(.seconds(50))
            let original = await plan(["snapshot_id": .string(snapshot), "policy": policy()], cache: cache, registry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(original)))
            let id = try #require(body["plan_id"] as? String)
            clock.advance(.seconds(9))
            let retrieved = await plan(["plan_id": .string(id)], cache: cache, registry: registry)
            #expect(sharedToolText(retrieved) == sharedToolText(original))
            clock.advance(.seconds(1))
            let expired = await plan(["plan_id": .string(id)], cache: cache, registry: registry)
            let isError = try #require(expired.isError)
            #expect(isError)
            let failure = try #require(sharedJSONObject(sharedToolText(expired)))
            #expect(failure["error"] as? String == "stale_snapshot")
            #expect(!failure.keys.contains("plan_id"))
        }
    }

    @Test func sourceEvictionAndProjectChangeInvalidateRetainedPlans() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            for changeProject in [false, true] {
                let (cache, registry, snapshot, _) = try await fixture()
                let original = await plan(["snapshot_id": .string(snapshot), "policy": policy()], cache: cache, registry: registry)
                let body = try #require(sharedJSONObject(sharedToolText(original)))
                let id = try #require(body["plan_id"] as? String)
                if changeProject {
                    await cache.updateProject(ProjectInfo(name: "Other", filePath: "/tmp/Other.logicx"))
                } else {
                    for _ in 0..<StateCache.sessionCaptureLimit {
                        _ = await ProjectDispatcher.handle(command: "inspect_session", params: [:],
                            router: ChannelRouter(), cache: cache, targetRegistry: registry,
                            cleanupAuditFileReader: .unavailable)
                    }
                }
                let refused = await plan(["plan_id": .string(id)], cache: cache, registry: registry)
                let isError = try #require(refused.isError)
                #expect(isError)
                let failure = try #require(sharedJSONObject(sharedToolText(refused)))
                #expect(failure["error"] as? String == "stale_snapshot")
                #expect(!failure.keys.contains("plan_id"))
            }
        }
    }

    @Test func approvedWhitespaceIsPreservedAndChangesTheCanonicalDigest() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            func parameters(_ name: String) -> [String: Value] {
                ["snapshot_id": .string(snapshot), "policy": policy(reference: reference),
                 "names": .array([.object(["target": .string("track"), "name": .string(name)])])]
            }
            let unchanged = await plan(parameters("Original"), cache: cache, registry: registry)
            let unchangedBody = try #require(sharedJSONObject(sharedToolText(unchanged)))
            let wanted = " Original "
            let changed = await plan(parameters(wanted), cache: cache, registry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(changed)))
            let steps = try #require(body["steps"] as? [[String: Any]])
            #expect(steps.count == 1)
            let approved = try #require(body["approved_names"] as? [[String: Any]])
            #expect(approved.first?["name"] as? String == wanted)
            let digest = try #require(body["digest"] as? String)
            let unchangedDigest = try #require(unchangedBody["digest"] as? String)
            #expect(digest != unchangedDigest)
            let executable = try #require(body["executable"] as? Bool)
            #expect(!executable)
        }
    }

    @Test func invalidRawLaterNameRefusesAValidEarlierTask() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            let inputPolicy: Value = .object([
                "schema": .string(ProjectSessionAudit.intentPolicySchema),
                "targets": .array([
                    .object(["handle": .string("track"), "track_ref": .string(reference)]),
                    .object(["handle": .string("later"), "track_ref": .string("trk_unobserved_later")])]),
                "roles": .array([]), "outputs": .array([])])
            let result = await plan(["snapshot_id": .string(snapshot), "policy": inputPolicy,
                "names": .array([
                    .object(["target": .string("track"), "name": .string("Valid first name")]),
                    .object(["target": .string("later"), "name": .string(" " + String(repeating: "x", count: 128))])])],
                cache: cache, registry: registry)
            let isError = try #require(result.isError)
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "invalid_params")
            #expect(!body.keys.contains("plan_id"))
            #expect(!body.keys.contains("steps"))
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
        }
    }

    @Test func ninthPlanEvictsOnlyTheOldestPlanWithoutEvictingItsCapture() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, _) = try await fixture(clock: RepairPlanTestClock())
            var plans: [(String, String)] = []
            for _ in 0...StateCache.sessionCaptureLimit {
                let result = await plan(["snapshot_id": .string(snapshot), "policy": policy()], cache: cache, registry: registry)
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                plans.append((try #require(body["plan_id"] as? String), sharedToolText(result)))
            }
            let oldest = try #require(plans.first)
            let evicted = await plan(["plan_id": .string(oldest.0)], cache: cache, registry: registry)
            let isError = try #require(evicted.isError)
            #expect(isError)
            let next = plans[1]
            let preserved = await plan(["plan_id": .string(next.0)], cache: cache, registry: registry)
            #expect(sharedToolText(preserved) == next.1)
            let inspection = try #require(await cache.retainedInspection(id: snapshot))
            #expect(inspection.capture.captureID == snapshot)
        }
    }

    @Test func oversizedCanonicalPreviewRefusesWithoutEvictingAValidPlan() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            let original = await plan(["snapshot_id": .string(snapshot), "policy": policy()], cache: cache, registry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(original)))
            let id = try #require(body["plan_id"] as? String)
            // A prefix-valid unknown reference is accounted for as blocked. Its original
            // bytes recur in policy, steps and preview, exercising the plan limit itself.
            let handle = "track"
            let largeReference = "trk_" + String(repeating: "r", count: 800_000)
            let input: [String: Value] = ["snapshot_id": .string(snapshot),
                "policy": .object(["schema": .string(ProjectSessionAudit.intentPolicySchema),
                    "targets": .array([.object(["handle": .string(handle), "track_ref": .string(largeReference)])]),
                    "roles": .array([]), "outputs": .array([])]),
                "names": .array([.object(["target": .string(handle), "name": .string("Renamed")])])]
            let encoded = try encodeJSONStrict(Value.object(input), compact: true)
            #expect(encoded.utf8.count < StateCache.sessionCaptureByteLimit)
            let refused = await plan(input, cache: cache, registry: registry)
            let isError = try #require(refused.isError)
            #expect(isError)
            let failure = try #require(sharedJSONObject(sharedToolText(refused)))
            #expect(failure["error"] as? String == "stale_snapshot")
            #expect(!failure.keys.contains("plan_id"))
            let attempted = try #require(failure["write_attempted"] as? Bool)
            #expect(!attempted)
            let preserved = await plan(["plan_id": .string(id)], cache: cache, registry: registry)
            #expect(sharedToolText(preserved) == sharedToolText(original))
        }
    }

}

private final class RepairPlanTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
