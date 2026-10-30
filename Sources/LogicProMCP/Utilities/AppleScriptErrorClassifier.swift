import Foundation

enum AppleScriptErrorClassifier {
    static let systemEventsAutomationDeniedHint =
        "System Events Automation is unavailable for the process responsible for launching this server (a launcher-permission gap, not a Logic limitation). The current operation terminated before further action; Logic Pro automation being granted is separate and not sufficient."

    static func systemEventsAutomationTerminalExtras(
        _ extras: [String: Any] = [:]
    ) -> [String: Any] {
        extras.merging([
            "safe_to_retry": false,
            "automatic_permission_attempts_exhausted": true,
            "terminal": true,
            "human_intervention_required": false,
            "human_intervention_requests": 0,
            "human_dependent_transitions": 0,
        ]) { _, terminalValue in terminalValue }
    }

    static let systemEventsAutomationDeniedCoreMatchTokens = ["-1743", "errAEEventNotPermitted", "not authorized to send Apple events to System Events", "not allowed to send Apple events to System Events", "System Events", "systemevents"]

    static func isSystemEventsAutomationDenied(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        let hasPermissionCode = lowercased.contains(systemEventsAutomationDeniedCoreMatchTokens[0])
            || lowercased.contains(systemEventsAutomationDeniedCoreMatchTokens[1].lowercased())
        // Real osascript stderr sometimes omits -1743; the full System Events TCC denial phrase is still definitive.
        let hasCanonicalSystemEventsPermissionError = lowercased.contains(systemEventsAutomationDeniedCoreMatchTokens[2].lowercased())
            || lowercased.contains(systemEventsAutomationDeniedCoreMatchTokens[3].lowercased())
        let referencesSystemEvents = lowercased.contains(systemEventsAutomationDeniedCoreMatchTokens[4].lowercased())
            || lowercased.contains(systemEventsAutomationDeniedCoreMatchTokens[5])
        return hasCanonicalSystemEventsPermissionError || (hasPermissionCode && referencesSystemEvents)
    }
}
