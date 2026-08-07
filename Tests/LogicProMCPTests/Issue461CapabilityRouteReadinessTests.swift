import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #461 — a capability group may not outrun its operations
//
// `doctor --profile core` reported `core_transport: ready` while
// `transport.goto_position` had no runnable route, because the group's verdict
// came from environment checks tagged with its label and nothing joined those
// checks to the operations the group advertises. A new user's first action then
// failed against a setup doctor had just called ready.
//
// The fix is deliberately NOT a `goto_position` special case — that would leave
// every other operation exposed to the same drift. A group is ready only when
// every operation it advertises has a runnable route, and both the membership
// and the candidates come from one registry that reads the router's own table.
//
// These tests lock three things:
//   1. The registry is structurally sound — no advertised operation without a
//      route, no route that disagrees with what the router executes.
//   2. The regression: static checks all pass, AX is unavailable, and the group
//      must NOT be ready.
//   3. The release path, and the distinction between "will work", "will be
//      attempted", and "needs a manual step" — a planner that only ever said
//      not-ready would be as useless as the one that only ever said ready.

private let allChecksPassing = SetupDoctor.CheckStatus.pass

private func snapshot(
    accessibility: Bool = true,
    postEvent: Bool = true,
    automation: Bool = true,
    logicRunning: Bool = true,
    keycmdStaged: Bool? = true
) -> OperationCapabilityRegistry.HealthSnapshot {
    var satisfied: [String: Bool] = [
        "permissions.accessibility": accessibility,
        "permissions.post_event_access": postEvent,
        "permissions.automation_logic_pro": automation,
        "logic.application_state": logicRunning,
    ]
    var awaiting: Set<String> = []
    switch keycmdStaged {
    case .some(true):
        satisfied["channels.keycmd_reference"] = true
    case .some(false):
        satisfied["channels.keycmd_reference"] = false
    case nil:
        awaiting.insert("channels.keycmd_reference")
    }
    return OperationCapabilityRegistry.HealthSnapshot(satisfied: satisfied, awaitingManual: awaiting)
}

@Suite("Issue #461 — capability readiness is derived from operation routes")
struct Issue461CapabilityRouteReadinessTests {

    // MARK: Structural invariants

