import Foundation
import MCP
import Testing
@testable import LogicProMCP

// H-1 (2026-05-08 enterprise review): pre-fix `ProjectDispatcher.handle`
// emitted `[AUDIT] project.<command> executed` before parameter
// validation, before the destructive-confirmation gate, and before any
// route was attempted. Enterprise audit pipelines treated rejected calls
// the same as successful executions.
//
// The fix splits the audit signal into three machine-filterable phases:
//   - `rejected` — validation refused the call (no side effect)
//   - `confirmation_required` — destructive policy gated, awaiting confirm
//   - `executed` — route was actually invoked
//
// These tests pin each phase by injecting `Log.output` and grepping the
// captured stderr stream for the exact `[AUDIT]` substring. Helper
// `captureAuditLines` filters down to the `project` subsystem so other
// log noise (e.g. cache invalidation `INFO`) doesn't leak into the
// assertion.
//
private func captureAuditLines(during body: () async -> Void) async -> [String] {
    await LogTestConfiguration.capture(level: .info) {
        // We only care about [AUDIT] lines on the project subsystem.
        // Synchronous capture — no Task hop — so the line is recorded
        // before `Log.info(...)` returns. This eliminates the race where
        // a fire-and-forget Task could land after the test's snapshot.
        await body()
    }.filter { $0.contains("[AUDIT]") }
}

private func projectAudits(_ lines: [String]) -> [String] {
    lines.filter { $0.contains("[project]") || $0.contains("\"subsystem\":\"project\"") }
}

@Suite(.serialized)
struct ProjectAuditPhaseTests {

@Test func testProjectOpenWithMissingPathLogsRejected() async {
    let captured = await captureAuditLines {
        let result = await ProjectDispatcher.handle(
            command: "open",
            params: [:],
            router: ChannelRouter(),
            cache: StateCache()
        )
        #expect(result.isError!)
    }
    let audits = projectAudits(captured)
    #expect(audits.contains { $0.contains("project.open rejected") })
    #expect(!audits.contains { $0.contains("project.open executed") })
}

@Test func testProjectOpenWithInvalidPathLogsRejected() async {
    let captured = await captureAuditLines {
        let result = await ProjectDispatcher.handle(
            command: "open",
            params: ["path": .string("/tmp/nonexistent.logicx")],
            router: ChannelRouter(),
            cache: StateCache()
        )
        #expect(result.isError!)
    }
    let audits = projectAudits(captured)
    #expect(audits.contains { $0.contains("project.open rejected") })
    #expect(!audits.contains { $0.contains("project.open executed") })
}

@Test func testProjectOpenWithoutConfirmLogsConfirmationRequired() async throws {
    // Use a path that passes the existing-package safety check. open
    // requires confirmation by destructive policy, so without `confirmed:true`
    // the dispatcher should emit `confirmation_required` and NOT `executed`.
    // `AppleScriptSafety.isValidExistingProjectPackage` requires a `.logicx`
    // directory containing `Resources/ProjectInformation.plist` and at
    // least one `Alternatives/*/ProjectData` file.
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory
        .appendingPathComponent("audit-confirm-\(UUID().uuidString).logicx")
    let resourcesDir = tmpDir.appendingPathComponent("Resources", isDirectory: true)
    let altDir = tmpDir.appendingPathComponent("Alternatives", isDirectory: true)
        .appendingPathComponent("000", isDirectory: true)
    try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: altDir, withIntermediateDirectories: true)
    try Data().write(to: resourcesDir.appendingPathComponent("ProjectInformation.plist"))
    try Data().write(to: altDir.appendingPathComponent("ProjectData"))
    defer { try? fm.removeItem(at: tmpDir) }

    let captured = await captureAuditLines {
        _ = await ProjectDispatcher.handle(
            command: "open",
            params: ["path": .string(tmpDir.path)],
            router: ChannelRouter(),
            cache: StateCache()
        )
    }
    let audits = projectAudits(captured)
    #expect(audits.contains { $0.contains("project.open confirmation_required") })
    #expect(!audits.contains { $0.contains("project.open executed") })
    #expect(!audits.contains { $0.contains("project.open rejected") })
}

@Test func testProjectSaveAlwaysLogsExecuted() async {
    // `save` has no validation gate, no confirmation requirement → goes
    // straight to executed.
    let captured = await captureAuditLines {
        _ = await ProjectDispatcher.handle(
            command: "save",
            params: [:],
            router: ChannelRouter(),
            cache: StateCache()
        )
    }
    let audits = projectAudits(captured)
    #expect(audits.contains { $0.contains("project.save executed") })
    #expect(!audits.contains { $0.contains("project.save rejected") })
    #expect(!audits.contains { $0.contains("project.save confirmation_required") })
}

@Test func testProjectIsRunningEmitsNoAuditLine() async {
    // L0 read-only commands must NOT pollute the audit log.
    let captured = await captureAuditLines {
        _ = await ProjectDispatcher.handle(
            command: "is_running",
            params: [:],
            router: ChannelRouter(),
            cache: StateCache(),
            isLogicProRunning: { false }
        )
    }
    let audits = projectAudits(captured)
    #expect(audits.allSatisfy { !$0.contains("project.is_running") })
}

@Test func testProjectQuitWithoutConfirmLogsConfirmationRequired() async {
    let captured = await captureAuditLines {
        _ = await ProjectDispatcher.handle(
            command: "quit",
            params: [:],
            router: ChannelRouter(),
            cache: StateCache(),
            isLogicProRunning: { true }
        )
    }
    let audits = projectAudits(captured)
    #expect(audits.contains { $0.contains("project.quit confirmation_required") })
    #expect(!audits.contains { $0.contains("project.quit executed") })
}

@Test func testProjectExportRunWithoutConfirmLogsConfirmationRequired() async throws {
    let projDir = try makeExecTempDir()
    let outputRoot = try makeExecTempDir()
    let project = try makeLogicxProject(in: projDir, named: "Audit Export Song")

    let captured = await captureAuditLines {
        _ = await ProjectDispatcher.handle(
            command: "export_run",
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                "artifacts": .array([.string("bounce")]),
            ],
            router: ChannelRouter(),
            cache: StateCache()
        )
    }

    let audits = projectAudits(captured)
    #expect(audits.contains { $0.contains("project.export_run confirmation_required") })
    #expect(!audits.contains { $0.contains("project.export_run executed") })
    #expect(!audits.contains { $0.contains("project.export_run rejected") })
}

@Test func cleanupApplyTerminalAuthorizationRefusalsLogRejected() async throws {
    let cases: [[String: Value]] = [
        ["step_id": .string("rename_duplicate_kick_0_1")],
        ["step_id": .string("rename_duplicate_kick_0_1"), "confirmed": .bool(false)],
    ]

    for params in cases {
        let captured = await captureAuditLines {
            let result = await ProjectDispatcher.handle(
                command: "cleanup_apply",
                params: params,
                router: ChannelRouter(),
                cache: StateCache()
            )
            let body = sharedJSONObject(sharedToolText(result))
            #expect(body != nil)
            if let body {
                let terminal = body["terminal"] as? Bool
                #expect(terminal != nil)
                if let terminal { #expect(terminal) }
            }
        }
        let audits = projectAudits(captured)
        #expect(audits.contains { $0.contains("project.cleanup_apply rejected") })
        #expect(!audits.contains { $0.contains("project.cleanup_apply confirmation_required") })
        #expect(!audits.contains { $0.contains("project.cleanup_apply executed") })
    }
}

}  // end @Suite(.serialized) struct ProjectAuditPhaseTests
