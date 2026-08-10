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
    children: [AXUIElement] = [],
    enabled: Bool = true
) -> AXUIElement {
    let item = b.element(id)
    b.setAttribute(item, kAXRoleAttribute as String, kAXMenuItemRole as String)
    b.setAttribute(item, kAXTitleAttribute as String, title)
    // Measured on Logic 12.3: every one of the 1090 items in an open plug-in menu exposes a readable
    // AXEnabled, and 264 of them are disabled — section headers like "Recent" among them. A fixture
    // that leaves the attribute unset models a tree Logic does not produce, and it was the reason a
    // strict pre-pick check could not be adopted.
    b.setAttribute(item, kAXEnabledAttribute as String, enabled as CFTypeRef)
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
    let fake = FakeInsertDriver(outcome: .postCommitTimeout(strategy: "slot_popup_axpick_menu_select"))
    let obj = await runInsert(insertParams(insert: "0"), runtime: runtime, driver: fake.driver)

    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "operation_timeout")
    #expect(obj["commit_strategy"] as? String == "slot_popup_axpick_menu_select")
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

// MARK: - #425: coordinate-free slot-popup navigation

private let slotPopupOpenCustomAction = AccessibilityChannel.slotPopupOpenCustomAction

@Test func testSlotPopupOpenCustomActionMatchesLiveAXMeasurement() {
    let action = AccessibilityChannel.slotPopupOpenCustomAction
    let metadataLines = action.components(separatedBy: "\n")

    #expect(action.utf8.count == 70)
    #expect(!action.hasPrefix("\""))
    #expect(!action.hasSuffix("\""))
    #expect(action.contains("\n"))
    #expect(!action.contains("\\n"))
    #expect(action.hasPrefix("Name:Open plug-in menu with legacy plug-ins"))
    #expect(metadataLines.count == 3)
    #expect(metadataLines[0] == "Name:Open plug-in menu with legacy plug-ins")
    #expect(metadataLines[1] == "Target:0x0")
    #expect(metadataLines[2] == "Selector:(null)")
}

/// Captures calls that pass through the injected AX action runtime seam. The
/// tests run sequentially, so this deliberately lightweight recorder is safe.
private final class AXActionRecorder: @unchecked Sendable {
    private(set) var calls: [(elementID: Int, action: String)] = []
    private(set) var attributeWrites: [(elementID: Int, attribute: String)] = []

    func record(elementID: Int, action: String) {
        calls.append((elementID, action))
    }

    func recordAttributeWrite(elementID: Int, attribute: String) {
        attributeWrites.append((elementID, attribute))
    }

    func contains(elementID: Int, action: String) -> Bool {
        calls.contains { $0.elementID == elementID && $0.action == action }
    }

    func count(elementID: Int, action: String) -> Int {
        calls.count { $0.elementID == elementID && $0.action == action }
    }

    func touched(elementID: Int) -> Bool {
        calls.contains { $0.elementID == elementID }
            || attributeWrites.contains { $0.elementID == elementID }
    }

    func nonTargetActionCount(targetElementID: Int) -> Int {
        calls.count { $0.elementID != targetElementID }
    }

    func nonTargetAttributeWriteCount(targetElementID: Int) -> Int {
        attributeWrites.count { $0.elementID != targetElementID }
    }
}

private final class SlotOccupier: @unchecked Sendable {
    private let performOccupancy: () -> Void

    init(_ performOccupancy: @escaping () -> Void) {
        self.performOccupancy = performOccupancy
    }

    func occupy() {
        performOccupancy()
    }
}

