import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Controlled cache fixtures exercise the public dispatcher; no host is contacted.
@Suite("Retained canonical repair plans", .serialized)
struct Issue966RetainedPlanTests {
    private func fixture(clock: RepairPlanTestClock? = nil, initialName: String = "Original") async throws -> (StateCache, TargetRegistry, String, String) {
        let cache = StateCache(sessionCaptureNow: { clock?.now() ?? .now })
        let registry = TargetRegistry()
        await cache.updateProject(ProjectInfo(name: "Fixture", filePath: "/tmp/Fixture.logicx"))
        await cache.updateTracks([TrackState(id: 0, name: initialName, type: .audio)])
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

    @Test func byteDistinctUnicodeNamesRemainBlockedTasks() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            for (observed, wanted) in [("\u{00E9}", "e\u{0301}"), ("e\u{0301}", "\u{00E9}")] {
                let (cache, registry, snapshot, reference) = try await fixture(initialName: observed)
                let result = await plan([
                    "snapshot_id": .string(snapshot), "policy": policy(reference: reference),
                    "names": .array([.object(["target": .string("track"), "name": .string(wanted)])])
                ], cache: cache, registry: registry)
                let body = try #require(sharedJSONObject(sharedToolText(result)))
                let executable = try #require(body["executable"] as? Bool)
                #expect(!executable)
                let unchanged = try #require(body["unchanged_tasks"] as? [String])
                #expect(!unchanged.contains("name_track"))
                let steps = try #require(body["steps"] as? [[String: Any]])
                #expect(steps.count == 1)
                let step = try #require(steps.first)
                let before = try #require(step["before"] as? [String: Any])
                let after = try #require(step["after"] as? [String: Any])
                let beforeName = try #require(before["name"] as? String)
                let afterName = try #require(after["name"] as? String)
                #expect(beforeName.utf8.elementsEqual(observed.utf8))
                #expect(afterName.utf8.elementsEqual(wanted.utf8))
                let blocked = try #require(step["blocked_reasons"] as? [String])
                #expect(blocked.contains("naming_preservation_adapter_unavailable"))
            }
        }
    }

    @Test func byteIdenticalUnicodeNameRemainsANoChangeTask() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let observed = "e\u{0301}"
            let (cache, registry, snapshot, reference) = try await fixture(initialName: observed)
            let result = await plan([
                "snapshot_id": .string(snapshot), "policy": policy(reference: reference),
                "names": .array([.object(["target": .string("track"), "name": .string(observed)])])
            ], cache: cache, registry: registry)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let steps = try #require(body["steps"] as? [[String: Any]])
            #expect(steps.isEmpty)
            let unchanged = try #require(body["unchanged_tasks"] as? [String])
            #expect(unchanged.contains("name_track"))
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

    // MARK: - #1073 RF-001: a matching name over an unreadable row is not an unchanged task

    private func inspect(_ domains: [String], cache: StateCache,
                         registry: TargetRegistry) async throws -> [String: Any] {
        let result = await ProjectDispatcher.handle(command: "inspect_session", params: [
            "domains": .array(domains.map(Value.string))
        ], router: ChannelRouter(), cache: cache, targetRegistry: registry,
           cleanupAuditFileReader: .unavailable)
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    /// The plan body, whether `name_track` is an unchanged task, and its step when it is not.
    private func namePlan(snapshot: String, reference: String, name: String, cache: StateCache,
                          registry: TargetRegistry) async throws -> ([String: Any], Bool, [String: Any]?) {
        let result = await plan([
            "snapshot_id": .string(snapshot), "policy": policy(reference: reference),
            "names": .array([.object(["target": .string("track"), "name": .string(name)])])
        ], cache: cache, registry: registry)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let unchanged = try #require(body["unchanged_tasks"] as? [String])
        let steps = try #require(body["steps"] as? [[String: Any]])
        return (body, unchanged.contains("name_track"), steps.first { $0["id"] as? String == "name_track" })
    }

    /// The same capture with its track read `seconds` older than its end, under a new identity.
    private func aged(_ c: SessionPopulationObservation.Capture,
                      by seconds: TimeInterval) -> SessionPopulationObservation.Capture {
        SessionPopulationObservation.Capture(
            before: c.before, after: c.after, projectEpoch: c.projectEpoch, project: c.project,
            tracks: c.tracks, tracksFetchedAt: c.endedAt.addingTimeInterval(-seconds),
            channelStrips: c.channelStrips, mixerFetchedAt: c.mixerFetchedAt,
            fileTrackCount: c.fileTrackCount, projectFileNotBound: c.projectFileNotBound,
            requestedProjectMatches: c.requestedProjectMatches, referencesEnabled: c.referencesEnabled,
            targetSnapshot: c.targetSnapshot, issued: c.issued, projectIssuance: c.projectIssuance,
            beganAt: c.beganAt, endedAt: c.endedAt)
    }

    private func reportTrackReasons(_ inspection: StateCache.RetainedInspection) throws -> [String] {
        let report = SessionPopulationObservation.build(request: inspection.request, capture: inspection.capture)
        let body = try #require(sharedJSONObject(encodeJSONStrict(report, compact: true)))
        let tracks = try #require(body["tracks"] as? [String: Any])
        return try #require(tracks["reasons"] as? [String])
    }

    @Test func aStaleTrackReadMatchingTheApprovedNameStaysABlockedTask() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            // Control: the same name over the fresh read is an unchanged task.
            let (_, controlUnchanged, controlStep) = try await namePlan(
                snapshot: snapshot, reference: reference, name: "Original", cache: cache, registry: registry)
            #expect(controlUnchanged)
            #expect(controlStep == nil)

            let fresh = try #require(await cache.retainedInspection(id: snapshot))
            let old = aged(fresh.capture, by: ProjectSessionAudit.staleThresholdSeconds + 1)
            let staleReport = SessionPopulationObservation.build(request: fresh.request, capture: old)
            let retained = await cache.retainSessionReport(
                id: old.captureID, json: try encodeJSONStrict(staleReport, compact: true),
                capturedEpoch: old.projectEpoch, capturedPath: old.project.filePath,
                capture: old, request: fresh.request)
            try #require(retained)
            // The inspection itself says the rows are stale; the plan must not read past it.
            let staleInspection = try #require(await cache.retainedInspection(id: old.captureID))
            #expect(try reportTrackReasons(staleInspection).contains("track_cache_stale"))

            let (body, unchanged, maybeStep) = try await namePlan(
                snapshot: old.captureID, reference: reference, name: "Original", cache: cache, registry: registry)
            #expect(!unchanged)
            let step = try #require(maybeStep)
            // The seam: the stale row was located and read, so only the reason can block it.
            let before = try #require(step["before"] as? [String: Any])
            #expect(before["name"] as? String == "Original")
            let blocked = try #require(step["blocked_reasons"] as? [String])
            #expect(blocked.contains("track_cache_stale"))
            let executable = try #require(body["executable"] as? Bool)
            #expect(!executable)
        }
    }

    @Test func anOccludedTrackReadMatchingTheApprovedNameStaysABlockedTask() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            let (_, controlUnchanged, _) = try await namePlan(
                snapshot: snapshot, reference: reference, name: "Original", cache: cache, registry: registry)
            #expect(controlUnchanged)

            await cache.updateAXOccluded(true)
            let body = try await inspect(["tracks", "strips", "routing"], cache: cache, registry: registry)
            let occluded = try #require(body["snapshot_id"] as? String)
            let tracks = try #require(body["tracks"] as? [String: Any])
            let reasons = try #require(tracks["reasons"] as? [String])
            #expect(reasons.contains("ax_occluded"))
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            let occludedReference = try #require(rows.first?["track_ref"] as? String)

            let (_, unchanged, maybeStep) = try await namePlan(
                snapshot: occluded, reference: occludedReference, name: "Original", cache: cache, registry: registry)
            #expect(!unchanged)
            let step = try #require(maybeStep)
            let before = try #require(step["before"] as? [String: Any])
            #expect(before["name"] as? String == "Original")
            let blocked = try #require(step["blocked_reasons"] as? [String])
            #expect(blocked.contains("ax_occluded"))
        }
    }

    @Test func anUnrequestedTrackDomainMatchingTheApprovedNameStaysABlockedTask() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, reference) = try await fixture()
            let (_, controlUnchanged, _) = try await namePlan(
                snapshot: snapshot, reference: reference, name: "Original", cache: cache, registry: registry)
            #expect(controlUnchanged)

            let body = try await inspect(["strips", "routing"], cache: cache, registry: registry)
            let partial = try #require(body["snapshot_id"] as? String)
            let (_, unchanged, maybeStep) = try await namePlan(
                snapshot: partial, reference: reference, name: "Original", cache: cache, registry: registry)
            #expect(!unchanged)
            let step = try #require(maybeStep)
            let before = try #require(step["before"] as? [String: Any])
            #expect(before["name"] as? String == "Original")
            let blocked = try #require(step["blocked_reasons"] as? [String])
            #expect(blocked.contains("tracks_not_requested"))
        }
    }

    /// Over a stale read and an occluded one, the planner blocks on that reason and on no track
    /// reason the report does not also give for the same capture: it invents none. The converse is
    /// not checked. `build` and `trackRowReadbackReasons` still decide row validity separately, so
    /// a row reason added to the report alone passes here while the planner reads past it.
    @Test func thePlannersRowReasonsAreASubsetOfTheReportsTrackReasons() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, snapshot, _) = try await fixture()
            let fresh = try #require(await cache.retainedInspection(id: snapshot))
            #expect(SessionPopulationObservation.trackRowReadbackReasons(capture: fresh.capture).isEmpty)
            let old = StateCache.RetainedInspection(
                capture: aged(fresh.capture, by: ProjectSessionAudit.staleThresholdSeconds + 1),
                request: fresh.request, expiresAt: fresh.expiresAt)
            await cache.updateAXOccluded(true)
            let body = try await inspect(["tracks", "strips", "routing"], cache: cache, registry: registry)
            let occludedID = try #require(body["snapshot_id"] as? String)
            let occluded = try #require(await cache.retainedInspection(id: occludedID))
            for (inspection, expected) in [(old, "track_cache_stale"), (occluded, "ax_occluded")] {
                let helper = SessionPopulationObservation.trackRowReadbackReasons(capture: inspection.capture)
                    .map(\.rawValue)
                #expect(helper.contains(expected))
                #expect(Set(helper).isSubset(of: Set(try reportTrackReasons(inspection))))
            }
        }
    }

}

