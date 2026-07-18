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

// MARK: - Coordinate-free selection: AXPress + OBSERVED effect, never the return code

/// Records AX actions posted through the fake runtime's `performAction` seam so a
/// test can assert the selection path uses AXPress on AXMenuItems only — never a
/// mouse/CGEvent primitive (the fake has no mouse seam, and the source no longer
/// contains one). All handlers below return `false` to model Logic 12.3 (which
/// reports a non-zero AX status even when the action succeeds) — the code must
/// decide by the OBSERVED AX tree, never that return.
private final class PluginPickerActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(id: Int, action: String)] = []
    func record(_ id: Int, _ action: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append((id, action))
    }
    func pressed(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return calls.contains { $0.id == id && $0.action == (kAXPressAction as String) }
    }
    var actions: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.action)
    }
    var pressCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.action == (kAXPressAction as String) }.count
    }
}

// clickPopupPluginLeaf decides success by the OBSERVED commit — a selected leaf
// dismisses the whole popup — never the AXPress return. The actuated menu items
// are FRAMELESS (no AXPosition/AXSize), which the deleted coordinate path
// (`elementCenter`) would have rejected outright, proving no coordinate primitive
// remains; the (observation-only) root menu carries a frame and the handler
// models the commit by making it invisible.
@Test func testSlotPopupLeafCommitDecidedByObservedDismissalNotReturn() async {
    let b = FakeAXRuntimeBuilder()
    let leaf = addMenuItem(b, 9001, title: "Gain")   // frameless terminal leaf, no submenu
    let rootMenu = addMenu(b, 9300, children: [leaf])
    b.setAttribute(rootMenu, kAXPositionAttribute as String, axPoint(10, 10))
    b.setAttribute(rootMenu, kAXSizeAttribute as String, axSize(200, 300))   // visible
    let recorder = PluginPickerActionRecorder()
    let leafID = b.elementID(leaf)
    let runtime = b.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { [b, leafID] element, action in
            recorder.record(b.elementID(element), action)
            if b.elementID(element) == leafID {                                  // leaf press commits →
                b.setAttribute(b.element(9300), kAXSizeAttribute as String, axSize(0, 0))  // popup dismisses
            }
            return false                                                         // Logic 12.3 lies; ignore
        }
    )

    let ok = await AccessibilityChannel.clickPopupPluginLeaf(leaf, rootMenu: rootMenu, runtime: runtime)

    #expect(ok)                            // succeeded on OBSERVED dismissal, not the false return
    #expect(recorder.pressed(leafID))      // via AXPress on the frameless leaf
    #expect(recorder.pressCount == 1)      // exactly one selecting AXPress
    #expect(recorder.actions.allSatisfy { $0 == (kAXPressAction as String) })  // AX actions only
}

// The strategy-fallthrough fix: a noop leaf press (nothing commits, popup stays
// up) must return FALSE so clickPluginInAnchoredSlotPopup falls through to the
// search / recursive strategies instead of short-circuiting on a blind true.
@Test func testSlotPopupLeafNoopReturnsFalseSoStrategiesFallThrough() async {
    let b = FakeAXRuntimeBuilder()
    let leaf = addMenuItem(b, 9001, title: "Gain")
    let rootMenu = addMenu(b, 9300, children: [leaf])
    b.setAttribute(rootMenu, kAXPositionAttribute as String, axPoint(10, 10))
    b.setAttribute(rootMenu, kAXSizeAttribute as String, axSize(200, 300))   // stays visible
    let recorder = PluginPickerActionRecorder()
    let runtime = b.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { [b] element, action in
            recorder.record(b.elementID(element), action)   // press issued, but nothing commits
            return false
        }
    )

    let ok = await AccessibilityChannel.clickPopupPluginLeaf(leaf, rootMenu: rootMenu, runtime: runtime)

    #expect(!ok)                                 // no observed commit → false (NOT a blind true)
    #expect(recorder.pressed(b.elementID(leaf))) // the press WAS attempted
}

