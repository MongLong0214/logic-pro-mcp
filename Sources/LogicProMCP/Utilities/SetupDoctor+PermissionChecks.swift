import Foundation

extension SetupDoctor {
    static func accessibilityPermissionCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        check(
            id: "permissions.accessibility",
            domain: "permissions",
            status: status.accessibility ? .pass : .fail,
            summary: status.accessibility ? "Accessibility permission is granted." : "Accessibility permission is not granted.",
            evidence: ["state": status.accessibilityState.rawValue],
            remediationType: status.accessibility ? .none : .systemSettings
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
            checkStatus = .manual
        }
        return check(
            id: "permissions.automation_logic_pro",
            domain: "permissions",
            status: checkStatus,
            summary: automationSummary(for: status.automationState),
            evidence: ["state": status.automationState.rawValue],
            remediationType: status.automationState == .granted ? .none : .systemSettings
        )
    }


    static func systemEventsAutomationCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        // Surfaces the System Events automation target the runtime treats as a HARD
        // requirement (#188) but the v1 doctor dropped. Honest mapping: a probe that
        // could-not-run (.notVerifiable) is `manual`, never `fail` ("denied").
        let checkStatus: CheckStatus
        switch status.systemEventsAutomationState {
        case .granted:
            checkStatus = .pass
        case .notGranted:
            checkStatus = .fail
        case .notVerifiable:
            checkStatus = .manual
        }
        return check(
            id: "permissions.automation_system_events",
            domain: "permissions",
            status: checkStatus,
            summary: systemEventsSummary(for: status.systemEventsAutomationState),
            evidence: ["state": status.systemEventsAutomationState.rawValue],
            remediationType: status.systemEventsAutomationState == .granted ? .none : .systemSettings
        )
    }


    static func postEventAccessCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        check(
            id: "permissions.post_event_access",
            domain: "permissions",
            status: status.postEventAccess ? .pass : .fail,
            summary: status.postEventAccess
                ? "PostEvent access for CGEvent-family operations is granted."
                : "PostEvent access is denied; CGEvent-family ops (transport.stop/pause + most edit/view/track fallbacks) will fail.",
            evidence: ["post_event_access": status.postEventAccess ? "granted" : "denied"],
            remediationType: status.postEventAccess ? .none : .systemSettings
        )
    }


    static func launchContextCheck(runtime: Runtime) -> Check {
        let context = runtime.launchContext()
        let summary = context.context == "unknown"
            ? "Launch context is unknown; TCC follows the responsible process that launches the server. Re-run doctor from that app, or run under Terminal, iTerm, or your editor if it already has Automation grants."
            : "This report measures the TCC responsible process of \(context.context); re-verify under a different app if it spawns the server, or run under Terminal, iTerm, or your editor if it already has Automation grants."
        return check(
            id: "permissions.launch_context",
            domain: "permissions",
            status: .pass,
            summary: summary,
            evidence: ["launch_context": context.context, "responsible_hint": context.responsibleHint],
            remediationType: .none
        )
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
                remediationType: .systemSettings
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


    static func systemEventsSummary(for state: PermissionChecker.CheckState) -> String {
        switch state {
        case .granted:
            return "Automation permission for System Events is granted."
        case .notGranted:
            return "Automation permission for System Events is not granted for the responsible process that launched this server; this is a launcher-permission gap, and Logic Pro automation is separate."
        case .notVerifiable:
            return "Automation permission for System Events could not be verified."
        }
    }


}
