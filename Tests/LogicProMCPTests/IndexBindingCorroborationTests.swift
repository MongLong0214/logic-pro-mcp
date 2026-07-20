import Foundation
import MCP
import Testing

@testable import LogicProMCP

// PRD-007 (ADR-002 #285) — index-binding ratchet.
//
// The `.corroborated` tier closes the wrong-target window on the INDEX path of
// irreversible / topology-mutating ops. Before this ratchet, `tracks.delete`
// with a bare `index` wrote to whatever row happened to sit at that ordinal —
// an out-of-band reorder between the caller's read and its write silently
// destroyed the wrong track, with a State A claiming success.
//
// The contract under test, for a seed-set op called WITHOUT `target_ref`:
//   - no `expected_name`               -> index_binding_corroboration_required
//   - `expected_name` != live name     -> target_identity_mismatch
//   - live header unreadable           -> target_identity_mismatch (header_unreadable)
//   - `expected_name` matches but is
//     NON-UNIQUE across the live surface -> target_name_ambiguous
//   - unique match                     -> the existing index write path, unchanged
// Every failure is pre-write and fail-closed: `write_attempted:false` AND the
// probe channels record zero routed operations.

// MARK: - Fixtures

/// Live AX header scan fixture. Mirrors `AXLogicProElements.trackNames()`'s
/// shape (`[Int: String]?`, nil == unreadable) so these tests exercise the same
/// primitive the F5/ref path uses instead of reaching into the state cache.
private func liveHeaders(_ names: [Int: String]) -> @Sendable () -> [Int: String]? {
    { names }
}

private let unreadableHeaders: @Sendable () -> [Int: String]? = { nil }

private func corroborationErrorCode(_ result: CallTool.Result) -> String? {
    sharedJSONObject(sharedToolText(result))?["error"] as? String
}

private func writeAttempted(_ result: CallTool.Result) -> Bool? {
    sharedJSONObject(sharedToolText(result))?["write_attempted"] as? Bool
}

// MARK: - tracks.delete (seed set)

@Test func testDeleteWithoutExpectedNameRequiresCorroboration() async throws {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2)],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Drums"])
    )

    #expect(result.isError!, "bare-index delete must fail closed")
    #expect(corroborationErrorCode(result) == "index_binding_corroboration_required")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)

    // Proof of no side effect: nothing was routed at all — not even the
    // `track.select` that precedes the delete.
    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.isEmpty, "corroboration must fail BEFORE any routed op")
    #expect(keyCmdOps.isEmpty, "track.delete must never be routed")
}

@Test func testDeleteCorroborationRequiredHintNamesBothRoutes() async throws {
    let router = ChannelRouter()
    await router.register(VerifiedSelectMockChannel(id: .mcu))
    await router.register(MockChannel(id: .midiKeyCommands))

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2)],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Drums"])
    )

    let object = sharedJSONObject(sharedToolText(result))
    let hint = (object?["hint"] as? String) ?? ""
    #expect(hint.contains("expected_name"), "hint must name the corroboration route, got: \(hint)")
    #expect(hint.contains("target_ref"), "hint must name the stable-ref route, got: \(hint)")
    let v1 = try #require(object?["safe_to_retry"] as? Bool)
    #expect(v1, "supplying the missing param is a safe retry")
}

@Test func testDeleteWithMismatchedExpectedNameFailsClosed() async throws {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    // The caller believes index 2 is "Drums"; the live surface says "Bass"
    // (someone reordered the tracks out of band). This is the exact wrong-target
    // deletion the ratchet exists to prevent.
    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2), "expected_name": .string("Drums")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([1: "Drums", 2: "Bass"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "target_identity_mismatch")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)

    let object = sharedJSONObject(sharedToolText(result))
    #expect(object?["expected_track_name"] as? String == "Drums")
    #expect(object?["observed_track_name"] as? String == "Bass")

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.isEmpty, "no write may be attempted on identity mismatch")
    #expect(keyCmdOps.isEmpty, "the wrong track must NOT be deleted")
}

@Test func testDeleteWithUnreadableLiveHeaderFailsClosed() async throws {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2), "expected_name": .string("Drums")],
        router: router,
        cache: StateCache(),
        liveTrackNames: unreadableHeaders
    )

    #expect(result.isError!, "an unreadable live surface must not be read as agreement")
    #expect(corroborationErrorCode(result) == "target_identity_mismatch")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)

    let object = sharedJSONObject(sharedToolText(result))
    #expect(object?["reason"] as? String == "header_unreadable")

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.isEmpty)
    #expect(keyCmdOps.isEmpty)
}

