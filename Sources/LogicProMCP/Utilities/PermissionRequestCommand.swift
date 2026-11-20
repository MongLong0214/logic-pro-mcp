import Foundation
import ApplicationServices
import Darwin

/// `LogicProMCP --request-permissions`: an explicit, person-run request for the Accessibility
/// and PostEvent grants **for this binary itself** (#1596).
///
/// The check paths (`--check-permissions`, `doctor`, `logic_system permissions`) never prompt.
/// This command does, and only when a person runs it. It makes the request from a copy of this
/// binary spawned with TCC responsibility disclaimed, the arrangement a disclaiming MCP client
/// uses for servers, so macOS records the request for the LogicProMCP binary rather than for
/// Terminal. A request made in-process from Terminal would register Terminal instead, so when
/// the disclaimed copy cannot be started the command refuses rather than fall back.
enum PermissionRequestCommand {
    static let flag = "--request-permissions"
    /// Internal: the disclaimed copy. Not documented as a user command.
    static let disclaimedChildFlag = "--request-permissions-disclaimed"

    struct Runtime {
        var principal: () -> TCCResponsibility.Principal?
        var ownExecutablePath: () -> String?
        var runDisclaimed: (String, [String]) -> TCCResponsibility.SpawnOutcome
        /// `AXIsProcessTrustedWithOptions` with the prompt option set.
        var requestAccessibility: () -> Bool
        /// `CGRequestPostEventAccess`.
        var requestPostEvent: () -> Bool

        static var production: Runtime { Runtime(
            principal: { TCCResponsibility.currentPrincipal() },
            ownExecutablePath: { TCCResponsibility.executablePath(of: getpid()) },
            runDisclaimed: { TCCResponsibility.runDisclaimed(executable: $0, arguments: $1) },
            requestAccessibility: {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            requestPostEvent: { CGRequestPostEventAccess() }
        ) }
    }

    static func run(arguments: [String], runtime: Runtime = .production, writeStderr: (String) -> Void) -> Int32 {
        if arguments.contains(disclaimedChildFlag) {
            return requestAsOwnPrincipal(runtime: runtime, writeStderr: writeStderr)
        }
        if let principal = runtime.principal(), principal.isSelf {
            return requestAsOwnPrincipal(runtime: runtime, writeStderr: writeStderr)
        }
        guard let executable = runtime.ownExecutablePath() else {
            writeStderr("Could not resolve this binary's path; no permission was requested.\n")
            return 1
        }
        switch runtime.runDisclaimed(executable, [disclaimedChildFlag]) {
        case let .exited(code):
            return code
        case .disclaimUnavailable:
            writeStderr(
                "This macOS does not expose the responsibility-disclaim spawn attribute; no permission was requested, "
                    + "because a request from this process would be recorded for the app that launched it.\n"
            )
            return 1
        case let .spawnFailed(code):
            writeStderr("Could not start the request process (\(String(cString: strerror(code)))); no permission was requested.\n")
            return 1
        }
    }

    private static func requestAsOwnPrincipal(runtime: Runtime, writeStderr: (String) -> Void) -> Int32 {
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
            Requested for: \(principal.displayPath)
            Accessibility: \(accessibility ? "granted" : "NOT GRANTED")
            PostEvent (CGEvent): \(postEvent ? "granted" : "NOT GRANTED")

            """
        )
        if accessibility && postEvent { return 0 }
        writeStderr(
            """
            macOS shows a prompt for this binary when it has no recorded decision. Turn on LogicProMCP in
            System Settings > Privacy & Security > Accessibility (it is listed under this exact path), then
            quit and reopen the MCP client. This grant applies when the client launches this binary as its
            own principal; check the "TCC principal" line of --check-permissions.

            """
        )
        return 1
    }
}
