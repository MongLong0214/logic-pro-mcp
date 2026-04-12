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
        description: "Project lifecycle in Logic Pro. Commands: new, open, save, save_as, close, bounce, launch, quit. Params: open -> { path: String }; save_as -> { path: String }; bounce -> {}; launch/quit -> {}; others -> {}.",
        commandDescription: "Project command to execute"
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        isLogicProRunning: () -> Bool = {
            ProcessUtils.isLogicProRunning || PermissionChecker.checkAutomationState() == .granted
        },
        executeLifecycleScript: (String) async -> LifecycleExecution = { script in
            await executeAppleScript(script)
        },
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async -> CallTool.Result {
        let confirmed = params["confirmed"]?.boolValue ?? false

        // Audit log for L1+ commands
        if DestructivePolicy.needsAuditLog(for: command) {
            Log.info("[AUDIT] project.\(command) executed", subsystem: "project")
        }

        switch command {
        case "new":
            let result = await router.route(operation: "project.new")
            return toolTextResult(result)

        case "open":
            let path = params["path"]?.stringValue ?? ""
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
            let path = params["path"]?.stringValue ?? ""
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
            if !confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                return toolTextResult(response)
            }
            let result = await router.route(operation: "project.close")
            return toolTextResult(result)

        case "bounce":
            if !confirmed, let response = DestructivePolicy.confirmationResponse(command: command) {
                return toolTextResult(response)
            }
            let result = await router.route(operation: "project.bounce")
            return toolTextResult(result)

        case "is_running":
            return toolTextResult(isLogicProRunning() ? "true" : "false")

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
                "Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, is_running, launch, quit",
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
            return LifecycleExecution(
                executionError: nil,
                timedOut: true,
                terminationStatus: process.terminationStatus,
                stderrOutput: ""
            )
        }

        let stderrOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LifecycleExecution(
            executionError: nil,
            timedOut: false,
            terminationStatus: process.terminationStatus,
            stderrOutput: stderrOutput
        )
    }
}