@Test func testDeleteWithAmbiguousLiveNameFailsClosed() async throws {
    // THE load-bearing case. Two tracks share a name, so (index, name) stays
    // self-consistent even after they swap positions: corroboration would PASS
    // while pointing at the wrong track. Uniqueness is therefore required, and
    // the caller is pushed to the only binding that survives a swap: target_ref.
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2), "expected_name": .string("Gtr")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Gtr", 5: "Gtr"])
    )

    #expect(result.isError!, "a matching name that is not unique proves nothing")
    #expect(corroborationErrorCode(result) == "target_name_ambiguous")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)

    let object = sharedJSONObject(sharedToolText(result))
    #expect(object?["ambiguous_track_indices"] as? [Int] == [2, 5])
    let hint = (object?["hint"] as? String) ?? ""
    #expect(hint.contains("target_ref"), "ambiguity's only real escape is a stable ref, got: \(hint)")

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.isEmpty)
    #expect(keyCmdOps.isEmpty)
}

@Test func testDeleteWithUniqueMatchingNameProceeds() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2), "expected_name": .string("Drums")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([1: "Bass", 2: "Drums", 3: "Vox"])
    )

    #expect(!(result.isError!), "corroborated delete must proceed unchanged")

    // The pre-existing index write path is untouched: select-then-delete.
    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.count == 1)
    #expect(mcuOps[0].0 == "track.select")
    #expect(mcuOps[0].1 == ["index": "2"])
    #expect(keyCmdOps.count == 1)
    #expect(keyCmdOps[0].0 == "track.delete")
    // The corroboration param is a binding proof, not a write param — it must
    // not leak into the routed channel params.
    #expect(keyCmdOps[0].1["expected_name"] == nil)
}

@Test func testDeleteExpectedNameIsTrimmedBeforeComparison() async {
    let router = ChannelRouter()
    await router.register(VerifiedSelectMockChannel(id: .mcu))
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2), "expected_name": .string("  Drums  ")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Drums"])
    )

    #expect(!(result.isError!), "trimmed comparison matches the F5 path's semantics")
    let keyCmdOps = await keyCmd.executedOps
    #expect(keyCmdOps.count == 1)
}

@Test func testDeleteWithBlankExpectedNameRequiresCorroboration() async {
    // A blank string is not a corroboration — it must be treated as absent
    // rather than compared (and certainly never matched against a blank header).
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(VerifiedSelectMockChannel(id: .mcu))
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2), "expected_name": .string("   ")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "   "])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "index_binding_corroboration_required")
    let keyCmdOps = await keyCmd.executedOps
    #expect(keyCmdOps.isEmpty)
}

// MARK: - tracks.duplicate / tracks.set_instrument (seed set)

@Test func testDuplicateWithoutExpectedNameRequiresCorroboration() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "duplicate",
        params: ["index": .int(3)],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([3: "Keys"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "index_binding_corroboration_required")
    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.isEmpty)
    #expect(keyCmdOps.isEmpty)
}

@Test func testDuplicateWithUniqueMatchingNameProceeds() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "duplicate",
        params: ["index": .int(4), "expected_name": .string("Keys")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([4: "Keys"])
    )

    #expect(!(result.isError!))
    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.count == 1)
    #expect(mcuOps[0].0 == "track.select")
    #expect(keyCmdOps.count == 1)
    #expect(keyCmdOps[0].0 == "track.duplicate")
}

