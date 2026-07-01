import Darwin
import Foundation

enum SetupDoctor {
    enum CheckStatus: String, Codable, Sendable {
        case pass
        case warn
        case fail
        case manual
        case skipped
    }

    enum ReportStatus: String, Codable, Sendable {
        case ok
        case degraded
        case failed
        case manualActionRequired = "manual_action_required"
    }

    enum InstallSource: String, Codable, Sendable {
        case homebrew
        case releaseBinary = "release_binary"
        case sourceBuild = "source_build"
        case unknown
    }

    enum RemediationType: String, Codable, Sendable {
        case command
        case docs
        case systemSettings = "system_settings"
        case manual
        case none
    }

    /// Closed, typed taxonomy added in v2 (lazycodex-style `CheckCategory`).
    /// Parallel to the v1 free-string `domain`, which is retained for back-compat.
    enum Category: String, Codable, Sendable {
        case installation
        case configuration
        case permissions
        case dependencies
        case runtime
        case updates
    }

    /// Display-grade severity derived from `CheckStatus`. Used for headline
    /// ordering ("fix the error first") — never drives the exit code.
    enum Severity: String, Codable, Sendable {
        case error
        case warning
        case info
    }

    struct Remediation: Codable, Equatable, Sendable {
        let type: RemediationType
        let value: String
    }

    struct Check: Codable, Equatable, Sendable {
        let id: String
        let domain: String
        let status: CheckStatus
        let summary: String
        let evidence: [String: String]
        let remediation: Remediation
        // v2 additive fields. `category`/`severity` are derived in the `check`
        // factory; `durationMs` is stamped post-hoc by the `generate` timing
        // wrapper (var so the wrapper can set it without rebuilding the struct).
        let category: Category
        let severity: Severity
        var durationMs: Double

        // Explicit CodingKeys enumerate EVERY key — the six v1 keys keep their
        // exact wire names so a v2 payload stays a strict field-superset of v1,
        // and adding `duration_ms` can never silently rename a v1 key.
        enum CodingKeys: String, CodingKey {
            case id
            case domain
            case status
            case summary
            case evidence
            case remediation
            case category
            case severity
            case durationMs = "duration_ms"
        }
    }

    /// v2 roll-up. Invariant: passed+failed+warnings+manual+skipped == total == checks.count.
    struct Summary: Codable, Equatable, Sendable {
        let total: Int
        let passed: Int
        let failed: Int
        let warnings: Int
        let manual: Int
        let skipped: Int
        let durationMs: Double

        enum CodingKeys: String, CodingKey {
            case total
            case passed
            case failed
            case warnings
            case manual
            case skipped
            case durationMs = "duration_ms"
        }
    }

    struct Report: Codable, Equatable, Sendable {
        let schema: String
        let status: ReportStatus
        let version: String
        let installSource: InstallSource
        let checks: [Check]
        // v2 additive top-level fields.
        let summary: Summary
        let headline: String

        enum CodingKeys: String, CodingKey {
            case schema
            case status
            case version
            case installSource = "install_source"
            case checks
            case summary
            case headline
        }
    }

    struct CommandOutput: Equatable, Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Result of inspecting the Claude Code config for a logic-pro registration.
    /// This is a pure config read — it never spawns the registered server, so the
    /// doctor's read-only / run-before-startup contract is honored (no CoreMIDI
    /// ports, no health sweep, no SIGKILL of an indirectly-spawned server).
    enum ClaudeRegistration: Equatable, Sendable {
        /// A logic-pro-style MCP entry resolving to a LogicProMCP binary was found.
        /// `command` is the registered command string for evidence.
        case registered(command: String)
        /// The config was read successfully but no matching registration exists.
        case notRegistered
        /// The config file is absent / unreadable / not valid JSON.
        /// `reason` is a short human-readable explanation for the evidence dict.
        case configUnavailable(reason: String)
    }

    struct Runtime: @unchecked Sendable {
        let resolveExecutablePath: (String?) -> String?
        let fileExists: (String) -> Bool
        let isExecutableFile: (String) -> Bool
        let logicProRunning: () -> Bool
        let logicProHasVisibleWindow: () -> Bool
        let runCommand: (String, [String]) -> CommandOutput?
        let readClaudeRegistration: () -> ClaudeRegistration
        // v2 seams. Defaults keep every existing `Runtime(...)` construction site
        // compiling; `.production` and the test helper supply real/fake impls.
        var macOSVersion: () -> OperatingSystemVersion? = { ProcessInfo.processInfo.operatingSystemVersion }
        // Monotonic millisecond clock for per-check timing. Monotonic (uptime),
        // never wall-clock, so a duration can never go negative across an NTP step.
        var monotonicNowMs: () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0 }
        // nil ⇒ the opt-in update check is not emitted and no network is touched.
        // Non-nil only when `--check-updates` is passed (wired in MainEntrypoint).
        var latestReleaseLookup: (() -> UpdateOutcome)?

