import Foundation

/// #461 — the shared source of truth linking a doctor capability GROUP to the
/// operations it claims, and each operation to the channels that can actually
/// run it.
///
/// Before this, doctor and the runtime reasoned about readiness through two
/// unconnected abstractions. Doctor aggregated environment checks tagged with a
/// group label; the runtime resolved an operation string to an ordered channel
/// list and executed. Nothing joined them, so `core_transport` could report
/// `ready` on the strength of "Accessibility permission is granted, Logic is
/// running" while `transport.goto_position` had no runnable path at all — which
/// is exactly what a new user hit as their first action.
///
/// The fix is not a `goto_position` special case. A capability group is READY
/// only when every operation it advertises has a runnable route, and both the
/// group membership and the route candidates are declared here, in one place,
/// derived from the routing table the router itself executes.
enum OperationCapabilityRegistry {

    // MARK: - Channel prerequisites

    /// What a channel needs from the environment before it can run anything.
    ///
    /// These are the doctor check IDs whose failure makes the channel unusable.
    /// Keeping the mapping here — rather than inside doctor's rendering — is what
    /// lets a route plan be computed from a health snapshot without doctor.
    static let channelPrerequisites: [ChannelID: [String]] = [
        .accessibility: ["permissions.accessibility", "logic.application_state"],
        .cgEvent: ["permissions.post_event_access", "logic.application_state"],
        .appleScript: ["permissions.automation_logic_pro", "logic.application_state"],
        // Key Commands actuation rides CoreMIDI and needs the staged preset; the
        // staging check is the one that told users to approve before setup (#457).
        .midiKeyCommands: ["channels.keycmd_reference"],
        // MCU and CoreMIDI have no environment check that can PROVE they work —
        // Logic-side control-surface wiring is not observable from outside. They
        // are therefore never a basis for a verified-ready claim; see
        // `verificationStrength`.
        .mcu: [],
        .coreMIDI: [],
        .scripter: [],
    ]

    /// How strongly a channel's success can be believed.
    ///
    /// A send-only channel actuates and cannot read back, so a route whose only
    /// reachable candidate is send-only must never be published as verified —
    /// that is the difference between "this will work" and "this will be
    /// attempted". Doctor downgrades such a route to a live-verify claim.
    enum VerificationStrength: String, Sendable {
        /// Writes and independently reads the result back.
        case verified
        /// Actuates without readback. Honest Contract State B territory.
        case sendOnly
    }

    static func verificationStrength(of channel: ChannelID) -> VerificationStrength {
        switch channel {
        case .accessibility, .appleScript:
            return .verified
        case .cgEvent, .mcu, .coreMIDI, .midiKeyCommands, .scripter:
            return .sendOnly
        }
    }

    // MARK: - Capability membership

    /// Operations each capability group advertises.
    ///
    /// Membership is explicit rather than inferred from the operation-name prefix:
    /// `transport.get_state` is a read that a broken write path does not make
    /// unavailable, and grouping by prefix would drag it into the same verdict.
    /// An operation listed here is one an agent can invoke once the group is
    /// presented as ready, so listing it is a promise.
    static let capabilityOperations: [String: [String]] = [
        "core_transport": [
            "transport.play",
            "transport.stop",
            "transport.record",
            "transport.goto_position",
            "transport.get_state",
            "transport.toggle_cycle",
            "transport.toggle_metronome",
            "transport.set_tempo",
        ],
        "track_management": [
            "track.get_tracks",
            "track.select",
            "track.create_audio",
            "track.create_instrument",
            "track.rename",
            "track.delete",
        ],
        "midi_import": ["midi.import_file"],
        "project_lifecycle": ["project.save", "project.open"],
    ]

    /// The channels that can run an operation, in the order the router tries
    /// them. Read from the router's OWN table so a plan cannot drift from what
    /// actually executes — a second inventory is precisely the failure this
    /// registry exists to remove.
    static func routeCandidates(for operation: String) -> [ChannelID] {
        ChannelRouter.v2RoutingTable[operation] ?? []
    }

    // MARK: - Route planning

    /// Why a candidate cannot run. Structural only — no user content.
    enum CandidateBlock: String, Sendable {
        case missingPrerequisite = "missing_prerequisite"
        case prerequisiteUnknown = "prerequisite_unknown"
        case awaitingManualSetup = "awaiting_manual_setup"
    }

    struct CandidatePlan: Sendable, Equatable {
        let channel: ChannelID
        let block: CandidateBlock?
        /// The prerequisite check that blocked it, when one did.
        let blockingCheck: String?

