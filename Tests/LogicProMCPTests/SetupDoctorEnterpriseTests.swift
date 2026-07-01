import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Hermetic runtime/permission builders for the v2 doctor surface

private func enterpriseRuntime(
    macOSVersion: OperatingSystemVersion? = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
    monotonicNowMs: @escaping () -> Double = { 0 },
    latestReleaseLookup: (() -> SetupDoctor.UpdateOutcome)? = nil
) -> SetupDoctor.Runtime {
    var runtime = SetupDoctor.Runtime(
        resolveExecutablePath: { _ in "/opt/homebrew/bin/LogicProMCP" },
        fileExists: { _ in true },
        isExecutableFile: { _ in true },
        logicProRunning: { true },
        logicProHasVisibleWindow: { true },
        runCommand: { executable, arguments in
            if executable == "/usr/bin/codesign" { return .init(exitCode: 0, stdout: "", stderr: "") }
            if executable == "/usr/bin/xattr" { return .init(exitCode: 1, stdout: "", stderr: "No such xattr") }
            if executable == "/opt/homebrew/bin/brew" || executable == "/usr/local/bin/brew",
               arguments == ["list", "--versions", "logic-pro-mcp"] {
                return .init(exitCode: 0, stdout: "logic-pro-mcp 3.7.4\n", stderr: "")
            }
            return nil
        },
        readClaudeRegistration: { .registered(command: "/opt/homebrew/bin/LogicProMCP") }
    )
    runtime.macOSVersion = { macOSVersion }
    runtime.monotonicNowMs = monotonicNowMs
    runtime.latestReleaseLookup = latestReleaseLookup
    return runtime
}

private func granted(
    accessibility: Bool = true,
    automationLogicPro: Bool = true,
    systemEvents: PermissionChecker.CheckState = .granted
) -> PermissionChecker.PermissionStatus {
    .init(
        accessibilityState: accessibility ? .granted : .notGranted,
        automationState: automationLogicPro ? .granted : .notGranted,
        systemEventsAutomationState: systemEvents
    )
}

private func enterpriseApprovals() -> [ManualValidationChannel: ManualValidationApproval] {
    Dictionary(uniqueKeysWithValues: ManualValidationChannel.allCases.map {
        ($0, ManualValidationApproval(approvedAt: Date(timeIntervalSince1970: 0), note: "test"))
    })
}

private func makeReport(
    runtime: SetupDoctor.Runtime = enterpriseRuntime(),
    permission: PermissionChecker.PermissionStatus = granted(),
    approvals: [ManualValidationChannel: ManualValidationApproval]? = nil
) -> SetupDoctor.Report {
    SetupDoctor.generate(
        arguments: ["LogicProMCP", "doctor", "--json"],
        permissionStatus: permission,
        approvals: approvals ?? enterpriseApprovals(),
        runtime: runtime
    )
}

private func check(_ report: SetupDoctor.Report, _ id: String) -> SetupDoctor.Check? {
    report.checks.first { $0.id == id }
}

// MARK: - T1: v2 model framework

@Test func test_t1_schema_is_v2() {
    #expect(makeReport().schema == "logic_pro_mcp_doctor.v2")
}

@Test func test_t1_each_check_has_category_severity_duration() throws {
    let report = makeReport()
    for c in report.checks {
        // Concrete-value assertions (no `!= nil` on non-optional fields = dead).
        #expect(c.severity == SetupDoctor.severity(for: c.status))
        #expect(c.category == SetupDoctor.category(forDomain: c.domain))
        #expect(c.durationMs >= 0)
    }
    // Spot-check a known mapping concretely.
    let accessibility = try #require(check(report, "permissions.accessibility"))
    #expect(accessibility.category == .permissions)
}

@Test func test_t1_severity_mapping_total() {
    #expect(SetupDoctor.severity(for: .fail) == .error)
    #expect(SetupDoctor.severity(for: .warn) == .warning)
    #expect(SetupDoctor.severity(for: .manual) == .warning)
    #expect(SetupDoctor.severity(for: .skipped) == .info)
    #expect(SetupDoctor.severity(for: .pass) == .info)
}

