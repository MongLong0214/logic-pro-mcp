import Foundation
import Testing
@testable import LogicProMCP

/// The Import-button wait is ONE STAGE of `midi.import_file`'s script. A stage that outlasts the
/// script it runs in cannot report what it saw: the child is killed at the bound and the caller is
/// told the script timed out, which names no stage at all.
///
/// Measured 2026-09-13: raising the button wait to 30s under a 30s script bound turned the
/// envelope from `the Import button stayed disabled` — which says exactly where Logic stalled —
/// into `AppleScript error: timedOut`. The information loss is the defect; the ordering is the fix.
@Suite("midi.import_file stage budgets")
struct Issue594ImportButtonBudgetTests {
    @Test("the button-enable budget is inside the script bound it runs under")
    func midiImportButtonEnableBudgetIsInsideTheScriptBound() {
        #expect(ServerConfig.midiImportButtonEnableBudget < ServerConfig.midiImportAppleScriptTimeout)
    }

    /// The real invariant is not about one stage. Every stage can stall, and the script bound has
    /// to outlast the WORST CASE — all of them plus the fixed delays between them — or a raise to
    /// any single stage silently converts a precise failure into `AppleScript error: timedOut`.
    /// Asserting only the button budget would have passed the version that did exactly that.
    @Test("every stage budget plus the fixed delays fits inside the script bound")
    func midiImportStageBudgetsFitInsideTheScriptBound() {
        let worstCase = ServerConfig.midiImportFileOpenSheetBudget
            + ServerConfig.midiImportPathAcceptBudget
            + ServerConfig.midiImportButtonEnableBudget
            + ServerConfig.midiImportTempoProbeBudget
            + ServerConfig.midiImportFixedDelayAllowance
        #expect(worstCase <= ServerConfig.midiImportAppleScriptTimeout,
                "worst case \(worstCase)s exceeds the \(ServerConfig.midiImportAppleScriptTimeout)s script bound")
    }

    /// #449's floor, restated against the stages that own it: the sheet, the path entry and the
    /// tempo prompt are the loops that timeout measured at 17.2s, and the bound must outlast them
    /// even if the button never stalls at all.
    @Test("the stages beside the button still clear the measured floor")
    func theStagesBesideTheButtonClearTheMeasuredFloor() {
        let beside = ServerConfig.midiImportFileOpenSheetBudget
            + ServerConfig.midiImportPathAcceptBudget
            + ServerConfig.midiImportTempoProbeBudget
        #expect(beside >= 17.2)
    }
}