    /// Every operation a group advertises must exist in the routing table with at
    /// least one candidate. An advertised operation with no route is the exact
    /// shape of the defect: the group promises something nothing can run.
    @Test("every advertised operation has at least one route candidate")
    func advertisedOperationsHaveRoutes() {
        for (capability, operations) in OperationCapabilityRegistry.capabilityOperations {
            #expect(!operations.isEmpty, "\(capability) declares no operations")
            for operation in operations {
                let candidates = OperationCapabilityRegistry.routeCandidates(for: operation)
                #expect(
                    !candidates.isEmpty,
                    "\(capability) advertises \(operation), which has no route destination"
                )
            }
        }
    }

    /// The planner must read the SAME table the router executes. A second
    /// inventory that drifts is the failure this registry exists to remove, so
    /// this compares against the router's own map rather than a copy.
    @Test("planner candidates match the router's routing table exactly")
    func plannerAgreesWithRouter() {
        for operations in OperationCapabilityRegistry.capabilityOperations.values {
            for operation in operations {
                #expect(
                    OperationCapabilityRegistry.routeCandidates(for: operation)
                        == (ChannelRouter.v2RoutingTable[operation] ?? []),
                    "\(operation) plan diverges from the executed route"
                )
            }
        }
    }

    /// Every channel a declared route can reach must have a prerequisite entry,
    /// even an empty one. A missing entry would silently read as "no
    /// prerequisites" and mark an unusable channel executable.
    @Test("every reachable channel declares its prerequisites")
    func reachableChannelsDeclarePrerequisites() {
        for operations in OperationCapabilityRegistry.capabilityOperations.values {
            for channel in operations.flatMap({ OperationCapabilityRegistry.routeCandidates(for: $0) }) {
                #expect(
                    OperationCapabilityRegistry.channelPrerequisites[channel] != nil,
                    "\(channel.rawValue) is reachable but declares no prerequisite entry"
                )
            }
        }
    }

    // MARK: The regression

    /// The reported defect, at the operation level: AX controls are unavailable,
    /// so `goto_position` must not be ready even though nothing else changed.
    @Test("goto_position is not ready when Accessibility is unavailable")
    func gotoPositionNotReadyWithoutAccessibility() {
        let plan = OperationCapabilityRegistry.plan(
            operation: "transport.goto_position",
            health: snapshot(accessibility: false)
        )

        #expect(!plan.executableChannels.contains(.accessibility))
        #expect(plan.readiness != .readyVerified, "no verified path exists without AX readback")
        let axCandidate = plan.candidates.first { $0.channel == .accessibility }
        #expect(axCandidate?.blockingCheck == "permissions.accessibility")
    }

    /// The reported defect, at the group level: every static `core_transport`
    /// check passes, and the group must still not be reported ready.
    @Test("core_transport is not ready while a member operation has no verified route")
    func coreTransportNotReadyWhenAnOperationIsBlocked() {
        let plans = OperationCapabilityRegistry.plan(
            capability: "core_transport",
            health: snapshot(accessibility: false)
        )
        #expect(!plans.isEmpty, "core_transport must advertise operations or this proves nothing")

        let aggregate = OperationCapabilityRegistry.aggregate(plans)
        #expect(aggregate != .readyVerified, "a group may not be verified-ready past a blocked member")

        // `transport.set_tempo` and `get_state` are AX-only, so losing AX leaves
        // them with no candidate at all — the group verdict must follow the worst.
        let tempo = plans.first { $0.operation == "transport.set_tempo" }
        #expect(tempo?.readiness == .notReady)
        #expect(aggregate == .notReady, "the group is only as ready as its least-ready operation")
    }

    /// End-to-end through doctor, on the case where the two layers genuinely
    /// disagree — which is the only case that proves the route plan is consulted
    /// at all.
    ///
    /// With `permissions.accessibility` merely AWAITING approval rather than
    /// failed, the check layer reaches `unknown_live_verify_required`: nothing is
    /// broken, something is unconfirmed. The route layer knows more.
    /// `transport.set_tempo` routes through Accessibility and nothing else, so an
    /// unapproved AX permission leaves it with no candidate whatsoever — the
    /// group is NOT ready, and calling it merely "verify live" would invite an
    /// agent to try. A check-only verdict cannot see this, which is #461's class
    /// 4: an approval present while its actual prerequisite is not.
    @Test("doctor consults the route plan, not just the tagged check set")
    func doctorCapabilityFollowsRoutePlan() throws {
        let checks = doctorChecks(accessibilityStatus: .manual)
        let capability = SetupDoctor.capabilities(for: checks, profile: .core)["core_transport"]

        // The check layer alone would stop here — this pins that the fixture
        // really does put the two layers in disagreement, so the assertion below
        // cannot pass for the wrong reason.
        #expect(
            SetupDoctor.healthSnapshot(from: checks).satisfied["permissions.accessibility"] == nil,
            "an awaiting check must not be recorded as satisfied"
        )
        #expect(
            capability?.status == .notReady,
            "an AX-only operation with no approved AX permission is not ready, however the checks read"
        )
        // Unwrap once rather than comparing an Optional<Bool> to `true`: that
        // comparison compiles and passes even when the optional is nil, so it
        // would assert nothing about a capability the fixture failed to produce.
        let rows = try #require(capability?.operations, "core_transport must publish operation rows")
        #expect(
            rows.contains { $0.operation == "transport.set_tempo" && $0.readiness == "manual_setup_required" },
            "the blocked operation must be named, not just folded into the group verdict"
        )
        #expect(
            rows.contains { $0.blockedBy == "permissions.accessibility" },
            "output must name the setup action that would enable the operation"
        )
    }

    /// A hard permission failure must still be reported, and must still name the
    /// operation — this is the plainer half of the same contract.
    @Test("doctor reports the blocked operation when a permission has failed")
    func doctorNamesBlockedOperationOnFailure() throws {
        let capability = SetupDoctor.capabilities(
            for: doctorChecks(accessibilityStatus: .fail),
            profile: .core
        )["core_transport"]
        #expect(capability?.status == .notReady)
        let rows = try #require(capability?.operations, "core_transport must publish operation rows")
        #expect(rows.contains { $0.readiness == "not_ready" })
        #expect(rows.contains { $0.blockedBy == "permissions.accessibility" })
    }

    // MARK: The release path

    /// The gate must release, or doctor could never report a healthy machine.
    @Test("a healthy environment reports core_transport ready")
    func healthyEnvironmentIsReady() {
        let plans = OperationCapabilityRegistry.plan(capability: "core_transport", health: snapshot())
        #expect(OperationCapabilityRegistry.aggregate(plans) == .readyVerified)
        #expect(plans.allSatisfy { !$0.executableChannels.isEmpty })

        let ready = SetupDoctor.capabilities(for: doctorChecks(accessibilityStatus: .pass), profile: .core)
        #expect(ready["core_transport"]?.status == .ready)
    }

    /// A held manual step is not a broken machine. It must read as
    /// manual-setup-required, so the user is told what to do rather than that
    /// something is wrong — and it must still not read as ready.
    @Test("an operation whose only route awaits manual setup is distinguished from a failure")
    func awaitingManualIsItsOwnStatus() {
        // capture_recording routes only through Key Commands and CGEvent, so
        // holding the keycmd staging check plus removing post-event access
        // leaves nothing executable and nothing broken.
        let plan = OperationCapabilityRegistry.plan(
            operation: "transport.capture_recording",
            health: snapshot(postEvent: false, keycmdStaged: nil)
        )
        #expect(plan.readiness == .manualSetupRequired)
        #expect(plan.readiness != .notReady, "an unfinished setup step is not a failure")
    }

    /// A send-only route must never be promoted to verified readiness. This is
    /// the Honest Contract line: CGEvent actuates without reading back.
    @Test("a send-only-only route is degraded, never verified-ready")
    func sendOnlyRouteIsNotVerified() {
        // transport.stop routes CGEvent -> AX -> MCU -> CoreMIDI -> AppleScript.
        // Removing both readback-capable channels leaves only send-only paths.
        let plan = OperationCapabilityRegistry.plan(
            operation: "transport.stop",
            health: snapshot(accessibility: false, automation: false)
        )
        #expect(plan.executableChannels.contains(.cgEvent))
        #expect(plan.readiness != .readyVerified, "CGEvent cannot read back, so it cannot verify")
        #expect(plan.readiness == .readyDegraded)
    }

    /// Verification strength is a property of the channel, and every channel must
    /// declare one — an unclassified channel would default into whichever branch
    /// the compiler picked and could silently be treated as verified.
    @Test("every channel declares a verification strength")
    func everyChannelHasVerificationStrength() {
        let verified = ChannelID.allCases.filter {
            OperationCapabilityRegistry.verificationStrength(of: $0) == .verified
        }
        #expect(verified.contains(.accessibility), "AX reads back and must count as verified")
        #expect(!verified.contains(.cgEvent), "CGEvent is send-only")
        #expect(!verified.contains(.mcu), "MCU feedback is not an independent readback")
    }
}

/// A doctor check set where every `core_transport` check passes except, when
/// asked, the Accessibility permission — the exact reported configuration.
private func doctorChecks(accessibilityStatus: SetupDoctor.CheckStatus) -> [SetupDoctor.Check] {
    let ids = [
        "binary.path", "binary.executable", "permissions.accessibility",
        "permissions.post_event_access", "permissions.automation_logic_pro",
        "logic.installation", "logic.version_support", "logic.application_state",
        "channels.keycmd_reference",
    ]
    return ids.map { id in
        SetupDoctor.check(
            id: id,
            domain: "test",
            status: id == "permissions.accessibility" ? accessibilityStatus : allChecksPassing,
            summary: "fixture",
            evidence: [:],
            remediationType: .none
        )
    }
}