@Test func test_t1_category_mapping_complete() {
    #expect(SetupDoctor.category(forDomain: "binary") == .installation)
    #expect(SetupDoctor.category(forDomain: "install") == .installation)
    #expect(SetupDoctor.category(forDomain: "release") == .installation)
    #expect(SetupDoctor.category(forDomain: "system") == .installation)
    #expect(SetupDoctor.category(forDomain: "mcp") == .configuration)
    #expect(SetupDoctor.category(forDomain: "channels") == .configuration)
    #expect(SetupDoctor.category(forDomain: "permissions") == .permissions)
    #expect(SetupDoctor.category(forDomain: "dependencies") == .dependencies)
    #expect(SetupDoctor.category(forDomain: "updates") == .updates)
    #expect(SetupDoctor.category(forDomain: "logic") == .runtime)
}

@Test func test_t1_summary_counts_invariant() {
    let report = makeReport()
    let s = report.summary
    #expect(s.total == report.checks.count)
    #expect(s.passed + s.failed + s.warnings + s.manual + s.skipped == s.total)
    #expect(s.passed == report.checks.filter { $0.status == .pass }.count)
    #expect(s.failed == report.checks.filter { $0.status == .fail }.count)
    #expect(s.warnings == report.checks.filter { $0.status == .warn }.count)
    #expect(s.manual == report.checks.filter { $0.status == .manual }.count)
    #expect(s.skipped == report.checks.filter { $0.status == .skipped }.count)
}

@Test func test_t1_summary_status_formula_degraded() {
    let report = makeReport(
        runtime: enterpriseRuntime(macOSVersion: nil)
    )
    #expect(report.status == .degraded)
    #expect(report.summary.failed == 0)
    #expect(report.summary.manual == 0)
    #expect(report.summary.warnings > 0 || report.summary.skipped > 0)
}

@Test func test_t1_summary_status_formula_ok() {
    let report = makeReport()
    #expect(report.status == .ok)
    #expect(report.summary.failed == 0)
    #expect(report.summary.manual == 0)
    #expect(report.summary.warnings == 0)
    #expect(report.summary.skipped == 0)
}

@Test func test_t1_summary_duration_is_sum_of_per_check() {
    // Deterministic monotonic clock: 0,1,2,3,... Each check = 2 calls (start,end),
    // delta 1ms. 13 checks (no update check) → summary == 13.0, and >= max per-check.
    var tick = 0.0
    let report = makeReport(
        runtime: enterpriseRuntime(monotonicNowMs: {
            let value = tick
            tick += 1
            return value
        })
    )
    #expect(report.checks.count == 13)
    let perCheckSum = report.checks.reduce(0.0) { $0 + $1.durationMs }
    #expect(report.summary.durationMs == perCheckSum)
    #expect(report.summary.durationMs == 13.0)
    let maxPerCheck = report.checks.map(\.durationMs).max() ?? 0
    #expect(report.summary.durationMs >= maxPerCheck)
    #expect(report.summary.durationMs >= 0)
}

@Test func test_t1_monotonicity_chokepoint_accessibility() {
    let report = makeReport(permission: granted(accessibility: false))
    #expect(report.status != .ok)
}

@Test func test_t1_monotonicity_chokepoint_automation_logic_pro() {
    // automationLogicPro not granted (Logic Pro running so it's a real denial, not notVerifiable).
    let report = makeReport(permission: granted(automationLogicPro: false))
    #expect(report.status != .ok)
}

@Test func test_t1_monotonicity_chokepoint_system_events() {
    let report = makeReport(permission: granted(systemEvents: .notGranted))
    #expect(report.status != .ok)
}

