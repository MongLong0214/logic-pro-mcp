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

    /// The script bound must also leave room for the stages BESIDE the button wait — the sheet,
    /// the path entry and the tempo prompt, whose summed per-iteration delays #449 measured at a
    /// 17.2s floor. This is the half of that floor the button wait does not own.
    @Test("the script bound leaves room for the stages beside the button wait")
    func theScriptBoundLeavesRoomForTheOtherStages() {
        let remaining = ServerConfig.midiImportAppleScriptTimeout
            - ServerConfig.midiImportButtonEnableBudget
        #expect(remaining >= 17.2)
    }

}
