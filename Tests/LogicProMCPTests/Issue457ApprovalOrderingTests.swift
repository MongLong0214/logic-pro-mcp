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
        status: staged ? .pass : .warn,
        summary: staged ? "staged" : "not staged",
        evidence: ["preset_staged": String(staged)],
        remediationType: .none
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
    /// A reference file cannot make the mapped channel ready, so its absence
    /// must not delay or replace the terminal unattended result.
    @Test("missing reference does not delay terminal channel result")
    func missingReferenceDoesNotDelayTerminalResult() {
        let manual = manualCheck(staged: false)
        #expect(manual.blockedBy == nil)
        #expect(manual.status == .fail)
        #expect(manual.remediation.type == .none)
        #expect(manual.evidence["terminal"] == "true")
    }

    @Test("missing reference and terminal channel expose no fix action")
    func missingReferenceAndTerminalChannelAreAbsentFromFixPlan() {
        let keycmd = SetupDoctor.check(
            id: "channels.keycmd_reference",
            domain: "channels",
            status: .warn,
            summary: "not staged",
            evidence: [:],
            remediationType: .none
        )
        let plan = SetupDoctor.computeFixPlan([keycmd, manualCheck(staged: false)])
        #expect(!plan.contains("channels.keycmd_reference"))
        #expect(!plan.contains("channels.manual_validation"))
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

    /// A profile that never needs these channels remains outside the terminal check.
    @Test("a profile that does not require manual channels is unaffected")
    func profileScopingWinsOverBlocking() {
        let manual = manualCheck(staged: false, profile: .core)
        #expect(manual.skipReason == .profileNotRequired)
        #expect(manual.blockedBy == nil)
    }
}