@Test func test_t1_headline_names_highest_severity() {
    let report = makeReport(
        runtime: enterpriseRuntime(),
        permission: granted(accessibility: false)
    )
    #expect(report.headline.contains("permissions.accessibility"))
}

@Test func test_t1_headline_healthy_when_all_pass() {
    #expect(makeReport().headline == "Logic Pro MCP install is healthy.")
}

@Test func test_t1_e10a_v2_json_contains_literal_v1_keys() throws {
    let json = encodeJSON(makeReport())
    let object = try #require(sharedJSONObject(json))
    for key in ["schema", "status", "version", "install_source", "checks"] {
        #expect(object[key] != nil, "missing top-level v1 key \(key)")
    }
    let checks = try #require(object["checks"] as? [[String: Any]])
    let first = try #require(checks.first)
    for key in ["id", "domain", "status", "summary", "evidence", "remediation"] {
        #expect(first[key] != nil, "missing per-check v1 key \(key)")
    }
    // v2 additive keys present too.
    #expect(first["category"] != nil)
    #expect(first["severity"] != nil)
    #expect(first["duration_ms"] != nil)
}

private struct FrozenV1Remediation: Codable { let type: String; let value: String }
private struct FrozenV1Check: Codable {
    let id: String
    let domain: String
    let status: String
    let summary: String
    let evidence: [String: String]
    let remediation: FrozenV1Remediation
}
private struct FrozenV1Report: Codable {
    let schema: String
    let status: String
    let version: String
    let installSource: String
    let checks: [FrozenV1Check]
    enum CodingKeys: String, CodingKey {
        case schema, status, version
        case installSource = "install_source"
        case checks
    }
}

@Test func test_t1_e10b_v2_decodes_with_frozen_v1_struct() throws {
    let json = encodeJSON(makeReport())
    // A frozen v1-shaped consumer must still decode v2 output (additive superset).
    let frozen: FrozenV1Report = try decodeJSON(json)
    #expect(frozen.schema == "logic_pro_mcp_doctor.v2")
    let ids = Set(frozen.checks.map(\.id))
    // Every original v1 check id must survive (a dropped v1 check would fail this).
    let v1Ids = [
        "binary.path", "binary.executable", "binary.version", "install.source",
        "release.signature", "release.quarantine", "mcp.claude_code_registration",
        "permissions.accessibility", "permissions.automation_logic_pro",
        "logic.application_state", "channels.manual_validation",
    ]
    for id in v1Ids {
        #expect(ids.contains(id), "v1 check id \(id) missing from v2 output")
    }
    // Each decoded check has the v1 remediation shape (type+value) — a type change would throw above.
    let first = try #require(frozen.checks.first)
    #expect(!first.remediation.type.isEmpty)
}

// MARK: - T2: System Events / macOS checks

@Test func test_t2_system_events_pass() throws {
    let c = try #require(check(makeReport(permission: granted(systemEvents: .granted)), "permissions.automation_system_events"))
    #expect(c.status == .pass)
    #expect(c.category == .permissions)
}

@Test func test_t2_system_events_fail_and_remediation() throws {
    let c = try #require(check(makeReport(permission: granted(systemEvents: .notGranted)), "permissions.automation_system_events"))
    #expect(c.status == .fail)
    #expect(c.remediation.type == .systemSettings)
    #expect(c.remediation.value.contains("System Events"))
    #expect(c.severity == .error)
}

@Test func test_t2_system_events_manual_on_not_verifiable() throws {
    let c = try #require(check(makeReport(permission: granted(systemEvents: .notVerifiable)), "permissions.automation_system_events"))
    #expect(c.status == .manual)
}

@Test func test_t2_system_events_independent_of_logic_pro_automation() throws {
    // Logic Pro automation notVerifiable (Logic not running → manual) but System
    // Events independently granted → System Events passes (AC-1.6 independence).
    let permission = PermissionChecker.PermissionStatus(
        accessibilityState: .granted,
        automationState: .notVerifiable,
        systemEventsAutomationState: .granted
    )
    let report = makeReport(permission: permission)
    let logicAutomation = try #require(check(report, "permissions.automation_logic_pro"))
    let systemEvents = try #require(check(report, "permissions.automation_system_events"))
    #expect(logicAutomation.status == .manual)
    #expect(systemEvents.status == .pass)
}

