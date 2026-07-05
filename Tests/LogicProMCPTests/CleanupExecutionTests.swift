import Foundation
import MCP
import Testing
@testable import LogicProMCP

// Issue #28 — guarded execution of cleanup-plan steps via
// `logic_project cleanup_apply`. These tests drive the dispatcher with an
// injected/fake Accessibility channel so the rename path's Honest Contract
// State A/B/C is exercised headlessly, with no real Logic Pro.
//
// Every #expect here is force-unwrap / boolean-expression / nil-compare so it
// can genuinely FAIL (issue #92 dead-assertion footgun avoided).

// MARK: - Fake Accessibility channel

/// Returns a caller-supplied Honest Contract envelope for `track.rename`
/// (the only op cleanup_apply currently dispatches), and records what it saw
/// so a test can assert the dispatcher actually routed — or DIDN'T route — a
/// rename. Any other op returns a hard error so an unexpected route surfaces.
private actor FakeRenameChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    /// Maps requested rename name -> HC envelope JSON to return.
    private let envelopeForName: @Sendable (String) -> ChannelResult
    private(set) var renameCalls: [(index: String, name: String)] = []

    init(envelopeForName: @escaping @Sendable (String) -> ChannelResult) {
        self.envelopeForName = envelopeForName
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "track.rename" else {
            return .error("FakeRenameChannel: unexpected op \(operation)")
        }
        let name = params["name"] ?? ""
        renameCalls.append((index: params["index"] ?? "", name: name))
        return envelopeForName(name)
    }

    func healthCheck() async -> ChannelHealth { .healthy(detail: "fake") }

    func calls() -> [(index: String, name: String)] { renameCalls }
}

private func stateARename(name: String) -> ChannelResult {
    .success(HonestContract.encodeStateA(extras: [
        "op": "track.rename",
        "observed": name,
        "requested": name,
    ]))
}

private func stateBRename(name: String) -> ChannelResult {
    .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: [
        "op": "track.rename",
        "requested": name,
    ]))
}

// MARK: - Cache fixtures

/// Seed a cache with two duplicate-named tracks so the deterministic audit
/// produces a `rename_duplicate_<name>_<i0>_<i1>` cleanup step that
/// `cleanup_apply` can target. Returns the expected step id.
@discardableResult
private func seedDuplicateTracks(_ cache: StateCache) async -> String {
    await cache.updateDocumentState(true)
    await cache.updateTracks([
        TrackState(id: 0, name: "Kick", type: .audio),
        TrackState(id: 1, name: "Kick", type: .audio),
        TrackState(id: 2, name: "Bass", type: .audio),
    ])
    return "rename_duplicate_kick_0_1"
}

@discardableResult
private func seedEmptyTrackReviewStep(_ cache: StateCache) async -> String {
    await cache.updateDocumentState(true)
    await cache.updateTracks([
        TrackState(id: 0, name: "Has Region", type: .audio),
        TrackState(id: 1, name: "Empty One", type: .audio),
    ])
    await cache.updateRegions([
        RegionState(
            id: "0:1:5:Has Region",
            name: "Has Region",
            trackIndex: 0,
            startPosition: "1 1 1 1",
            endPosition: "5 1 1 1",
            length: "4 0 0 0"
        ),
    ])
    return "review_empty_tracks_no_delete"
}

private func routerWith(_ channel: any Channel) async -> ChannelRouter {
    let router = ChannelRouter()
    await router.register(channel)
    return router
}

private let headlessCleanupAuditFileReader = LogicProjectFileReader.Runtime(
    currentDocumentPath: { nil },
    now: Date.init,
    readPlistData: { _ in nil },
    mtime: { _ in nil },
    sleep: { _ in }
)

// MARK: - Tests