        var isExecutable: Bool { block == nil }
    }

    /// Operation-level readiness. Distinguishing these is the point: a single
    /// ready/not-ready bit cannot say "this will run but cannot be verified" or
    /// "this needs a manual step you have not done", and collapsing them is how
    /// a group came to be published as ready.
    enum OperationReadiness: String, Sendable {
        /// A verified-strength candidate is executable.
        case readyVerified = "ready_verified"
        /// Only send-only candidates are executable — it will be attempted, not
        /// confirmed.
        case readyDegraded = "ready_degraded"
        /// Executable, but the only candidates need live confirmation that no
        /// environment check can supply.
        case unknownLiveVerifyRequired = "unknown_live_verify_required"
        /// Every candidate is blocked by a manual step the operator has not done.
        case manualSetupRequired = "manual_setup_required"
        /// No candidate can run.
        case notReady = "not_ready"
    }

    struct OperationPlan: Sendable, Equatable {
        let operation: String
        let readiness: OperationReadiness
        let candidates: [CandidatePlan]

        var executableChannels: [ChannelID] {
            candidates.filter(\.isExecutable).map(\.channel)
        }
    }

    /// A snapshot of what the environment currently supports, keyed by doctor
    /// check ID. `nil` for a check that was not run — deliberately distinct from
    /// `false`, because "we did not look" must not read as "it works".
    struct HealthSnapshot: Sendable {
        let satisfied: [String: Bool]
        /// Checks awaiting an operator action rather than failing outright.
        let awaitingManual: Set<String>

        init(satisfied: [String: Bool], awaitingManual: Set<String> = []) {
            self.satisfied = satisfied
            self.awaitingManual = awaitingManual
        }
    }

    /// Plan one operation against a health snapshot. Pure — no AX, no I/O — so
    /// doctor and any future runtime pre-check can share it and cannot disagree.
    static func plan(operation: String, health: HealthSnapshot) -> OperationPlan {
        let candidates = routeCandidates(for: operation).map { channel -> CandidatePlan in
            let prerequisites = channelPrerequisites[channel] ?? []
            for check in prerequisites {
                if health.awaitingManual.contains(check) {
                    return CandidatePlan(channel: channel, block: .awaitingManualSetup, blockingCheck: check)
                }
                guard let satisfied = health.satisfied[check] else {
                    return CandidatePlan(channel: channel, block: .prerequisiteUnknown, blockingCheck: check)
                }
                if !satisfied {
                    return CandidatePlan(channel: channel, block: .missingPrerequisite, blockingCheck: check)
                }
            }
            return CandidatePlan(channel: channel, block: nil, blockingCheck: nil)
        }

        return OperationPlan(
            operation: operation,
            readiness: readiness(for: candidates),
            candidates: candidates
        )
    }

    private static func readiness(for candidates: [CandidatePlan]) -> OperationReadiness {
        let executable = candidates.filter(\.isExecutable)
        guard !executable.isEmpty else {
            // An operation with NO declared route is not ready either. Reporting
            // it as ready-by-vacuity is the shape of the original defect.
            if candidates.contains(where: { $0.block == .awaitingManualSetup }) {
                return .manualSetupRequired
            }
            return .notReady
        }
        if executable.contains(where: { verificationStrength(of: $0.channel) == .verified }) {
            return .readyVerified
        }
        // Executable, but nothing that reads back. MCU and CoreMIDI additionally
        // have no environment check at all, so their "executable" is an absence
        // of evidence rather than evidence of presence.
        if executable.allSatisfy({ (channelPrerequisites[$0.channel] ?? []).isEmpty }) {
            return .unknownLiveVerifyRequired
        }
        return .readyDegraded
    }

    /// Plan every operation a capability group advertises.
    static func plan(capability: String, health: HealthSnapshot) -> [OperationPlan] {
        (capabilityOperations[capability] ?? []).map { plan(operation: $0, health: health) }
    }

    /// The group's verdict, which is the WEAKEST of its operations. A group is
    /// only as ready as the least-ready thing it lets an agent call — averaging
    /// or majority would reproduce the original bug on a single broken operation.
    static func aggregate(_ plans: [OperationPlan]) -> OperationReadiness? {
        guard !plans.isEmpty else { return nil }
        let order: [OperationReadiness] = [
            .notReady, .manualSetupRequired, .unknownLiveVerifyRequired, .readyDegraded, .readyVerified,
        ]
        return plans
            .map(\.readiness)
            .min { lhs, rhs in
                (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
            }
    }
}