        static let production = Runtime(
            resolveExecutablePath: { raw in
                resolveProductionExecutablePath(raw)
            },
            fileExists: { path in
                FileManager.default.fileExists(atPath: path)
            },
            isExecutableFile: { path in
                FileManager.default.isExecutableFile(atPath: path)
            },
            logicProRunning: {
                ProcessUtils.isLogicProRunning
            },
            logicProHasVisibleWindow: {
                ProcessUtils.hasVisibleWindow()
            },
            runCommand: { executable, arguments in
                runProductionCommand(executable: executable, arguments: arguments, timeout: 1.5)?.output
            },
            readClaudeRegistration: {
                readProductionClaudeRegistration()
            }
        )
    }

    /// Typed outcome of the opt-in update lookup, so the check body can write an
    /// accurate enumerated `reason` (AC-6.4) instead of collapsing every failure
    /// mode to a bare `nil`.
    enum UpdateOutcome: Equatable, Sendable {
        case found(version: String)
        case offline
        case sourceUnavailable
        case parseError
        case httpError
        case timeout
    }

    static let schema = "logic_pro_mcp_doctor.v2"

    static let remediationAnchorsByCheckID: [String: String] = [
        "binary.path": "docs/SETUP.md#doctor-binarypath",
        "binary.executable": "docs/SETUP.md#doctor-binaryexecutable",
        "install.source": "docs/SETUP.md#doctor-installsource",
        "release.signature": "docs/SETUP.md#doctor-releasesignature",
        "release.quarantine": "docs/SETUP.md#doctor-releasequarantine",
        "mcp.claude_code_registration": "docs/SETUP.md#doctor-mcpclaude-code-registration",
        "permissions.accessibility": "docs/SETUP.md#doctor-permissionsaccessibility",
        "permissions.automation_logic_pro": "docs/SETUP.md#doctor-permissionsautomation-logic-pro",
        "permissions.automation_system_events": "docs/SETUP.md#doctor-permissionsautomation-system-events",
        "system.macos_version": "docs/SETUP.md#doctor-systemmacos-version",
        "updates.latest_release": "docs/SETUP.md#doctor-updateslatest-release",
        "logic.application_state": "docs/SETUP.md#doctor-logicapplication-state",
        "channels.manual_validation": "docs/SETUP.md#doctor-channelsmanual-validation",
    ]

    static func generate(
        arguments: [String],
        permissionStatus: PermissionChecker.PermissionStatus,
        approvals: [ManualValidationChannel: ManualValidationApproval],
        runtime: Runtime = .production
    ) -> Report {
        let executablePath = runtime.resolveExecutablePath(arguments.first)
        let installSource = detectInstallSource(executablePath: executablePath, runtime: runtime)

        // Per-check monotonic timing. Each check runs once, in declared order
        // (sequential — no concurrency), wrapped to stamp `duration_ms`. Checks
        // are non-throwing, so no exception isolation is required.
        func timed(_ make: () -> Check) -> Check {
            let start = runtime.monotonicNowMs()
            var result = make()
            // Round to whole milliseconds so the JSON machine contract matches the
            // human renderer's `formatDuration` precision and sub-millisecond timing
            // jitter doesn't churn the `--json` bytes run-to-run (sub-ms checks → 0).
            result.durationMs = (max(0, runtime.monotonicNowMs() - start)).rounded()
            return result
        }

        var checks: [Check] = []

        checks.append(timed { binaryPathCheck(executablePath: executablePath, runtime: runtime) })
        checks.append(timed { binaryExecutableCheck(executablePath: executablePath, runtime: runtime) })
        checks.append(timed { binaryVersionCheck() })
        checks.append(timed { installSourceCheck(installSource: installSource, executablePath: executablePath) })
        checks.append(timed { releaseSignatureCheck(executablePath: executablePath, runtime: runtime) })
        checks.append(timed { releaseQuarantineCheck(executablePath: executablePath, runtime: runtime) })
        checks.append(timed { claudeRegistrationCheck(runtime: runtime) })
        checks.append(timed { accessibilityPermissionCheck(permissionStatus) })
        checks.append(timed { automationPermissionCheck(permissionStatus) })
        checks.append(timed { systemEventsAutomationCheck(permissionStatus) })
        checks.append(timed { macOSVersionCheck(runtime: runtime) })
        checks.append(timed { logicApplicationStateCheck(runtime: runtime) })
        checks.append(timed { manualValidationCheck(approvals: approvals) })
        // Opt-in update check: emitted only when `--check-updates` armed the lookup seam.
        if let lookup = runtime.latestReleaseLookup {
            checks.append(timed { updateCheck(outcome: lookup()) })
        }

        // Honesty chokepoint (G1/AC-1.5): the report can never claim `ok` while a
        // required permission is ungranted. Extracted to a pure helper so the invariant
        // is OWNED and directly unit-tested here, not left emergent on each permission
        // check happening to be non-pass.
        let status = clampStatusForPermissions(
            aggregateStatus(checks),
            allGranted: permissionStatus.allGranted
        )

        let totalDurationMs = checks.reduce(0.0) { $0 + $1.durationMs }
        return Report(
            schema: schema,
            status: status,
            version: ServerConfig.serverVersion,
            installSource: installSource,
            checks: checks,
            summary: calculateSummary(checks, totalDurationMs: totalDurationMs),
            headline: computeHeadline(checks: checks, status: status)
        )
    }

    enum OutputMode: Sendable {
        case `default`
        case verbose
        case quiet
    }

    static func renderHuman(
        _ report: Report,
        mode: OutputMode = .default,
        useColor: Bool = false
    ) -> String {
        var lines: [String] = []
        // Headline (next action) + summary roll-up lead the report in every mode.
        lines.append(report.headline)
        lines.append(renderSummaryLine(report.summary))
        // Existing v1 header block is preserved so the non-TTY human shape stays
        // a back-compatible superset (a scraper grepping these lines keeps working).
        lines.append("Logic Pro MCP doctor")
        lines.append("schema: \(report.schema)")
        lines.append("status: \(report.status.rawValue)")
        lines.append("version: \(report.version)")
        lines.append("install_source: \(report.installSource.rawValue)")
        lines.append("")
        for check in report.checks {
            if mode == .quiet, check.status == .pass {
                continue
            }
            lines.append(renderCheckLine(check, useColor: useColor))
            if check.remediation.type != .none {
                lines.append("  \u{2192} \(check.remediation.value)")
            }
            if mode == .verbose {
                for key in check.evidence.keys.sorted() {
                    lines.append("    \(key)=\(check.evidence[key] ?? "")")
                }
                lines.append("    duration_ms: \(formatDuration(check.durationMs))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderSummaryLine(_ summary: Summary) -> String {
        var parts: [String] = ["\(summary.passed) passed"]
        if summary.failed > 0 {
            parts.append("\(summary.failed) failed")
        }
        if summary.warnings > 0 {
            parts.append("\(summary.warnings) warning\(summary.warnings == 1 ? "" : "s")")
        }
        if summary.manual > 0 {
            parts.append("\(summary.manual) manual")
        }
        if summary.skipped > 0 {
            parts.append("\(summary.skipped) skipped")
        }
        return "summary: \(parts.joined(separator: ", ")) (\(formatDuration(summary.durationMs))ms)"
    }

    private static func renderCheckLine(_ check: Check, useColor: Bool) -> String {
        guard useColor else {
            // Plain ASCII fallback (non-TTY / NO_COLOR): byte-clean for pipes & CI.
            return "[\(check.status.rawValue)] \(check.id) - \(check.summary)"
        }
        let reset = "\u{1B}[0m"
        let (symbol, color) = colorSymbol(for: check.status)
        return "\(color)\(symbol)\(reset) \(check.id) - \(check.summary)"
    }

    /// (symbol, ANSI color prefix) per status. Only used when color is enabled.
    private static func colorSymbol(for status: CheckStatus) -> (String, String) {
        switch status {
        case .pass:
            return ("\u{2713}", "\u{1B}[32m")   // ✓ green
        case .fail:
            return ("\u{2717}", "\u{1B}[31m")   // ✗ red
        case .warn:
            return ("\u{26A0}", "\u{1B}[33m")   // ⚠ yellow
        case .manual:
            return ("\u{2022}", "\u{1B}[34m")   // • blue
        case .skipped:
            return ("\u{2205}", "\u{1B}[90m")   // ∅ grey
        }
    }

    private static func formatDuration(_ ms: Double) -> String {
        String(Int(ms.rounded()))
    }

    static func shouldExitWithFailure(_ report: Report) -> Bool {
        report.status == .failed
    }

    private static func aggregateStatus(_ checks: [Check]) -> ReportStatus {
        if checks.contains(where: { $0.status == .fail }) {
            return .failed
        }
        if checks.contains(where: { $0.status == .manual }) {
            return .manualActionRequired
        }
        if checks.contains(where: { $0.status == .warn || $0.status == .skipped }) {
            return .degraded
        }
        return .ok
    }

    /// Honesty chokepoint (G1/AC-1.5): the report must never be `ok` when a required
    /// permission is ungranted. Pure + directly unit-tested so the invariant is owned
    /// here rather than left to emerge from each permission check being non-pass.
    /// `allGranted == accessibility && automationLogicPro && automationSystemEvents`.
    static func clampStatusForPermissions(_ status: ReportStatus, allGranted: Bool) -> ReportStatus {
        (!allGranted && status == .ok) ? .degraded : status
    }

    private static func binaryPathCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath, runtime.fileExists(executablePath) else {
            return check(
                id: "binary.path",
                domain: "binary",
                status: .fail,
                summary: "LogicProMCP binary could not be resolved from argv0 or PATH.",
                evidence: ["argv0_resolved": executablePath ?? "<nil>"],
                remediationType: .docs
            )
        }
        return check(
            id: "binary.path",
            domain: "binary",
            status: .pass,
            summary: "LogicProMCP binary path resolved.",
            evidence: ["path": executablePath],
            remediationType: .none
        )
    }

    private static func binaryExecutableCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath, runtime.fileExists(executablePath) else {
            return check(
                id: "binary.executable",
                domain: "binary",
                status: .skipped,
                summary: "Executable bit could not be checked because the binary path is missing.",
                evidence: [:],
                remediationType: .docs
            )
        }
        let executable = runtime.isExecutableFile(executablePath)
        return check(
            id: "binary.executable",
            domain: "binary",
            status: executable ? .pass : .fail,
            summary: executable ? "Binary has executable permission." : "Binary is not executable.",
            evidence: ["path": executablePath, "executable": String(executable)],
            remediationType: executable ? .none : .command,
            remediationValueOverride: executable ? nil : "chmod +x \(executablePath)"
        )
    }

    private static func binaryVersionCheck() -> Check {
        // Honest reporting: this echoes the version compiled into the running
        // doctor process, not the version of the binary at binary.path. It cannot
        // detect a stale/mismatched install, so it never fails — the summary states
        // exactly what it reports and the remediation is unconditionally .none
        // rather than carrying a dead .fail branch + unreachable docs anchor.
        check(
            id: "binary.version",
            domain: "binary",
            status: .pass,
            summary: "Running server version: \(ServerConfig.serverVersion).",
            evidence: ["version": ServerConfig.serverVersion],
            remediationType: .none
        )
    }

    private static func installSourceCheck(installSource: InstallSource, executablePath: String?) -> Check {
        let status: CheckStatus = installSource == .unknown ? .warn : .pass
        return check(
            id: "install.source",
            domain: "install",
            status: status,
            summary: installSource == .unknown ? "Install source is unknown or manual." : "Install source detected as \(installSource.rawValue).",
            evidence: ["install_source": installSource.rawValue, "path": executablePath ?? "<nil>"],
            remediationType: installSource == .unknown ? .docs : .none
        )
    }

    private static func releaseSignatureCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath, runtime.fileExists(executablePath) else {
            return check(
                id: "release.signature",
                domain: "release",
                status: .skipped,
                summary: "Signature verification skipped because the binary path is missing.",
                evidence: [:],
                remediationType: .docs
            )
        }
        guard let output = runtime.runCommand("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", executablePath]) else {
            return check(
                id: "release.signature",
                domain: "release",
                status: .warn,
                summary: "codesign verification could not be executed.",
                evidence: ["path": executablePath],
                remediationType: .docs
            )
        }
        return check(
            id: "release.signature",
            domain: "release",
            status: output.exitCode == 0 ? .pass : .warn,
            summary: output.exitCode == 0 ? "Binary signature verifies." : "Binary signature did not verify.",
            evidence: [
                "path": executablePath,
                "exit_code": String(output.exitCode),
                "stderr": output.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            ],
            remediationType: output.exitCode == 0 ? .none : .docs
        )
    }

    private static func releaseQuarantineCheck(executablePath: String?, runtime: Runtime) -> Check {
        guard let executablePath, runtime.fileExists(executablePath) else {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .skipped,
                summary: "Quarantine check skipped because the binary path is missing.",
                evidence: [:],
                remediationType: .docs
            )
        }
        guard let output = runtime.runCommand("/usr/bin/xattr", ["-p", "com.apple.quarantine", executablePath]) else {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .warn,
                summary: "xattr quarantine check could not be executed.",
                evidence: ["path": executablePath],
                remediationType: .docs
            )
        }
        // Distinguish three outcomes instead of folding everything but exit 0 into
        // .pass. xattr exits non-zero both when the attribute is absent (exit 1,
        // "No such xattr") AND on permission-denied or other errors; collapsing all
        // of those to "not quarantined" would let the doctor affirm a clean state it
        // never verified.
        let trimmedStderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence: [String: String] = [
            "path": executablePath,
            "exit_code": String(output.exitCode),
            "stderr": trimmedStderr,
        ]
        if output.exitCode == 0 {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .warn,
                summary: "Binary has a macOS quarantine attribute.",
                evidence: evidence,
                remediationType: .command,
                remediationValueOverride: "xattr -d com.apple.quarantine \(executablePath)"
            )
        }
        let attributeAbsent = output.exitCode == 1
            && trimmedStdout.isEmpty
            && trimmedStderr.localizedCaseInsensitiveContains("No such xattr")
        if attributeAbsent {
            return check(
                id: "release.quarantine",
                domain: "release",
                status: .pass,
                summary: "Binary is not quarantined.",
                evidence: evidence,
                remediationType: .none
            )
        }
        return check(
            id: "release.quarantine",
            domain: "release",
            status: .warn,
            summary: "Quarantine state could not be determined.",
            evidence: evidence,
            remediationType: .docs
        )
    }

    private static func claudeRegistrationCheck(runtime: Runtime) -> Check {
        // Read-only registration detection: inspect the Claude Code config file
        // directly instead of shelling out to `claude mcp list`. `claude mcp list`
        // health-checks every registered MCP server, which spawns the registered
        // LogicProMCP binary over stdio (creating CoreMIDI virtual ports + AX
        // pollers) — a real side effect that violates the doctor's documented
        // "read-only / run-before-startup" contract, and one the old 1.5s SIGKILL
        // could orphan. Reading the config is fast, non-mutating, and spawns nothing.
        switch runtime.readClaudeRegistration() {
        case let .registered(command):
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .pass,
                summary: "Claude Code MCP registration found.",
                evidence: ["registered": "true", "command": command],
                remediationType: .none
            )
        case .notRegistered:
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .warn,
                summary: "Claude Code MCP registration was not found.",
                evidence: ["registered": "false"],
                remediationType: .command,
                remediationValueOverride: "claude mcp add --scope user logic-pro -- LogicProMCP"
            )
        case let .configUnavailable(reason):
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .manual,
                summary: "Claude Code registration could not be checked because the Claude config could not be read.",
                evidence: ["reason": reason],
                remediationType: .manual
            )
        }
    }

    private static func accessibilityPermissionCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
        check(
            id: "permissions.accessibility",
            domain: "permissions",
            status: status.accessibility ? .pass : .fail,
            summary: status.accessibility ? "Accessibility permission is granted." : "Accessibility permission is not granted.",
            evidence: ["state": status.accessibilityState.rawValue],
            remediationType: status.accessibility ? .none : .systemSettings
        )
    }

    private static func automationPermissionCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
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

    private static func systemEventsAutomationCheck(_ status: PermissionChecker.PermissionStatus) -> Check {
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

    private static func macOSVersionCheck(runtime: Runtime) -> Check {
        let minimumMajor = 14 // Package.swift: platforms: [.macOS(.v14)]
        guard let version = runtime.macOSVersion() else {
            return check(
                id: "system.macos_version",
                domain: "system",
                status: .skipped,
                summary: "macOS version could not be determined.",
                evidence: ["reason": "version_unreadable"],
                remediationType: .docs
            )
        }
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        if version.majorVersion >= minimumMajor {
            return check(
                id: "system.macos_version",
                domain: "system",
                status: .pass,
                summary: "macOS \(versionString) meets the minimum (\(minimumMajor)+).",
                evidence: ["version": versionString, "minimum_major": String(minimumMajor)],
                remediationType: .none
            )
        }
        return check(
            id: "system.macos_version",
            domain: "system",
            status: .fail,
            summary: "macOS \(versionString) is below the required minimum (\(minimumMajor)+).",
            evidence: ["version": versionString, "minimum_major": String(minimumMajor)],
            remediationType: .docs
        )
    }

    private static func updateCheck(outcome: UpdateOutcome) -> Check {
        let installed = ServerConfig.serverVersion
        switch outcome {
        case let .found(rawLatest):
            let latest = normalizeVersion(rawLatest)
            // An unparseable tag (e.g. "v", "-beta.1", "latest") normalizes to a value
            // with no numeric major. compareVersions would treat it as 0.0.0 and falsely
            // report "up to date" — so report skipped/parse_error instead of fabricating a pass.
            guard let major = latest.split(separator: ".").first, Int(major) != nil else {
                return check(
                    id: "updates.latest_release",
                    domain: "updates",
                    status: .skipped,
                    summary: "Could not parse the latest release version.",
                    evidence: ["reason": "parse_error"],
                    remediationType: .docs
                )
            }
            let order = compareVersions(installed, latest)
            if order >= 0 {
                return check(
                    id: "updates.latest_release",
                    domain: "updates",
                    status: .pass,
                    summary: "Installed version \(installed) is up to date.",
                    evidence: ["installed": installed, "latest": latest],
                    remediationType: .none
                )
            }
            return check(
                id: "updates.latest_release",
                domain: "updates",
                status: .warn,
                summary: "A newer release is available: \(latest) (installed \(installed)).",
                evidence: ["installed": installed, "latest": latest],
                remediationType: .command,
                remediationValueOverride: "brew upgrade logic-pro-mcp"
            )
        case .offline, .sourceUnavailable, .parseError, .httpError, .timeout:
            // Redaction (AC-6.4): evidence carries ONLY an enumerated reason — never
            // stderr, env, tokened URLs, or headers. The lookup is unauthenticated.
            return check(
                id: "updates.latest_release",
                domain: "updates",
                status: .skipped,
                summary: "Could not check for the latest release.",
                evidence: ["reason": updateReason(outcome)],
                remediationType: .docs
            )
        }
    }

    private static func updateReason(_ outcome: UpdateOutcome) -> String {
        switch outcome {
        case .found:
            return "found"
        case .offline:
            return "offline"
        case .sourceUnavailable:
            return "source_unavailable"
        case .parseError:
            return "parse_error"
        case .httpError:
            return "http_error"
        case .timeout:
            return "timeout"
        }
    }

    /// Normalize a release tag for comparison: strip a leading `v` (`v3.7.4` → `3.7.4`)
    /// and drop any pre-release/build suffix (`4.0.0-beta.1` → `4.0.0`) so a hyphenated
    /// segment can't be misread as a numeric component by `compareVersions` (which would
    /// otherwise rank a pre-release as newer than its GA release).
    static func normalizeVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value = String(value.dropFirst())
        }
        return value.components(separatedBy: "-").first ?? value
    }

    /// Numeric, component-wise version compare (NEVER lexicographic: "3.9" < "3.10").
    /// Returns negative if a < b, 0 if equal, positive if a > b.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right ? -1 : 1
            }
        }
        return 0
    }

    private static func systemEventsSummary(for state: PermissionChecker.CheckState) -> String {
        switch state {
        case .granted:
            return "Automation permission for System Events is granted."
        case .notGranted:
            return "Automation permission for System Events is not granted."
        case .notVerifiable:
            return "Automation permission for System Events could not be verified."
        }
    }

    private static func logicApplicationStateCheck(runtime: Runtime) -> Check {
        let running = runtime.logicProRunning()
        let visible = running && runtime.logicProHasVisibleWindow()
        let status: CheckStatus = running ? (visible ? .pass : .warn) : .manual
        return check(
            id: "logic.application_state",
            domain: "logic",
            status: status,
            summary: logicApplicationSummary(running: running, visible: visible),
            evidence: ["running": String(running), "visible_window": String(visible)],
            remediationType: running ? (visible ? .none : .manual) : .manual
        )
    }

    private static func manualValidationCheck(approvals: [ManualValidationChannel: ManualValidationApproval]) -> Check {
        let missing = ManualValidationChannel.allCases
            .filter { approvals[$0] == nil }
            .map(\.rawValue)
        return check(
            id: "channels.manual_validation",
            domain: "channels",
            status: missing.isEmpty ? .pass : .manual,
            summary: missing.isEmpty
                ? "Manual-validation channels have operator approvals."
                : "Manual-validation channels need operator approval or an explicit decision to skip.",
            evidence: ["missing": missing.joined(separator: ",")],
            remediationType: missing.isEmpty ? .none : .command,
            remediationValueOverride: missing.isEmpty ? nil : "LogicProMCP --approve-channel MIDIKeyCommands && LogicProMCP --approve-channel Scripter"
        )
    }

    private static func detectInstallSource(executablePath: String?, runtime: Runtime) -> InstallSource {
        // Match a real `.build` path component (SwiftPM's canonical build dir),
        // not a bare substring — a path like `/Users/x/my.build/release/LogicProMCP`
        // must NOT be misclassified as source_build.
        if let executablePath, URL(fileURLWithPath: executablePath).pathComponents.contains(".build") {
            return .sourceBuild
        }

        // Probe brew at canonical absolute paths instead of resolving via PATH.
        // A launchd/minimal-supervisor env often has a stripped PATH without
        // /opt/homebrew/bin, which would otherwise make a genuine Homebrew install
        // fall through to .releaseBinary based purely on ambient PATH.
        for brewPath in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if let brew = runtime.runCommand(brewPath, ["list", "--versions", "logic-pro-mcp"]),
               brew.exitCode == 0,
               brew.stdout.contains("logic-pro-mcp") {
                return .homebrew
            }
        }

        guard let executablePath else { return .unknown }
        if executablePath.hasPrefix("/usr/local/bin/") || executablePath.hasPrefix("/opt/homebrew/bin/") {
            return .releaseBinary
        }
        return .unknown
    }

    private static func automationSummary(for state: PermissionChecker.CheckState) -> String {
        switch state {
        case .granted:
            return "Automation permission for Logic Pro is granted."
        case .notGranted:
            return "Automation permission for Logic Pro is not granted."
        case .notVerifiable:
            return "Automation permission could not be verified because Logic Pro is not running."
        }
    }

    private static func logicApplicationSummary(running: Bool, visible: Bool) -> String {
        if visible {
            return "Logic Pro is running with a visible window."
        }
        if running {
            return "Logic Pro is running, but no visible project window was detected."
        }
        return "Logic Pro is not running; live setup checks need manual validation."
    }

    private static func check(
        id: String,
        domain: String,
        status: CheckStatus,
        summary: String,
        evidence: [String: String],
        remediationType: RemediationType,
        remediationValueOverride: String? = nil
    ) -> Check {
        let value = remediationValueOverride ?? defaultRemediationValue(for: id, type: remediationType)
        // category/severity are DERIVED here (single chokepoint) so no check can be
        // built with an inconsistent taxonomy and the 11 existing call sites need no
        // edit. durationMs is stamped post-hoc by the `generate` timing wrapper.
        return Check(
            id: id,
            domain: domain,
            status: status,
            summary: summary,
            evidence: evidence,
            remediation: Remediation(type: remediationType, value: value),
            category: category(forDomain: domain),
            severity: severity(for: status),
            durationMs: 0
        )
    }

    /// Maps the v1 free-string `domain` to the closed v2 `Category`. Complete table —
    /// every domain a check can carry has a row; unknown domains fall back to runtime.
    static func category(forDomain domain: String) -> Category {
        switch domain {
        case "binary", "install", "release", "system":
            return .installation
        case "mcp", "channels":
            return .configuration
        case "permissions":
            return .permissions
        case "dependencies":
            return .dependencies
        case "updates":
            return .updates
        case "logic":
            return .runtime
        default:
            return .runtime
        }
    }

    /// Total status→severity mapping (AC-4.1). `skipped` is `info` (could-not-verify
    /// is not actionable noise), not `warning`.
    static func severity(for status: CheckStatus) -> Severity {
        switch status {
        case .fail:
            return .error
        case .warn, .manual:
            return .warning
        case .skipped, .pass:
            return .info
        }
    }

    static func calculateSummary(_ checks: [Check], totalDurationMs: Double) -> Summary {
        Summary(
            total: checks.count,
            passed: checks.filter { $0.status == .pass }.count,
            failed: checks.filter { $0.status == .fail }.count,
            warnings: checks.filter { $0.status == .warn }.count,
            manual: checks.filter { $0.status == .manual }.count,
            skipped: checks.filter { $0.status == .skipped }.count,
            durationMs: totalDurationMs
        )
    }

    /// The "next action" one-liner (AC-4.2/4.3): names the single highest-priority
    /// remediation — errors before warnings, then stable check order. `info`
    /// (pass/skipped) is never headlined. All-pass → healthy message.
    static func computeHeadline(checks: [Check], status: ReportStatus) -> String {
        let priority: (Severity) -> Int = { severity in
            switch severity {
            case .error: return 0
            case .warning: return 1
            case .info: return 2
            }
        }
        // Stable: enumerate in declared order, pick the first lowest-priority-number
        // non-pass check (errors win ties by appearing first at priority 0).
        let actionable = checks
            .filter { $0.status != .pass }
            .min(by: { priority($0.severity) < priority($1.severity) })
        guard let lead = actionable, lead.severity != .info else {
            // No actionable (error/warning) check. Distinguish a truly clean run from
            // one that is merely usable-but-not-fully-verified (e.g. a skipped check
            // degrades the aggregate) — never claim "healthy" while status is non-ok.
            return status == .ok
                ? "Logic Pro MCP install is healthy."
                : "Logic Pro MCP install is usable; some checks could not be verified."
        }
        let remediationHint = lead.remediation.type == .none ? "" : " — \(lead.remediation.value)"
        return "Next action [\(lead.id)]: \(lead.summary)\(remediationHint)"
    }

    private static func defaultRemediationValue(for id: String, type: RemediationType) -> String {
        switch type {
        case .none:
            return ""
        case .systemSettings:
            if id == "permissions.accessibility" {
                return "System Settings > Privacy & Security > Accessibility"
            }
            if id == "permissions.automation_logic_pro" {
                return "System Settings > Privacy & Security > Automation > Logic Pro"
            }
            if id == "permissions.automation_system_events" {
                return "System Settings > Privacy & Security > Automation > System Events"
            }
            return remediationAnchorsByCheckID[id] ?? "docs/SETUP.md#doctor"
        case .command, .docs, .manual:
            return remediationAnchorsByCheckID[id] ?? "docs/SETUP.md#doctor"
        }
    }

    private static func resolveProductionExecutablePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        if raw.contains("/") {
            let url: URL
            if raw.hasPrefix("/") {
                url = URL(fileURLWithPath: raw)
            } else {
                url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(raw)
            }
            return url.standardizedFileURL.path
        }

        guard let output = runProductionCommand(
            executable: "/usr/bin/which",
            arguments: [raw],
            timeout: 1.0
        )?.output, output.exitCode == 0 else {
            return nil
        }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Outcome of running an external command, distinguishing the failure modes
    /// so callers can message truthfully (timeout vs. could-not-spawn) rather than
    /// collapsing both into a bare `nil`.
    enum ProductionCommandResult: Equatable, Sendable {
        case completed(CommandOutput)
        /// The process did not finish within the timeout (terminated/killed).
        case timedOut
        /// The process could not be launched (e.g. executable not found).
        case spawnFailed(String)

        /// Convenience accessor for callers that only need the successful output.
        var output: CommandOutput? {
            if case let .completed(value) = self { return value }
            return nil
        }
    }

    private static func runProductionCommand(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProductionCommandResult? {
        switch BoundedProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout) {
        case let .completed(output):
            return .completed(
                CommandOutput(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
            )
        case .timedOut:
            return .timedOut
        case let .spawnFailed(message):
            return .spawnFailed(message)
        }
    }

    /// Production update lookup (wired by MainEntrypoint only under `--check-updates`).
    /// UNAUTHENTICATED public read — no Authorization header, no token — so no secret
    /// is ever in scope to leak into evidence (AC-6.4). Bounded; degrades to a typed
    /// failure outcome that the check renders as `skipped`, never `fail`.
    static func productionLatestReleaseLookup() -> UpdateOutcome {
        let repo = "MongLong0214/logic-pro-mcp"
        let url = "https://api.github.com/repos/\(repo)/releases/latest"
        if let result = runProductionCommand(
            executable: "/usr/bin/curl",
            arguments: ["-fsSL", "--max-time", "3", "-H", "Accept: application/vnd.github+json", url],
            timeout: 3.5
        ) {
            switch result {
            case let .completed(output):
                if output.exitCode == 0 {
                    return parseLatestTag(from: output.stdout).map { .found(version: $0) } ?? .parseError
                }
                if output.exitCode == 28 {
                    return .timeout // curl --max-time self-terminated before the bounded wrapper.
                }
                if output.exitCode == 22 {
                    return .httpError // curl -f: HTTP response >= 400
                }
                // Other curl failures (could-not-resolve/connect) → try gh, else offline.
            case .timedOut:
                return .timeout
            case .spawnFailed:
                break // curl missing — try gh.
            }
        }
        // gh fallback (best-effort; gh is a dev tool, often absent on end-user installs).
        for ghPath in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
            if let gh = runProductionCommand(
                executable: ghPath,
                arguments: ["release", "view", "--repo", repo, "--json", "tagName", "-q", ".tagName"],
                timeout: 3.5
            )?.output, gh.exitCode == 0 {
                let tag = gh.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return tag.isEmpty ? .parseError : .found(version: tag)
            }
        }
        return .offline
    }

    /// Parse `tag_name` from the GitHub "latest release" JSON. Returns nil on any
    /// shape mismatch (→ `.parseError`). Never echoes the payload anywhere.
    static func parseLatestTag(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              !tag.isEmpty else {
            return nil
        }
        return tag
    }

    /// Production reader for the Claude Code registration. Parses ~/.claude.json
    /// directly (top-level `mcpServers` plus every `projects.<path>.mcpServers`)
    /// and reports registration when a logic-pro-style entry resolves to a
    /// LogicProMCP binary. This spawns nothing — honoring the read-only contract.
    static func readProductionClaudeRegistration(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    ) -> ClaudeRegistration {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .configUnavailable(reason: "config file not found at \(configURL.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            return .configUnavailable(reason: "config file could not be read: \(String(describing: error))")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .configUnavailable(reason: "config file is not valid JSON: \(String(describing: error))")
        }
        guard let object = root as? [String: Any] else {
            return .configUnavailable(reason: "config root is not a JSON object")
        }

        var serverScopes: [[String: Any]] = []
        if let top = object["mcpServers"] as? [String: Any] {
            serverScopes.append(top)
        }
        if let projects = object["projects"] as? [String: Any] {
            for case let project as [String: Any] in projects.values {
                if let scoped = project["mcpServers"] as? [String: Any] {
                    serverScopes.append(scoped)
                }
            }
        }

        for scope in serverScopes {
            for (name, rawEntry) in scope {
                guard let entry = rawEntry as? [String: Any] else { continue }
                let nameMatches = name.localizedCaseInsensitiveContains("logic-pro")
                let command = (entry["command"] as? String) ?? ""
                let commandMatches = command
                    .localizedCaseInsensitiveContains("LogicProMCP")
                if nameMatches && commandMatches {
                    return .registered(command: command)
                }
            }
        }
        return .notRegistered
    }

    // MARK: - Test seams

    /// Test-only access to the production subprocess runner so the concurrent-drain
    /// and timeout/spawn-failure distinction can be exercised against real children.
    static func runProductionCommandForTesting(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProductionCommandResult? {
        runProductionCommand(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Test-only access to the config-based registration reader against a custom URL.
    static func readClaudeRegistrationForTesting(configURL: URL) -> ClaudeRegistration {
        readProductionClaudeRegistration(configURL: configURL)
    }
}
