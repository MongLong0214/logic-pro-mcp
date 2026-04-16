import Foundation
import MCP

struct ProjectDispatcher {
    struct LifecycleExecution: Sendable {
        let executionError: String?
        let timedOut: Bool
        let terminationStatus: Int32
        let stderrOutput: String
    }

    static let tool = commandTool(
        name: "logic_project",
        description: "Project lifecycle + read-only project state in Logic Pro. Commands: new, open, save, save_as, close, bounce, launch, quit, get_regions. Params: open -> { path: String }; save_as -> { path: String }; close -> { saving?: \"yes\"|\"no\"|\"ask\" }; bounce/launch/quit -> {}; get_regions -> {} (returns JSON array of { name, trackIndex, startBar, endBar, kind, rawHelp } parsed from Logic's arrange area via AX); others -> {}.",
        commandDescription: "Project command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        // Single source of truth — use ProcessUtils.isLogicProRunning everywhere
        // (NSRunningApplication-based with multi-fallback). Removed prior OR with
        // PermissionChecker.checkAutomationState() == .granted because permission
        // grant ≠ Logic actually running, and the OR caused state inconsistency
        // vs `system.health` and `transport.toggle_cycle` which use ProcessUtils only.
        isLogicProRunning: () -> Bool = { ProcessUtils.isLogicProRunning },
        executeLifecycleScript: (String) async -> LifecycleExecution = { script in
            await executeAppleScript(script)
        },
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async -> CallTool.Result {
        let confirmed = boolParam(params, "confirmed", default: false)

        // Audit log for L1+ commands
        if DestructivePolicy.needsAuditLog(for: command) {
            Log.info("[AUDIT] project.\(command) executed", subsystem: "project")
        }

        switch command {
        case "new":
            let result = await router.route(operation: "project.new")
            return toolTextResult(result)

        case "open":
            let path = stringParam(params, "path")
            guard !path.isEmpty else {
                return toolTextResult("open requires 'path' param", isError: true)
            }
            guard AppleScriptSafety.isValidProjectPath(path, requireExisting: true) else {
                return toolTextResult("open requires an existing absolute .logicx project path", isError: true)
            }
            if !confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                return toolTextResult(response)
            }
            let result = await router.route(
                operation: "project.open",
                params: ["path": path]
            )
            return toolTextResult(result)

        case "save":
            let result = await router.route(operation: "project.save")
            return toolTextResult(result)

        case "save_as":
            let path = stringParam(params, "path")
            guard !path.isEmpty else {
                return toolTextResult("save_as requires 'path' param", isError: true)
            }
            guard AppleScriptSafety.isValidProjectPath(path, requireExisting: false) else {
                return toolTextResult("save_as requires an absolute .logicx project path", isError: true)
            }
            if !confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                return toolTextResult(response)
            }
            let result = await router.route(
                operation: "project.save_as",
                params: ["path": path]
            )
            return toolTextResult(result)

        case "close":
            let savingRaw = stringParam(params, "saving", default: "yes")
            let saving = ["yes", "no", "ask"].contains(savingRaw) ? savingRaw : "yes"
            if savingRaw != saving {
                return toolTextResult(
                    "close 'saving' must be one of: yes, no, ask (got: \(savingRaw))",
                    isError: true
                )
            }
            if !confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                return toolTextResult(response)
            }
            let result = await router.route(
                operation: "project.close",
                params: ["saving": saving]
            )
            return toolTextResult(result)

