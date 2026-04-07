import Foundation
import ApplicationServices

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

        static let production = Runtime(
            checkAccessibility: { prompt in
                let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            isLogicProRunning: { ProcessUtils.isLogicProRunning },
            runAutomationProbe: {
                runAutomationProbeViaShell()
            }
        )
    }

    struct PermissionStatus: Sendable {
        let accessibilityState: CheckState
        let automationState: CheckState

        init(accessibility: Bool, automationLogicPro: Bool) {
            self.accessibilityState = accessibility ? .granted : .notGranted
            self.automationState = automationLogicPro ? .granted : .notGranted
        }

        init(accessibilityState: CheckState, automationState: CheckState) {
            self.accessibilityState = accessibilityState
            self.automationState = automationState
        }

        var accessibility: Bool { accessibilityState.isGranted }
        var automationLogicPro: Bool { automationState.isGranted }
        var automationVerifiable: Bool { automationState != .notVerifiable }

        var allGranted: Bool { accessibility && automationLogicPro }

        var summary: String {
            var lines: [String] = []
            lines.append("Accessibility: \(accessibilityState.summaryLabel)")
            switch automationState {
            case .granted, .notGranted:
                lines.append("Automation (Logic Pro): \(automationState.summaryLabel)")
            case .notVerifiable:
                lines.append("Automation (Logic Pro): NOT VERIFIABLE (Logic Pro not running)")
            }
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

    /// Full permission check.
    static func check() -> PermissionStatus {
        check(runtime: .production)
    }

    static func check(runtime: Runtime) -> PermissionStatus {
        PermissionStatus(
            accessibilityState: checkAccessibilityState(runtime: runtime),
            automationState: checkAutomationState(runtime: runtime)
        )
    }

    private static func runAutomationProbeViaShell() -> Bool {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        stdin.fileHandleForWriting.closeFile()
        let script = "tell application id \"\(ServerConfig.logicProBundleID)\" to return name"
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "osascript -e '\(script.replacingOccurrences(of: "'", with: "'\"'\"'"))'"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else {
            return false
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output == ServerConfig.logicProProcessName
    }
}