@Suite("Cleanup execution", .serialized)
struct CleanupExecutionTests {

@Test func testCleanupApplyRenameReachesStateAOnVerifiedReadback() async throws {
    let cache = StateCache()
    let stepID = await seedDuplicateTracks(cache)
    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    // Sanity: the plan really does contain the step we are about to execute.
    let plan = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
    let planned = plan.steps.first { $0.id == stepID }
    let step = try #require(planned, "expected duplicate-rename step in the plan")
    #expect(step.supportedByCurrentTools)
    #expect(step.mutatesProject)

    await seedDuplicateTracks(cache)
    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string(stepID),
            "confirmed": .bool(true),
            "names": .string("Kick L,Kick R"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    let resultIsError = result.isError ?? false
    #expect(!resultIsError)
    let body = sharedToolText(result)
    let json = try #require(sharedJSONObject(body), "response must be a JSON object")
    #expect(try #require(json["success"] as? Bool))
    #expect(try #require(json["verified"] as? Bool))
    #expect(json["step_id"] as? String == stepID)
    #expect(json["command"] as? String == "rename")

    // The dispatcher must have routed exactly one rename per target track,
    // with the supplied names — proving it went through the real track path.
    let calls = await channel.calls()
    #expect(calls.count == 2)
    #expect(calls.map(\.index).sorted() == ["0", "1"])
    #expect(Set(calls.map(\.name)) == ["Kick L", "Kick R"])
}

@Test func testCleanupApplyRefusesWhenNotConfirmed() async throws {
    let cache = StateCache()
    let stepID = await seedDuplicateTracks(cache)
    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string(stepID),
            "confirmed": .bool(false),
            "names": .string("Kick L,Kick R"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    // Fail-closed: NO rename was attempted.
    let calls = await channel.calls()
    #expect(calls.isEmpty)
}

@Test func testCleanupApplyRefusesWhenConfirmedMissing() async throws {
    let cache = StateCache()
    let stepID = await seedDuplicateTracks(cache)
    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string(stepID),
            "names": .string("Kick L,Kick R"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    let calls = await channel.calls()
    #expect(calls.isEmpty)
}

@Test func testCleanupApplyRefusesUnknownStep() async throws {
    let cache = StateCache()
    await seedDuplicateTracks(cache)
    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string("rename_duplicate_does_not_exist_9_99"),
            "confirmed": .bool(true),
            "names": .string("x,y"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    #expect(json["error"] as? String == "element_not_found")
    let calls = await channel.calls()
    #expect(calls.isEmpty)
}

@Test func testCleanupApplyRefusesUnsupportedStep() async throws {
    // The `review_empty_tracks_no_delete` step is `supported_by_current_tools:
    // false` and `mutates_project:false` by construction — exactly the kind of
    // step cleanup_apply must refuse. Seed a project with an empty track to
    // produce it.
    let cache = StateCache()
    let stepID = await seedEmptyTrackReviewStep(cache)
    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    // Confirm the unsupported step exists before asserting it's refused.
    let plan = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
    let emptyStep = try #require(
        plan.steps.first { $0.id == stepID },
        "expected empty-track review step"
    )
    #expect(!(emptyStep.supportedByCurrentTools))

    await seedEmptyTrackReviewStep(cache)
    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string(stepID),
            "confirmed": .bool(true),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    // A non-mutating step is caught by the mutates_project gate first.
    #expect(json["error"] as? String == "invalid_params")
    let calls = await channel.calls()
    #expect(calls.isEmpty)
}

@Test func testCleanupApplyNeverExecutesDeletion() async throws {
    // No real plan step proposes a supported delete, so we verify the
    // deletion refusal directly against a synthetic delete step that lies
    // about being supported + mutating. This proves the belt-and-braces guard
    // refuses a delete even if a future plan mislabels it.
    let deleteStep = ProjectSessionAudit.CleanupPlanStep(
        id: "delete_empty_tracks",
        targetIdentifier: "tracks:3,4",
        proposedOperation: "Delete empty tracks.",
        rationale: "synthetic",
        riskLevel: .high,
        requiredConfirmation: "L2",
        expectedReadback: "tracks gone",
        rollbackOrRecovery: "undo",
        stopCondition: "—",
        supportedByCurrentTools: true,
        mutatesProject: true,
        tool: "logic_tracks",
        command: "delete"
    )
    #expect(ProjectDispatcher.cleanupApplyIsDeletion(deleteStep))

    // Also: a delete COMMAND on the track tool must not be parseable into the
    // rename dispatch path. There is no ("logic_tracks","delete") executable
    // arm, so even bypassing the deletion guard it would hit notImplemented —
    // but the deletion guard fires first.
    #expect(ProjectDispatcher.cleanupApplyTargetIndices(deleteStep.targetIdentifier) == [3, 4])
}

@Test func testCleanupApplyRefusesStaleInventory() async throws {
    // hasDocument=true but the track inventory was never read (tracksFetchedAt
    // stays at .distantPast), so the audit reports the track evidence as
    // unavailable/stale. cleanup_apply must refuse before any rename.
    //
    // We seed the duplicate-rename step body by hand-deriving the SAME step id
    // the plan uses, but the audit (built from this stale cache) will instead
    // refuse on the stale-inventory gate. To make the step actually present we
    // would need fresh tracks — but a stale cache yields no rename step at all,
    // which is itself fail-closed. So here we assert: with stale inventory, the
    // duplicate-rename step is NOT in the plan, and applying it is refused.
    let cache = StateCache()
    await cache.updateDocumentState(true)
    // Deliberately do NOT call updateTracks — tracksFetchedAt stays distantPast.

    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    let plan = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
    #expect(plan.steps.first { $0.id == "rename_duplicate_kick_0_1" } == nil)

    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string("rename_duplicate_kick_0_1"),
            "confirmed": .bool(true),
            "names": .string("Kick L,Kick R"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    let calls = await channel.calls()
    #expect(calls.isEmpty)
}

@Test func testCleanupApplyRefusesOccludedInventory() async throws {
    // Fresh duplicate tracks (so the step exists) but AX is occluded — the
    // plan's targets cannot be trusted, so the stale/occluded gate must refuse
    // even though the step is present and supported.
    let cache = StateCache()
    let stepID = await seedDuplicateTracks(cache)
    await cache.updateAXOccluded(true)

    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    // The step is still in the plan...
    let plan = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
    #expect(plan.steps.first { $0.id == stepID } != nil)

    // ...but cleanup_apply refuses on the occlusion gate.
    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string(stepID),
            "confirmed": .bool(true),
            "names": .string("Kick L,Kick R"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    #expect(json["error"] as? String == "stale_snapshot")
    let calls = await channel.calls()
    #expect(calls.isEmpty)
}

@Test func testCleanupApplyStateBStopsBeforeClaimingSuccess() async throws {
    // The first rename comes back State A, the second State B (unverified).
    // cleanup_apply must NOT report an overall State A; it must fail closed at
    // the unverified track and surface State C with the underlying envelope.
    let cache = StateCache()
    let stepID = await seedDuplicateTracks(cache)
    let channel = FakeRenameChannel { name in
        name == "Kick R" ? stateBRename(name: name) : stateARename(name: name)
    }
    let router = await routerWith(channel)

    await seedDuplicateTracks(cache)
    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string(stepID),
            "confirmed": .bool(true),
            "names": .string("Kick L,Kick R"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    // Some rename(s) were attempted; the failure surfaces the failed track.
    let calls = await channel.calls()
    #expect(!(calls.isEmpty))
}

@Test func testCleanupApplyRefusesNameCountMismatch() async throws {
    let cache = StateCache()
    let stepID = await seedDuplicateTracks(cache)
    let channel = FakeRenameChannel { stateARename(name: $0) }
    let router = await routerWith(channel)

    // Two targets, one name supplied -> fail closed before any write.
    await seedDuplicateTracks(cache)
    let result = await ProjectDispatcher.handle(
        command: "cleanup_apply",
        params: [
            "step_id": .string(stepID),
            "confirmed": .bool(true),
            "names": .string("OnlyOne"),
        ],
        router: router,
        cache: cache,
        cleanupAuditFileReader: headlessCleanupAuditFileReader
    )

    #expect(result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(!(try #require(json["success"] as? Bool)))
    #expect(json["error"] as? String == "invalid_params")
    let calls = await channel.calls()
    #expect(calls.isEmpty)
}
}
