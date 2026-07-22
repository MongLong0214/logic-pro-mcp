@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// logic_plugins.insert_verified — live validation gates (R7 / AC5 / AC17 / AC19 /
// AC21) followed by the live exact-slot popup insert path. The
// deterministic gates (mode/path/identity/inventory/slot-empty)
// fail closed BEFORE the live-write boundary; once every gate passes, the op
// drives an injected insert driver and maps its post-insert readback to:
//   - State A  ONLY when the requested plugin is observed at the requested slot
//   - State C  post_insert_readback_unavailable (readback subtree unreadable)
//   - State C  insert_not_ax_automatable (every strategy ran, plugin never mounted)
//   - State C  post_insert_plugin_mismatch (driver reports a mount elsewhere)
// The post-insert readback gate is the SOLE State A path → a false verified
// insert is structurally impossible. The production driver
// (liveExactSlotPopupInsert) is exercised live; here we inject a fake so the
// gate→outcome→envelope mapping is deterministic without a running Logic Pro.

private let expectedPath = "/Users/me/Music/MySong copy.logicx"

private func addEmptySlot(_ b: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
    let el = b.element(id)
    b.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(el, kAXDescriptionAttribute as String, "오디오 플러그인")
    b.setAttribute(el, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
    return el
}

private func addOccupiedSlot(_ b: FakeAXRuntimeBuilder, _ id: Int, name: String?) -> AXUIElement {
    let group = b.element(id)
    let bypass = b.element(id * 10 + 1)
    let open = b.element(id * 10 + 2)
    b.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
    if let name { b.setAttribute(group, kAXDescriptionAttribute as String, name) }
    b.setChildren(group, [bypass, open])
    b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
    b.setAttribute(bypass, kAXValueAttribute as String, 0)
    b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
    return group
}

private func addMenu(_ b: FakeAXRuntimeBuilder, _ id: Int, children: [AXUIElement] = []) -> AXUIElement {
    let menu = b.element(id)
    b.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
    b.setChildren(menu, children)
    return menu
}

private func addMenuItem(
    _ b: FakeAXRuntimeBuilder,
    _ id: Int,
    title: String,
    children: [AXUIElement] = []
) -> AXUIElement {
    let item = b.element(id)
    b.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
    b.setAttribute(item, kAXTitleAttribute as String, title)
    b.setChildren(item, children)
    return item
}

private func makeMixerFixture(
    _ b: FakeAXRuntimeBuilder,
    stripChildren: (FakeAXRuntimeBuilder) -> [AXUIElement]
) -> AXLogicProElements.Runtime {
    let app = b.element(900)
    let window = b.element(901)
    let mixer = b.element(902)
    let strip = b.element(903)
    b.setAttribute(app, kAXMainWindowAttribute as String, window)
    b.setChildren(window, [mixer])
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    b.setChildren(mixer, [strip])
    b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(strip, stripChildren(b))
    return b.makeLogicRuntime(appElement: app)
}

/// A driver that records its inputs and returns a canned outcome. Used to verify
/// the gate→outcome→envelope mapping without driving any live UI. The driver is
/// invoked at most once per test (sequentially, under --no-parallel), so plain
/// mutable recording is race-free here; `@unchecked Sendable` documents that.
private final class FakeInsertDriver: @unchecked Sendable {
    private(set) var invoked = false
    private(set) var lastTrack: Int?
    private(set) var lastInsert: Int?
    private(set) var lastPluginID: String?
    private(set) var lastQuery: String?
    private let outcome: AccessibilityChannel.InsertDriverOutcome
    private let trace: [String: Any]

    init(
        outcome: AccessibilityChannel.InsertDriverOutcome,
        trace: [String: Any] = ["fake": true]
    ) {
        self.outcome = outcome
        self.trace = trace
    }

    var driver: AccessibilityChannel.PluginInsertDriver {
        { track, insert, pluginID, query, _ in
            self.invoked = true
            self.lastTrack = track
            self.lastInsert = insert
            self.lastPluginID = pluginID
            self.lastQuery = query
            return (self.outcome, self.trace)
        }
    }
}

/// A driver that fails the test if ever invoked — used to assert that a gate
/// short-circuits BEFORE the live-write boundary.
private let neverCalledDriver: AccessibilityChannel.PluginInsertDriver = { _, _, _, _, _ in
    Issue.record("insert driver must not run when a gate fails closed")
    return (.mountMismatch(observedName: nil), [:])
}

/// Deterministic fake rollback so the gate's rollback reporting is hermetic (no
/// live Logic / AppleScript). Defaults to a confirmed-removal result.
private func fakeRollback(
    attempted: Bool = true, succeeded: Bool = true, retries: Int = 0
) -> AccessibilityChannel.PluginInsertRollback {
    { _, _, _, _ in
        AccessibilityChannel.RollbackResult(
            attempted: attempted, succeeded: succeeded, retries: retries, lastClickResult: "ok"
        )
    }
}

/// Counts how many times the injected undo-click ran (P1-2 re-undo guard test).
/// Invoked sequentially under --no-parallel, so plain mutation is race-free here.
private final class ClickCounter: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
}

