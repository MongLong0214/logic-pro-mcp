import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #457 — approval must not be offered before the setup it attests
//
// `--approve-channel` records an OPERATOR ASSERTION that manual setup happened.
// It neither configures nor verifies Logic. The fix plan listed it before
// `channels.keycmd_reference`, so a new user approved both channels first and
// only afterwards discovered Key Commands had never been staged — a durable
// false attestation the helper cannot repair, because Logic 12.2+ still needs a
// manual MIDI Learn that no file-presence check can prove.
//
// The fix declares the dependency and holds the approval check until staging
// passes. `computeFixPlan` drops blocked checks, so the prompt disappears from
// the plan rather than merely sorting later.
//
// These tests lock both directions. A gate that only ever blocks would be as
// wrong as one that never blocks, so the release path is asserted too.

private func manualCheck(staged: Bool, profile: SetupDoctor.DoctorProfile = .keycmd) -> SetupDoctor.Check {
    let keycmd = SetupDoctor.check(
        id: "channels.keycmd_reference",
        domain: "channels",
        status: staged ? .pass : .manual,
        summary: staged ? "staged" : "not staged",
        evidence: ["preset_staged": String(staged)],
        remediationType: staged ? .none : .command
    )
    return SetupDoctor.manualValidationCheck(
        approvals: [:],
        profile: profile,
        storeHealth: .ok,
        checks: [keycmd]
    )
}

@Suite("Issue #457 — approval ordering")
struct Issue457ApprovalOrderingTests {
    /// The regression: approving before staging is a false attestation.
    @Test("approval is held while Key Commands staging is incomplete")
    func approvalHeldUntilStagingCompletes() {
        let manual = manualCheck(staged: false)
        #expect(manual.blockedBy == "channels.keycmd_reference")
        #expect(manual.status == .skipped)
    }

    /// A held check must actually leave the fix plan, not just sort later —
    /// sorting alone still shows the user the premature command.
    @Test("a held approval does not appear in the fix plan")
    func heldApprovalIsAbsentFromFixPlan() {
        let keycmd = SetupDoctor.check(
            id: "channels.keycmd_reference",
            domain: "channels",
            status: .manual,
            summary: "not staged",
            evidence: [:],
            remediationType: .command
        )
        let plan = SetupDoctor.computeFixPlan([keycmd, manualCheck(staged: false)])
        #expect(plan.contains("channels.keycmd_reference"), "staging must still be offered")
        #expect(
            !plan.contains("channels.manual_validation"),
            "approval must not be offered before the setup it attests"
        )
    }

    /// The gate must release, or the user could never approve at all.
    @Test("approval is offered once staging passes")
    func approvalReleasedAfterStaging() {
        let manual = manualCheck(staged: true)
        #expect(manual.blockedBy == nil, "staging complete must release the approval prompt")
        #expect(manual.status == .manual, "approval is still required, just no longer premature")
    }

    /// Profile scoping outranks the dependency: a profile that never needs these
    /// channels must report `profile_not_required`, not "waiting on staging".
    @Test("a profile that does not require manual channels is unaffected")
    func profileScopingWinsOverBlocking() {
        let manual = manualCheck(staged: false, profile: .core)
        #expect(manual.skipReason == .profileNotRequired)
        #expect(manual.blockedBy == nil)
    }
}
