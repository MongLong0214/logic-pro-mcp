import Foundation

extension SetupDoctor {
    static func accessibilityPermissionCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        check(
            id: "permissions.accessibility",
            domain: "permissions",
            status: status.accessibility ? .pass : .fail,
            summary: status.accessibility
                ? "Accessibility permission is granted\(principalClause(status))."
                : "Accessibility permission is not granted\(principalClause(status)).",
            evidence: principalEvidence(status, ["state": status.accessibilityState.rawValue]),
            remediationType: .none
        )
    }


    static func automationPermissionCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        let checkStatus: CheckStatus
        switch status.automationState {
        case .granted:
            checkStatus = .pass
        case .notGranted:
            checkStatus = .fail
        case .notVerifiable:
            checkStatus = .fail
        }
        return check(
            id: "permissions.automation_logic_pro",
            domain: "permissions",
            status: checkStatus,
            summary: automationSummary(for: status.automationState),
            evidence: ["state": status.automationState.rawValue],
            remediationType: .none
        )
    }


    static func systemEventsAutomationCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        // Surfaces the System Events automation target the runtime treats as a HARD
        // requirement (#188) but the v1 doctor dropped. A probe that could not run
        // remains distinguishable in evidence, but it is an explicit unsuccessful
        // terminal outcome rather than a request for a person to repair the host.
        let checkStatus: CheckStatus
        switch status.systemEventsAutomationState {
        case .granted:
            checkStatus = .pass
        case .notGranted:
            checkStatus = .fail
        case .notVerifiable:
            checkStatus = .fail
        }
        return check(
            id: "permissions.automation_system_events",
            domain: "permissions",
            status: checkStatus,
            summary: systemEventsSummary(for: status.systemEventsAutomationState, principal: status.principal),
            evidence: ["state": status.systemEventsAutomationState.rawValue],
            remediationType: .none
        )
    }


    static func postEventAccessCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        check(
            id: "permissions.post_event_access",
            domain: "permissions",
            status: status.postEventAccess ? .pass : .fail,
            summary: status.postEventAccess
                ? "PostEvent access for CGEvent-family operations is granted\(principalClause(status))."
                : "PostEvent access is denied\(principalClause(status)); CGEvent-family ops (transport.stop/pause + most edit/view/track fallbacks) will fail.",
            evidence: principalEvidence(status, ["post_event_access": status.postEventAccess ? "granted" : "denied"]),
            remediationType: .none
        )
    }


    static func launchContextCheck(
        runtime: Runtime,
        permissionStatus: PermissionChecker.PermissionStatus? = nil
    ) -> Check {
        let context = runtime.launchContext()
        // #1596: attribution comes only from the measured principal. The launch context is a hint
        // about the client found in the parent chain; it never names who the grants belong to.
        let hint = "launch context hint: \(context.context)"
        let summary: String
        if let principal = permissionStatus?.principal {
            summary = principal.isSelf
                ? "Permission results were measured for this LogicProMCP binary itself (\(principal.displayName)); grants held by the launching app do not apply to this server (\(hint))."
                : "Permission results were measured for the responsible process \(principal.displayName) (\(hint))."
        } else if permissionStatus != nil {
            summary = "The responsible process could not be measured, so permission results are shown without an identity; the identity is unresolved (\(hint))."
        } else {
            summary = "Permission results are not attributed to a process here (\(hint))."
        }
        var launchEvidence = principalEvidence(
            permissionStatus,
            ["launch_context": context.context, "responsible_hint": publicResponsibleHint(context)]
        )
        if let permissionStatus, permissionStatus.principal == nil {
            launchEvidence["tcc_principal"] = "unresolved"
        }
        return check(
            id: "permissions.launch_context",
            domain: "permissions",
            status: .pass,
            summary: summary,
            evidence: launchEvidence,
            remediationType: .none
        )
    }


    /// " for <principal>" when the principal was measured, so a denial names the process that was
    /// denied (#1596) instead of leaving the reader to assume it was the launcher app.
    static func principalClause(_ status: PermissionChecker.PermissionStatus) -> String {
        guard let principal = status.principal else { return "" }
        return principal.isSelf
            ? " for this LogicProMCP binary (\(principal.displayName))"
            : " for \(principal.displayName)"
    }


    static func principalEvidence(
        _ status: PermissionChecker.PermissionStatus?,
        _ evidence: [String: String]
    ) -> [String: String] {
        guard let principal = status?.principal else { return evidence }
        var merged = evidence
        merged["tcc_principal"] = principal.displayName
        merged["tcc_principal_is_self"] = principal.isSelf ? "true" : "false"
        return merged
    }


    static func tccCrossContextCheck(runtime: Runtime) -> Check {
        switch runtime.tccCrossContextProbe() {
        case let .granted(detail):
            return check(
                id: "permissions.tcc_cross_context",
                domain: "permissions",
                status: .pass,
                summary: "TCC database confirms a known MCP host grant.",
                evidence: ["tcc_db_readable": "true", "full_disk_access": "true", "findings": detail],
                remediationType: .none
            )
        case let .denied(detail):
            return check(
                id: "permissions.tcc_cross_context",
                domain: "permissions",
                status: .warn,
                summary: "TCC database shows a known MCP host explicitly denied a required permission.",
                evidence: ["tcc_db_readable": "true", "full_disk_access": "true", "findings": detail],
                remediationType: .none
            )
        case let .skipped(reason):
            let readable: String
            switch reason {
            case .fullDiskAccessUnavailable:
                readable = "false"
            case .tccQueryUnavailable:
                readable = "unknown"
            default:
                readable = "true"
            }
            return check(
                id: "permissions.tcc_cross_context",
                domain: "permissions",
                status: .skipped,
                summary: "Cross-context TCC enrichment could not answer; live permission probes remain authoritative.",
                evidence: ["tcc_db_readable": readable, "full_disk_access": readable, "reason": reason.rawValue],
                remediationType: .docs,
                skipReason: reason
            )
        }
    }


    static func automationSummary(for state: PermissionChecker.CheckState) -> String {
        switch state {
        case .granted:
            return "Automation permission for Logic Pro is granted."
        case .notGranted:
            return "Automation permission for Logic Pro is not granted."
        case .notVerifiable:
            return "Automation permission could not be verified because Logic Pro is not running."
        }
    }


    static func systemEventsSummary(
        for state: PermissionChecker.CheckState,
        principal: TCCResponsibility.Principal? = nil
    ) -> String {
        switch state {
        case .granted:
            return "Automation permission for System Events is granted."
        case .notGranted:
            let subject: String
            if let principal {
                subject = principal.isSelf
                    ? "this LogicProMCP binary (\(principal.displayName))"
                    : principal.displayName
            } else {
                subject = "the responsible process (identity unresolved)"
            }
            return "Automation permission for System Events is not granted for \(subject); Logic Pro automation is separate."
        case .notVerifiable:
            return "Automation permission for System Events could not be verified."
        }
    }


}