private func runInsert(
    _ params: [String: String],
    runtime: AXLogicProElements.Runtime,
    frontDoc: String? = expectedPath,
    driver: @escaping AccessibilityChannel.PluginInsertDriver = neverCalledDriver,
    rollback: @escaping AccessibilityChannel.PluginInsertRollback = fakeRollback()
) async -> [String: Any] {
    let result = await AccessibilityChannel.defaultInsertVerified(
        params: params, runtime: runtime, frontDocumentPath: { frontDoc },
        insertDriver: driver, rollback: rollback
    )
    return try! JSONSerialization.jsonObject(with: result.message.data(using: .utf8)!) as! [String: Any]
}

private func insertParams(
    track: String = "0", insert: String = "0",
    plugin: String = "Gain", mode: String = "duplicate_applyback",
    path: String? = expectedPath
) -> [String: String] {
    var p = ["track": track, "insert": insert, "plugin": plugin, "mode": mode]
    if let path { p["project_expected_path"] = path }
    return p
}

// MARK: - State A: post-insert readback confirms the requested plugin at slot K

@Test func testInsertVerifiedStateAWhenReadbackConfirmsMount() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 940)] }
    let fake = FakeInsertDriver(
        outcome: .mounted(slot: 0, pluginID: "logic.stock.effect.gain", observedName: "Gain"),
        trace: ["winning_strategy": "row_double_click"]
    )
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)

    #expect(obj["state"] as? String == "A")
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(obj["observed_plugin_id"] as? String == "logic.stock.effect.gain")
    #expect(obj["observed_plugin_name"] as? String == "Gain")
    #expect(obj["observed_slot"] as? Int == 0)
    #expect(obj["write_source"] as? String == "ax_exact_slot_popup")
    #expect(obj["verify_source"] as? String == "ax_plugin_inventory")
    let trace = obj["select_trace"] as? [String: Any]
    #expect(trace?["winning_strategy"] as? String == "row_double_click")
    let identity = obj["target_identity"] as? [String: Any]
    #expect(identity?["track_index"] as? Int == 0)
    #expect(identity?["insert"] as? Int == 0)
    #expect(identity?["plugin_id"] as? String == "logic.stock.effect.gain")
    // The driver received the canonical id + display-name search query.
    #expect(fake.invoked)
    #expect(fake.lastPluginID == "logic.stock.effect.gain")
    #expect(fake.lastQuery == "Gain")
    #expect(fake.lastInsert == 0)
}

@Test func testSlotPopupAnchorMustBeNearTargetSlotBeforeCommit() {
    let b = FakeAXRuntimeBuilder()
    let slot = addEmptySlot(b, 8000)
    b.setAttribute(slot, kAXPositionAttribute as String, axPoint(400, 300))
    b.setAttribute(slot, kAXSizeAttribute as String, axSize(70, 18))

    let nearMenu = addMenu(b, 8010)
    b.setAttribute(nearMenu, kAXPositionAttribute as String, axPoint(390, 280))
    b.setAttribute(nearMenu, kAXSizeAttribute as String, axSize(240, 420))

    let farMenu = addMenu(b, 8020)
    b.setAttribute(farMenu, kAXPositionAttribute as String, axPoint(30, 30))
    b.setAttribute(farMenu, kAXSizeAttribute as String, axSize(240, 420))

    let runtime = b.makeAXRuntime()
    #expect(AccessibilityChannel.slotPopupMenuIsAnchored(nearMenu, toSlot: slot, runtime: runtime))
    #expect(!AccessibilityChannel.slotPopupMenuIsAnchored(farMenu, toSlot: slot, runtime: runtime))
}

@Test func testPopupExactLeafDiscoveryDoesNotDependOnLocalizedCategoryNames() {
    let b = FakeAXRuntimeBuilder()
    let gain = addMenuItem(b, 8110, title: "Gain")
    let localizedCategoryMenu = addMenu(b, 8111, children: [gain])
    let localizedCategory = addMenuItem(b, 8112, title: "Dienstprogramme", children: [localizedCategoryMenu])
    let root = addMenu(b, 8113, children: [localizedCategory])

    let paths = AccessibilityChannel.popupExactLeafPaths(
        displayName: "Gain", rootMenu: root, runtime: b.makeAXRuntime()
    )

    #expect(paths.map { $0.joined(separator: " > ") } == ["Dienstprogramme > Gain"])
}

