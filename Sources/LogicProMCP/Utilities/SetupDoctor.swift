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

    enum DoctorProfile: String, Codable, CaseIterable, Hashable, Sendable {
        case auto
        case core
        case mixer
        case keycmd
        case legacyScripter = "legacy-scripter"
        case full
    }

    enum ClientProfile: String, Codable, CaseIterable, Hashable, Sendable {
        case auto
        case claudeCode = "claude-code"
        case claudeDesktop = "claude-desktop"
        case cursor
        case vscode
        case terminal
        case custom
    }

    enum SkipReason: String, Codable, Sendable {
        case profileNotRequired = "profile_not_required"
        case clientNotSelected = "client_not_selected"
        case pathDependentUnresolved = "path_dependent_unresolved"
        case capabilityAbsent = "capability_absent"
        case sourceBuildNoShareDir = "source_build_no_share_dir"
        case configAbsentOptional = "config_absent_optional"
    }

    enum CapabilityStatus: String, Codable, Sendable {
        case ready
        case notReady = "not_ready"
        case unknownLiveVerifyRequired = "unknown_live_verify_required"
        case notInProfile = "not_in_profile"
    }

    struct DoctorProfileBlock: Codable, Equatable, Sendable {
        let requested: DoctorProfile
        let effective: DoctorProfile
        let basis: String
    }

    struct ClientProfileBlock: Codable, Equatable, Sendable {
        let requested: ClientProfile
        let effective: ClientProfile
        let basis: String
    }

    struct CapabilityReadiness: Codable, Equatable, Sendable {
        let status: CapabilityStatus
        let checks: [String]
        let liveVerify: String?

        enum CodingKeys: String, CodingKey {
            case status
            case checks
            case liveVerify = "live_verify"
        }
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
        let skipReason: SkipReason?

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
            case skipReason = "skip_reason"
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
        let profile: DoctorProfileBlock
        let client: ClientProfileBlock
        let capabilities: [String: CapabilityReadiness]

        enum CodingKeys: String, CodingKey {
            case schema
            case status
            case version
            case installSource = "install_source"
            case checks
            case summary
            case headline
            case fixPlan = "fix_plan"
            case profile
            case client
            case capabilities
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

    static let schema = "logic_pro_mcp_doctor.v4"

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
        let profileArgument = optionValue("--profile", in: arguments)
        let clientArgument = optionValue("--client", in: arguments)
        let requestedProfile = doctorProfile(from: profileArgument)
        let requestedClient = clientProfile(from: clientArgument)
        let launchContext = runtime.launchContext()
        let profileBlock = profileBlock(
            requested: requestedProfile,
            explicitArgument: profileArgument != nil,
            launchContext: launchContext
        )
        let clientBlock = clientBlock(
            requested: requestedClient,
            explicitArgument: clientArgument != nil,
            launchContext: launchContext,
            claudeRegistration: claudeRegistration,
            claudeDesktopRegistration: runtime.readClaudeDesktopRegistration()
        )
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
        let scopedChecks = (profileArgument != nil || clientArgument != nil)
            ? applyReadinessScope(checks, profile: profileBlock.effective, client: clientBlock.effective)
            : checks
        let capabilities = capabilityReadiness(checks: scopedChecks, profile: profileBlock.effective)

        // Honesty chokepoint (G1/AC-1.5): the report can never claim `ok` while a
        // required permission is ungranted. Extracted to a pure helper so the invariant
        // is OWNED and directly unit-tested here, not left emergent on each permission
        // check happening to be non-pass.
        let status = clampStatusForPermissions(
            aggregateStatus(scopedChecks),
            allGranted: permissionStatus.allGranted
        )

        let totalDurationMs = scopedChecks.reduce(0.0) { $0 + $1.durationMs }
        return Report(
            schema: schema,
            status: status,
            version: ServerConfig.serverVersion,
            installSource: installSource,
            checks: scopedChecks,
            summary: calculateSummary(scopedChecks, totalDurationMs: totalDurationMs),
            headline: computeHeadline(checks: scopedChecks, status: status),
            fixPlan: computeFixPlan(scopedChecks),
            profile: profileBlock,
            client: clientBlock,
            capabilities: capabilities
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
        blockedBy: String? = nil,
        skipReason: SkipReason? = nil
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
            optional: optional,
            skipReason: skipReason
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

    static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func doctorProfile(from raw: String?) -> DoctorProfile {
        guard let raw else { return .auto }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return DoctorProfile(rawValue: normalized) ?? .auto
    }

    static func clientProfile(from raw: String?) -> ClientProfile {
        guard let raw else { return .auto }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ClientProfile(rawValue: normalized) ?? .auto
    }

    static func profileBlock(
        requested: DoctorProfile,
        explicitArgument: Bool,
        launchContext: LaunchContextInfo
    ) -> DoctorProfileBlock {
        if !explicitArgument {
            return DoctorProfileBlock(requested: .auto, effective: .full, basis: "default_v3_compat")
        }
        switch requested {
        case .auto:
            let inferred: DoctorProfile
            let basis: String
            if launchContext.context == "terminal" {
                inferred = .core
                basis = "auto_terminal_core"
            } else {
                inferred = .core
                basis = "auto_default_core"
            }
            return DoctorProfileBlock(requested: requested, effective: inferred, basis: basis)
        case .core, .mixer, .keycmd, .legacyScripter, .full:
            return DoctorProfileBlock(requested: requested, effective: requested, basis: "explicit_flag")
        }
    }

    static func clientBlock(
        requested: ClientProfile,
        explicitArgument: Bool,
        launchContext: LaunchContextInfo,
        claudeRegistration: ClaudeRegistration,
        claudeDesktopRegistration: ClaudeRegistration
    ) -> ClientProfileBlock {
        if !explicitArgument {
            return ClientProfileBlock(requested: .auto, effective: .custom, basis: "default_v3_compat")
        }
        switch requested {
        case .auto:
            if launchContext.context == "claude_code" {
                return ClientProfileBlock(requested: requested, effective: .claudeCode, basis: "launch_context")
            }
            if launchContext.context == "claude_desktop" {
                return ClientProfileBlock(requested: requested, effective: .claudeDesktop, basis: "launch_context")
            }
            if launchContext.context == "cursor" {
                return ClientProfileBlock(requested: requested, effective: .cursor, basis: "launch_context")
            }
            if launchContext.context == "vscode" {
                return ClientProfileBlock(requested: requested, effective: .vscode, basis: "launch_context")
            }
            if launchContext.context == "terminal" {
                return ClientProfileBlock(requested: requested, effective: .terminal, basis: "launch_context")
            }
            if case .registered = claudeRegistration {
                return ClientProfileBlock(requested: requested, effective: .claudeCode, basis: "claude_code_config")
            }
            if case .registered = claudeDesktopRegistration {
                return ClientProfileBlock(requested: requested, effective: .claudeDesktop, basis: "claude_desktop_config")
            }
            return ClientProfileBlock(requested: requested, effective: .custom, basis: "auto_default_custom")
        case .claudeCode, .claudeDesktop, .cursor, .vscode, .terminal, .custom:
            return ClientProfileBlock(requested: requested, effective: requested, basis: "explicit_flag")
        }
    }

    static func applyReadinessScope(
        _ checks: [Check],
        profile: DoctorProfile,
        client: ClientProfile
    ) -> [Check] {
        checks.map { check in
            if profileExcludedCheckIDs(profile).contains(check.id) {
                return scopedSkip(check, reason: .profileNotRequired)
            }
            if clientExcludedCheckIDs(client).contains(check.id) {
                return scopedSkip(check, reason: .clientNotSelected)
            }
            return check
        }
    }

    private static func profileExcludedCheckIDs(_ profile: DoctorProfile) -> Set<String> {
        switch profile {
        case .auto:
            return profileExcludedCheckIDs(.core)
        case .core:
            return [
                "channels.manual_validation",
                "channels.keycmd_reference",
                "channels.mcu_wiring_hint",
            ]
        case .mixer:
            return [
                "channels.manual_validation",
                "channels.keycmd_reference",
                "channels.mcu_wiring_hint",
            ]
        case .keycmd:
            return [
                "channels.mcu_wiring_hint",
            ]
        case .legacyScripter:
            return [
                "channels.keycmd_reference",
                "channels.mcu_wiring_hint",
            ]
        case .full:
            return []
        }
    }

    private static func clientExcludedCheckIDs(_ client: ClientProfile) -> Set<String> {
        switch client {
        case .auto:
            return clientExcludedCheckIDs(.custom)
        case .claudeCode:
            return ["mcp.claude_desktop_registration"]
        case .claudeDesktop:
            return ["mcp.claude_code_registration", "mcp.registration_target"]
        case .cursor, .vscode, .terminal, .custom:
            return [
                "mcp.claude_code_registration",
                "mcp.registration_target",
                "mcp.claude_desktop_registration",
            ]
        }
    }

    private static func scopedSkip(_ check: Check, reason: SkipReason) -> Check {
        Check(
            id: check.id,
            domain: check.domain,
            status: .skipped,
            summary: "\(check.summary) Skipped for selected readiness scope.",
            evidence: check.evidence,
            remediation: Remediation(type: .none, value: ""),
            category: check.category,
            severity: severity(for: .skipped),
            durationMs: check.durationMs,
            blockedBy: check.blockedBy,
            optional: true,
            skipReason: reason
        )
    }

    private struct CapabilityDefinition {
        let id: String
        let checks: [String]
        let profiles: Set<DoctorProfile>
        let liveVerify: String?
        let hintGrade: Bool
    }

    private static let capabilityDefinitions: [CapabilityDefinition] = [
        CapabilityDefinition(
            id: "core_transport",
            checks: [
                "binary.path",
                "binary.executable",
                "permissions.accessibility",
                "permissions.post_event_access",
                "logic.installation",
                "logic.version_support",
                "logic.application_state",
            ],
            profiles: [.core, .mixer, .keycmd, .legacyScripter, .full],
            liveVerify: nil,
            hintGrade: false
        ),
        CapabilityDefinition(
            id: "track_management",
            checks: [
                "permissions.automation_logic_pro",
                "logic.blocking_dialog",
            ],
            profiles: [.core, .mixer, .full],
            liveVerify: nil,
            hintGrade: false
        ),
        CapabilityDefinition(
            id: "midi_import",
            checks: [
                "permissions.automation_system_events",
            ],
            profiles: [.keycmd, .full],
            liveVerify: nil,
            hintGrade: false
        ),
        CapabilityDefinition(
            id: "mixer_ax",
            checks: [
                "permissions.automation_logic_pro",
                "logic.blocking_dialog",
            ],
            profiles: [.mixer, .full],
            liveVerify: nil,
            hintGrade: false
        ),
        CapabilityDefinition(
            id: "mixer_mcu",
            checks: [
                "channels.mcu_wiring_hint",
            ],
            profiles: [.full],
            liveVerify: "logic://system/health mcu.connected",
            hintGrade: true
        ),
        CapabilityDefinition(
            id: "project_lifecycle",
            checks: [
                "permissions.automation_logic_pro",
                "permissions.automation_system_events",
            ],
            profiles: [.core, .full],
            liveVerify: nil,
            hintGrade: false
        ),
        CapabilityDefinition(
            id: "keycmd_only_ops",
            checks: [
                "channels.keycmd_reference",
                "channels.manual_validation",
            ],
            profiles: [.keycmd, .full],
            liveVerify: nil,
            hintGrade: false
        ),
        CapabilityDefinition(
            id: "legacy_scripter",
            checks: [
                "channels.manual_validation",
            ],
            profiles: [.legacyScripter, .full],
            liveVerify: nil,
            hintGrade: false
        ),
        CapabilityDefinition(
            id: "verified_plugin_applyback",
            checks: [
                "permissions.automation_logic_pro",
                "logic.blocking_dialog",
            ],
            profiles: [.mixer, .full],
            liveVerify: nil,
            hintGrade: false
        ),
    ]

    static func capabilityReadiness(
        checks: [Check],
        profile: DoctorProfile
    ) -> [String: CapabilityReadiness] {
        let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })
        var result: [String: CapabilityReadiness] = [:]
        for definition in capabilityDefinitions {
            guard definition.profiles.contains(profile) else {
                result[definition.id] = CapabilityReadiness(
                    status: .notInProfile,
                    checks: definition.checks,
                    liveVerify: definition.liveVerify
                )
                continue
            }
            let contributing = definition.checks.compactMap { byID[$0] }
            let status: CapabilityStatus
            if contributing.count != definition.checks.count {
                status = .unknownLiveVerifyRequired
            } else if contributing.contains(where: { $0.status == .fail || $0.status == .warn }) {
                status = .notReady
            } else if definition.hintGrade || contributing.contains(where: { $0.status == .manual || $0.status == .skipped }) {
                status = .unknownLiveVerifyRequired
            } else {
                status = .ready
            }
            result[definition.id] = CapabilityReadiness(
                status: status,
                checks: definition.checks,
                liveVerify: definition.liveVerify
            )
        }
        return result
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
