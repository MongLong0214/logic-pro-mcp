import Foundation
import Testing
@testable import LogicProMCP

/// #999. A goto_position receipt written after the leaf click must say the menu was actuated, and
/// must report the dialog cleanup and the menu cleanup each from its own observation.
///
/// Every post-leaf site closes the Go To Position dialog first and the menu second
/// (`Issue942PostLeafMenuReconciliationTests.eachSiteSettlesTheDialogBeforeTheMenu`), so each of
/// its three results fixes both halves:
///
/// | result            | dialog_cleanup | menu_state                               |
/// |-------------------|----------------|------------------------------------------|
/// | dialog refusal    | unobserved     | unobserved (the menu cleanup never ran)  |
/// | menu refusal      | closed         | closed or could_not_be_closed, from the reconciliation pass |
/// | the site's result | closed         | closed                                   |
///
/// Before #999 the menu refusal said `dialog_cleanup: "unobserved"`, the State B receipt carried no
/// `menu_state` at all, and the State C receipt said `menu_actuation_attempted: false`.
@Suite struct Issue999GotoRefusalReceiptTests {
    typealias Harness = Issue942PostLeafMenuReconciliationTests

    static func expectReceipt(
        _ envelope: [String: Any], site: AccessibilityChannel.PostLeafCleanupSite,
        dialogCleanup: String, menuState: String
    ) throws {
        #expect(try #require(envelope["dialog_cleanup"] as? String) == dialogCleanup, "\(site.identifier)")
        #expect(try #require(envelope["menu_state"] as? String) == menuState, "\(site.identifier)")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool), "\(site.identifier)")
        if Harness.refusesAsStateC(site) {
            #expect(try #require(envelope["state"] as? String) == "C", "\(site.identifier)")
            #expect(try #require(envelope["menu_actuation_attempted"] as? Bool), "\(site.identifier)")
        } else {
            #expect(try #require(envelope["state"] as? String) == "B", "\(site.identifier)")
        }
    }

    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.map(\.identifier), [true, false])
    func aMenuRefusalReportsTheDialogClosedAndTheMenuAsReconciled(
        _ identifier: String, reconcilerObservedClosed: Bool
    ) async throws {
        let site = try Harness.site(identifier)
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: reconcilerObservedClosed ? "CLOSED" : "OPEN")
        try Self.expectReceipt(
            run.envelope, site: site, dialogCleanup: "closed",
            menuState: reconcilerObservedClosed ? "closed" : "could_not_be_closed")
    }

    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.map(\.identifier))
    func aDialogRefusalReportsNeitherHalfClosed(_ identifier: String) async throws {
        let site = try Harness.site(identifier)
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: "CLOSED", result: Harness.dialogRefusal(site))
        try Self.expectReceipt(run.envelope, site: site, dialogCleanup: "unobserved", menuState: "unobserved")
    }

    /// The eight sites whose result is refused as State B whatever their cleanup said. The four
    /// State C sites' own results are not refusals, so they end in no receipt this suite reads.
    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.filter {
        !Issue942PostLeafMenuReconciliationTests.refusesAsStateC($0)
    }.map(\.identifier))
    func aSitesOwnResultReportsBothHalvesClosed(_ identifier: String) async throws {
        let site = try Harness.site(identifier)
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: "OPEN", result: "\(site.resultPrefix): fixture")
        #expect(run.calls == 0, "both halves were observed closed, so nothing is reconciled")
        try Self.expectReceipt(run.envelope, site: site, dialogCleanup: "closed", menuState: "closed")
    }

    /// The two post-leaf returns that run no cleanup at all still followed the leaf click.
    @Test(arguments: ["DIALOG_UNIDENTIFIED_NEW_WINDOW", "DIALOG_APPEARANCE_UNREADABLE"])
    func aDialogThatNeverAppearedStillFollowedTheLeafClick(_ result: String) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(site, reconcilerAnswer: "CLOSED", result: result)
        let envelope = run.envelope
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["menu_actuation_attempted"] as? Bool))
        #expect(try #require(envelope["dialog_actuation_attempted"] as? Bool))
        #expect(try #require(envelope["dialog_cleanup"] as? String) == "unobserved")
        #expect(try #require(envelope["menu_state"] as? String) == "unobserved")
    }

    /// A child that dies after the leaf is reconciled with the snapshot pass, which reads the
    /// dialog first and answers CLOSED only after it has also read the menus closed. So one answer
    /// fixes both halves of the State B receipt.
    @Test(arguments: [true, false])
    func aReconciledExecutionFailureReportsBothHalvesFromThePass(_ reconcilerObservedClosed: Bool) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: reconcilerObservedClosed ? "CLOSED" : "OPEN",
            executionFailureStage: "LEAF_ARMED")
        let envelope = run.envelope
        #expect(run.calls == 1)
        #expect(try #require(run.script).contains(run.snapshotPath), "the snapshot pass, not the menu-only one")
        #expect(try #require(envelope["state"] as? String) == "B")
        #expect(try #require(envelope["dialog_route_outcome"] as? String)
            == "execution_failed_issuance_LEAF_ARMED_cleanup_closed_\(reconcilerObservedClosed)")
        let observed = reconcilerObservedClosed ? "closed" : "unobserved"
        #expect(try #require(envelope["dialog_cleanup"] as? String) == observed)
        #expect(try #require(envelope["menu_state"] as? String) == observed)
    }

    /// The pre-leaf refusals are the control: the leaf was never clicked, and they still say so.
    @Test(arguments: [
        "DIALOG_PREEXISTING: Go To Position dialog was already present before leaf click",
        "DIALOG_PREEXISTENCE_UNREADABLE: Go To Position window snapshot could not be persisted before leaf click",
    ])
    func aPreLeafRefusalStillSaysTheLeafWasNotClicked(_ result: String) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(site, reconcilerAnswer: "CLOSED", result: result)
        #expect(try #require(run.envelope["state"] as? String) == "C")
        #expect(!(try #require(run.envelope["dialog_actuation_attempted"] as? Bool)))
    }
}