@Test func testPopupExactLeafDiscoveryPrefersDirectRootRecentItem() {
    let b = FakeAXRuntimeBuilder()
    let directGain = addMenuItem(b, 8120, title: "Gain")
    let nestedGain = addMenuItem(b, 8121, title: "Gain")
    let localizedCategoryMenu = addMenu(b, 8122, children: [nestedGain])
    let localizedCategory = addMenuItem(b, 8123, title: "Utilitaires", children: [localizedCategoryMenu])
    let root = addMenu(b, 8124, children: [directGain, localizedCategory])

    let path = AccessibilityChannel.preferredPopupExactLeafPath(
        displayName: "Gain", rootMenu: root, runtime: b.makeAXRuntime()
    )

    #expect(path == ["Gain"])
}

// MARK: - State C: readback subtree unreadable after the insert

@Test func testInsertVerifiedReadbackUnavailableIsStateC() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 941)] }
    let fake = FakeInsertDriver(outcome: .readbackUnavailable)
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "post_insert_readback_unavailable")
    #expect(!((obj["verified"] as? Bool)!))
    #expect((obj["write_attempted"] as? Bool)!)
    #expect((obj["safe_to_retry"] as? Bool)!)
    #expect(obj["select_trace"] != nil)
}

// MARK: - State C: transient pre-mount setup failure is retry-able (P2-3)

@Test func testInsertVerifiedTransientSetupFailureIsRetryable() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 942)] }
    // The driver reports a transient UI-setup failure (e.g. the search dialog was
    // not ready) — this is distinct from the permanent insert_not_ax_automatable
    // and must be retry-able with no write attempted.
    let fake = FakeInsertDriver(outcome: .transientSetupFailure(stage: "search_field_not_found"))
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "insert_setup_failed")
    #expect(obj["setup_stage"] as? String == "search_field_not_found")
    #expect((obj["safe_to_retry"] as? Bool)!)
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testInsertVerifiedPostCommitTimeoutIsStateC() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 942)] }
    // The live driver stops after a strategy appears to dismiss/commit the dialog
    // but readback never observes the requested plugin. This prevents stale
    // stale clicks after a popup/menu commit changed the UI.
    let fake = FakeInsertDriver(outcome: .postCommitTimeout(strategy: "slot_popup_physical_menu_click"))
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "operation_timeout")
    #expect(obj["commit_strategy"] as? String == "slot_popup_physical_menu_click")
    #expect((obj["safe_to_retry"] as? Bool)!)
    #expect((obj["write_attempted"] as? Bool)!)
}

@Test func testInsertVerifiedRollbackFailedAbortsStateC() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 942)] }
    // A stray mount that cannot be rolled back is terminal: the driver must not
    // keep trying fallback strategies and later report State A with residue left
    // in the project.
    let rollback = AccessibilityChannel.RollbackResult(
        attempted: true, succeeded: false, retries: 2, lastClickResult: "ok"
    )
    let fake = FakeInsertDriver(
        outcome: .rollbackFailed(
            slot: 3,
            pluginID: nil,
            observedName: "Third Party FX",
            rollback: rollback
        )
    )
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "rollback_failed")
    #expect(obj["observed_slot"] as? Int == 3)
    #expect(obj["observed_plugin_name"] as? String == "Third Party FX")
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect(!((obj["rollback_succeeded"] as? Bool)!))
    #expect(obj["rollback_retries"] as? Int == 2)
    #expect((obj["write_attempted"] as? Bool)!)
    #expect(obj["recovery_action"] != nil)
}

// MARK: - State C: every strategy ran, requested plugin never mounted

@Test func testInsertVerifiedMountMismatchIsHonestStateC() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 942)] }
    let fake = FakeInsertDriver(outcome: .mountMismatch(observedName: nil))
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "insert_not_ax_automatable")
    #expect((obj["write_attempted"] as? Bool)!)
    #expect(!((obj["safe_to_retry"] as? Bool)!))
    #expect(((obj["what_was_observed"] as? String)?.contains("exact slot popup"))!)
}

@Test func testInsertVerifiedMountMismatchReportsObservedName() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 943)] }
    // A different plugin lingered in the slot after rollback failed.
    let fake = FakeInsertDriver(outcome: .mountMismatch(observedName: "Channel EQ"))
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)
    #expect(obj["error"] as? String == "insert_not_ax_automatable")
    #expect(obj["observed_plugin_name"] as? String == "Channel EQ")
}

