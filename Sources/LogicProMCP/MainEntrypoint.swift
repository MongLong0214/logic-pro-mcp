import Darwin
import Dispatch
import Foundation

protocol ServerStarting: Sendable {
    func start() async throws
    func stop() async
}

extension ServerStarting {
    /// Default no-op so existing test mocks that only implement `start()` keep
    /// working. Production `LogicProServer` overrides with the real teardown.
    func stop() async {}
}

extension LogicProServer: ServerStarting {}

enum MainEntrypoint {
    static func run(
        arguments: [String],
        permissionCheck: () -> PermissionChecker.PermissionStatus = PermissionChecker.check,
        serverFactory: () -> any ServerStarting = { LogicProServer() },
        approvalStoreFactory: () -> any ManualValidationStoring = { ManualValidationStore() },
        doctorRuntime: SetupDoctor.Runtime = .production,
        lifecycleRuntime: SetupLifecycle.Runtime = .production,
        // Injected so doctor's color/TTY gating is pinnable in tests (AC-5.4).
        isStdoutTTY: () -> Bool = { isatty(STDOUT_FILENO) != 0 },
        doctorEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        writeStdout: (String) -> Void = { message in
            FileHandle.standardOutput.write(Data(message.utf8))
        },
        writeStderr: (String) -> Void = { message in
            FileHandle.standardError.write(Data(message.utf8))
        }
    ) async -> Int {
        // `--version` and `--help` are terminal global flags: print and exit
        // WITHOUT creating the approval store, checking permissions, or —
        // critically — starting the long-lived MCP server channels (#212/#213).
        // Placed before every other branch so no side effect runs first.
        //
        // `--version` emits the bare version string only: SetupLifecycle
        // .productionInstalledBinaryVersion() runs the installed binary with
        // `--version`, requires exit 0, and compares the trimmed stdout for
        // EQUALITY against ServerConfig.serverVersion to detect install drift.
        // Any prefix (e.g. "logic-pro-mcp 3.7.4") would break that equality.
        if hasFlag("--version", or: "-V", in: arguments) {
            writeStdout(ServerConfig.serverVersion + "\n")
            return 0
        }
        if hasFlag("--help", or: "-h", in: arguments) {
            writeStdout(usageText + "\n")
            return 0
        }

        let approvalStore = approvalStoreFactory()

        if isDoctorCommand(arguments) {
            // Arm the opt-in update lookup ONLY when --check-updates is present, so
            // the default run never touches the network (G7/NG4). A test-injected
            // lookup (already non-nil) is left untouched.
            var runtime = doctorRuntime
            if arguments.contains("--check-updates"), runtime.latestReleaseLookup == nil {
                runtime.latestReleaseLookup = { SetupDoctor.productionLatestReleaseLookup() }
            }
            let report = SetupDoctor.generate(
                arguments: arguments,
                permissionStatus: permissionCheck(),
                approvals: await approvalStore.list(),
                runtime: runtime
            )
            if arguments.contains("--json") {
                // --json is the machine contract: identical bytes regardless of
                // verbosity/color flags (AC-5.5).
                writeStdout(encodeJSON(report) + "\n")
            } else {
                let mode: SetupDoctor.OutputMode = arguments.contains("--verbose")
                    ? .verbose
                    : (arguments.contains("--quiet") ? .quiet : .default)
                let useColor = isStdoutTTY() && doctorEnvironment["NO_COLOR"] == nil
                writeStdout(SetupDoctor.renderHuman(report, mode: mode, useColor: useColor) + "\n")
            }
            return SetupDoctor.shouldExitWithFailure(report) ? 1 : 0
        }

        if isLifecycleSubcommand(arguments) {
            // #214: `LogicProMCP lifecycle <install|update|uninstall> [--json]`
            // is the documented read-only planning surface. Pre-fix the
            // `lifecycle` verb was unparsed and fell through to server startup
            // (the audit saw a hang/timeout). It prints the SAME plan the bare
            // `<action> --dry-run` form produces — no `--dry-run` needed because
            // the `lifecycle` namespace never executes anything; live execution
            // stays delegated to Scripts/install.sh / uninstall.sh.
            guard let command = lifecycleSubcommandAction(arguments) else {
                let valid = SetupLifecycle.Command.allCases.map(\.rawValue).joined(separator: "|")
                writeStderr(
                    "Usage: LogicProMCP lifecycle <\(valid)> [--json]\n"
                        + "Prints a read-only lifecycle plan (see docs/SETUP.md).\n"
                )
                return 1
            }
            let plan = SetupLifecycle.plan(command: command, runtime: lifecycleRuntime)
            let output = arguments.contains("--json")
                ? encodeJSON(plan)
                : SetupLifecycle.renderHuman(plan)
            writeStdout(output + "\n")
            return 0
        }

        if let command = lifecycleCommand(arguments) {
            // Live execution is intentionally NOT performed here — it is delegated
            // to Scripts/install.sh / uninstall.sh. Without --dry-run we refuse
            // honestly and exit non-zero rather than faking execution.
            guard arguments.contains("--dry-run") else {
                let script = command == .uninstall
                    ? "Scripts/uninstall.sh"
                    : "Scripts/install.sh"
                writeStderr(
                    "Live \(command.rawValue) is not performed by this binary. "
                        + "Re-run with --dry-run to preview the plan, or run \(script) "
                        + "to execute (see docs/SETUP.md).\n"
                )
                return 1
            }
            let plan = SetupLifecycle.plan(command: command, runtime: lifecycleRuntime)
            let output = arguments.contains("--json")
                ? encodeJSON(plan)
                : SetupLifecycle.renderHuman(plan)
            writeStdout(output + "\n")
            return 0
        }

        if arguments.contains("--list-approvals") {
            let approvals = await approvalStore.list()
            writeStderr(ManualValidationStore.summary(for: approvals) + "\n")
            return 0
        }

        if let rawChannel = optionValue("--approve-channel", in: arguments) {
            guard let channel = ManualValidationChannel.parse(rawChannel) else {
                writeStderr("Unknown approval channel: \(rawChannel)\n")
                return 1
            }
            do {
                try await approvalStore.approve(channel, note: optionValue("--approval-note", in: arguments))
                writeStderr("Approved \(channel.rawValue) for runtime use.\n")
                return 0
            } catch {
                writeStderr("Failed to persist approval for \(channel.rawValue): \(error)\n")
                return 1
            }
        }

        if let rawChannel = optionValue("--revoke-channel", in: arguments) {
            guard let channel = ManualValidationChannel.parse(rawChannel) else {
                writeStderr("Unknown approval channel: \(rawChannel)\n")
                return 1
            }
            do {
                try await approvalStore.revoke(channel)
                writeStderr("Revoked approval for \(channel.rawValue).\n")
                return 0
            } catch {
                writeStderr("Failed to revoke approval for \(channel.rawValue): \(error)\n")
                return 1
            }
        }

        if arguments.contains("--check-permissions") {
            let status = permissionCheck()
            writeStderr(status.summary + "\n")
            return status.allGranted ? 0 : 1
        }

        let server = serverFactory()

        // SIGTERM / SIGINT → coordinated shutdown, then exit. Pre-fix the
        // handlers called `exit(0)` directly which skipped the AX poller,
        // channel transports, and virtual MIDI port teardown — leaking
        // resources every time a supervisor restarted the process.
        //
        // The handler runs on a dedicated background queue (not `.main`) so
        // `group.wait` cannot deadlock against an actor that needs the main
        // runloop. Hard timeout caps cleanup at 3s; on overrun we still exit
        // with a non-zero code so a supervisor can notice.
        let signalQueue = DispatchQueue(label: "logic-pro-mcp.signal")
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let shutdownTimeout = DispatchTimeInterval.seconds(3)
        let shutdown: @Sendable () -> Void = { [server] in
            let group = DispatchGroup()
            group.enter()
            Task {
                await server.stop()
                group.leave()
            }
            if group.wait(timeout: .now() + shutdownTimeout) == .timedOut {
                Log.error(
                    "Shutdown timeout exceeded — exiting without confirmed cleanup",
                    subsystem: "main"
                )
                exit(1)
            }
            Log.info("Server stopped — graceful shutdown complete", subsystem: "main")
            exit(0)
        }
        signalSource.setEventHandler(handler: shutdown)
        intSource.setEventHandler(handler: shutdown)
        signalSource.resume()
        intSource.resume()

        do {
            try await server.start()
            return 0
        } catch {
            Log.error("Server failed: \(error)", subsystem: "main")
            return 1
        }
    }

