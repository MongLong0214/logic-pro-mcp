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
@Suite(.serialized) struct Issue999GotoRefusalReceiptTests {
    typealias Harness = Issue942PostLeafMenuReconciliationTests

    static func expectReceipt(
        _ envelope: [String: Any], site: AccessibilityChannel.PostLeafCleanupSite,
        dialogCleanup: String, menuState: String
    ) throws {
        #expect(try #require(envelope["dialog_cleanup"] as? String) == dialogCleanup, "\(site.identifier)")
        #expect(try #require(envelope["menu_state"] as? String) == menuState, "\(site.identifier)")
        #expect(try #require(envelope["fallback_unsafe"] as? Bool), "\(site.identifier)")
        #expect(try #require(envelope["menu_actuation_attempted"] as? Bool), "\(site.identifier)")
        if Harness.refusesAsStateC(site) {
            #expect(try #require(envelope["state"] as? String) == "C", "\(site.identifier)")
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

    /// The eight sites whose result is refused as State B whatever their cleanup said.
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

    /// The other four sites fall through to the unavailable State C receipt once cleanup closes.
    @Test(arguments: AccessibilityChannel.postLeafCleanupSites.filter {
        Issue942PostLeafMenuReconciliationTests.refusesAsStateC($0)
    }.map(\.identifier))
    func aCleanPostLeafStateCFallthroughReportsTheLeafClick(_ identifier: String) async throws {
        let site = try Harness.site(identifier)
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: "OPEN", result: "\(site.resultPrefix): fixture")
        #expect(run.calls == 0)
        #expect(try #require(run.envelope["state"] as? String) == "C")
        #expect(try #require(run.envelope["menu_actuation_attempted"] as? Bool), "\(identifier)")
    }

    @Test func aSuccessfulDialogResultReportsTheLeafClick() async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(site, reconcilerAnswer: "OPEN", result: "OK")
        #expect(run.calls == 0)
        #expect(try #require(run.envelope["state"] as? String) == "B")
        #expect(try #require(run.envelope["menu_actuation_attempted"] as? Bool))
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

    /// A child that dies at LEAF_ARMED may not have clicked the leaf. The snapshot pass reads the
    /// dialog first and answers CLOSED only after it has also read the menus closed; its answer
    /// settles the cleanup fields while the click stays indeterminate.
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
        #expect(envelope["menu_actuation_attempted"] == nil)
        #expect(try #require(envelope["menu_actuation_indeterminate"] as? Bool))
    }

    @Test(arguments: ["SELECT_ALL_ARMED", "POSITION_INPUT_ARMED", "RETURN_ARMED"])
    func aDeadChildAfterTheLeafReportsTheClick(_ stage: String) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: "OPEN", executionFailureStage: stage)
        #expect(try #require(run.envelope["state"] as? String) == "B")
        #expect(try #require(run.envelope["menu_actuation_attempted"] as? Bool), "\(stage)")
        #expect(run.envelope["menu_actuation_indeterminate"] == nil)
    }

    /// NOT_ISSUED and an unreadable ledger can still follow the menu-bar revalidation click.
    /// Neither marker proves whether that earlier click happened.
    @Test(arguments: ["NOT_ISSUED", "UNKNOWN"])
    func aDeadChildWithoutMenuEvidenceIsIndeterminate(_ stage: String) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: "OPEN", executionFailureStage: stage)
        let state = try #require(run.envelope["state"] as? String)
        if stage == "UNKNOWN" {
            #expect(state == "B")
        } else {
            #expect(state == "C")
        }
        #expect(run.envelope["menu_actuation_attempted"] == nil)
        #expect(try #require(run.envelope["menu_actuation_indeterminate"] as? Bool))
    }

    /// The leaf was not clicked on these paths, but the forced menu-bar revalidation may have
    /// clicked earlier. The script's flag records either menu actuation.
    static let preLeafResults = [
        "DIALOG_PREEXISTING: Go To Position dialog was already present before leaf click",
        "DIALOG_PREEXISTENCE_UNREADABLE: Go To Position window snapshot was unreadable before leaf click",
        "DIALOG_PREEXISTENCE_UNREADABLE: Go To Position window count was unreadable before leaf click",
        "DIALOG_PREEXISTENCE_UNREADABLE: Go To Position window snapshot could not be persisted before leaf click",
        "MENU_PICK_FAILED: could not persist dialog issuance before leaf click",
    ]

    @Test(arguments: preLeafResults, [true, false])
    func aPreLeafRefusalCarriesTheMenuBarAttempt(_ result: String, _ attempted: Bool) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: "CLOSED",
            result: "\(result) menu_actuation_attempted=\(attempted)")
        let envelope = run.envelope
        #expect(try #require(envelope["state"] as? String) == "C")
        let reported = try #require(envelope["menu_actuation_attempted"] as? Bool)
        if attempted {
            #expect(reported, "\(result)")
        } else {
            #expect(!reported, "\(result)")
        }
        #expect(envelope["menu_actuation_indeterminate"] == nil)
        if !result.hasPrefix("MENU_PICK_FAILED") {
            #expect(!(try #require(envelope["dialog_actuation_attempted"] as? Bool)))
        }
    }

    @Test(arguments: preLeafResults)
    func aPreLeafResultWithoutTheFlagIsIndeterminate(_ result: String) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(site, reconcilerAnswer: "CLOSED", result: result)
        #expect(run.envelope["menu_actuation_attempted"] == nil)
        #expect(try #require(run.envelope["menu_actuation_indeterminate"] as? Bool))
    }

    @Test(arguments: preLeafResults)
    func aPreLeafResultWithAnUnreadableFlagIsIndeterminate(_ result: String) async throws {
        let site = try Harness.site("dialog_not_ready")
        let run = try await Harness.runMenuRefusal(
            site, reconcilerAnswer: "CLOSED", result: "\(result) menu_actuation_attempted=garbage")
        #expect(run.envelope["menu_actuation_attempted"] == nil)
        #expect(try #require(run.envelope["menu_actuation_indeterminate"] as? Bool))
    }

    @Test func everyPreLeafReturnEmitsTheRecordedFlag() {
        let script = AccessibilityChannel.gotoPositionViaDialogAppleScript(bar: 999)
        for result in Self.preLeafResults {
            #expect(script.contains(
                "return \"\(result) menu_actuation_attempted=\" & (menuActuationAttempted as text)"
            ), "\(result)")
        }
    }
}
