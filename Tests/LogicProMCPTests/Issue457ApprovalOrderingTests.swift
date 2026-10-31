import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #457 — legacy assertions never qualify unattended execution
//
// Legacy records neither configure nor verify Logic. They stay readable for
// compatibility, but cannot become a success gate or a remediation request.
//
// The staging dependency still collapses the causal chain to its root. Once it
// resolves, the check reports a terminal unattended-unavailable result.

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

    /// Staging can establish file presence, but a stored operator assertion is
    /// not an unattended readback and must never become a success gate.
    @Test("staging does not expose a human approval continuation")
    func approvalIsTerminalAfterStaging() {
        let manual = manualCheck(staged: true)
        #expect(manual.blockedBy == nil)
        #expect(manual.status == .fail)
        #expect(manual.remediation.type == .none)
        #expect(manual.remediation.value == "")
        #expect(manual.evidence["terminal"] == "true")
        #expect(manual.evidence["human_intervention_required"] == "false")
        #expect(manual.evidence["human_intervention_requests"] == "0")
        #expect(!SetupDoctor.computeFixPlan([manual]).contains("channels.manual_validation"))
    }

    @Test("a stored approval does not qualify unattended execution")
    func storedApprovalDoesNotPass() {
        let approval = ManualValidationApproval(
            approvedAt: Date(timeIntervalSince1970: 0),
            note: "legacy"
        )
        let manual = SetupDoctor.manualValidationCheck(
            approvals: [.midiKeyCommands: approval, .scripter: approval],
            profile: .full,
            storeHealth: .ok,
            checks: [SetupDoctor.check(
                id: "channels.keycmd_reference",
                domain: "channels",
                status: .pass,
                summary: "staged",
                evidence: [:],
                remediationType: .none
            )]
        )
        #expect(manual.status == .fail)
        #expect(manual.remediation.type == .none)
        #expect(manual.evidence["legacy_approvals_ignored"] == "MIDIKeyCommands,Scripter")
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