// MARK: - State C: driver reports a mount of the WRONG plugin → plugin mismatch

@Test func testInsertVerifiedDriverWrongPluginIsPluginMismatch() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 944)] }
    // The driver observed a DIFFERENT plugin mount than requested (Gain asked,
    // Compressor appeared) — identity mismatch is post_insert_plugin_mismatch.
    let fake = FakeInsertDriver(
        outcome: .mounted(slot: 0, pluginID: "logic.stock.effect.compressor", observedName: "Compressor")
    )
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "post_insert_plugin_mismatch")
    #expect(obj["observed_plugin_id"] as? String == "logic.stock.effect.compressor")
    #expect((obj["write_attempted"] as? Bool)!)
}

// MARK: - insert:K honesty — wrong-slot readback still fails closed

@Test func testInsertVerifiedLandedAtDifferentSlotFailsClosed() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 945)] }
    // Requested insert 0, but the insert driver reported the correct plugin at
    // slot 6 — fail closed with insert_landed_at_different_slot + observed_slot,
    // never a false "verified at 0". The (faked) rollback confirmed removal.
    let fake = FakeInsertDriver(
        outcome: .mounted(slot: 6, pluginID: "logic.stock.effect.gain", observedName: "Gain")
    )
    let obj = await runInsert(
        insertParams(insert: "0"), runtime: runtime, driver: fake.driver,
        rollback: fakeRollback(attempted: true, succeeded: true, retries: 1)
    )
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "insert_landed_at_different_slot")
    #expect(obj["observed_slot"] as? Int == 6)
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect((obj["rollback_succeeded"] as? Bool)!)
    #expect(obj["rollback_retries"] as? Int == 1)
    #expect((obj["write_attempted"] as? Bool)!)
}

@Test func testInsertVerifiedLandedAtDifferentSlotReportsRollbackFailureHonestly() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 945)] }
    // The rollback could not confirm removal — the channel must report it
    // honestly (rollback_succeeded:false), never claim a clean rollback.
    let fake = FakeInsertDriver(
        outcome: .mounted(slot: 6, pluginID: "logic.stock.effect.gain", observedName: "Gain")
    )
    let obj = await runInsert(
        insertParams(insert: "0"), runtime: runtime, driver: fake.driver,
        rollback: fakeRollback(attempted: true, succeeded: false, retries: 4)
    )
    #expect(obj["error"] as? String == "insert_landed_at_different_slot")
    #expect((obj["rollback_attempted"] as? Bool)!)
    #expect(!((obj["rollback_succeeded"] as? Bool)!))
}

@Test func testInsertVerifiedNonFirstFreeRequestStillDrivesInsert() async {
    let b = FakeAXRuntimeBuilder()
    // slot 0 empty, slot 1 empty; requesting insert 1 is no longer pre-rejected —
    // The insert driver runs for any empty readable slot; the gate compares the
    // observed slot against the requested one.
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 945), addEmptySlot(b, 946)] }
    let fake = FakeInsertDriver(
        outcome: .mounted(slot: 1, pluginID: "logic.stock.effect.gain", observedName: "Gain")
    )
    let obj = await runInsert(insertParams(insert: "1"), runtime: runtime, driver: fake.driver)
    #expect(obj["state"] as? String == "A", "driver-detected slot 1 matches requested insert 1")
    #expect(fake.invoked)
    #expect(fake.lastInsert == 1)
}

@Test func testInsertVerifiedFirstFreeSlotProceedsToDriver() async {
    let b = FakeAXRuntimeBuilder()
    // slot 0 occupied, slot 1 empty; requesting insert 1 is OK.
    let runtime = makeMixerFixture(b) { b in
        [addOccupiedSlot(b, 947, name: "Compressor"), addEmptySlot(b, 948)]
    }
    let fake = FakeInsertDriver(
        outcome: .mounted(slot: 1, pluginID: "logic.stock.effect.gain", observedName: "Gain")
    )
    let obj = await runInsert(insertParams(insert: "1"), runtime: runtime, driver: fake.driver)
    #expect(obj["state"] as? String == "A")
    #expect(fake.invoked)
    #expect(fake.lastInsert == 1)
}

// MARK: - AC5: occupied slot refusal (gate fails BEFORE the live-write boundary)

@Test func testInsertVerifiedRefusesOccupiedSlot() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in
        [addEmptySlot(b, 910), addOccupiedSlot(b, 911, name: "Compressor")]
    }
    // insert 1 is occupied → slot_occupied, no silent replace.
    let obj = await runInsert(insertParams(insert: "1"), runtime: runtime)
    #expect(obj["error"] as? String == "slot_occupied")
    #expect(!((obj["write_attempted"] as? Bool)!))
    #expect((obj["target_identity"] as? [String: Any])?["plugin_id"] as? String == "logic.stock.effect.gain")
    // The slot was never pressed — the gate refuses before any UI mutation.
    #expect(b.actionCalls.isEmpty)
}