@Test func test_t2_system_events_fail_independent_of_logic_automation() throws {
    // Mirror case (R10): Logic Pro automation granted but System Events denied → SE fail.
    let report = makeReport(permission: granted(automationLogicPro: true, systemEvents: .notGranted))
    let systemEvents = try #require(check(report, "permissions.automation_system_events"))
    #expect(systemEvents.status == .fail)
}

@Test func test_t2_macos_pass_ge_14() throws {
    let c = try #require(check(makeReport(runtime: enterpriseRuntime(macOSVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 1))), "system.macos_version"))
    #expect(c.status == .pass)
    #expect(c.evidence["version"] == "14.5.1")
}

@Test func test_t2_macos_pass_future() throws {
    let c = try #require(check(makeReport(runtime: enterpriseRuntime(macOSVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))), "system.macos_version"))
    #expect(c.status == .pass)
}

@Test func test_t2_macos_fail_lt_14() throws {
    let c = try #require(check(makeReport(runtime: enterpriseRuntime(macOSVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 1))), "system.macos_version"))
    #expect(c.status == .fail)
}

@Test func test_t2_macos_skipped_unreadable() throws {
    let c = try #require(check(makeReport(runtime: enterpriseRuntime(macOSVersion: nil)), "system.macos_version"))
    #expect(c.status == .skipped)
    #expect(c.evidence["reason"] == "version_unreadable")
}

@Test func test_t2_system_events_denial_makes_report_failed() {
    let report = makeReport(permission: granted(systemEvents: .notGranted))
    #expect(report.status == .failed)
}

// MARK: - T3: presentation

@Test func test_t3_default_render_shape() {
    let report = makeReport(permission: granted(systemEvents: .notGranted))
    let out = SetupDoctor.renderHuman(report, mode: .default, useColor: false)
    #expect(out.contains("summary:"))
    #expect(out.contains("[pass] binary.path"))
    #expect(out.contains("permissions.automation_system_events"))
}

@Test func test_t3_verbose_render_adds_evidence_and_duration() {
    let out = SetupDoctor.renderHuman(makeReport(), mode: .verbose, useColor: false)
    #expect(out.contains("duration_ms:"))
    #expect(out.contains("version=")) // macOS version evidence key
}

@Test func test_t3_quiet_render_only_nonpass() {
    let report = makeReport(permission: granted(systemEvents: .notGranted))
    let out = SetupDoctor.renderHuman(report, mode: .quiet, useColor: false)
    #expect(out.contains("[fail] permissions.automation_system_events"))
    #expect(!out.contains("[pass] binary.path")) // pass lines omitted in quiet mode
}

@Test func test_t3_color_on_tty() {
    let report = makeReport(permission: granted(systemEvents: .notGranted))
    let out = SetupDoctor.renderHuman(report, mode: .default, useColor: true)
    #expect(out.contains("\u{1B}[")) // ANSI escape present
    #expect(out.contains("\u{2713}")) // ✓ symbol for a pass check
}

@Test func test_t3_plain_when_not_tty() {
    let report = makeReport(runtime: enterpriseRuntime())
    let out = SetupDoctor.renderHuman(report, mode: .default, useColor: false)
    #expect(!out.contains("\u{1B}[")) // no ANSI escapes
    #expect(out.contains("[pass]"))
}

@Test func test_t3_headline_render_nonpass() {
    let report = makeReport(permission: granted(systemEvents: .notGranted))
    let out = SetupDoctor.renderHuman(report, mode: .default, useColor: false)
    #expect(out.contains("Next action"))
    #expect(out.contains("permissions.automation_system_events"))
}