private final class RepairPlanTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

/// #1073 RF-002: the planner probe the qualification sweep sends, driven through the dispatcher and
/// classified by the live gate. Each step is the sweep's own: a cache-only `inspect_session` seed
/// with no parameters, `probeParams`, the planner, and the independent readback.
@Suite("Planner qualification probe over a seeded inspection", .serialized)
struct Issue966PlannerProbeWitnessTests {
    private func planner() throws -> OperationSpec {
        try #require(OperationRegistry.specs.first { $0.id == .projectPlanSessionRepair })
    }

    private func cache(filePath: String?) async -> (StateCache, TargetRegistry) {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Fixture", filePath: filePath))
        await cache.updateTracks([TrackState(id: 0, name: "Original", type: .audio)])
        return (cache, TargetRegistry())
    }

    private func seed(_ cache: StateCache, _ registry: TargetRegistry) async throws -> String {
        let result = await ProjectDispatcher.handle(command: "inspect_session", params: [:],
            router: ChannelRouter(), cache: cache, targetRegistry: registry,
            cleanupAuditFileReader: .unavailable)
        let isError = try #require(result.isError)
        #expect(!isError)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let id = try #require(body["snapshot_id"] as? String)
        try #require(!id.isEmpty)
        return id
    }

    private func probe(_ cache: StateCache, _ registry: TargetRegistry,
                       handle: String?) async throws -> QualificationOperationResult {
        let spec = try planner()
        let raw = QualificationTransport.probeParams(for: spec, traceID: "trace", sessionSnapshotID: handle)
        let params = try JSONDecoder().decode([String: Value].self,
                                              from: JSONSerialization.data(withJSONObject: raw))
        let result = await ProjectDispatcher.handle(command: spec.command, params: params,
            router: ChannelRouter(), cache: cache, targetRegistry: registry,
            cleanupAuditFileReader: .unavailable)
        let text = sharedToolText(result)
        let typed = sharedJSONObject(text)
        let source = QualificationTransport.readbackSource(for: spec)
        let readback = try await ResourceHandlers.read(uri: source, cache: cache, router: ChannelRouter(),
            targetRegistry: registry, fileReader: .unavailable)
        return QualificationOperationResult(
            operationID: spec.id.rawValue, tool: spec.tool.rawValue, command: spec.command,
            mutability: spec.mutability, requestID: "2", responseData: Data(text.utf8),
            isError: result.isError, state: typed?["state"] as? String,
            error: typed?["error"] as? String, hint: typed?["hint"] as? String,
            writeAttempted: typed?["write_attempted"] as? Bool, readbackSource: source,
            readbackRequestID: "3", readbackData: Data(sharedResourceText(readback).utf8),
            verification: spec.verification, deadline: spec.deadline, failureReason: nil)
    }