// MARK: - AC21: occupied-unreadable slot is never write-safe

@Test func testInsertVerifiedRefusesOccupiedUnreadableSlot() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in
        [addOccupiedSlot(b, 920, name: nil)] // occupied-unreadable
    }
    // An occupied-unreadable slot makes the whole snapshot incomplete, so the
    // op is refused with incomplete_inventory BEFORE the slot-occupied check —
    // either way it is never treated as empty/overwritten (AC21 / R3).
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime)
    let error = obj["error"] as? String
    #expect(error == "incomplete_inventory" || error == "slot_occupied",
            "an occupied-unreadable slot is never write-safe")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - incomplete inventory refusal (R3)

@Test func testInsertVerifiedRefusesIncompleteInventory() async {
    let b = FakeAXRuntimeBuilder()
    // target slot 0 is empty, but slot 1 is unreadable → complete:false →
    // incomplete_inventory even though the target itself is readable (fail-closed).
    let runtime = makeMixerFixture(b) { b in
        [addEmptySlot(b, 930), addOccupiedSlot(b, 931, name: nil)]
    }
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime)
    #expect(obj["error"] as? String == "incomplete_inventory")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testVerifiedDiffSnapshotRefusesUnreadableSlots() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in
        [addEmptySlot(b, 932), addOccupiedSlot(b, 933, name: nil)]
    }

    let snapshot = AccessibilityChannel.fullStripInventory(track: 0, runtime: runtime)
    #expect(snapshot == nil, "verified insert diff must not treat unreadable existing slots as newly mounted later")
}

// MARK: - mode / path / identity gates (still fail closed before the driver)

@Test func testInsertVerifiedConfirmedLiveBlocked() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 950)] }
    let obj = await runInsert(insertParams(mode: "confirmed_live"), runtime: runtime)
    #expect(obj["error"] as? String == "unsupported_mode")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testInsertVerifiedMissingPathBlocked() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 960)] }
    let obj = await runInsert(insertParams(path: nil), runtime: runtime)
    #expect(obj["error"] as? String == "project_path_required")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testInsertVerifiedPathMismatchBlocked() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 965)] }
    // Front document path disagrees with project_expected_path → identity gate.
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime,
                              frontDoc: "/Users/me/Music/Other.logicx")
    #expect(obj["error"] as? String == "project_identity_mismatch")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testInsertVerifiedNoiseGateNotInsertable() async {
    // Noise Gate is identity-only, excluded from the insertable allowlist (R5).
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 970)] }
    let obj = await runInsert(insertParams(plugin: "Noise Gate"), runtime: runtime)
    #expect(obj["error"] as? String == "unknown_plugin_identity")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

@Test func testInsertVerifiedUnknownIdentityBlocked() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 980)] }
    let obj = await runInsert(insertParams(plugin: "com.apple.logic.gain"), runtime: runtime)
    #expect(obj["error"] as? String == "unknown_plugin_identity")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - Compressor also routes through the driver (not plugin-specific)

@Test func testInsertVerifiedCompressorReachesStateAViaDriver() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 990)] }
    let fake = FakeInsertDriver(
        outcome: .mounted(slot: 0, pluginID: "logic.stock.effect.compressor", observedName: "Compressor")
    )
    let obj = await runInsert(insertParams(insert: "0", plugin: "Compressor"), runtime: runtime, driver: fake.driver)
    #expect(obj["state"] as? String == "A")
    #expect((obj["target_identity"] as? [String: Any])?["plugin_id"] as? String == "logic.stock.effect.compressor")
    #expect(fake.lastQuery == "Compressor")
}

// MARK: - verifiedUndoPluginInsert removal-confirmation honesty (P2 Issue 2)
// Hermetic: an injected `undoClick` (no live AppleScript) + a fake inventory.

@Test func testVerifiedUndoUnverifiableStrayNeverReportsSuccess() async {
    // A non-allowlisted stray mounted (plugin_id resolves to nil) and was reported
    // with NEITHER an id NOR a slot — removal is structurally unverifiable, so the
    // rollback must NOT claim success (the pre-fix code returned succeeded:true).
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in
        [addOccupiedSlot(b, 700, name: "Roland TR-909")] // non-allowlisted → pluginID nil
    }
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0, strayPluginID: nil, straySlot: nil, runtime: runtime,
        maxRetries: 2, undoClick: { "ok" }
    )
    #expect(!(result.succeeded), "unverifiable removal must never report succeeded:true")
}

