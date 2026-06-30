import Foundation
import ApplicationServices
import Darwin

/// Checks macOS permissions required for the server to operate.
enum PermissionChecker {
    enum CheckState: String, Sendable {
        case granted = "granted"
        case notGranted = "not_granted"
        case notVerifiable = "not_verifiable"

        var isGranted: Bool {
            self == .granted
        }

        var summaryLabel: String {
            switch self {
            case .granted:
                return "granted"
            case .notGranted:
                return "NOT GRANTED"
            case .notVerifiable:
                return "NOT VERIFIABLE"
            }
        }
    }

    struct Runtime: Sendable {
        let checkAccessibility: @Sendable (Bool) -> Bool
        let isLogicProRunning: @Sendable () -> Bool
        let runAutomationProbe: @Sendable () -> Bool
        // Automation → System Events is a SEPARATE TCC target from Automation →
        // Logic Pro. Multi-step paths (MIDI import, tempo dialog, project-state
        // probes) drive `tell application "System Events"`, so a host that has
        // Logic Pro automation granted can still have System Events denied —
        // which is exactly the #188 gap where health looked green but
        // record_sequence failed mid-import with an Apple Events denial.
        let runSystemEventsAutomationProbe: @Sendable () -> Bool

        static let production = Runtime(
            checkAccessibility: { prompt in
                let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            isLogicProRunning: { ProcessUtils.isLogicProRunning },
            runAutomationProbe: {
                runAutomationProbeViaShell()
            },
            runSystemEventsAutomationProbe: {
                runSystemEventsAutomationProbeViaShell()
            }
        )
    }

    struct PermissionStatus: Sendable {
        let accessibilityState: CheckState
        let automationState: CheckState
        let systemEventsAutomationState: CheckState

        init(accessibility: Bool, automationLogicPro: Bool, systemEventsAutomation: CheckState = .notVerifiable) {
            self.accessibilityState = accessibility ? .granted : .notGranted
            self.automationState = automationLogicPro ? .granted : .notGranted
            self.systemEventsAutomationState = systemEventsAutomation
        }

        init(
            accessibilityState: CheckState,
            automationState: CheckState,
            systemEventsAutomationState: CheckState = .notVerifiable
        ) {
            self.accessibilityState = accessibilityState
            self.automationState = automationState
            self.systemEventsAutomationState = systemEventsAutomationState
        }

        var accessibility: Bool { accessibilityState.isGranted }
        var automationLogicPro: Bool { automationState.isGranted }
        var automationVerifiable: Bool { automationState != .notVerifiable }
        var automationSystemEvents: Bool { systemEventsAutomationState.isGranted }

        // System Events automation is a hard requirement, not optional: MIDI
        // import, the tempo dialog, and project-state probes all drive
        // `tell application "System Events"`. Excluding it let
        // `--check-permissions` exit 0 while those paths fail mid-mutation with
        // an Apple Events denial — the exact #188 false-green. The production
        // probe is unconditional (System Events is always running), so a denied
        // target is reported truthfully here rather than advertised as ready.
        var allGranted: Bool { accessibility && automationLogicPro && automationSystemEvents }

        var summary: String {
            var lines: [String] = []
            lines.append("Accessibility: \(accessibilityState.summaryLabel)")
            switch automationState {
            case .granted, .notGranted:
                lines.append("Automation (Logic Pro): \(automationState.summaryLabel)")
            case .notVerifiable:
                lines.append("Automation (Logic Pro): NOT VERIFIABLE (Logic Pro not running)")
            }
            lines.append("Automation (System Events): \(systemEventsAutomationState.summaryLabel)")
            if accessibilityState == .notGranted {
                lines.append("  → System Settings > Privacy & Security > Accessibility → add your terminal app")
            }
            switch automationState {
            case .notGranted:
                lines.append("  → System Settings > Privacy & Security > Automation → allow control of Logic Pro")
            case .notVerifiable:
                lines.append("  → Launch Logic Pro once, then rerun --check-permissions to verify Automation access")
            case .granted:
                break
            }
            // System Events automation is required by MIDI import / tempo-dialog
            // paths; surface its own remediation so a green Logic-Pro automation
            // line never hides a denied System Events target (#188).
            if systemEventsAutomationState == .notGranted {
                lines.append("  → System Settings > Privacy & Security > Automation → allow control of System Events")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Check if Accessibility API access is granted.
    /// Uses the trusted check with prompt=false to avoid triggering the system dialog.
    static func checkAccessibility(prompt: Bool = false) -> Bool {
        checkAccessibility(prompt: prompt, runtime: .production)
    }

    static func checkAccessibility(prompt: Bool = false, runtime: Runtime) -> Bool {
        runtime.checkAccessibility(prompt)
    }

    static func checkAccessibilityState(prompt: Bool = false, runtime: Runtime = .production) -> CheckState {
        checkAccessibility(prompt: prompt, runtime: runtime) ? .granted : .notGranted
    }

    /// Check if Automation permission for Logic Pro is granted.
    /// This attempts a lightweight AppleScript to test permission.
    static func checkAutomation() -> Bool {
        checkAutomation(runtime: .production)
    }

    static func checkAutomation(runtime: Runtime) -> Bool {
        checkAutomationState(runtime: runtime).isGranted
    }

    static func checkAutomationState(runtime: Runtime = .production) -> CheckState {
        guard runtime.isLogicProRunning() else {
            return .notVerifiable
        }
        return runtime.runAutomationProbe() ? .granted : .notGranted
    }

    /// Check if Automation permission for System Events is granted. Required by
    /// the MIDI import / tempo-dialog / project-state paths that drive
    /// `tell application "System Events"`. System Events is always running, so
    /// (unlike Logic Pro) the probe is unconditional; a denied or undetermined
    /// target returns `notGranted`.
    static func checkSystemEventsAutomation() -> Bool {
        checkSystemEventsAutomation(runtime: .production)
    }

    static func checkSystemEventsAutomation(runtime: Runtime) -> Bool {
        checkSystemEventsAutomationState(runtime: runtime).isGranted
    }

    static func checkSystemEventsAutomationState(runtime: Runtime = .production) -> CheckState {
        runtime.runSystemEventsAutomationProbe() ? .granted : .notGranted
    }

    /// Full permission check.
    static func check() -> PermissionStatus {
        check(runtime: .production)
    }

    static func check(runtime: Runtime) -> PermissionStatus {
        PermissionStatus(
            accessibilityState: checkAccessibilityState(runtime: runtime),
            automationState: checkAutomationState(runtime: runtime),
            systemEventsAutomationState: checkSystemEventsAutomationState(runtime: runtime)
        )
    }

    private static func runAutomationProbeViaShell() -> Bool {
        let escapedBundleID = ServerConfig.logicProBundleID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application id \"\(escapedBundleID)\" to return name"
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 1.0,
            outputLimitBytes: 4 * 1024
        ), output.exitCode == 0 else {
            return false
        }

        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == ServerConfig.logicProProcessName
    }

    private static func runSystemEventsAutomationProbeViaShell() -> Bool {
        // A no-op read against System Events. If the launcher lacks Automation →
        // System Events, osascript exits non-zero (e.g. errAEEventNotPermitted
        // -1743) and the probe reports notGranted instead of letting a later
        // MIDI import fail mid-mutation with the same denial.
        let script = "tell application \"System Events\" to return name"
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 1.0,
            outputLimitBytes: 4 * 1024
        ), output.exitCode == 0 else {
            return false
        }

        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "System Events"
    }
}
