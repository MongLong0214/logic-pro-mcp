import Foundation
import ApplicationServices
import Darwin

/// `LogicProMCP --request-permissions [<executable>]`: an explicit, person-run request for the
/// Accessibility and PostEvent grants **for one LogicProMCP binary itself** (#1596).
///
/// The check paths (`--check-permissions`, `doctor`, `logic_system permissions`) never prompt.
/// This command does, and only when a person runs it. It always makes the request from a copy of
/// the target binary spawned with TCC responsibility disclaimed, the arrangement a disclaiming MCP
/// client uses for servers, so macOS records the request for that binary rather than for
/// Terminal. If the disclaimed copy cannot be started the command refuses and calls neither
/// prompting API: a request from this process would be recorded for whatever app launched it.
///
/// The optional argument names the binary to request for (the one the MCP client is configured to
/// launch). Output names it by its public label only; the path is used to spawn and never printed.
enum PermissionRequestCommand {
    static let flag = "--request-permissions"
    /// Internal: the disclaimed copy. Refuses unless the parent's one-shot provenance is present.
    static let disclaimedChildFlag = "--request-permissions-disclaimed"
    /// Carries `<parent pid>:<one-shot token>` from the public command to its disclaimed child.
    /// A user-typed flag cannot supply it by accident.
    static let provenanceVariable = "LOGICPROMCP_REQUEST_PROVENANCE"

    struct Runtime {
        var principal: () -> TCCResponsibility.Principal?
        var ownExecutablePath: () -> String?
        /// executable, arguments, extra environment.
        var runDisclaimed: (String, [String], [String: String]) -> TCCResponsibility.SpawnOutcome
        /// `AXIsProcessTrustedWithOptions` with the prompt option set.
        var requestAccessibility: () -> Bool
        /// `CGRequestPostEventAccess`.
        var requestPostEvent: () -> Bool
        var environment: () -> [String: String]
        var ownPID: () -> pid_t
        var parentPID: () -> pid_t
        var makeToken: () -> String
        /// Validates an explicit executable argument; nil when it is not a runnable file.
        var resolveTarget: (String) -> String?
        /// Public-safe label for an executable path.
        var labelForPath: (String) -> String

        static var production: Runtime { Runtime(
            principal: { TCCResponsibility.currentPrincipal() },
            ownExecutablePath: { TCCResponsibility.executablePath(of: getpid()) },
            runDisclaimed: {
                TCCResponsibility.runDisclaimed(executable: $0, arguments: $1, extraEnvironment: $2)
            },
            requestAccessibility: {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            requestPostEvent: { CGRequestPostEventAccess() },
            environment: { ProcessInfo.processInfo.environment },
            ownPID: { getpid() },
            parentPID: { getppid() },
            makeToken: { UUID().uuidString },
            resolveTarget: { argument in
                let url = URL(fileURLWithPath: argument).resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
                return url.path
            },
            labelForPath: { TCCResponsibility.publicLabel(forExecutablePath: $0) }
        ) }
    }

    static func run(arguments: [String], runtime: Runtime = .production, writeStderr: (String) -> Void) -> Int32 {
        if arguments.dropFirst().first == disclaimedChildFlag {
            return requestAsDisclaimedChild(runtime: runtime, writeStderr: writeStderr)
        }
        return spawnDisclaimedRequest(arguments: arguments, runtime: runtime, writeStderr: writeStderr)
    }

    private static func spawnDisclaimedRequest(
        arguments: [String],
        runtime: Runtime,
        writeStderr: (String) -> Void
    ) -> Int32 {
        let extra = Array(arguments.dropFirst(2))
        let target: String
        switch extra.count {
        case 0:
            guard let own = runtime.ownExecutablePath() else {
                writeStderr("Could not resolve this binary; no permission was requested.\n")
                return 1
            }
            target = own
        case 1 where !extra[0].hasPrefix("-"):
            guard let resolved = runtime.resolveTarget(extra[0]) else {
                writeStderr("The given path is not a runnable executable file; no permission was requested.\n")
                return 1
            }
            target = resolved
        default:
            writeStderr("Usage: LogicProMCP --request-permissions [<path to the LogicProMCP executable>]\n")
            return 1
        }
        writeStderr("Requesting for: \(runtime.labelForPath(target))\n")
        let provenance = "\(runtime.ownPID()):\(runtime.makeToken())"
        switch runtime.runDisclaimed(target, [disclaimedChildFlag], [provenanceVariable: provenance]) {
        case let .exited(code):
            return code
        case .disclaimUnavailable:
            writeStderr(
                "This macOS does not expose the responsibility-disclaim spawn attribute; no permission was requested, "
                    + "because a request from this process would be recorded for the app that launched it.\n"
            )
            return 1
        case .spawnFailed:
            // Fixed text: the system's error string can carry the path.
            writeStderr("Could not start the disclaimed request process; no permission was requested.\n")
            return 1
        }
    }

    /// The child proves it was started by `--request-permissions` (the parent's pid and a token it
    /// minted) and that it is its own TCC principal, before either prompting API can run.
    private static func provenanceIsValid(runtime: Runtime) -> Bool {
        guard let value = runtime.environment()[provenanceVariable] else { return false }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let parent = pid_t(parts[0]), !parts[1].isEmpty else { return false }
        return parent == runtime.parentPID()
    }

    private static func requestAsDisclaimedChild(runtime: Runtime, writeStderr: (String) -> Void) -> Int32 {
        guard provenanceIsValid(runtime: runtime) else {
            writeStderr(
                "\(disclaimedChildFlag) is internal and is started only by \(flag); "
                    + "no permission was requested. Run \(flag) instead.\n"
            )
            return 1
        }
        guard let principal = runtime.principal(), principal.isSelf else {
            // Requesting now would record the grant for whichever app is responsible for us.
            writeStderr(
                "This process is not its own TCC principal; no permission was requested, "
                    + "because the request would be recorded for the app that launched it.\n"
            )
            return 1
        }
        let accessibility = runtime.requestAccessibility()
        let postEvent = runtime.requestPostEvent()
        writeStderr(
            """
            Requested for: \(principal.displayName)
            Accessibility: \(accessibility ? "granted" : "NOT GRANTED")
            PostEvent (CGEvent): \(postEvent ? "granted" : "NOT GRANTED")

            """
        )
        if accessibility && postEvent { return 0 }
        writeStderr(
            """
            macOS shows a prompt for this binary when it has no recorded decision. Turn on this LogicProMCP
            entry in System Settings > Privacy & Security > Accessibility, then quit and reopen the MCP
            client. This grant applies when the client launches this binary as its own principal; check the
            "TCC principal" line of --check-permissions run from that client.

            """
        )
        return 1
    }
}