@Test func testVerifiedUndoKnownSlotStillOccupiedReportsFailure() async {
    // Known slot, unknown id: the slot is STILL occupied after undo → not removed.
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in
        [addOccupiedSlot(b, 710, name: "Roland TR-909")]
    }
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0, strayPluginID: nil, straySlot: 0, runtime: runtime,
        maxRetries: 1, undoClick: { "ok" }
    )
    #expect(!(result.succeeded), "a slot still occupied after undo is not a confirmed removal")
}

@Test func testVerifiedUndoKnownSlotNowEmptyReportsSuccess() async {
    // Known slot, now empty after undo → confirmed removal → succeeded:true.
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 720)] } // slot 0 empty
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0, strayPluginID: nil, straySlot: 0, runtime: runtime,
        maxRetries: 1, undoClick: { "ok" }
    )
    #expect(result.succeeded, "an emptied slot is a confirmed removal")
    #expect(result.attempted)
}

@Test func testVerifiedUndoKnownIdRemovedReportsSuccess() async {
    // Known id (allowlisted Gain), absent everywhere after undo → confirmed gone.
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 730)] } // no Gain present
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0, strayPluginID: "logic.stock.effect.gain", straySlot: nil, runtime: runtime,
        maxRetries: 1, undoClick: { "ok" }
    )
    #expect(result.succeeded)
}

// P1-1: a non-allowlisted stray (nil id) is removable by NAME at its known slot.
@Test func testVerifiedUndoNilIdStrayRemovedByNameReportsSuccess() async {
    // Slot 0 now holds a DIFFERENT name than the stray → confirmed removed by name.
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addOccupiedSlot(b, 740, name: "Compressor")] }
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0, strayPluginID: nil, straySlot: 0, strayName: "Roland TR-909",
        runtime: runtime, maxRetries: 1, undoClick: { "ok" }
    )
    #expect(result.succeeded, "slot name differs from the stray → removal confirmed by name (P1-1)")
}

// P1-2 data-safety: an UNVERIFIABLE state must NOT trigger a second Undo click
// (a blind retry could undo a prior user action).
@Test func testVerifiedUndoUnverifiableDoesNotReUndo() async {
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in [addEmptySlot(b, 750)] }
    let counter = ClickCounter()
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0, strayPluginID: nil, straySlot: nil, runtime: runtime,
        maxRetries: 4, undoClick: { counter.bump(); return "ok" }
    )
    #expect(!(result.succeeded))
    #expect(counter.count == 1, "unverifiable removal must click Undo at most once (no blind re-undo)")
}

// MARK: - #234 zero-slot slot-addressing diagnostics (AC-5)

@Test func testInsertVerifiedZeroSlotsStateCDistinctDiagnostics() async {
    // A zero-slot (Master-shaped) strip through the insert slot-addressing guard.
    // Pre-#234 this reported the bare "slot 0 is out of range (0 slots)"; now the
    // observation names the real condition (insert_section_not_enumerable
    // semantics) and carries the recovery hint. Still State C with its existing
    // invalid_params code — writes never soften to State B — and no write is
    // attempted (the gate fails closed before the live-write boundary).
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in masterShapedStripChildren(b, base: 970) }
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "invalid_params")
    #expect(!((obj["write_attempted"] as? Bool)!))
    let observed = (obj["what_was_observed"] as? String) ?? ""
    #expect(observed.contains("no enumerable insert slots"))
    let hint = (obj["recovery_hint"] as? String) ?? ""
    #expect(hint.contains("Master"))
}

@Test func testLegacyInsertPluginZeroSlotsHint() async {
    // Legacy logic_mixer.insert_plugin against a zero-slot strip keeps its
    // element_not_found code and visible_slots:0 field, but its hint now names the
    // insert-section-not-enumerable condition instead of the generic out-of-range
    // message (AC-5). The gate fails before menu selection.
    let b = FakeAXRuntimeBuilder()
    let runtime = makeMixerFixture(b) { b in masterShapedStripChildren(b, base: 980) }
    let result = await AccessibilityChannel.defaultInsertPlugin(
        params: ["track": "0", "slot": "0", "plugin_name": "Gain"],
        runtime: runtime,
        selectPlugin: { _, _, _ in
            Issue.record("a zero-slot strip must fail before menu selection")
            return true
        }
    )
    #expect(!result.isSuccess)
    let obj = try! JSONSerialization.jsonObject(with: result.message.data(using: .utf8)!) as! [String: Any]
    #expect(obj["error"] as? String == "element_not_found")
    #expect(obj["visible_slots"] as? Int == 0)
    #expect(b.actionCalls.isEmpty)
    let hint = (obj["hint"] as? String) ?? ""
    #expect(hint.contains("no enumerable insert slots"))
}