// MARK: - T3/T4 entrypoint flag routing

private actor EnterpriseMockServer: ServerStarting {
    func start() async throws {}
}

private func runEntrypoint(
    _ args: [String],
    permission: PermissionChecker.PermissionStatus = granted(),
    runtime: SetupDoctor.Runtime = enterpriseRuntime(),
    isTTY: Bool = false,
    env: [String: String] = [:]
) async -> (Int, String) {
    var stdout = ""
    let store = ManualValidationStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-ent-\(UUID().uuidString)").appendingPathExtension("json")
    )
    try? await store.approve(.midiKeyCommands, note: "t")
    try? await store.approve(.scripter, note: "t")
    let code = await MainEntrypoint.run(
        arguments: args,
        permissionCheck: { permission },
        serverFactory: {
            Issue.record("server must not start for doctor")
            return EnterpriseMockServer()
        },
        approvalStoreFactory: { store },
        doctorRuntime: runtime,
        isStdoutTTY: { isTTY },
        doctorEnvironment: env,
        writeStdout: { stdout += $0 },
        writeStderr: { _ in }
    )
    return (code, stdout)
}

@Test func test_t3_entrypoint_json_beats_verbose() async {
    let (_, jsonOnly) = await runEntrypoint(["LogicProMCP", "doctor", "--json"])
    let (_, jsonVerbose) = await runEntrypoint(["LogicProMCP", "doctor", "--json", "--verbose"])
    // Identical JSON bytes regardless of verbosity (compare strings — [String:Any] isn't Equatable).
    #expect(jsonOnly == jsonVerbose)
    #expect(!jsonVerbose.contains("\u{1B}["))
}

@Test func test_t3_entrypoint_verbose_beats_quiet() async {
    let (_, out) = await runEntrypoint(["LogicProMCP", "doctor", "--verbose", "--quiet"])
    #expect(out.contains("duration_ms:")) // verbose shape wins
}

@Test func test_t3_entrypoint_plain_when_no_color_env_even_on_tty() async {
    let report = enterpriseRuntime()
    let (_, out) = await runEntrypoint(
        ["LogicProMCP", "doctor"], runtime: report, isTTY: true, env: ["NO_COLOR": "1"]
    )
    #expect(!out.contains("\u{1B}["))
}

@Test func test_t3_entrypoint_color_on_tty_without_no_color() async {
    let report = enterpriseRuntime()
    let (_, out) = await runEntrypoint(
        ["LogicProMCP", "doctor"], runtime: report, isTTY: true, env: [:]
    )
    #expect(out.contains("\u{1B}["))
}

@Test func test_t3_entrypoint_exit_code_verbosity_independent() async {
    for args in [["LogicProMCP", "doctor"], ["LogicProMCP", "doctor", "--quiet"], ["LogicProMCP", "doctor", "--verbose"]] {
        let (code, _) = await runEntrypoint(args, permission: granted(systemEvents: .notGranted))
        #expect(code == 1)
    }
}

@Test func test_t2_entrypoint_system_events_denied_exits_1() async {
    let (code, _) = await runEntrypoint(["LogicProMCP", "doctor"], permission: granted(systemEvents: .notGranted))
    #expect(code == 1)
}

@Test func test_t4_entrypoint_default_run_has_no_update_check() async {
    let (_, out) = await runEntrypoint(["LogicProMCP", "doctor", "--json"])
    #expect(!out.contains("updates.latest_release")) // no flag → no update check, no network
}

// MARK: - T4: update check

@Test func test_t4_no_update_check_without_lookup() {
    let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: nil))
    #expect(check(report, "updates.latest_release") == nil)
}

@Test func test_t4_update_pass_when_current() throws {
    let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { .found(version: ServerConfig.serverVersion) }))
    let c = try #require(check(report, "updates.latest_release"))
    #expect(c.status == .pass)
    #expect(c.evidence["installed"] == ServerConfig.serverVersion)
    #expect(c.evidence["latest"] == ServerConfig.serverVersion)
    #expect(c.category == .updates)
}