// Format-variant plugin: AXPress the exact item opens its format submenu, then
// AXPress the preferred off-screen format leaf, whose press commits + dismisses
// the popup. All actuated items frameless; success decided by observed dismissal.
@Test func testSlotPopupFormatLeafCommitViaAXPressOffScreen() async {
    let b = FakeAXRuntimeBuilder()
    let stereo = addMenuItem(b, 9102, title: "Stereo")            // frameless format leaf
    let formatSubmenu = addMenu(b, 9103, children: [stereo])      // frameless submenu
    let parent = addMenuItem(b, 9101, title: "ChannelEQ", children: [formatSubmenu])
    let rootMenu = addMenu(b, 9300, children: [parent])
    b.setAttribute(rootMenu, kAXPositionAttribute as String, axPoint(10, 10))
    b.setAttribute(rootMenu, kAXSizeAttribute as String, axSize(200, 300))
    let recorder = PluginPickerActionRecorder()
    let stereoID = b.elementID(stereo)
    let runtime = b.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { [b, stereoID] element, action in
            recorder.record(b.elementID(element), action)
            if b.elementID(element) == stereoID {                                // format-leaf press commits
                b.setAttribute(b.element(9300), kAXSizeAttribute as String, axSize(0, 0))
            }
            return false
        }
    )

    let ok = await AccessibilityChannel.clickPopupPluginLeaf(parent, rootMenu: rootMenu, runtime: runtime)

    #expect(ok)
    #expect(recorder.pressed(b.elementID(parent)))   // AXPress opened the format submenu
    #expect(recorder.pressed(stereoID))              // AXPress selected the off-screen Stereo leaf
    #expect(recorder.pressCount == 2)                // parent-open + format-leaf-select only
}

// openMenuBarItem decides by OBSERVED menu contents (an AXMenu child that becomes
// populated), never the AXPress return. Case A: the press opens the menu but
// reports false → true. Case B: the press reports true but nothing populates →
// false (the return is ignored; only the observed effect governs).
@Test func testOpenMenuBarItemDecidedByObservedMenuNotReturn() async {
    let b = FakeAXRuntimeBuilder()
    _ = addMenuItem(b, 9402, title: "Item")               // becomes the opened menu's child
    _ = addMenu(b, 9401, children: [])                    // empty menu until "opened"
    let barItem = b.element(9400)
    b.setAttribute(barItem, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
    b.setChildren(barItem, [b.element(9401)])
    let barItemID = b.elementID(barItem)
    let runtimeA = b.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { [b, barItemID] element, _ in
            if b.elementID(element) == barItemID {
                b.setChildren(b.element(9401), [b.element(9402)])   // the press opens (populates) the menu
            }
            return false                                            // …while reporting failure
        }
    )
    let openedResult = await AccessibilityChannel.openMenuBarItem(barItem, runtime: runtimeA)
    #expect(openedResult)   // true because the menu was OBSERVED populated, not the return

    let b2 = FakeAXRuntimeBuilder()
    _ = addMenu(b2, 9411, children: [])
    let barItem2 = b2.element(9410)
    b2.setAttribute(barItem2, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
    b2.setChildren(barItem2, [b2.element(9411)])
    let runtimeB = b2.makeAXRuntime(
        setAttributeHandler: nil,
        performActionHandler: { _, _ in true }              // claims success, opens nothing
    )
    let notOpened = await AccessibilityChannel.openMenuBarItem(barItem2, runtime: runtimeB)
    #expect(!notOpened)   // false because no menu contents were observed
}

// closeGoToPositionDialog dismisses via AXPress but decides by the OBSERVED
// disappearance of the dialog — not the AXPress return. When Cancel actually
// dismisses (handler removes the dialog) despite returning false, the function
// must NOT also actuate Close (no double-actuation that could steal focus /
// dismiss another surface mid-insert).
@Test func testCloseGoToPositionDialogPollsAbsenceAndDoesNotDoubleActuate() async {
    let b = FakeAXRuntimeBuilder()
    let app = b.element(9500)
    let dialog = b.element(9501)
    let cancel = b.element(9502)
    let close = b.element(9503)
    b.setAttribute(dialog, kAXTitleAttribute as String, "Go to Position")
    b.setChildren(dialog, [cancel, close])
    b.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    b.setAttribute(close, kAXRoleAttribute as String, kAXButtonRole as String)
    b.setAttribute(close, kAXSubroleAttribute as String, kAXCloseButtonSubrole as String)
    b.setAttribute(app, kAXWindowsAttribute as String, [dialog])
    let recorder = PluginPickerActionRecorder()
    let cancelID = b.elementID(cancel)
    let runtime = b.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { [b, cancelID] element, action in
            recorder.record(b.elementID(element), action)
            if b.elementID(element) == cancelID {                    // Cancel actually dismisses →
                b.setAttribute(b.element(9500), kAXWindowsAttribute as String, [] as [AXUIElement])
            }
            return false                                             // …while reporting failure
        }
    )

    let handled = await AccessibilityChannel.closeGoToPositionDialog(runtime: runtime)

    #expect(handled)                                // a dialog was present and dismissal confirmed
    #expect(recorder.pressed(cancelID))             // Cancel was AXPressed
    #expect(!recorder.pressed(b.elementID(close)))  // Close was NOT actuated (no double-actuation)
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