@Test func testPlugin425RecursiveDiscoveryReadsAttachedSubmenusWithoutActuatingThem() async throws {
    let b = FakeAXRuntimeBuilder()
    let target = addMenuItem(b, 9100, title: "Gain")
    let vendorMenu = addMenu(b, 9101, children: [target])
    let vendor = addMenuItem(b, 9102, title: "Fabricant", children: [vendorMenu])
    let categoryMenu = addMenu(b, 9103, children: [vendor])
    let category = addMenuItem(b, 9104, title: "Dienstprogramme", children: [categoryMenu])
    let searchField = b.element(9106)
    b.setAttribute(searchField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    let rootMenu = addMenu(b, 9105, children: [searchField, category])
    let actions = AXActionRecorder()
    let runtime = b.makeAXRuntime(
        setAttributeHandler: { element, attribute, _ in
            actions.recordAttributeWrite(elementID: b.elementID(element), attribute: attribute)
            return true
        },
        performActionHandler: { element, action in
            actions.record(elementID: b.elementID(element), action: action)
            return true
        }
    )

    let click = await AccessibilityChannel.clickPluginInAnchoredSlotPopup(
        pluginID: "logic.stock.effect.gain",
        displayName: "Gain",
        rootMenu: rootMenu,
        runtime: runtime
    )

    #expect(actions.nonTargetActionCount(targetElementID: b.elementID(target)) == 0)
    #expect(actions.nonTargetAttributeWriteCount(targetElementID: b.elementID(target)) == 0)
    #expect(actions.attributeWrites.isEmpty)
    let result = try #require(click)
    #expect(result.path == ["Dienstprogramme", "Fabricant", "Gain"])
    #expect(actions.count(elementID: b.elementID(target), action: kAXPickAction as String) == 1)
}

@Test func testPlugin425LeafSelectionHasNoCoordFreeStrategyDiscriminator() async throws {
    let b = FakeAXRuntimeBuilder()
    let target = addMenuItem(b, 9110, title: "Gain")
    let rootMenu = addMenu(b, 9111, children: [target])
    let click = await AccessibilityChannel.clickPluginInAnchoredSlotPopup(
        pluginID: "logic.stock.effect.gain",
        displayName: "Gain",
        rootMenu: rootMenu,
        runtime: b.makeAXRuntime()
    )

    let result = try #require(click)
    let storedPropertyNames = Mirror(reflecting: result).children.compactMap(\.label)
    #expect(!storedPropertyNames.contains("coordFree"))
}

private let coordFreeExpectedPath = "/Users/me/Music/CoordFree425 copy.logicx"

private struct SlotPopupInsertFixture {
    let runtime: AXLogicProElements.Runtime
    let slotItemID: Int
    let categoryItemID: Int?
    let nonMatchingLeafItemID: Int?
    let nonMatchingFormatLeafItemIDs: [Int]
    let formatNamedCategoryItemID: Int?
    let leafItemID: Int
    let actions: AXActionRecorder
    let slotOccupier: SlotOccupier
    let slotReplacer: SlotOccupier
    let replacementSlotID: Int
    let nonFormatSubmenuItemIDs: [Int]
    let nonTerminalFormatEntryID: Int?
    let searchFieldID: Int
    let leftoverMenuItemID: Int?
    let coordinateFallbackClick: () -> Bool
}

/// The full AX tree the real insert driver walks. The action handler models the
/// separately-observed effects of opening a popup, revealing a submenu, and
/// mounting a plugin, while its Bool return independently models AX's unreliable
/// status code.
private func makeSlotPopupInsertFixture(
    popupAppearsAfterSlotOpen: Bool = true,
    popupInitiallyVisible: Bool = false,
    slotOpenResult: Bool = true,
    includeCategory: Bool = false,
    includeNonMatchingLeaf: Bool = false,
    includeNonMatchingLeafFormatMenu: Bool = false,
    includeFormatNamedCategoryEntry: Bool = false,
    includeFormatLeaf: Bool = false,
    leafPickResult: Bool = true,
    mountGainOnLeafPick: Bool = false,
    occupySlotOnWindowRaise: Bool = false,
    includeNonFormatSubmenu: Bool = false,
    includeNonTerminalFormatEntry: Bool = false,
    leftoverNeighbourMenuVisible: Bool = false
) -> SlotPopupInsertFixture {
    let b = FakeAXRuntimeBuilder()
    let app = b.element(9000)
    let window = b.element(9001)
    let headersGroup = b.element(9002)
    let headerRow = b.element(9003)
    let mixer = b.element(9004)
    let strip = b.element(9005)
    let slot = b.element(9006)
    let popupMenu = b.element(9007)
    let gainItem = b.element(9008)
    let searchField = b.element(9009)
    let categoryItem = includeCategory ? b.element(9010) : nil
    let categoryMenu = includeCategory ? b.element(9011) : nil
    let nonMatchingLeafItem = includeNonMatchingLeaf ? b.element(9016) : nil
    let nonMatchingFormatMenu = includeNonMatchingLeafFormatMenu ? b.element(9017) : nil
    let nonMatchingFormatMono = includeNonMatchingLeafFormatMenu ? b.element(9018) : nil
    let nonMatchingFormatMonoToStereo = includeNonMatchingLeafFormatMenu ? b.element(9019) : nil
    let formatNamedCategoryItem = includeFormatNamedCategoryEntry ? b.element(9020) : nil
    let leftoverMenu = leftoverNeighbourMenuVisible ? b.element(9040) : nil
    let leftoverSearch = leftoverNeighbourMenuVisible ? b.element(9041) : nil
    let leftoverItem = leftoverNeighbourMenuVisible ? b.element(9042) : nil
    let nonTerminalFormatMenu = includeNonTerminalFormatEntry ? b.element(9034) : nil
    let nonTerminalFormatEntry = includeNonTerminalFormatEntry ? b.element(9035) : nil
    let nonTerminalFormatChild = includeNonTerminalFormatEntry ? b.element(9036) : nil
    let nonTerminalFormatChildMenu = includeNonTerminalFormatEntry ? b.element(9037) : nil
    let nonFormatSubmenu = includeNonFormatSubmenu ? b.element(9031) : nil
    let nonFormatEntryA = includeNonFormatSubmenu ? b.element(9032) : nil
    let nonFormatEntryB = includeNonFormatSubmenu ? b.element(9033) : nil
    let formatLeafItem = includeFormatLeaf ? b.element(9014) : nil
    let formatMenu = includeFormatLeaf ? b.element(9015) : nil

    // Track header rail (getTrackHeaders matches the "트랙 헤더" group), one
    // selected row so verifiedTrackSelected reads AXSelected == true.
    b.setAttribute(headersGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    b.setAttribute(headersGroup, kAXDescriptionAttribute as String, "트랙 헤더")
    b.setChildren(headersGroup, [headerRow])
    b.setAttribute(headerRow, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setAttribute(headerRow, kAXDescriptionAttribute as String, "1개의 ‘Track 1’ 트랙")
    b.setAttribute(headerRow, kAXSelectedAttribute as String, true)

    // Mixer → strip → one empty insert slot (with geometry for the anchor check).
    b.setAttribute(slot, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(slot, kAXDescriptionAttribute as String, "오디오 플러그인")
    b.setAttribute(slot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
    b.setAttribute(slot, kAXPositionAttribute as String, axPoint(400, 300))
    b.setAttribute(slot, kAXSizeAttribute as String, axSize(70, 18))
    b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(strip, [slot])
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    b.setChildren(mixer, [strip])

    b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    b.setAttribute(window, kAXTitleAttribute as String, "CoordFree425 — Tracks")
    b.setChildren(window, [headersGroup, mixer])

    // Slot popup: visible + anchored after the modeled custom slot-open action.
    b.setAttribute(gainItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
    b.setAttribute(gainItem, kAXTitleAttribute as String, "Gain")
    // Live Logic exposes AXEnabled on every menu item in an open chain, so a fixture item without it
    // models a tree that does not occur.
    b.setAttribute(gainItem, kAXEnabledAttribute as String, true as CFTypeRef)
    if let leftoverMenu, let leftoverSearch, let leftoverItem {
        // A pop-up left open by a neighbouring slot. It is a plug-in menu, it is visible, and it sits
        // close enough that the geometric anchor test accepts it for our slot too — so only its
        // having been there BEFORE we actuated distinguishes it from ours.
        b.setAttribute(leftoverSearch, kAXRoleAttribute as String, kAXTextFieldRole as String)
        b.setAttribute(leftoverItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(leftoverItem, kAXTitleAttribute as String, "Gain")
        b.setAttribute(leftoverMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setAttribute(leftoverMenu, kAXPositionAttribute as String, axPoint(400, 290))
        b.setAttribute(leftoverMenu, kAXSizeAttribute as String, axSize(300, 400))
        b.setChildren(leftoverMenu, [leftoverSearch, leftoverItem])
    }
    if let nonTerminalFormatMenu, let nonTerminalFormatEntry, let nonTerminalFormatChild,
       let nonTerminalFormatChildMenu {
        // Every entry carries a real format label, so the submenu passes the format discriminator —
        // but the matching entry owns a menu of its own, i.e. it is a category wearing a format
        // name. Picking it would actuate before any terminal target is known.
        b.setAttribute(nonTerminalFormatChild, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(nonTerminalFormatChild, kAXTitleAttribute as String, "Gain")
        b.setAttribute(nonTerminalFormatChildMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(nonTerminalFormatChildMenu, [nonTerminalFormatChild])
        b.setAttribute(nonTerminalFormatEntry, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(nonTerminalFormatEntry, kAXTitleAttribute as String, "Mono")
        b.setChildren(nonTerminalFormatEntry, [nonTerminalFormatChildMenu])
        b.setAttribute(nonTerminalFormatMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(nonTerminalFormatMenu, [nonTerminalFormatEntry])
        b.setChildren(gainItem, [nonTerminalFormatMenu])
    }
    if let nonFormatSubmenu, let nonFormatEntryA, let nonFormatEntryB {
        // Entries a format chooser would never contain; the discriminator must refuse this submenu.
        b.setAttribute(nonFormatEntryA, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(nonFormatEntryA, kAXTitleAttribute as String, "Legacy")
        b.setAttribute(nonFormatEntryB, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(nonFormatEntryB, kAXTitleAttribute as String, "Utility")
        b.setAttribute(nonFormatSubmenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(nonFormatSubmenu, [nonFormatEntryA, nonFormatEntryB])
        b.setChildren(gainItem, [nonFormatSubmenu])
    }
    if let formatLeafItem, let formatMenu {
        b.setAttribute(formatLeafItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
        // Measured live on this Logic build: a plug-in entry's submenu contains only channel-format
        // entries (Gain -> "Mono", "Mono->Stereo"; Compressor and Channel EQ -> "Mono"). The former
        // "Audio Unit" label modelled no real entry and only kept the arbitrary items.first fallback
        // looking justified.
        b.setAttribute(formatLeafItem, kAXTitleAttribute as String, "Mono")
        b.setAttribute(formatMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(formatMenu, [formatLeafItem])
        b.setChildren(gainItem, [formatMenu])
    }
    b.setAttribute(searchField, kAXRoleAttribute as String, kAXTextFieldRole as String)
    b.setAttribute(popupMenu, kAXRoleAttribute as String, kAXMenuRole as String)
    b.setAttribute(popupMenu, kAXPositionAttribute as String, axPoint(410, 320))
    b.setAttribute(popupMenu, kAXSizeAttribute as String, axSize(240, 420))
    if let nonMatchingLeafItem {
        b.setAttribute(nonMatchingLeafItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(nonMatchingLeafItem, kAXTitleAttribute as String, "Compressor")
        if let nonMatchingFormatMenu, let nonMatchingFormatMono, let nonMatchingFormatMonoToStereo {
            b.setAttribute(nonMatchingFormatMenu, kAXRoleAttribute as String, kAXMenuRole as String)
            b.setAttribute(nonMatchingFormatMono, kAXRoleAttribute as String, kAXMenuItemRole as String)
            b.setAttribute(nonMatchingFormatMono, kAXTitleAttribute as String, "Mono")
            b.setAttribute(nonMatchingFormatMonoToStereo, kAXRoleAttribute as String, kAXMenuItemRole as String)
            b.setAttribute(nonMatchingFormatMonoToStereo, kAXTitleAttribute as String, "Mono->Stereo")
            b.setChildren(nonMatchingFormatMenu, [nonMatchingFormatMono, nonMatchingFormatMonoToStereo])
            b.setChildren(nonMatchingLeafItem, [nonMatchingFormatMenu])
        }
    }
    if let categoryItem, let categoryMenu {
        b.setAttribute(categoryItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(categoryItem, kAXTitleAttribute as String, "Utility")
        b.setAttribute(categoryMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        if let formatNamedCategoryItem {
            b.setAttribute(formatNamedCategoryItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
            b.setAttribute(formatNamedCategoryItem, kAXTitleAttribute as String, "Mono")
        }
        // The submenu is already an AX child but has no visible frame. Recursive
        // discovery must read this child directly without actuating the category.
        b.setChildren(categoryMenu, (formatNamedCategoryItem.map { [$0] } ?? []) + [gainItem])
        b.setChildren(categoryItem, [categoryMenu])
        b.setChildren(popupMenu, [searchField] + (nonMatchingLeafItem.map { [$0] } ?? []) + [categoryItem])
    } else {
        b.setChildren(popupMenu, [searchField] + (nonMatchingLeafItem.map { [$0] } ?? []) + [gainItem])
    }

    // App: AXWindows for mainWindow; children so slotPopupMenu's app-descent finds
    // the (top-level) popup menu.
    b.setAttribute(app, kAXWindowsAttribute as String, [window])
    b.setAttribute(app, kAXMainWindowAttribute as String, window)
    // The leftover menu is present from the start: that is what makes it "already open".
    var initialAppChildren: [AXUIElement] = [window]
    if let leftoverMenu { initialAppChildren.append(leftoverMenu) }
    if popupInitiallyVisible { initialAppChildren.append(popupMenu) }
    b.setChildren(app, initialAppChildren)

    let slotKey = b.elementID(slot)
    let windowKey = b.elementID(window)
    let leafKey = formatLeafItem.map(b.elementID) ?? b.elementID(gainItem)
    let categoryKey = categoryItem.map(b.elementID)
    let nonMatchingLeafKey = nonMatchingLeafItem.map(b.elementID)
    let nonMatchingFormatLeafKeys = [nonMatchingFormatMono, nonMatchingFormatMonoToStereo]
        .compactMap { $0.map(b.elementID) }
    let formatNamedCategoryKey = formatNamedCategoryItem.map(b.elementID)
    let actions = AXActionRecorder()
    let pickAction = kAXPickAction as String
    // The AX tree can hand back a DIFFERENT element for the same still-empty slot. Anything the
    // driver learned about the old element — notably whether it exposes the custom opener — was
    // never about this one.
    let replacementSlot = b.element(9030)
    let slotReplacer = SlotOccupier {
        b.setAttribute(replacementSlot, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(replacementSlot, kAXDescriptionAttribute as String, "오디오 플러그인")
        b.setAttribute(replacementSlot, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
        b.setAttribute(replacementSlot, kAXPositionAttribute as String, axPoint(400, 300))
        b.setAttribute(replacementSlot, kAXSizeAttribute as String, axSize(70, 18))
        b.setChildren(strip, [replacementSlot])
    }

    let slotOccupier = SlotOccupier {
        let bypass = b.element(9021)
        let open = b.element(9022)
        b.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(slot, kAXDescriptionAttribute as String, "Compressor")
        b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
        b.setAttribute(bypass, kAXValueAttribute as String, 0)
        b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
        b.setChildren(slot, [bypass, open])
    }
    let runtime = b.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, _ in
            actions.recordAttributeWrite(elementID: b.elementID(element), attribute: attribute)
            return true
        },
        performActionHandler: { element, action in
            let elementID = b.elementID(element)
            actions.record(elementID: elementID, action: action)
            if occupySlotOnWindowRaise,
               elementID == windowKey,
               action == (kAXRaiseAction as String) {
                slotOccupier.occupy()
            }
            if elementID == slotKey, action == slotPopupOpenCustomAction {
                if popupAppearsAfterSlotOpen {
                    b.setChildren(app, leftoverMenu.map { [window, $0, popupMenu] } ?? [window, popupMenu])
                }
                return slotOpenResult
            }
            if elementID == leafKey, action == pickAction {
                if mountGainOnLeafPick {
                    b.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
                    b.setAttribute(slot, kAXDescriptionAttribute as String, "Gain")
                    let bypass = b.element(9012)
                    let open = b.element(9013)
                    b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
                    b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
                    b.setAttribute(bypass, kAXValueAttribute as String, 0)
                    b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
                    b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
                    b.setChildren(slot, [bypass, open])
                }
                return leafPickResult
            }
            return true
        }
    )
    return SlotPopupInsertFixture(
        runtime: runtime,
        slotItemID: slotKey,
        categoryItemID: categoryKey,
        nonMatchingLeafItemID: nonMatchingLeafKey,
        nonMatchingFormatLeafItemIDs: nonMatchingFormatLeafKeys,
        formatNamedCategoryItemID: formatNamedCategoryKey,
        leafItemID: leafKey,
        actions: actions,
        slotOccupier: slotOccupier,
        slotReplacer: slotReplacer,
        replacementSlotID: b.elementID(replacementSlot),
        nonFormatSubmenuItemIDs: [nonFormatEntryA, nonFormatEntryB].compactMap { $0 }.map(b.elementID),
        nonTerminalFormatEntryID: nonTerminalFormatEntry.map(b.elementID),
        searchFieldID: b.elementID(searchField),
        leftoverMenuItemID: leftoverItem.map(b.elementID),
        coordinateFallbackClick: {
            b.setChildren(app, leftoverMenu.map { [window, $0, popupMenu] } ?? [window, popupMenu])
            return true
        }
    )
}

private func runRealInsert(runtime: AXLogicProElements.Runtime) async -> [String: Any] {
    let result = await AccessibilityChannel.defaultInsertVerified(
        params: [
            "track": "0", "insert": "0", "plugin": "Gain",
            "mode": "duplicate_applyback", "project_expected_path": coordFreeExpectedPath,
        ],
        runtime: runtime,
        frontDocumentPath: { coordFreeExpectedPath }
    )
    return try! JSONSerialization.jsonObject(with: result.message.data(using: .utf8)!) as! [String: Any]
}

private func run425Insert(
    fixture: SlotPopupInsertFixture,
    slotOpenActions: [String],
    coordinateFallbackResult: Bool = false
) async -> [String: Any] {
    await AccessibilityChannel.withSlotPopupOpenActionNamesForTests(slotOpenActions) {
        await AccessibilityChannel.withForceCoordinateActuationForTests(coordinateFallbackResult) {
            await runRealInsert(runtime: fixture.runtime)
        }
    }
}

@Test func testPlugin425SlotOpenCustomActionFailureProceedsWhenPopupIsObserved() async throws {
    let fixture = makeSlotPopupInsertFixture(
        slotOpenResult: false, mountGainOnLeafPick: true
    )
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "A")
    #expect(fixture.actions.contains(elementID: fixture.slotItemID, action: slotPopupOpenCustomAction))
    let trace = try #require(obj["select_trace"] as? [String: Any])
    let fallbackTaken = try #require(trace["slot_popup_open_fallback_taken"] as? Bool)
    #expect(!fallbackTaken)
}

@Test func testPlugin425SlotOpenFailsClosedWhenActionEnumerationFails() async throws {
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true)
    let obj = await AccessibilityChannel.withSlotPopupOpenCustomActionEnumerationResultForTests(
        .enumerationFailed
    ) {
        await AccessibilityChannel.withCoordinateActuationForTests(fixture.coordinateFallbackClick) {
            await runRealInsert(runtime: fixture.runtime)
        }
    }

    let state = try #require(obj["state"] as? String)
    #expect(state == "C")
    let stage = try #require(obj["setup_stage"] as? String)
    #expect(stage == "slot_action_enumeration_failed")
    #expect(!fixture.actions.touched(elementID: fixture.slotItemID))
    let trace = try #require(obj["select_trace"] as? [String: Any])
    let fallbackTaken = try #require(trace["slot_popup_open_fallback_taken"] as? Bool)
    #expect(!fallbackTaken)
    let slotOpenAction = try #require(trace["slot_popup_open_action"] as? String)
    #expect(slotOpenAction == "action_enumeration_failed")
}

@Test func testPlugin425SlotOpenSuccessFailsClosedWhenPopupIsNotObserved() async throws {
    let fixture = makeSlotPopupInsertFixture(popupAppearsAfterSlotOpen: false)
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "C")
    let stage = try #require(obj["setup_stage"] as? String)
    #expect(stage == "slot_popup_menu_not_found")
    #expect(fixture.actions.contains(elementID: fixture.slotItemID, action: slotPopupOpenCustomAction))
}

@Test func testPlugin425AttachedCategoryDiscoveryDoesNotNeedCategoryPick() async throws {
    let fixture = makeSlotPopupInsertFixture(
        includeCategory: true,
        mountGainOnLeafPick: true
    )
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "A")
    let categoryID = try #require(fixture.categoryItemID)
    #expect(!fixture.actions.touched(elementID: categoryID))
    #expect(fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
    let trace = try #require(obj["select_trace"] as? [String: Any])
    let strategy = try #require(trace["winning_strategy"] as? String)
    #expect(strategy == "slot_popup_recursive_exact_leaf")
    let leafSelectCoordFree = try #require(trace["leaf_select_coord_free"] as? Bool)
    #expect(leafSelectCoordFree)
}

@Test func testPlugin425FailsClosedWhenTargetSlotBecomesOccupiedBeforeActuation() async throws {
    let fixture = makeSlotPopupInsertFixture(
        mountGainOnLeafPick: true,
        occupySlotOnWindowRaise: true
    )
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "C")
    let error = try #require(obj["error"] as? String)
    #expect(error == "insert_setup_failed")
    let stage = try #require(obj["setup_stage"] as? String)
    #expect(stage == "target_slot_no_longer_empty")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(!fixture.actions.touched(elementID: fixture.slotItemID))
    #expect(!fixture.actions.touched(elementID: fixture.leafItemID))
}

@Test func testPlugin425RecursiveWalkOnlyPicksExactLeaf() async throws {
    let fixture = makeSlotPopupInsertFixture(
        includeCategory: true,
        includeNonMatchingLeaf: true,
        mountGainOnLeafPick: true
    )
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "A")
    let categoryID = try #require(fixture.categoryItemID)
    let nonMatchingLeafID = try #require(fixture.nonMatchingLeafItemID)
    #expect(!fixture.actions.touched(elementID: categoryID))
    #expect(fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
    #expect(!fixture.actions.touched(elementID: nonMatchingLeafID))
}

@Test func testPlugin425RecursiveWalkSkipsNonMatchingFormatLeafWithoutActuation() async throws {
    let fixture = makeSlotPopupInsertFixture(
        includeCategory: true,
        includeNonMatchingLeaf: true,
        includeNonMatchingLeafFormatMenu: true,
        mountGainOnLeafPick: true
    )
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "A")
    let categoryID = try #require(fixture.categoryItemID)
    let nonMatchingLeafID = try #require(fixture.nonMatchingLeafItemID)
    #expect(!fixture.actions.touched(elementID: categoryID))
    #expect(fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
    #expect(!fixture.actions.touched(elementID: nonMatchingLeafID))
    for formatLeafID in fixture.nonMatchingFormatLeafItemIDs {
        #expect(!fixture.actions.touched(elementID: formatLeafID))
    }
}

@Test func testPlugin425RecursiveWalkDescendsPastFormatNamedCategoryEntryWithoutActuation() async throws {
    let fixture = makeSlotPopupInsertFixture(
        includeCategory: true,
        includeFormatNamedCategoryEntry: true,
        mountGainOnLeafPick: true
    )
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "A")
    let categoryID = try #require(fixture.categoryItemID)
    let formatNamedCategoryID = try #require(fixture.formatNamedCategoryItemID)
    #expect(!fixture.actions.touched(elementID: categoryID))
    #expect(!fixture.actions.touched(elementID: formatNamedCategoryID))
    #expect(fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
}

@Test func testPlugin425LeafPickFailureProceedsWhenInventoryDiffIsObserved() async throws {
    let fixture = makeSlotPopupInsertFixture(
        includeCategory: true,
        includeFormatLeaf: true,
        leafPickResult: false,
        mountGainOnLeafPick: true
    )
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "A")
    let verified = try #require(obj["verified"] as? Bool)
    #expect(verified)
    #expect(fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
}

@Test func testPlugin425LeafPickSuccessWithoutInventoryDiffFailsClosed() async throws {
    let fixture = makeSlotPopupInsertFixture(leafPickResult: true)
    let obj = await run425Insert(
        fixture: fixture, slotOpenActions: [slotPopupOpenCustomAction]
    )

    let state = try #require(obj["state"] as? String)
    #expect(state == "C")
    let error = try #require(obj["error"] as? String)
    #expect(error == "operation_timeout")
    #expect(fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
    let verified = try #require(obj["verified"] as? Bool)
    #expect(!verified)
}

@Test func testPlugin425SlotOpenFallsBackToCoordinateClickWhenCustomActionIsAbsent() async throws {
    let fixture = makeSlotPopupInsertFixture(
        popupInitiallyVisible: false, mountGainOnLeafPick: true
    )
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([]) {
        await AccessibilityChannel.withCoordinateActuationForTests(fixture.coordinateFallbackClick) {
            await runRealInsert(runtime: fixture.runtime)
        }
    }

    let state = try #require(obj["state"] as? String)
    #expect(state == "A")
    #expect(!fixture.actions.touched(elementID: fixture.slotItemID))
    let trace = try #require(obj["select_trace"] as? [String: Any])
    let fallbackTaken = try #require(trace["slot_popup_open_fallback_taken"] as? Bool)
    #expect(fallbackTaken)
    let slotOpenAction = try #require(trace["slot_popup_open_action"] as? String)
    #expect(slotOpenAction == "coordinate_fallback")
}

@Test func testPlugin425CoordinateFallbackFailsClosedWhenSlotBecomesOccupiedDuringEnumeration() async throws {
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true)
    let slotOccupier = fixture.slotOccupier
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([]) {
        await AccessibilityChannel.withSlotPopupOpenActionEnumerationHookForTests {
            slotOccupier.occupy()
        } operation: {
            await AccessibilityChannel.withCoordinateActuationForTests(fixture.coordinateFallbackClick) {
                await runRealInsert(runtime: fixture.runtime)
            }
        }
    }

    let state = try #require(obj["state"] as? String)
    #expect(state == "C")
    let stage = try #require(obj["setup_stage"] as? String)
    #expect(stage == "target_slot_no_longer_empty")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(!fixture.actions.touched(elementID: fixture.slotItemID))
    #expect(!fixture.actions.touched(elementID: fixture.leafItemID))
}

@Test func testPlugin425NeverNavigatesAPopupThatWasAlreadyOpen() async throws {
    // A menu left open by a neighbouring slot passes the geometric anchor test — slots sit ~17px
    // apart while the bands are ±96px and ~500px. Only "it appeared after we actuated" separates it
    // from ours, and navigating the wrong one mounts the plug-in on somebody else's slot.
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true, leftoverNeighbourMenuVisible: true)
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([slotPopupOpenCustomAction]) {
        await runRealInsert(runtime: fixture.runtime)
    }
    let leftoverID = try #require(fixture.leftoverMenuItemID)
    #expect(!fixture.actions.touched(elementID: leftoverID))
    // and the run still did its real work, so this is not an absence caused by nothing happening
    #expect(try #require(obj["state"] as? String) == "A")
    #expect(fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
}

@Test func testPlugin425FullInsertWritesNoAttributesAnywhereInThePopup() async throws {
    // The unit-level discovery test proves the recursive walk writes nothing. This asserts the same
    // property end-to-end through the real driver, where the pop-up carries a search field: a whole
    // successful insert must not set a single attribute on any pop-up element.
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true)
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([slotPopupOpenCustomAction]) {
        await runRealInsert(runtime: fixture.runtime)
    }
    #expect(try #require(obj["state"] as? String) == "A")
    #expect(!fixture.actions.touched(elementID: fixture.searchFieldID))
    #expect(fixture.actions.attributeWrites.isEmpty)
}

@Test func testPlugin425NeverPicksAFormatLabelledEntryThatOwnsItsOwnMenu() async throws {
    // A "Mono" entry that owns a submenu is a category wearing a format name. It satisfies the
    // format-label check, so only the terminal requirement keeps AXPick off it.
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true, includeNonTerminalFormatEntry: true)
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([slotPopupOpenCustomAction]) {
        await runRealInsert(runtime: fixture.runtime)
    }
    // Same reasoning: show the flow reached the pick, so "the category was untouched" is a result
    // rather than a consequence of nothing having happened.
    #expect(fixture.actions.contains(elementID: fixture.slotItemID, action: slotPopupOpenCustomAction))
    let entryID = try #require(fixture.nonTerminalFormatEntryID)
    #expect(!fixture.actions.touched(elementID: entryID))
    // No terminal format leaf exists here, so nothing may be picked and no insert may be claimed.
    #expect(!fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
    #expect(try #require(obj["state"] as? String) != "A")
}

@Test func testPlugin425NeverActuatesInsideANonFormatSubmenu() async throws {
    // Logic exposes category entries named like plug-ins, so "the matched item owns an AXMenu" does
    // not mean that menu is a channel-format chooser. Entering it and picking whatever sits first
    // would actuate a target nothing identified.
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true, includeNonFormatSubmenu: true)
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([slotPopupOpenCustomAction]) {
        await runRealInsert(runtime: fixture.runtime)
    }
    // An absence assertion proves nothing if the flow never got there, so prove it did: the slot was
    // opened and the exact Gain entry — not anything inside the foreign submenu — was picked.
    // The slot really was opened, so the refusals below are results rather than a run that did
    // nothing.
    #expect(fixture.actions.contains(elementID: fixture.slotItemID, action: slotPopupOpenCustomAction))
    // Nothing inside the foreign submenu may be actuated...
    for id in fixture.nonFormatSubmenuItemIDs {
        #expect(!fixture.actions.touched(elementID: id))
    }
    // ...and neither may its OWNER. An entry that owns a submenu we cannot identify as channel
    // formats is a category wearing the plug-in's name; picking it actuates a category. The earlier
    // revision of this test asserted that pick as the expected behaviour.
    #expect(!fixture.actions.contains(elementID: fixture.leafItemID, action: kAXPickAction as String))
    // With no terminal target identified, the operation must not claim a verified insert.
    #expect(try #require(obj["state"] as? String) != "A")
}

@Test func testPlugin425FailsClosedWhenTheSlotElementIsReplacedDuringEnumeration() async throws {
    // Whether the custom opener is present was read from ONE element. If the AX tree hands back a
    // different element for the same still-empty slot, that answer was never about the element we
    // are about to drive — so the attempt must refuse rather than actuate on an unexamined element.
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true)
    let replacer = fixture.slotReplacer
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([slotPopupOpenCustomAction]) {
        await AccessibilityChannel.withSlotPopupOpenActionEnumerationHookForTests {
            replacer.occupy()
        } operation: {
            await runRealInsert(runtime: fixture.runtime)
        }
    }

    let state = try #require(obj["state"] as? String)
    #expect(state == "C")
    let stage = try #require(obj["setup_stage"] as? String)
    #expect(stage == "target_slot_element_replaced")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(!fixture.actions.touched(elementID: fixture.slotItemID))
    #expect(!fixture.actions.touched(elementID: fixture.replacementSlotID))
}

@Test func testPlugin425CustomSlotOpenFailsClosedWhenSlotBecomesOccupiedDuringEnumeration() async throws {
    let fixture = makeSlotPopupInsertFixture(mountGainOnLeafPick: true)
    let slotOccupier = fixture.slotOccupier
    let obj = await AccessibilityChannel.withSlotPopupOpenActionNamesForTests([slotPopupOpenCustomAction]) {
        await AccessibilityChannel.withSlotPopupOpenActionEnumerationHookForTests {
            slotOccupier.occupy()
        } operation: {
            await runRealInsert(runtime: fixture.runtime)
        }
    }

    let state = try #require(obj["state"] as? String)
    #expect(state == "C")
    let stage = try #require(obj["setup_stage"] as? String)
    #expect(stage == "target_slot_no_longer_empty")
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    #expect(!fixture.actions.touched(elementID: fixture.slotItemID))
    #expect(!fixture.actions.touched(elementID: fixture.leafItemID))
}

/// Records which elements received a `kAXPress` when the default action-
/// recording is bypassed by an injected `performActionHandler` (contract C).
/// Invoked sequentially within one test (awaited), so plain mutation is
/// race-free here; `@unchecked Sendable` documents that.
private final class AXPressRecorder: @unchecked Sendable {
    private(set) var pressedElementIDs: [Int] = []
    func record(_ id: Int) { pressedElementIDs.append(id) }
}

/// #474 — an entry whose enabled state cannot be read must not be pressed.
///
/// `AXEnabled` is the one signal that distinguishes "will act" from "will do nothing" before the
/// press, and the pick path used to treat an unreadable value as enabled. Measured on Logic 12.3 with
/// the plug-in menu chain open, all 1090 items expose a readable value and 264 are disabled —
/// section headers such as "Recent" among them — so this is a population the picker can land on.
@Test func testPlugin474LeafWithUnreadableEnabledStateIsNotPressed() async throws {
    // The gap is an UNREADABLE attribute, not a readable false: a readable false is already refused
    // by the lenient discovery check, so a fixture that sets `enabled: false` tests behaviour that
    // already worked. Build the item without the attribute at all, which is what "unreadable" means.
    let b = FakeAXRuntimeBuilder()
    let unreadable = b.element(9500)
    b.setAttribute(unreadable, kAXRoleAttribute as String, kAXMenuItemRole as String)
    b.setAttribute(unreadable, kAXTitleAttribute as String, "Gain")
    let rootMenu = addMenu(b, 9501, children: [unreadable])
    let recorder = AXPressRecorder()
    let runtime = b.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            recorder.record(b.elementID(element))
            return true
        }
    )

    let click = await AccessibilityChannel.clickPluginInAnchoredSlotPopup(
        pluginID: "logic.stock.effect.gain",
        displayName: "Gain",
        rootMenu: rootMenu,
        runtime: runtime
    )

    #expect(click == nil)
    #expect(!recorder.pressedElementIDs.contains(b.elementID(unreadable)))
}

/// The same fixture with the entry enabled must succeed, so the test above fails for the reason it
/// names rather than because nothing could ever be picked.
@Test func testPlugin474EnabledLeafIsStillPressed() async throws {
    let b = FakeAXRuntimeBuilder()
    let target = addMenuItem(b, 9510, title: "Gain")
    let rootMenu = addMenu(b, 9511, children: [target])
    let recorder = AXPressRecorder()
    let runtime = b.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            recorder.record(b.elementID(element))
            return true
        }
    )

    let click = await AccessibilityChannel.clickPluginInAnchoredSlotPopup(
        pluginID: "logic.stock.effect.gain",
        displayName: "Gain",
        rootMenu: rootMenu,
        runtime: runtime
    )

    #expect(click != nil)
    #expect(recorder.pressedElementIDs.contains(b.elementID(target)))
}

/// #475 — an unreadable mixer child renumbers every later strip, so ordinal addressing stops meaning
/// what the caller asked for.
///
/// `mixerChannelStrips` filters to layout items; a child whose role cannot be read is dropped and
/// each later strip moves down one. Callers address strips by ordinal, so a request for track 0 would
/// act on physical strip 1. No downstream readback can catch it — the readback reads the same shifted
/// list — so the write path refuses rather than addressing a list it cannot trust.
@Test func testPlugin475UnreadableMixerChildIsNotSilentlyRenumbered() async throws {
    let b = FakeAXRuntimeBuilder()
    let mixer = b.element(9600)
    let ghost = b.element(9601)      // role unreadable: dropped by the filter
    let stripA = b.element(9602)
    let stripB = b.element(9603)
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
    // `ghost` deliberately has NO role attribute.
    b.setAttribute(stripA, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setAttribute(stripB, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(mixer, [ghost, stripA, stripB])

    let runtime = b.makeAXRuntime(setAttributeHandler: nil, performActionHandler: { _, _ in false })
    let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime)

    // The filter still yields two strips, but they are NOT at the ordinals the caller means: the
    // caller's "strip 0" is physically the second child here.
    #expect(enumeration.strips.count == 2)
    #expect(enumeration.unreadableChildren == 1)
}

@Test func testPlugin475FullyReadableMixerReportsNoUnreadableChildren() async throws {
    let b = FakeAXRuntimeBuilder()
    let mixer = b.element(9610)
    let stripA = b.element(9611)
    let stripB = b.element(9612)
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(stripA, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setAttribute(stripB, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(mixer, [stripA, stripB])

    let runtime = b.makeAXRuntime(setAttributeHandler: nil, performActionHandler: { _, _ in false })
    let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: runtime)

    // The positive twin: a healthy mixer must not be refused, or the guard would block every write.
    #expect(enumeration.strips.count == 2)
    #expect(enumeration.unreadableChildren == 0)
}

private final class AXPressLogBox: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// #475 — a rollback must undo OUR insert, never whatever is on top of the user's undo stack.
///
/// The rollback matched only the localized "Undo" prefix and pressed the entry it found. Measured on
/// Logic 12.3 the Edit menu offers "Undo Insert Plug-in in Channel Strip" for our own write, and
/// entries such as "Undo selected Channel Strips" for actions that are not ours. Pressing the latter
/// reverts the user's work while reporting a successful rollback.
@Test func testPlugin475RollbackDoesNotUndoSomethingThatIsNotOurInsert() async throws {
    let clicks = AXPressLogBox()
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0,
        strayPluginID: "logic.stock.effect.gain",
        straySlot: 0,
        strayName: "Gain",
        runtime: emptyLogicRuntimeForRollbackTests(),
        maxRetries: 4,
        undoClick: { clicks.bump(); return "not_ours" }
    )

    // The properties that protect the user's work: the entry was looked at once, nothing was
    // pressed, and there was no retry — a retry would keep hammering Undo at their stack.
    //
    // `succeeded` is not asserted here. This fixture's strip is empty, so the stray reads as already
    // gone and removal confirms on its own; that says nothing about the refusal.
    #expect(clicks.count == 1)
    #expect(!result.attempted)
    #expect(result.lastClickResult == "not_ours")
}

/// The positive twin: when the entry IS ours, the rollback proceeds, so the refusal above is a
/// decision rather than a path that can never roll anything back.
@Test func testPlugin475RollbackStillProceedsWhenTheEntryIsOurs() async throws {
    let clicks = AXPressLogBox()
    let result = await AccessibilityChannel.verifiedUndoPluginInsert(
        track: 0,
        strayPluginID: "logic.stock.effect.gain",
        straySlot: 0,
        strayName: "Gain",
        runtime: emptyLogicRuntimeForRollbackTests(),
        maxRetries: 4,
        undoClick: { clicks.bump(); return "ok" }
    )

    #expect(clicks.count >= 1)
    #expect(result.attempted)
}

/// A strip whose inventory reads empty is the removal-confirmation the rollback polls for.
private func emptyLogicRuntimeForRollbackTests() -> AXLogicProElements.Runtime {
    let b = FakeAXRuntimeBuilder()
    let app = b.element(9700)
    let window = b.element(9701)
    let mixer = b.element(9702)
    let strip = b.element(9703)
    b.setAttribute(app, kAXMainWindowAttribute as String, window)
    b.setChildren(window, [mixer])
    b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
    b.setAttribute(mixer, kAXIdentifierAttribute as String, "Mixer")
    b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    b.setChildren(mixer, [strip])
    b.setChildren(strip, [])
    return b.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: { _, _ in false })
}

/// #475 — State A must not be granted to a document we can no longer name.
///
/// The front document is checked once, before the work begins. Track select, mixer raise, inventory,
/// pop-up, discovery, pick and poll all happen after it. Switching project inside that window puts
/// both the write and its readback in a different document than the caller named — and every check
/// in between still agrees with itself, because they all read the new document.
@Test func testPlugin475ProjectSwitchedMidInsertIsNotCertified() async throws {
    let fixture = makeSlotPopupInsertFixture(refuseLeafAXPress: false, mountGainOnLeafAXPress: true)
    let reads = AXPressLogBox()
    let result = await AccessibilityChannel.defaultInsertVerified(
        params: [
            "track": "0", "insert": "0", "plugin": "Gain",
            "mode": "duplicate_applyback", "project_expected_path": coordFreeExpectedPath,
        ],
        runtime: fixture.runtime,
        frontDocumentPath: {
            // The gate's read matches; the post-write re-read finds a different document.
            reads.bump()
            return reads.count == 1 ? coordFreeExpectedPath : "/Users/me/Music/Something Else.logicx"
        }
    )
    let obj = try! JSONSerialization.jsonObject(with: result.message.data(using: .utf8)!) as! [String: Any]

    #expect(try #require(obj["state"] as? String) == "C")
    #expect(try #require(obj["error"] as? String) == "project_identity_mismatch")
    // The write did happen — denying that would be the other kind of dishonesty.
    #expect(try #require(obj["write_attempted"] as? Bool))
    #expect(reads.count >= 2)
}

/// The positive twin: an unchanged document still certifies, so the check above is a decision rather
/// than a path that can never reach State A.
@Test func testPlugin475UnchangedProjectStillCertifies() async throws {
    let fixture = makeSlotPopupInsertFixture(refuseLeafAXPress: false, mountGainOnLeafAXPress: true)
    let obj = await runRealInsert(runtime: fixture.runtime)
    #expect(try #require(obj["state"] as? String) == "A")
}