@Test func test_t4_update_warn_when_behind() throws {
    let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { .found(version: "v99.0.0") }))
    let c = try #require(check(report, "updates.latest_release"))
    #expect(c.status == .warn)
    #expect(c.evidence["latest"] == "99.0.0") // leading v stripped
    #expect(c.evidence["installed"] == ServerConfig.serverVersion)
    #expect(c.remediation.value == "brew upgrade logic-pro-mcp")
}

@Test func test_t4_update_skipped_outcomes() throws {
    let cases: [(SetupDoctor.UpdateOutcome, String)] = [
        (.offline, "offline"),
        (.sourceUnavailable, "source_unavailable"),
        (.parseError, "parse_error"),
        (.httpError, "http_error"),
        (.timeout, "timeout"),
    ]
    for (outcome, expectedReason) in cases {
        let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { outcome }))
        let c = try #require(check(report, "updates.latest_release"))
        #expect(c.status == .skipped)
        #expect(c.evidence["reason"] == expectedReason)
    }
}

@Test func test_t4_update_evidence_redaction_keyset() throws {
    // AC-6.4: failure evidence carries ONLY an enumerated reason — no stderr/env/URL/headers.
    for outcome in [SetupDoctor.UpdateOutcome.offline, .sourceUnavailable, .parseError, .httpError, .timeout] {
        let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { outcome }))
        let c = try #require(check(report, "updates.latest_release"))
        #expect(Set(c.evidence.keys) == ["reason"]) // key-set assertion, not substring scan
        let reason = try #require(c.evidence["reason"])
        #expect(["offline", "source_unavailable", "parse_error", "http_error", "timeout"].contains(reason))
    }
}

@Test func test_t4_update_skipped_degrades_aggregate() {
    // Otherwise-healthy report + a skipped update check → degraded (consistent v1 skipped semantics).
    let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { .offline }))
    #expect(report.status == .degraded)
}

@Test func test_t4_compare_versions_numeric_not_lexicographic() {
    #expect(SetupDoctor.compareVersions("3.7.4", "3.7.4") == 0)
    #expect(SetupDoctor.compareVersions("3.9.0", "3.10.0") < 0) // numeric: 9 < 10 (lexicographic would be wrong)
    #expect(SetupDoctor.compareVersions("3.7.10", "3.7.4") > 0)
    #expect(SetupDoctor.compareVersions("4.0.0", "3.99.99") > 0)
}

@Test func test_t4_normalize_version_strips_v() {
    #expect(SetupDoctor.normalizeVersion("v3.7.4") == "3.7.4")
    #expect(SetupDoctor.normalizeVersion("3.7.4") == "3.7.4")
}

// MARK: - Phase-6 final-review hardening

@Test func test_t4_normalize_version_strips_prerelease_suffix() {
    // boomer-1: a pre-release tag must not be ranked newer than its GA release.
    #expect(SetupDoctor.normalizeVersion("v4.0.0-beta.1") == "4.0.0")
    #expect(SetupDoctor.normalizeVersion("4.0.0-rc.2") == "4.0.0")
    #expect(SetupDoctor.compareVersions(SetupDoctor.normalizeVersion("4.0.0"), SetupDoctor.normalizeVersion("4.0.0-beta.1")) == 0)
}

@Test func test_t4_parse_latest_tag() {
    // guardian-P2-2: lock the pure JSON-parse boundary of the network lookup.
    #expect(SetupDoctor.parseLatestTag(from: #"{"tag_name":"v3.7.4","name":"x"}"#) == "v3.7.4")
    #expect(SetupDoctor.parseLatestTag(from: #"{"tag_name":""}"#) == nil)
    #expect(SetupDoctor.parseLatestTag(from: #"{"no_tag":"x"}"#) == nil)
    #expect(SetupDoctor.parseLatestTag(from: "not json") == nil)
}