// MARK: - #425 (Option B): coordinate-free leaf selection contract
//
// The four assertions below pin the contract for promoting the leaf SELECTION
// to coordinate-free-by-default (kill-switch: insertCoordFree).
// They exercise the real leaf-select seam (`clickPopupPluginLeaf` /
// `clickPluginInAnchoredSlotPopup`) directly rather than through
// `defaultInsertVerified`, because the insert-entry tests above inject a fake
// driver that REPLACES the entire live path (so they never reach leaf-select),
// and the full `liveExactSlotPopupInsert` flow is CGEvent-bound (the slot-open
// at ~L1897 requires a real coordinate click). The coordinate leaf primitives
// (moveElementCenter/clickElementCenter) short-circuit to `false` when an
// element has no on-screen geometry, BEFORE posting any CGEvent, so these
// hermetic tests never move the physical mouse. `clickPopupPluginLeaf` /
// `clickPluginInAnchoredSlotPopup` / `SlotPopupPluginClick` were relaxed from
// `private` to `internal` solely so this contract is unit-testable.

/// Records which elements received a `kAXPress` when the default action-
/// recording is bypassed by an injected `performActionHandler` (contract C).
/// Invoked sequentially within one test (awaited), so plain mutation is
/// race-free here; `@unchecked Sendable` documents that.
private final class AXPressRecorder: @unchecked Sendable {
    private(set) var pressedElementIDs: [Int] = []
    func record(_ id: Int) { pressedElementIDs.append(id) }
}

/// A plugin menu item whose format submenu is exposed as an AX child (as Logic
/// exposes it without a hover) with a single preferred-format leaf ("Stereo").
private func addPluginItemWithFormatLeaf(
    _ b: FakeAXRuntimeBuilder,
    itemID: Int,
    title: String,
    formatLeafTitle: String = "Stereo"
) -> (item: AXUIElement, formatLeaf: AXUIElement) {
    let formatLeaf = addMenuItem(b, itemID * 10 + 1, title: formatLeafTitle)
    let submenu = addMenu(b, itemID * 10 + 2, children: [formatLeaf])
    let item = addMenuItem(b, itemID, title: title, children: [submenu])
    return (item, formatLeaf)
}

// Contract A (mechanism): coordFree:true selects the matched leaf via kAXPress.
@Test func test425ContractA_coordFreeTruePressesMatchedLeafViaAXPress() async {
    let b = FakeAXRuntimeBuilder()
    let (gain, formatLeaf) = addPluginItemWithFormatLeaf(b, itemID: 8210, title: "Gain")

    let ok = await AccessibilityChannel.clickPopupPluginLeaf(
        gain, runtime: b.makeAXRuntime(), coordFree: true
    )

    #expect(ok)
    let pressAction = kAXPressAction as String
    let leafID = b.elementID(formatLeaf)
    // The preferred-format leaf was AXPressed …
    #expect(b.actionCalls.contains { $0.elementID == leafID && $0.action == pressAction })
    // … and NOTHING else happened via a non-AXPress action (no coordinate path).
    #expect(b.actionCalls.allSatisfy { $0.action == pressAction })
}

// Contract A (discriminator): a coord-free DIRECT win reports coordFree == true.
// `SlotPopupPluginClick.coordFree` is the exact value the production flow assigns
// to `select_trace["leaf_select_coord_free"]` (liveExactSlotPopupInsert ~L1933),
// so asserting it here asserts the discriminator's truth value for a coord-free
// win — and it is sourced from the winning strategy, not the raw flag.
@Test func test425ContractA_discriminatorTrueForCoordFreeDirectWin() async throws {
    let b = FakeAXRuntimeBuilder()
    let (gain, formatLeaf) = addPluginItemWithFormatLeaf(b, itemID: 8220, title: "Gain")
    let root = addMenu(b, 8229, children: [gain])
    let runtime = b.makeAXRuntime()

    let click = await FeatureFlags.withInsertCoordFree(true) {
        await AccessibilityChannel.clickPluginInAnchoredSlotPopup(
            pluginID: "logic.stock.effect.gain",
            displayName: "Gain",
            rootMenu: root,
            runtime: runtime
        )
    }

    let winner = try #require(click)
    #expect(winner.strategy == "slot_popup_direct_exact_leaf")
    #expect(winner.coordFree)
    let pressAction = kAXPressAction as String
    let leafID = b.elementID(formatLeaf)
    #expect(b.actionCalls.contains { $0.elementID == leafID && $0.action == pressAction })
}

