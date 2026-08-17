@preconcurrency import ApplicationServices
import Testing
import Foundation
@testable import LogicProMCP

/// #554 — the AX-status pair annotates whichever unreadable reason a receipt currently reports, so it has
/// to be written totally: set when the reason carries a status, REMOVED when it does not.
///
/// `verifyTrackCreation` merges twice into one dictionary. The status keys used to be written only when a
/// status existed, so a second reason without one left the first reason's status standing beside it — a
/// `stray_menu_read_failed` envelope carrying a `-25200` that belonged to a sheet scan in an earlier
/// poll. That is a number describing a different failure, which is worse than no number.
@Suite("Issue #554 — the AX status pair moves with the reason it annotates")
struct Issue554StatusFollowsItsReasonTests {

    @Test("a reason with no status clears a status left by an earlier reason")
    func statusIsClearedWhenTheNewReasonHasNone() throws {
        var extras: [String: Any] = [:]
        AccessibilityChannel.ModalReadFailure
            .windowSheetReadFailed(AXHelpers.AXStatusError(raw: -25200))
            .apply(to: &extras)
        let first = try #require(extras["reconciled_modal_unreadable_ax_status"] as? Int)
        #expect(first == -25200)

        // A later poll fails for a reason that carries no AX status at all.
        AccessibilityChannel.ModalReadFailure.strayMenuReadFailed.apply(to: &extras)

        let reason = try #require(extras["reconciled_modal_unreadable_reason"] as? String)
        #expect(reason == "stray_menu_read_failed")
        #expect(
            extras["reconciled_modal_unreadable_ax_status"] == nil,
            "a status from the previous reason must not survive beside a reason that has none"
        )
        #expect(extras["reconciled_modal_unreadable_ax_status_name"] == nil)
    }

    @Test("a reason that carries a status still publishes it")
    func statusIsPublishedWhenPresent() throws {
        var extras: [String: Any] = [:]
        AccessibilityChannel.ModalReadFailure
            .mainWindowReadFailed(AXHelpers.AXStatusError(raw: -25204))
            .apply(to: &extras)
        let status = try #require(extras["reconciled_modal_unreadable_ax_status"] as? Int)
        #expect(status == -25204)
        let name = try #require(extras["reconciled_modal_unreadable_ax_status_name"] as? String)
        #expect(!name.isEmpty)
    }

    @Test("a later status replaces an earlier one rather than either surviving")
    func aNewStatusReplacesTheOld() throws {
        var extras: [String: Any] = [:]
        AccessibilityChannel.ModalReadFailure
            .windowSheetReadFailed(AXHelpers.AXStatusError(raw: -25200))
            .apply(to: &extras)
        AccessibilityChannel.ModalReadFailure
            .axWindowsReadFailed(AXHelpers.AXStatusError(raw: -25204))
            .apply(to: &extras)
        let status = try #require(extras["reconciled_modal_unreadable_ax_status"] as? Int)
        #expect(status == -25204)
        let reason = try #require(extras["reconciled_modal_unreadable_reason"] as? String)
        #expect(reason == "axwindows_read_failed")
    }
}

// MARK: - The sentinel sources have no symbolic name, and are not "no status"

/// `AXStatusError.malformedAttribute` and `.malformedChildren` are production sentinels deliberately
/// outside `AXError`, so `symbolicName` is nil for both. Gating the pair on the NAME deleted the status
/// field as well, publishing a receipt that says no unreadable status existed — for the exact failures
/// those sentinels were introduced to make visible.
@Test func testIssue554MalformedSourcesStillPublishTheirStatusPair() throws {
    let cases: [(AXHelpers.AXStatusError, String, Int)] = [
        (.malformedAttribute, "malformed_attribute", Int(Int32.min) + 1),
        (.malformedChildren, "malformed_children", Int(Int32.min)),
    ]
    for (status, expectedName, expectedRaw) in cases {
        // Precondition: this is the shape that broke it. If a future change gives these sources a
        // symbolic name this test would silently stop covering the regression, so assert the absence.
        #expect(status.symbolicName == nil)

        var extras: [String: Any] = [:]
        AccessibilityChannel.ModalReadFailure.windowSheetReadFailed(status).apply(to: &extras)

        #expect(try #require(extras["reconciled_modal_unreadable_ax_status"] as? Int) == expectedRaw)
        #expect(try #require(extras["reconciled_modal_unreadable_ax_status_name"] as? String) == expectedName)
    }
}

/// Control: an ordinary `AXError`-backed status must still publish its symbolic spelling, not the bare
/// number. Without this, the fix above could be satisfied by rendering every status as `diagnosticLabel`,
/// which degrades the common case from `cannotComplete` to `-25204`.
@Test func testIssue554OrdinaryStatusStillPublishesItsSymbolicName() throws {
    var extras: [String: Any] = [:]
    AccessibilityChannel.ModalReadFailure
        .windowSheetReadFailed(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        .apply(to: &extras)
    #expect(try #require(extras["reconciled_modal_unreadable_ax_status_name"] as? String) == "cannotComplete")
    #expect(try #require(extras["reconciled_modal_unreadable_ax_status"] as? Int) == Int(AXError.cannotComplete.rawValue))
}