@Test func test_t4_update_warn_strips_prerelease_and_compares_numeric() throws {
    // A pre-release "latest" equal to installed must NOT warn (normalize + numeric compare).
    let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { .found(version: "v\(ServerConfig.serverVersion)-beta.1") }))
    let c = try #require(check(report, "updates.latest_release"))
    #expect(c.status == .pass)
}

@Test func test_t1_clamp_status_for_permissions_owns_invariant() {
    // guardian-P1: the chokepoint is unit-tested directly (not emergent). An all-pass
    // aggregate with allGranted == false must be clamped to degraded.
    #expect(SetupDoctor.clampStatusForPermissions(.ok, allGranted: false) == .degraded)
    #expect(SetupDoctor.clampStatusForPermissions(.ok, allGranted: true) == .ok)
    // Already-non-ok statuses are passed through unchanged.
    #expect(SetupDoctor.clampStatusForPermissions(.failed, allGranted: false) == .failed)
    #expect(SetupDoctor.clampStatusForPermissions(.manualActionRequired, allGranted: false) == .manualActionRequired)
    #expect(SetupDoctor.clampStatusForPermissions(.degraded, allGranted: false) == .degraded)
}

@Test func test_t3_headline_not_healthy_when_degraded_skipped_only() {
    // boomer-E2 / guardian-P2-1: a skipped-only degraded report must not claim "healthy".
    // macOS unreadable → skipped (info severity, no actionable check) but aggregate degraded.
    let report = makeReport(runtime: enterpriseRuntime(macOSVersion: nil))
    #expect(report.status == .degraded)
    #expect(report.headline == "Logic Pro MCP install is usable; some checks could not be verified.")
}

// MARK: - Final merge-gate hardening (zero-edge-case pass)

@Test func test_t4_update_unparseable_tag_is_skipped_not_false_pass() throws {
    // boomer-B1/B5: a tag with no numeric major (bare "v", pure pre-release, "latest")
    // must NOT be reported "up to date" — it normalizes to no version and is unparseable.
    for raw in ["v", "-beta.1", "latest", ""] {
        let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { .found(version: raw) }))
        let c = try #require(check(report, "updates.latest_release"))
        #expect(c.status == .skipped, "tag '\(raw)' should be skipped, got \(c.status)")
        #expect(c.evidence["reason"] == "parse_error")
    }
}

@Test func test_t1_summary_counts_invariant_with_update_check_14() {
    // boomer-B2-3: invariant must hold with the opt-in update check present (14 checks).
    let report = makeReport(runtime: enterpriseRuntime(latestReleaseLookup: { .found(version: ServerConfig.serverVersion) }))
    #expect(report.checks.count == 14)
    let s = report.summary
    #expect(s.total == 14)
    #expect(s.passed + s.failed + s.warnings + s.manual + s.skipped == s.total)
}

@Test func test_t4_entrypoint_check_updates_flag_surfaces_update_check() async {
    // boomer-B2-2: the --check-updates flag path is wired through MainEntrypoint end-to-end.
    // (Inject a fake lookup so the test is hermetic — no network.)
    let (_, out) = await runEntrypoint(
        ["LogicProMCP", "doctor", "--check-updates", "--json"],
        runtime: enterpriseRuntime(latestReleaseLookup: { .found(version: ServerConfig.serverVersion) })
    )
    #expect(out.contains("updates.latest_release"))
}

@Test func test_t1_duration_ms_is_whole_milliseconds() {
    // debugger-P2: duration_ms is rounded to whole ms so the --json contract matches the
    // human renderer and sub-ms jitter doesn't churn the bytes. With the default {0} clock,
    // every duration collapses to exactly 0.0.
    let report = makeReport()
    for c in report.checks {
        #expect(c.durationMs == c.durationMs.rounded())
    }
    #expect(report.summary.durationMs == report.summary.durationMs.rounded())
}