        case "bounce":
            if !confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                return toolTextResult(response)
            }
            let result = await router.route(operation: "project.bounce")
            return toolTextResult(result)

        case "is_running":
            return toolTextResult(isLogicProRunning() ? "true" : "false")

        case "get_regions":
            // Read-only arrange-area inspection. Necessary for programmatic
            // verification of record_sequence region placement — without this
            // the only feedback loop was visual screenshots.
            let result = await router.route(operation: "region.get_regions")
            return toolTextResult(result)

        case "launch":
            if isLogicProRunning() {
                return toolTextResult("Logic Pro is already running")
            }
            return await runLifecycleScript(
                script: "tell application \"Logic Pro\" to activate",
                successMessage: "Logic Pro launched",
                expectedRunning: true,
                actionLabel: "launch",
                execute: executeLifecycleScript,
                isLogicProRunning: isLogicProRunning,
                sleep: sleep
            )

        case "quit":
            if !confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                return toolTextResult(response)
            }
            if !isLogicProRunning() {
                return toolTextResult("Logic Pro is not running")
            }
            return await runLifecycleScript(
                script: "tell application \"Logic Pro\" to quit",
                successMessage: "Logic Pro quit",
                expectedRunning: false,
                actionLabel: "quit",
                execute: executeLifecycleScript,
                isLogicProRunning: isLogicProRunning,
                sleep: sleep
            )

        default:
            return toolTextResult(
                "Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, is_running, launch, quit, get_regions",
                isError: true
            )
        }
    }

    private static func runLifecycleScript(
        script: String,
        successMessage: String,
        expectedRunning: Bool,
        actionLabel: String,
        execute: (String) async -> LifecycleExecution,
        isLogicProRunning: () -> Bool,
        sleep: (UInt64) async -> Void
    ) async -> CallTool.Result {
        let execution = await execute(script)
        if let executionError = execution.executionError {
            return toolTextResult("Failed to \(actionLabel) Logic Pro: \(executionError)", isError: true)
        }
        if execution.timedOut {
            return toolTextResult(
                "Failed to \(actionLabel) Logic Pro: timed out after \(Int(ServerConfig.appleScriptTimeout))s",
                isError: true
            )
        }
        if execution.terminationStatus != 0 {
            let message = execution.stderrOutput.isEmpty
                ? "osascript exited with status \(execution.terminationStatus)"
                : execution.stderrOutput
            return toolTextResult("Failed to \(actionLabel) Logic Pro: \(message)", isError: true)
        }

        let statePolls = Int(max(1, ServerConfig.appleScriptTimeout * 10))
        for _ in 0..<statePolls {
            if isLogicProRunning() == expectedRunning {
                return toolTextResult(successMessage)
            }
            await sleep(100_000_000)
        }

        return toolTextResult(
            "Lifecycle command completed but Logic Pro did not reach expected running state",
            isError: true
        )
    }

    static func executeAppleScript(
        _ script: String,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript")
    ) async -> LifecycleExecution {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = ["-e", script]
        process.standardError = stderr
        // Don't hold a second Pipe for stdout — osascript output isn't read here.
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return LifecycleExecution(
                executionError: String(describing: error),
                timedOut: false,
                terminationStatus: -1,
                stderrOutput: ""
            )
        }

        let timeoutNs = UInt64(ServerConfig.appleScriptTimeout * 1_000_000_000)
        let pollIntervalNs: UInt64 = 50_000_000
        var waitedNs: UInt64 = 0

        while process.isRunning && waitedNs < timeoutNs {
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            waitedNs += pollIntervalNs
        }

        if process.isRunning {
            process.terminate()
            // Reap zombie so the stderr Pipe's file descriptors are released
            // promptly — same class of FD leak that killed the server under
            // sustained set_tempo stress (diagnosed via BrokenPipeError).
            process.waitUntilExit()
            return LifecycleExecution(
                executionError: nil,
                timedOut: true,
                terminationStatus: process.terminationStatus,
                stderrOutput: ""
            )
        }

        let stderrOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Release Pipe FDs explicitly — delayed deinit was a leak vector under
        // sustained stress (same root cause as sprint 51 MCP server crash).
        try? stderr.fileHandleForReading.close()
        try? stderr.fileHandleForWriting.close()
        return LifecycleExecution(
            executionError: nil,
            timedOut: false,
            terminationStatus: process.terminationStatus,
            stderrOutput: stderrOutput
        )
    }
}
