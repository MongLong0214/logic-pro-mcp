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

    /// Shared with SetupLifecycle — see `SetupRemediationType`. Aliased (not
    /// redeclared) so both surfaces emit an identical `remediation` wire shape.
    typealias RemediationType = SetupRemediationType

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

    /// Shared with SetupLifecycle — see `SetupRemediation`.
    typealias Remediation = SetupRemediation

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
        // v3 additive field (D9). Root-cause id when this check's natural status was
        // collapsed by the `blockedByDependencies` table. `String?` so the synthesized
        // Codable emits `encodeIfPresent` — the `blocked_by` key is OMITTED when nil,
        // keeping v3 a strict superset a v1/v2 decoder never trips over. Set only at
        // construction via the `check(...)` factory (no post-construction mutation, R9).
        var blockedBy: String?
        let optional: Bool

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
            case blockedBy = "blocked_by"
            case optional
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
        // v3 additive top-level field (G2). Ordered check ids of the root-cause-collapsed,
        // severity-ordered actionable set (see `computeFixPlan`). Always present (may be []).
        let fixPlan: [String]

        enum CodingKeys: String, CodingKey {
            case schema
            case status
            case version
            case installSource = "install_source"
            case checks
            case summary
            case headline
            case fixPlan = "fix_plan"
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
        case registered(command: String, environment: [String: String] = [:])
        /// The config was read successfully but no matching registration exists.
        case notRegistered
        /// The config file is absent / unreadable / not valid JSON.
        /// `reason` is a short human-readable explanation for the evidence dict.
        case configUnavailable(reason: String)
    }

    struct LogicAppInfo: Equatable, Sendable {
        let path: String
        let version: String?
        let bundleID: String?
        let readable: Bool
    }

    enum ShareDirProbe: Equatable, Sendable {
        case complete(path: String, source: String)
        case missing(path: String, source: String, files: [String])
        case unresolved
        case invalid(path: String, source: String)
    }

    struct LaunchContextInfo: Equatable, Sendable {
        let context: String
        let responsibleHint: String
    }

    enum TCCCrossContextProbe: Equatable, Sendable {
        case granted(String)
        case denied(String)
        case skipped(reason: String)
    }

    struct TCCRow: Equatable, Sendable {
        let service: String
        let client: String
        let authValue: Int
        let indirectObjectIdentifier: String
    }

    enum TCCQueryOutcome: Equatable, Sendable {
        case rows([TCCRow])
        case fullDiskAccessUnavailable
        case queryUnavailable
        case schemaMismatch
    }

    enum StaticVersionResult: Equatable, Sendable {
        case version(String)
        case indeterminate([String])
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
        var logicApps: () -> [LogicAppInfo] = { SetupDoctor.productionLogicApps() }
        var shareDirProbe: () -> ShareDirProbe = { SetupDoctor.productionShareDirProbe() }
        var readClaudeDesktopRegistration: () -> ClaudeRegistration = { SetupDoctor.readProductionClaudeDesktopRegistration() }
        var keyCommandsPresetStaged: () -> Bool = { SetupDoctor.productionKeyCommandsPresetStaged() }
        var mcuPortReferenceFound: () -> Bool? = { SetupDoctor.productionMCUPortReferenceFound() }
        var launchContext: () -> LaunchContextInfo = { SetupDoctor.productionLaunchContext() }
        var tccCrossContextProbe: () -> TCCCrossContextProbe = { SetupDoctor.productionTCCCrossContextProbe() }
        var blockingDialogInfo: () -> AXLogicProElements.BlockingDialogInfo? = {
            AXLogicProElements.blockingDialogInfo()
        }
        var fileExistsAtPath: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var isRegularFile: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
            return !isDirectory.boolValue
        }
        var isDirectory: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
            return isDirectory.boolValue
        }

        static let production = Runtime(
            resolveExecutablePath: { raw in
                SetupDoctor.resolveProductionExecutablePath(raw)
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
                guard DoctorTool.resolve(executable) != nil else { return nil }
                return SetupDoctor.runProductionCommand(executable: executable, arguments: arguments, timeout: 1.5)?.output
            },
            readClaudeRegistration: {
                SetupDoctor.readProductionClaudeRegistration()
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

    static let schema = "logic_pro_mcp_doctor.v3"

    static let remediationAnchorsByCheckID: [String: String] = [
        "binary.path": "docs/SETUP.md#doctor-binarypath",
        "binary.executable": "docs/SETUP.md#doctor-binaryexecutable",
        "install.source": "docs/SETUP.md#doctor-installsource",
        "install.binary_inventory": "docs/SETUP.md#doctor-installbinary-inventory",
        "install.share_dir": "docs/SETUP.md#doctor-installshare-dir",
        "release.signature": "docs/SETUP.md#doctor-releasesignature",
        "release.quarantine": "docs/SETUP.md#doctor-releasequarantine",
        "mcp.claude_code_registration": "docs/SETUP.md#doctor-mcpclaude-code-registration",
        "mcp.registration_target": "docs/SETUP.md#doctor-mcpregistration-target",
        "mcp.claude_desktop_registration": "docs/SETUP.md#doctor-mcpclaude-desktop-registration",
        "permissions.accessibility": "docs/SETUP.md#doctor-permissionsaccessibility",
        "permissions.automation_logic_pro": "docs/SETUP.md#doctor-permissionsautomation-logic-pro",
        "permissions.automation_system_events": "docs/SETUP.md#doctor-permissionsautomation-system-events",
        "permissions.post_event_access": "docs/SETUP.md#doctor-permissionspost-event-access",
        "permissions.launch_context": "docs/SETUP.md#doctor-permissionslaunch-context",
        "permissions.tcc_cross_context": "docs/SETUP.md#doctor-permissionstcc-cross-context",
        "system.macos_version": "docs/SETUP.md#doctor-systemmacos-version",
        "updates.latest_release": "docs/SETUP.md#doctor-updateslatest-release",
        "logic.installation": "docs/SETUP.md#doctor-logicinstallation",
        "logic.version_support": "docs/SETUP.md#doctor-logicversion-support",
        "logic.application_state": "docs/SETUP.md#doctor-logicapplication-state",
        "logic.blocking_dialog": "docs/SETUP.md#doctor-logicblocking-dialog",
        "channels.manual_validation": "docs/SETUP.md#doctor-channelsmanual-validation",
        "channels.keycmd_reference": "docs/SETUP.md#doctor-channelskeycmd-reference",
        "channels.mcu_wiring_hint": "docs/SETUP.md#doctor-channelsmcu-wiring-hint",
        "dependencies.click_fallback": "docs/SETUP.md#doctor-dependenciesclick-fallback",
    ]

    static func generate(
        arguments: [String],
        permissionStatus: PermissionChecker.PermissionStatus,
        approvals: [ManualValidationChannel: ManualValidationApproval],
        runtime: Runtime = .production
    ) -> Report {
        let executablePath = runtime.resolveExecutablePath(arguments.first)
        let installSource = detectInstallSource(executablePath: executablePath, runtime: runtime)
        let claudeRegistration = runtime.readClaudeRegistration()
        let logicApps = runtime.logicApps()
        var staticVersionCache: [String: StaticVersionResult] = [:]

        func staticVersionForPath(_ path: String) -> StaticVersionResult {
            let key = standardized(path)
            if let cached = staticVersionCache[key] { return cached }
            let strings = runtime.runCommand("/usr/bin/strings", ["-a", path])?.stdout ?? ""
            let result = Self.staticVersion(fromStringsOutput: strings)
            staticVersionCache[key] = result
            return result
        }

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
        checks.append(timed {
            installBinaryInventoryCheck(
                executablePath: executablePath,
                runtime: runtime,
                claudeRegistration: claudeRegistration,
                staticVersionForPath: staticVersionForPath
            )
        })
        checks.append(timed { installShareDirCheck(runtime: runtime) })
        checks.append(timed { releaseSignatureCheck(executablePath: executablePath, runtime: runtime) })
        checks.append(timed { releaseQuarantineCheck(executablePath: executablePath, runtime: runtime) })
        checks.append(timed { claudeRegistrationCheck(registration: claudeRegistration) })
        checks.append(timed {
            mcpRegistrationTargetCheck(
                registration: claudeRegistration,
                runtime: runtime,
                checks: checks,
                staticVersionForPath: staticVersionForPath
            )
        })
        checks.append(timed { claudeDesktopRegistrationCheck(runtime: runtime) })
        checks.append(timed { accessibilityPermissionCheck(permissionStatus) })
        checks.append(timed { automationPermissionCheck(permissionStatus) })
        checks.append(timed { systemEventsAutomationCheck(permissionStatus) })
        checks.append(timed { postEventAccessCheck(permissionStatus) })
        checks.append(timed { launchContextCheck(runtime: runtime) })
        checks.append(timed { tccCrossContextCheck(runtime: runtime) })
        checks.append(timed { macOSVersionCheck(runtime: runtime) })
        checks.append(timed { logicInstallationCheck(logicApps: logicApps) })
        checks.append(timed { logicVersionSupportCheck(logicApps: logicApps, checks: checks) })
        checks.append(timed { logicApplicationStateCheck(runtime: runtime) })
        checks.append(timed { logicBlockingDialogCheck(runtime: runtime, checks: checks) })
        checks.append(timed { manualValidationCheck(approvals: approvals) })
        checks.append(timed { keycmdReferenceCheck(runtime: runtime) })
        checks.append(timed { mcuWiringHintCheck(runtime: runtime) })
        checks.append(timed { clickFallbackCheck(runtime: runtime, permissionStatus: permissionStatus) })
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
            headline: computeHeadline(checks: checks, status: status),
            fixPlan: computeFixPlan(checks)
        )
    }

    /// Shared binary-resolve precondition for the binary/release checks: the
    /// path must be present AND exist on disk. Returns the resolved path, or
    /// nil so the caller can emit its own missing-binary Check. Dedups the
    /// `guard let path, fileExists(path)` repeated across the four checks.
    static func check(
        id: String,
        domain: String,
        status: CheckStatus,
        summary: String,
        evidence: [String: String],
        remediationType: RemediationType,
        remediationValueOverride: String? = nil,
        optional: Bool = false,
        blockedBy: String? = nil
    ) -> Check {
        let value = remediationValueOverride ?? defaultRemediationValue(for: id, type: remediationType)
        // category/severity are DERIVED here (single chokepoint) so no check can be
        // built with an inconsistent taxonomy and the 11 existing call sites need no
        // edit. durationMs is stamped post-hoc by the `generate` timing wrapper.
        // `blockedBy` is threaded here (M1/R9) — the defaulted nil keeps every existing
        // call site compiling unchanged; T3/T5 checks pass a resolved cause id.
        return Check(
            id: id,
            domain: domain,
            status: status,
            summary: summary,
            evidence: sanitizedEvidence(evidence),
            remediation: Remediation(type: remediationType, value: value),
            category: category(forDomain: domain),
            severity: severity(for: status),
            durationMs: 0,
            blockedBy: blockedBy,
            optional: optional
        )
    }

    private static func sanitizedEvidence(_ evidence: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: evidence.map { key, value in
            if key == "stderr" {
                return (key, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "present")
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return (key, value.replacingOccurrences(of: home, with: "~"))
        })
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

    static func computeFixPlan(_ checks: [Check]) -> [String] {
        func tier(_ status: CheckStatus) -> Int {
            switch status {
            case .fail:
                return 0
            case .warn, .manual:
                return 1
            case .pass, .skipped:
                return 2
            }
        }

        return checks
            .enumerated()
            .filter { $0.element.blockedBy == nil }
            .filter { tier($0.element.status) < 2 }
            .sorted {
                let leftTier = tier($0.element.status)
                let rightTier = tier($1.element.status)
                return leftTier == rightTier ? $0.offset < $1.offset : leftTier < rightTier
            }
            .map(\.element.id)
    }

    static let blockedByDependencies: [String: [String]] = [
        "mcp.registration_target": ["mcp.claude_code_registration"],
        "logic.version_support": ["logic.installation"],
        "logic.blocking_dialog": ["logic.application_state", "permissions.accessibility"],
    ]

    static func status(of id: String, in checks: [Check]) -> CheckStatus? {
        checks.first { $0.id == id }?.status
    }

    static func blockingCause(for id: String, checks: [Check]) -> String? {
        for cause in blockedByDependencies[id] ?? [] {
            if status(of: cause, in: checks) != .pass {
                return cause
            }
        }
        return nil
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

}
