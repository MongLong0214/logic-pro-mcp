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
        // Legacy two-state Logic Pro automation seam. Retained so existing
        // Runtime constructions (and injected test doubles) keep their exact
        // Bool semantics; `runAutomationProbeState` carries the honest tri-state
        // that `checkAutomationState` actually consumes.
        let runAutomationProbe: @Sendable () -> Bool
        // Tri-state Logic Pro automation probe (P1 honesty, PRD §2.1 G6-a). A
        // probe that RAN and was denied → .notGranted, but a probe that COULD
        // NOT RUN (osascript timeout / spawn failure / unexpected output) →
        // .notVerifiable. The pre-fix Bool seam collapsed the latter into a
        // false "Automation NOT GRANTED" (#188), which this replaces — matching
        // the System Events sibling below.
        let runAutomationProbeState: @Sendable () -> CheckState
        // Automation → System Events is a SEPARATE TCC target from Automation →
        // Logic Pro. Multi-step paths (MIDI import, tempo dialog, project-state
        // probes) drive `tell application "System Events"`, so a host that has
        // Logic Pro automation granted can still have System Events denied —
        // which is exactly the #188 gap where health looked green but
        // record_sequence failed mid-import with an Apple Events denial.
        //
        // Tri-state (not Bool): a probe that RAN and was denied → .notGranted, but a
        // probe that COULD NOT RUN (osascript timeout / spawn failure / unexpected
        // output) → .notVerifiable. Collapsing the latter to .notGranted would report
        // "denied" for an infrastructure failure — a false-RED the doctor must not emit.
        let runSystemEventsAutomationProbe: @Sendable () -> CheckState
        let postEventPreflight: @Sendable () -> Bool

        /// `runAutomationProbeState` defaults to lifting the two-state
        /// `runAutomationProbe` into a CheckState, so existing 4-argument
        /// constructions compile unchanged with identical grant/deny behaviour;
        /// the production runtime overrides it with the honest tri-state probe.
        init(
            checkAccessibility: @escaping @Sendable (Bool) -> Bool,
            isLogicProRunning: @escaping @Sendable () -> Bool,
            runAutomationProbe: @escaping @Sendable () -> Bool,
            runSystemEventsAutomationProbe: @escaping @Sendable () -> CheckState,
            runAutomationProbeState: (@Sendable () -> CheckState)? = nil,
            postEventPreflight: @escaping @Sendable () -> Bool = { false }
        ) {
            self.checkAccessibility = checkAccessibility
            self.isLogicProRunning = isLogicProRunning
            self.runAutomationProbe = runAutomationProbe
            self.runSystemEventsAutomationProbe = runSystemEventsAutomationProbe
            self.postEventPreflight = postEventPreflight
            self.runAutomationProbeState = runAutomationProbeState ?? {
                runAutomationProbe() ? .granted : .notGranted
            }
        }

        static let production = Runtime(
            checkAccessibility: { prompt in
                let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            isLogicProRunning: { ProcessUtils.isLogicProRunning },
            runAutomationProbe: { runAutomationProbeViaShell().isGranted },
            runSystemEventsAutomationProbe: { runSystemEventsAutomationProbeViaShell() },
            runAutomationProbeState: { runAutomationProbeViaShell() },
            postEventPreflight: { CGPreflightPostEventAccess() }
        )
    }

    struct PermissionStatus: Sendable {
        let accessibilityState: CheckState
        let automationState: CheckState
        let systemEventsAutomationState: CheckState
        let postEventAccessState: CheckState

        init(
            accessibility: Bool,
            automationLogicPro: Bool,
            systemEventsAutomation: CheckState = .notVerifiable,
            postEventAccess: Bool = false
        ) {
            self.accessibilityState = accessibility ? .granted : .notGranted
            self.automationState = automationLogicPro ? .granted : .notGranted
            self.systemEventsAutomationState = systemEventsAutomation
            self.postEventAccessState = postEventAccess ? .granted : .notGranted
        }

        init(
            accessibilityState: CheckState,
            automationState: CheckState,
            systemEventsAutomationState: CheckState = .notVerifiable,
            postEventAccessState: CheckState = .notGranted
        ) {
            self.accessibilityState = accessibilityState
            self.automationState = automationState
            self.systemEventsAutomationState = systemEventsAutomationState
            self.postEventAccessState = postEventAccessState
        }

        var accessibility: Bool { accessibilityState.isGranted }
        var automationLogicPro: Bool { automationState.isGranted }
        var automationVerifiable: Bool { automationState != .notVerifiable }
        var automationSystemEvents: Bool { systemEventsAutomationState.isGranted }
        var postEventAccess: Bool { postEventAccessState.isGranted }

        // System Events automation is a hard requirement, not optional: MIDI
        // import, the tempo dialog, and project-state probes all drive
        // `tell application "System Events"`. Excluding it let
        // `--check-permissions` exit 0 while those paths fail mid-mutation with
        // an Apple Events denial — the exact #188 false-green. The production
        // probe is unconditional (System Events is always running), so a denied
        // target is reported truthfully here rather than advertised as ready.
        var allGranted: Bool { accessibility && automationLogicPro && automationSystemEvents && postEventAccess }

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
            lines.append("PostEvent (CGEvent): \(postEventAccessState.summaryLabel)")
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
            if postEventAccessState == .notGranted {
                lines.append("  → System Settings > Privacy & Security > Accessibility → grant PostEvent access to the host app")
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
        return runtime.runAutomationProbeState()
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
        runtime.runSystemEventsAutomationProbe()
    }

    /// Full permission check.
    static func check() -> PermissionStatus {
        check(runtime: .production)
    }

    static func check(runtime: Runtime) -> PermissionStatus {
        PermissionStatus(
            accessibilityState: checkAccessibilityState(runtime: runtime),
            automationState: checkAutomationState(runtime: runtime),
            systemEventsAutomationState: checkSystemEventsAutomationState(runtime: runtime),
            postEventAccessState: runtime.postEventPreflight() ? .granted : .notGranted
        )
    }

    private static func runAutomationProbeViaShell() -> CheckState {
        // Tri-state (P1 honesty, G6-a): a timeout / spawn failure surfaces as
        // .notVerifiable, not a false denial. See `probeState`.
        let escapedBundleID = AppleScriptSafety.escapeForScript(ServerConfig.logicProBundleID)
        let script = "tell application id \"\(escapedBundleID)\" to return name"
        return probeState(
            from: BoundedProcessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                timeout: 1.0,
                outputLimitBytes: 4 * 1024
            ),
            expectedName: ServerConfig.logicProProcessName
        )
    }

    private static func runSystemEventsAutomationProbeViaShell() -> CheckState {
        // A no-op read against System Events, mapped by the shared `probeState`.
        let script = "tell application \"System Events\" to return name"
        return probeState(
            from: BoundedProcessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                timeout: 1.0,
                outputLimitBytes: 4 * 1024
            ),
            expectedName: "System Events"
        )
    }

    /// Map an osascript automation-probe result to the honest tri-state. Shared
    /// by the Logic Pro and System Events probes (#188 semantics):
    ///  - completed, exit 0, expected app name → `.granted`
    ///  - completed, exit 0, unexpected output → `.notVerifiable` (ran but
    ///    produced no verifiable grant answer)
    ///  - completed, non-zero exit (e.g. errAEEventNotPermitted -1743) →
    ///    `.notGranted` (a real denial)
    ///  - timed out / spawn failed → `.notVerifiable` (an infrastructure
    ///    failure must NEVER be reported as a denial — the false-RED this fixes)
    ///
    /// Internal (not private) so `PermissionCheckerTriStateTests` can pin the
    /// mapping without spawning a real osascript process.
    static func probeState(
        from result: BoundedProcessRunner.Result,
        expectedName: String
    ) -> CheckState {
        switch result {
        case let .completed(output):
            if output.exitCode == 0 {
                let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == expectedName ? .granted : .notVerifiable
            }
            return .notGranted
        case .timedOut, .spawnFailed:
            return .notVerifiable
        }
    }
}