    @Test func aSavedProjectsSeededPlannerProbePassesTheLiveGate() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry) = await cache(filePath: "/tmp/Fixture.logicx")
            // Control, same run: the probe the sweep sent before the seed plans nothing.
            let unseeded = try await probe(cache, registry, handle: nil)
            #expect(unseeded.error == "invalid_params")
            #expect(unseeded.liveGateDisposition == .failed)

            let seeded = try await probe(cache, registry, handle: try await seed(cache, registry))
            let isError = try #require(seeded.isError)
            #expect(!isError)
            let response = try #require(seeded.responseData)
            let readback = try #require(seeded.readbackData)
            let oracle = try #require(SemanticOracleTable.byOperationID[.projectPlanSessionRepair])
            let verdict = try #require(oracle.evaluate(responseData: response, readbackData: readback))
            #expect(verdict)
            #expect(seeded.status == .passed)
            #expect(seeded.liveGateDisposition == .passed)
            let summary = QualificationLiveGateSummary(operationResults: [unseeded, seeded])
            #expect(summary.inScopePassed == 1)
            #expect(summary.failures.map(\.operationID) == [seeded.operationID])
        }
    }

    @Test func anUnsavedProjectsPlannerRefusalIsAnEnvironmentalPrerequisite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (unsaved, unsavedRegistry) = await cache(filePath: nil)
            let refused = try await probe(unsaved, unsavedRegistry, handle: try await seed(unsaved, unsavedRegistry))
            #expect(refused.error == "stale_snapshot")
            #expect(refused.hint == ProjectDispatcher.planSessionRepairUnboundProjectHint)
            #expect(refused.liveGateUnmetEnvironmentalPrecondition
                == "requires a project saved to a file, so its session inspection is retained")
            #expect(refused.liveGateDisposition == .environmentalPrecondition)
            #expect(refused.status != .passed)

            // Controls, same run: a saved project's unknown handle is the generic refusal, which
            // stays a failure, and so does the unseeded probe over the unsaved project.
            let (saved, savedRegistry) = await cache(filePath: "/tmp/Fixture.logicx")
            _ = try await seed(saved, savedRegistry)
            let unknown = try await probe(saved, savedRegistry, handle: "snap_unknown")
            #expect(unknown.error == "stale_snapshot")
            #expect(unknown.hint != ProjectDispatcher.planSessionRepairUnboundProjectHint)
            #expect(unknown.liveGateDisposition == .failed)
            let unseeded = try await probe(unsaved, unsavedRegistry, handle: nil)
            #expect(unseeded.liveGateDisposition == .failed)

            let summary = QualificationLiveGateSummary(operationResults: [refused])
            #expect(summary.environmentalPreconditions == [.init(operationID: refused.operationID,
                reason: "requires a project saved to a file, so its session inspection is retained")])
            #expect(summary.failures.isEmpty)
            #expect(summary.inScopePassed == 0)
        }
    }

    private static let debugExecutableURL = ProcessInfo.processInfo.environment[
        "LPMCP_TEST_DEBUG_SERVER_EXECUTABLE"
    ].map { URL(fileURLWithPath: $0) } ?? URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true
    ).appendingPathComponent(".build/debug/LogicProMCP")

    /// The inner tool text of a recorded `tools/call` response, or the arguments of its request.
    private static func frameJSON(_ frame: QualificationWireFrame) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(frame.payload.utf8)) as? [String: Any])
    }

    private static func responseText(_ frame: QualificationWireFrame) throws -> [String: Any] {
        let result = try #require(frameJSON(frame)["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        return try #require(sharedJSONObject(text))
    }

    /// The real server, driven by the sweep itself: its seed, its probe and its classification.
    /// Where no saved project is open (CI) the planner's answer is the unsaved-project
    /// prerequisite; over a saved project it is the plan. Anything else is a failure either way.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: Self.debugExecutableURL.path),
                   "Requires `swift build` (debug) before driving the real server."),
          .timeLimit(.minutes(2)))
    func theSweepSeedsTheRealServersPlannerWithItsOwnInspection() throws {
        let spec = try planner()
        let result = try QualificationTransport(requestTimeout: 30, shutdownGrace: 1).drive(.init(
            executableURL: Self.debugExecutableURL, environment: ProcessInfo.processInfo.environment,
            expectedOperationCount: OperationRegistry.specs.count, operations: [spec]))
        let operation = try #require(result.operationResults[spec.id.rawValue])

        // The seam: the seed's exchange is on the wire, and the probe sent the handle it returned.
        let seed = result.wireFrames.filter { $0.operationID == "session_inspection_seed" }
        #expect(seed.map(\.direction) == [.request, .response])
        let seedResponse = try #require(seed.last)
        let seededID = try #require(Self.responseText(seedResponse)["snapshot_id"] as? String)
        let probe = result.wireFrames.filter {
            $0.operationID == "operation_probe.\(spec.id.rawValue)" && $0.direction == .request
        }
        #expect(probe.count == 1)
        let request = try #require(probe.first)
        let params = try #require(Self.frameJSON(request)["params"] as? [String: Any])
        let arguments = try #require(params["arguments"] as? [String: Any])
        let sent = try #require(arguments["params"] as? [String: Any])
        #expect(sent["snapshot_id"] as? String == seededID)

        switch operation.liveGateDisposition {
        case .passed:
            #expect(operation.status == .passed)
        case .environmentalPrecondition:
            #expect(operation.hint == ProjectDispatcher.planSessionRepairUnboundProjectHint)
        default:
            Issue.record("planner probe was \(operation.liveGateDisposition.rawValue): \(operation.liveGateFailureReason ?? "no reason")")
        }
    }
}
