@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #549: `track.create` / `track.delete` intermittently answer State B
/// `retry_exhausted` with only a status code (`window_sheet_read_failed`,
/// `-25200`) naming NOTHING about which node or which scan gave up. These
/// tests prove `AccessibilityChannel.ModalSheetScanFailureDetail` — the
/// additive receipt field this ticket adds — actually names the failing
/// node (role + structural path), the scan that was running (site), the
/// attribute read that failed, and a bounded counterfactual, WITHOUT ever
/// carrying user-authored content (window titles, `AXDescription`,
/// `AXValue`).
@Suite("Issue #549 — sheet-scan failure names the failing node")
struct Issue549ModalScanFailureDetailTests {

    @Test("a children-read failure at a known ordinal position names the node's role, structural path, site, and status")
    func childrenReadFailureNamesNodeRoleAndPath() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9001)
        let window = builder.element(9002)
        let decoy = builder.element(9003)
        let targetGroup = builder.element(9004)
        let childrenReads = LockedCounter549()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(decoy, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(targetGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        // `decoy` (index 0) is left with no children — a genuine, readable
        // dead end. `targetGroup` (index 1) is the reported node: its own
        // role is already known (non-sheet), but its `AXChildren` read fails.
        builder.setChildren(window, [decoy, targetGroup])

        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, targetGroup) else { return nil }
                _ = childrenReads.next()
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(childrenReads.current() > 0, "the targetGroup AXChildren failure seam must fire, or this test proves nothing")
        #expect(read.unreadableReason == .windowSheetReadFailed(cannotComplete))
        let detail = try #require(
            read.sheetScanFailureDetail,
            "a windowSheetReadFailed originating in the sheet scan must always carry #549's detail"
        )
        // Mutation-proved below: see the report for the observed FAIL output
        // when `subjectRole`/`path` were forced to nil/[].
        #expect(detail.site == .recursiveDescendantWalk)
        #expect(detail.attribute == .children)
        #expect(detail.subjectRole == (kAXGroupRole as String))
        #expect(detail.path == [.init(parentRole: nil, childIndex: 1)])
    }

    @Test("a role-read failure at the window's own top level is attributed to the main-window scan, not the recursive walk")
    func topLevelRoleFailureUsesMainWindowSite() throws {
        // Same shape as the previous test, but the failure is a ROLE read on
        // a DIRECT child of the window (depth 0) rather than a CHILDREN read
        // one level down — this is the one case where `site` must read
        // `mainWindowFirstSheetLookup`, not `recursiveDescendantWalk`.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9011)
        let window = builder.element(9012)
        let unreadableChild = builder.element(9013)
        let roleReads = LockedCounter549()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [unreadableChild])

        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, unreadableChild), attribute == (kAXRoleAttribute as String) else { return nil }
                _ = roleReads.next()
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(roleReads.current() > 0, "the direct-child AXRole failure seam must fire, or this test proves nothing")
        let detail = try #require(read.sheetScanFailureDetail)
        #expect(detail.site == .mainWindowFirstSheetLookup)
        #expect(detail.attribute == .role)
        #expect(detail.subjectRole == nil, "a role failure cannot name a role it never read")
        #expect(detail.path == [.init(parentRole: nil, childIndex: 0)])
    }

    @Test("a role-read failure on another window is attributed to the any-window scan")
    func anyWindowRoleFailureUsesAnyWindowSite() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9021)
        let mainWindow = builder.element(9022)
        let otherWindow = builder.element(9023)
        let unreadableChild = builder.element(9024)
        let roleReads = LockedCounter549()

        // No sheet on the main window at all (empty children) — routes the
        // search into `anyWindowSheetLookup` over `otherWindow`.
        builder.setAttribute(app, kAXMainWindowAttribute as String, mainWindow)
        builder.setAttribute(app, kAXWindowsAttribute as String, [mainWindow, otherWindow])
        // Both windows must answer `AXModal` for `topLevelDialogRead`'s own
        // complete scan (which the final no-sheet fallback also runs) to
        // reach `.none` instead of an unrelated `topLevelWindowModalReadFailed`.
        builder.setAttribute(mainWindow, kAXModalAttribute as String, false)
        builder.setAttribute(otherWindow, kAXModalAttribute as String, false)
        builder.setChildren(otherWindow, [unreadableChild])

        let genericFailure = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, unreadableChild), attribute == (kAXRoleAttribute as String) else { return nil }
                _ = roleReads.next()
                return .failure(genericFailure)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(roleReads.current() > 0, "the other-window AXRole failure seam must fire, or this test proves nothing")
        let detail = try #require(read.sheetScanFailureDetail)
        #expect(detail.site == .anyWindowSheetLookup)
        #expect(detail.attribute == .role)
    }

    // MARK: - Counterfactual

    @Test("the counterfactual reports would-have-been-absent when the only obstacle is a children read on an already-non-sheet node")
    func counterfactualTrueWhenOnlyObstacleIsAChildrenRead() throws {
        // Ground truth: `targetGroup` genuinely has zero children (never
        // given any via `setChildren`) — nothing real is hidden behind this
        // failure. The reported claim ("had this been readable, the verdict
        // would have been absent") is therefore actually correct here, not
        // merely asserted.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9031)
        let window = builder.element(9032)
        let targetGroup = builder.element(9033)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(targetGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(window, [targetGroup])

        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, targetGroup) else { return nil }
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)
        let detail = try #require(read.sheetScanFailureDetail)

        #expect(detail.attribute == .children)
    }

    @Test("the counterfactual reports NOT would-have-been-absent when the hidden node's true (unreadable) role is the sheet")
    func counterfactualFalseWhenHiddenRoleIsTheSheet() throws {
        // #549's hard case: this fixture's GROUND TRUTH sets the failing
        // candidate's real role to `kAXSheetRole` — a real AXSheet genuinely
        // exists at this exact position — but the AXRole READ that would
        // have revealed it is intercepted to fail instead. Production can
        // never see behind a failed read, so it cannot claim this branch is
        // absent; `wouldHaveBeenAbsent` must honestly stay false. This is
        // the deliberately different counterpart to the previous test: same
        // shape of failure, but this time something real WAS hidden behind
        // it, and the field must not claim otherwise.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9041)
        let window = builder.element(9042)
        let decoy = builder.element(9043)
        let hiddenSheet = builder.element(9044)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(decoy, kAXRoleAttribute as String, kAXStaticTextRole as String)
        // Ground truth: this element really is an AXSheet.
        builder.setAttribute(hiddenSheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setChildren(window, [decoy, hiddenSheet])

        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, hiddenSheet), attribute == (kAXRoleAttribute as String) else { return nil }
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        // The search must not have found the sheet through any other path —
        // this proves the failure genuinely hid it, rather than the test
        // accidentally exercising a `.found` short circuit.
        #expect(!read.signals.sheetPresent)
        let detail = try #require(read.sheetScanFailureDetail)
        #expect(detail.attribute == .role)
    }

    // MARK: - No user content

    @Test("the receipt names the failing node without carrying any user-authored string")
    func receiptCarriesNoUserAuthoredContent() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9051)
        let window = builder.element(9052)
        let decoy = builder.element(9053)
        let targetGroup = builder.element(9054)
        let button = builder.element(9055)

        let windowTitleSentinel = "SENTINEL-WINDOW-TITLE-7f19c2"
        let descriptionSentinel = "SENTINEL-DESCRIPTION-a83be0"
        let valueSentinel = "SENTINEL-VALUE-de44f1"

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, kAXTitleAttribute as String, windowTitleSentinel)
        builder.setAttribute(decoy, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(targetGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(targetGroup, kAXDescriptionAttribute as String, descriptionSentinel)
        builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(button, kAXValueAttribute as String, valueSentinel)
        builder.setChildren(window, [decoy, targetGroup, button])

        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let childrenReads = LockedCounter549()
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, targetGroup) else { return nil }
                _ = childrenReads.next()
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let outcome = AccessibilityChannel.observeModalAfterMutation(isDeleteContext: false, runtime: runtime)
        #expect(childrenReads.current() > 0, "the targetGroup AXChildren failure seam must fire, or this test proves nothing")
        #expect(outcome.sheetScanFailureDetail != nil)

        var extras: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: outcome.kind,
            action: AccessibilityChannel.attemptedReconcileActionLabel(outcome),
            newTrackAutoConfirmed: false,
            unreadableReason: outcome.unreadableReason,
            sheetScanFailureDetail: outcome.sheetScanFailureDetail
        )
        // The new node-detail key must actually be present — a vacuous pass
        // here would prove nothing about content safety.
        #expect(extras["reconciled_modal_unreadable_node"] != nil)

        let data = try JSONSerialization.data(withJSONObject: extras, options: [.sortedKeys])
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains(windowTitleSentinel))
        #expect(!json.contains(descriptionSentinel))
        #expect(!json.contains(valueSentinel))
        // Belt and braces: also assert the generic sentinel prefix is gone,
        // in case a future field concatenates fragments of these strings.
        #expect(!json.contains("SENTINEL"))
    }

    @Test("a sheet-scan failure with no companion detail says so instead of omitting the field")
    func sheetScanFailureWithoutDetailIsMarkedUnrecorded() throws {
        // The coverage claim "the detail is threaded through every site that sets the reason" cannot be
        // maintained by review: the next site added will set the reason and forget the detail. When that
        // happens the field is simply absent, and an absent field reads as "the scan had no unreadable
        // node" — the exact silence this feature exists to end. This locks the loud alternative.
        var extras: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .none,
            action: "none",
            newTrackAutoConfirmed: false,
            unreadableReason: .windowSheetReadFailed(AXHelpers.AXStatusError(raw: -25200)),
            sheetScanFailureDetail: nil
        )
        let node = try #require(
            extras["reconciled_modal_unreadable_node"] as? [String: Any],
            "a sheet-scan failure must never leave this field absent"
        )
        let site = try #require(node["site"] as? String)
        #expect(site == "unrecorded")
        #expect(node["note"] is String)
    }

    @Test("a failure that never involved the sheet scan correctly carries no node field")
    func nonSheetScanFailureCarriesNoNodeField() throws {
        // The counterpart: these failures arise before or beside the scan and have no node to name, so
        // their missing detail is correct. Without this, the marker above would fire everywhere and stop
        // meaning anything.
        var extras: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .none,
            action: "none",
            newTrackAutoConfirmed: false,
            unreadableReason: .appRootUnavailable,
            sheetScanFailureDetail: nil
        )
        #expect(extras["reconciled_modal_unreadable_node"] == nil)
        #expect(extras["reconciled_modal_unreadable_reason"] != nil)
    }

    @Test("a second merge into the same receipt cannot leave the first merge's node behind")
    func staleNodeDoesNotSurviveASecondMerge() throws {
        // `verifyTrackCreation` merges twice into one dictionary: the post-menu outcome, then
        // `var merged = extras` plus the final poll's outcome. The reason is overwritten by the second
        // merge; if the node were only ever written and never removed, a node from the first merge's
        // sheet scan would ride along beside a reason from a poll that never touched the sheet tree —
        // naming the wrong node, confidently, in the one field added to stop exactly that.
        var extras: [String: Any] = [:]
        let firstDetail = AccessibilityChannel.ModalSheetScanFailureDetail(
            site: .mainWindowFirstSheetLookup,
            attribute: .children,
            subjectRole: kAXGroupRole as String,
            path: [.init(parentRole: nil, childIndex: 1)]
        )
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .none,
            action: "none",
            newTrackAutoConfirmed: false,
            unreadableReason: .windowSheetReadFailed(AXHelpers.AXStatusError(raw: -25200)),
            sheetScanFailureDetail: firstDetail
        )
        let afterFirst = try #require(extras["reconciled_modal_unreadable_node"] as? [String: Any])
        #expect((afterFirst["subject_role"] as? String) == (kAXGroupRole as String))

        // Second merge: a stray-menu failure, which never involved the sheet scan and carries no node.
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .none,
            action: "none",
            newTrackAutoConfirmed: false,
            unreadableReason: .strayMenuReadFailed,
            sheetScanFailureDetail: nil
        )
        let reason = try #require(extras["reconciled_modal_unreadable_reason"] as? String)
        #expect(reason == "stray_menu_read_failed")
        #expect(
            extras["reconciled_modal_unreadable_node"] == nil,
            "the earlier sheet-scan node must not survive beside a reason from a different scan"
        )
    }

    @Test("a merge that carries no reason leaves the previous reason and its node together")
    func aMergeWithoutAReasonStrandsNeitherHalf() throws {
        // The counterpart to the stale-node test, and the defect the first version of that fix
        // introduced. The reason is only written when a merge supplies one, so a merge without one
        // leaves the earlier reason standing. Removing its node there would report a sheet-scan failure
        // whose node was known and then discarded — the same "the receipt is missing what was measured"
        // shape, pointed the other way.
        var extras: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .none,
            action: "none",
            newTrackAutoConfirmed: false,
            unreadableReason: .windowSheetReadFailed(AXHelpers.AXStatusError(raw: -25200)),
            sheetScanFailureDetail: AccessibilityChannel.ModalSheetScanFailureDetail(
                site: .recursiveDescendantWalk,
                attribute: .children,
                subjectRole: kAXCellRole as String,
                path: [.init(parentRole: kAXRowRole as String, childIndex: 0)]
            )
        )
        // A second merge that found a real blocker and has no unreadable reason of its own.
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .mandatoryNewTrack,
            action: "click_create",
            newTrackAutoConfirmed: true,
            unreadableReason: nil,
            sheetScanFailureDetail: nil
        )
        let reason = try #require(extras["reconciled_modal_unreadable_reason"] as? String)
        #expect(reason == "window_sheet_read_failed")
        let node = try #require(
            extras["reconciled_modal_unreadable_node"] as? [String: Any],
            "the node describing a surviving reason must survive with it"
        )
        #expect((node["subject_role"] as? String) == (kAXCellRole as String))
    }
}

private final class LockedCounter549: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

}