// Contracts B & D: coordFree:false takes the COORDINATE path — never AXPress.
// This is the exact mode the recursive category-hover fallback forces (it always
// passes coordFree:false), so it also covers the "recursive is coordinate-only"
// half of contract D. Coverage gap (noted honestly): a WINNING recursive path
// cannot be produced hermetically — the recursive win requires the coordinate
// leaf click to succeed, which needs real on-screen geometry and would post a
// CGEvent (physical mouse move). So the recursive-win trace value (coordFree ==
// false while the flag is ON) is verified structurally (recursive call site +
// SlotPopupPluginClick(coordFree: false)) rather than behaviorally.
@Test func test425ContractBD_coordFreeFalseUsesCoordinateNeverAXPress() async {
    let b = FakeAXRuntimeBuilder()
    // Deliberately NO kAXPosition/kAXSize: the coordinate primitives return false
    // before posting a CGEvent, so the load-bearing assertion is the ABSENCE of
    // AXPress, proving coordFree:false does not use the coord-free press path.
    let (gain, _) = addPluginItemWithFormatLeaf(b, itemID: 8240, title: "Gain")

    let ok = await AccessibilityChannel.clickPopupPluginLeaf(
        gain, runtime: b.makeAXRuntime(), coordFree: false
    )

    #expect(!ok)
    let pressAction = kAXPressAction as String
    #expect(!b.actionCalls.contains { $0.action == pressAction })
}

// Contract C: if AXPress is neutralized, coord-free leaf select FAILS CLOSED —
// it must not silently "succeed", and it must genuinely have attempted AXPress.
@Test func test425ContractC_failsClosedWhenAXPressNeutralized() async {
    let b = FakeAXRuntimeBuilder()
    let (gain, _) = addPluginItemWithFormatLeaf(b, itemID: 8250, title: "Gain")
    let recorder = AXPressRecorder()
    let pressAction = kAXPressAction as String
    let runtime = b.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            if action == pressAction { recorder.record(b.elementID(element)) }
            return false // AXPress refused everywhere
        }
    )

    let ok = await AccessibilityChannel.clickPopupPluginLeaf(
        gain, runtime: runtime, coordFree: true
    )

    #expect(!ok)
    #expect(!recorder.pressedElementIDs.isEmpty)
}

// Contract #3 (discriminator honesty) — the DIVERGENCE case. A recursive
// (coordinate-only) win under the flag ON must report `coordFree == false`, NOT
// the flag. This is the ONLY case where the honest value diverges from the raw
// flag, so it is what makes the discriminator sourcing mutation-provable. The 4
// tests above all use a direct win with the flag on, where pluginClick.coordFree
// and FeatureFlags.insertCoordFree are BOTH true — they cannot catch a re-pin to
// the flag. This one can, driven hermetically via the DEBUG coordinate-actuation
// seam (no CGEvent / physical mouse): direct+search fail because AXPress is
// refused, so the recursive strategy wins ONLY via the coordinate path. It kills:
//   (i)   trace repinned to the flag        → leafSelectCoordFree(for:) returns false, not the flag
//   (ii)  recursive SlotPopupPluginClick(coordFree:) flipped to the flag → winner.coordFree
//   (iii) recursive clickPopupPluginLeaf(coordFree:) flipped to the flag → it would AXPress
//         (refused) → no recursive win → #require fails
@Test func test425Contract3_recursiveWinReportsCoordFreeFalseUnderFlagOn() async throws {
    let b = FakeAXRuntimeBuilder()
    // Exact-match leaf at the ROOT, no format submenu / text field / geometry.
    let gain = addMenuItem(b, 8260, title: "Gain")
    let root = addMenu(b, 8269, children: [gain])
    let pressAction = kAXPressAction as String
    let runtime = b.makeAXRuntime(
        setAttributeHandler: nil,
        // Refuse AXPress everywhere so the ONLY route to a win is the coordinate
        // path — a win therefore PROVES the recursive coordinate route executed.
        performActionHandler: { _, action in action == pressAction ? false : true }
    )

    let click = await FeatureFlags.withInsertCoordFree(true) {
        await AccessibilityChannel.withForceCoordinateActuationForTests(true) {
            await AccessibilityChannel.clickPluginInAnchoredSlotPopup(
                pluginID: "logic.stock.effect.gain",
                displayName: "Gain",
                rootMenu: root,
                runtime: runtime
            )
        }
    }

    let winner = try #require(click)
    #expect(winner.strategy == "slot_popup_recursive_exact_leaf")
    // The divergence: flag override is true, honest path is coordinate → false.
    #expect(!winner.coordFree)
    #expect(!AccessibilityChannel.leafSelectCoordFree(for: winner))
}