    /// CLI usage printed by `--help`. Kept in sync with the command branches
    /// below and the CLI surface documented in docs/SETUP.md.
    static let usageText = """
        \(ServerConfig.serverName) \(ServerConfig.serverVersion) — Logic Pro MCP server

        USAGE:
          LogicProMCP                          Start the MCP server over stdio (default; used by an MCP client)
          LogicProMCP --help, -h               Print this help and exit
          LogicProMCP --version, -V            Print the version and exit
          LogicProMCP doctor [--json] [--verbose|--quiet] [--check-updates]
                                               Print a diagnostic report and exit
          LogicProMCP <install|update|uninstall> --dry-run [--json]
                                               Print a read-only lifecycle plan and exit
          LogicProMCP --check-permissions      Print macOS permission status and exit (non-zero if not ready)
          LogicProMCP --list-approvals         List manual channel approvals and exit
          LogicProMCP --approve-channel <MIDIKeyCommands|Scripter> [--approval-note <note>]
                                               Record a manual channel approval and exit
          LogicProMCP --revoke-channel <MIDIKeyCommands|Scripter>
                                               Revoke a manual channel approval and exit

        With no arguments the binary runs as an MCP stdio server. See docs/SETUP.md for setup.
        """

    /// True when a terminal global flag (`--version`, `--help`, …) appears
    /// anywhere in the user-supplied arguments (the program path at index 0 is
    /// ignored). These flags print-and-exit, so they are checked before any
    /// subcommand parsing or server startup.
    private static func hasFlag(_ flag: String, or alias: String? = nil, in arguments: [String]) -> Bool {
        let userArgs = arguments.dropFirst()
        return userArgs.contains(flag) || (alias.map { userArgs.contains($0) } ?? false)
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func isDoctorCommand(_ arguments: [String]) -> Bool {
        Array(arguments.dropFirst()).first == "doctor"
    }

    private static func lifecycleCommand(_ arguments: [String]) -> SetupLifecycle.Command? {
        guard let first = Array(arguments.dropFirst()).first else { return nil }
        return SetupLifecycle.Command(rawValue: first)
    }

    private static func isLifecycleSubcommand(_ arguments: [String]) -> Bool {
        Array(arguments.dropFirst()).first == "lifecycle"
    }

    /// The action following the `lifecycle` verb, e.g. `lifecycle install` →
    /// `.install`. The first non-flag token after `lifecycle` is the action, so
    /// `lifecycle install --json` and `lifecycle --json install` both resolve.
    /// Returns nil for a missing or unrecognized action (→ usage error).
    private static func lifecycleSubcommandAction(_ arguments: [String]) -> SetupLifecycle.Command? {
        guard let actionRaw = arguments.dropFirst(2).first(where: { !$0.hasPrefix("-") }) else {
            return nil
        }
        return SetupLifecycle.Command(rawValue: actionRaw)
    }
}