@Test func testDuplicateWithMismatchedExpectedNameFailsClosed() async throws {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(VerifiedSelectMockChannel(id: .mcu))
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "duplicate",
        params: ["index": .int(4), "expected_name": .string("Keys")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([4: "Strings"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "target_identity_mismatch")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)
    let keyCmdOps = await keyCmd.executedOps
    #expect(keyCmdOps.isEmpty)
}

@Test func testSetInstrumentWithoutExpectedNameRequiresCorroboration() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "set_instrument",
        params: ["index": .int(1), "path": .string("Piano/Grand")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([1: "Piano"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "index_binding_corroboration_required")
    let axOps = await ax.executedOps
    #expect(axOps.isEmpty, "the patch load must never reach the router")
}

@Test func testSetInstrumentWithMismatchedExpectedNameFailsClosed() async throws {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "set_instrument",
        params: [
            "index": .int(1),
            "path": .string("Piano/Grand"),
            "expected_name": .string("Piano"),
        ],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([1: "Lead Synth"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "target_identity_mismatch")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)
    let axOps = await ax.executedOps
    #expect(axOps.isEmpty, "the wrong track's instrument must NOT be replaced")
}

@Test func testSetInstrumentWithUniqueMatchingNameProceeds() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    _ = await TrackDispatcher.handle(
        command: "set_instrument",
        params: [
            "index": .int(1),
            "path": .string("Piano/Grand"),
            "expected_name": .string("Piano"),
        ],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([0: "Drums", 1: "Piano"])
    )

    let axOps = await ax.executedOps
    #expect(axOps.count == 1, "corroborated set_instrument must reach the router")
    guard axOps.count == 1 else { return }
    #expect(axOps[0].0 == "track.set_instrument")
    #expect(axOps[0].1["index"] == "1")
    #expect(axOps[0].1["path"] == "Piano/Grand")
    #expect(axOps[0].1["expected_name"] == nil, "binding proof must not leak into write params")
}

// MARK: - plugins.insert_verified (seed set — dispatcher-level, P2-2)

// insert_verified is `.corroborated` too, but its guard lives on a different
// call site (PluginsDispatcher, pre verified-op-gate) with its own live-scan
// seam, so it gets its own dispatcher-level proof rather than riding the track
// suite. `plugin.insert_verified` routes to `.accessibility`; a MockChannel
// there records whether any AX write was attempted.

@Test func testInsertVerifiedWithoutExpectedNameRequiresCorroboration() async throws {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await PluginsDispatcher.handle(
        command: "insert_verified",
        params: [
            "track": .int(2),
            "insert": .int(0),
            "plugin": .string("Gain"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string("/tmp/p.logicx"),
        ],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Bass"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "index_binding_corroboration_required")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)
    // The guard precedes the verified-op gate AND the router — nothing routed.
    let axOps = await ax.executedOps
    #expect(axOps.isEmpty, "corroboration must fail before the AX insert is attempted")
}

@Test func testInsertVerifiedWithMismatchedExpectedNameFailsClosed() async throws {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    // Caller believes track 2 is "Bass"; the live surface says "Lead".
    let result = await PluginsDispatcher.handle(
        command: "insert_verified",
        params: [
            "track": .int(2),
            "insert": .int(0),
            "plugin": .string("Gain"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string("/tmp/p.logicx"),
            "expected_name": .string("Bass"),
        ],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([1: "Bass", 2: "Lead"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "target_identity_mismatch")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)

    let object = sharedJSONObject(sharedToolText(result))
    #expect(object?["expected_track_name"] as? String == "Bass")
    #expect(object?["observed_track_name"] as? String == "Lead")

    let axOps = await ax.executedOps
    #expect(axOps.isEmpty, "the wrong track's insert chain must NOT be mutated")
}

@Test func testInsertVerifiedWithAmbiguousLiveNameFailsClosed() async throws {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await PluginsDispatcher.handle(
        command: "insert_verified",
        params: [
            "track": .int(2),
            "insert": .int(0),
            "plugin": .string("Gain"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string("/tmp/p.logicx"),
            "expected_name": .string("Gtr"),
        ],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Gtr", 6: "Gtr"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "target_name_ambiguous")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)
    let object = sharedJSONObject(sharedToolText(result))
    #expect(object?["ambiguous_track_indices"] as? [Int] == [2, 6])

    let axOps = await ax.executedOps
    #expect(axOps.isEmpty)
}

@Test func testInsertVerifiedRejectsExpectedNameCombinedWithTargetRef() async throws {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await PluginsDispatcher.handle(
        command: "insert_verified",
        params: [
            "track": .int(2),
            "insert": .int(0),
            "plugin": .string("Gain"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string("/tmp/p.logicx"),
            "expected_name": .string("Bass"),
            "target_ref": .string("trk_whatever"),
        ],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Bass"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "invalid_params")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)
    let axOps = await ax.executedOps
    #expect(axOps.isEmpty)
}

// MARK: - Controls (must be unaffected by the ratchet)

@Test func testNonSeedMuteIsUnaffectedByCorroboration() async {
    // `tracks.mute` is `.legacyIndexAllowed`: a reversible toggle. The ratchet
    // must not silently widen to every target-bearing op.
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "mute",
        params: ["index": .int(2), "enabled": .bool(true)],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Drums"])
    )

    #expect(corroborationErrorCode(result) != "index_binding_corroboration_required")
    let axOps = await ax.executedOps
    #expect(axOps.count == 1, "legacy index path stays open for reversible ops")
    guard axOps.count == 1 else { return }
    #expect(axOps[0].0 == "track.set_mute")
}

@Test func testNonSeedRenameIsUnaffectedByCorroboration() async {
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility)
    await router.register(ax)

    let result = await TrackDispatcher.handle(
        command: "rename",
        params: ["index": .int(2), "name": .string("New Name")],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Drums"])
    )

    #expect(corroborationErrorCode(result) != "index_binding_corroboration_required")
    let axOps = await ax.executedOps
    #expect(!axOps.isEmpty, "rename's legacy index path must stay open")
}

@Test func testSeedOpRejectsExpectedNameCombinedWithTargetRef() async throws {
    // Documented choice: `expected_name` + `target_ref` is rejected outright
    // rather than cross-checked. The ref path already carries its own live
    // identity + ambiguity guards (F5); accepting both would stack two binding
    // proofs with two error vocabularies for one failure. Exactly one wins.
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: [
            "index": .int(2),
            "expected_name": .string("Drums"),
            "target_ref": .string("trk_whatever"),
        ],
        router: router,
        cache: StateCache(),
        liveTrackNames: liveHeaders([2: "Drums"])
    )

    #expect(result.isError!)
    #expect(corroborationErrorCode(result) == "invalid_params")
    let v1 = try #require(writeAttempted(result))
    #expect(!v1)
    let keyCmdOps = await keyCmd.executedOps
    #expect(keyCmdOps.isEmpty)
}
