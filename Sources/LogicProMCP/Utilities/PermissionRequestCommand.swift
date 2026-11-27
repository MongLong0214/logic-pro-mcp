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
/// Trust between the two processes is two inherited pipes, not the environment and not the exit
/// status. The parent writes a one-shot value to the child's `handoffDescriptor`; the child asks
/// only after reading it, and answers on `receiptDescriptor` with a receipt that echoes the value
/// and records what it measured. The parent reports success only from a well-formed receipt.
///
/// Bound of the contract: this stops an accidental or mistaken start (a typed internal flag, a
/// target that is not LogicProMCP, a program that merely exits 0). It does not defend against a
/// person who deliberately builds the pipes by hand on their own machine to see a permission
/// prompt; that is out of scope.
///
/// The optional argument names the binary to request for (the one the MCP client is configured to
/// launch). Output names it by its public label only; the path is used to spawn and never printed.
enum PermissionRequestCommand {
    static let flag = "--request-permissions"
    /// Internal: the disclaimed copy. Refuses unless the parent's handoff arrives on its pipe.
    static let disclaimedChildFlag = "--request-permissions-disclaimed"

    /// What the child reports back. The parent prints only values it derives from this, never text.
    struct Receipt: Codable, Equatable {
        struct Probe: Codable, Equatable {
            var accessibility: Bool
            var postEvent: Bool
        }
        var version: Int
        /// The one-shot value the parent handed over, echoed.
        var handoff: String
        /// The child ran the request path (both prompting calls were made).
        var requested: Bool
        /// The child measured itself as its own responsible process.
        var selfResponsible: Bool
        var before: Probe
        var after: Probe

        static let currentVersion = 1
    }

    struct Runtime {
        var principal: () -> TCCResponsibility.Principal?
        var ownExecutablePath: () -> String?
        /// executable, arguments, handoff value.
        var runDisclaimed: (String, [String], String) -> TCCResponsibility.DisclaimedRun
        /// `AXIsProcessTrustedWithOptions` with the prompt option set.
        var requestAccessibility: () -> Bool
        /// `CGRequestPostEventAccess`.
        var requestPostEvent: () -> Bool
        /// Non-prompting probes, taken before and after the request.
        var probeAccessibility: () -> Bool
        var probePostEvent: () -> Bool
        /// The value on the inherited handoff pipe, or nil when there is no such pipe.
        var readHandoff: () -> String?
        /// Writes the receipt to the inherited receipt pipe; false when there is none.
        var writeReceipt: (Data) -> Bool
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
                TCCResponsibility.runDisclaimed(executable: $0, arguments: $1, handoff: $2)
            },
            requestAccessibility: {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            },
            requestPostEvent: { CGRequestPostEventAccess() },
            probeAccessibility: { AXIsProcessTrusted() },
            probePostEvent: { CGPreflightPostEventAccess() },
            readHandoff: { readInheritedHandoff(descriptor: TCCResponsibility.handoffDescriptor) },
            writeReceipt: { writeInheritedReceipt($0, descriptor: TCCResponsibility.receiptDescriptor) },
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

    private static func isPipe(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
    }

    private static func readInheritedHandoff(descriptor: Int32) -> String? {
        guard isPipe(descriptor) else { return nil }
        var collected = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 128)
        while collected.count <= 512 {
            // The parent wrote and closed its end before spawning, so data or EOF is already there;
            // the timeout only keeps an unrelated inherited pipe from hanging this command.
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 2000) > 0 else { return nil }
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 { collected += chunk.prefix(count) } else if count == 0 || errno != EINTR { break }
        }
        return collected.isEmpty || collected.count > 512 ? nil : String(decoding: collected, as: UTF8.self)
    }

    private static func writeInheritedReceipt(_ data: Data, descriptor: Int32) -> Bool {
        guard isPipe(descriptor) else { return false }
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { written += count } else if count < 0 && errno == EINTR { continue } else { return false }
        }
        return true
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
        // Refused before anything is spawned: an arbitrary program would exit 0 having asked for nothing.
        guard (target as NSString).lastPathComponent == TCCResponsibility.productExecutableName else {
            writeStderr(
                "The target is not a \(TCCResponsibility.productExecutableName) executable; no permission was requested.\n"
            )
            return 1
        }
        writeStderr("Requesting for: \(runtime.labelForPath(target))\n")
        let handoff = "\(runtime.ownPID()):\(runtime.makeToken())"
        let run = runtime.runDisclaimed(target, [disclaimedChildFlag], handoff)
        switch run.outcome {
        case let .exited(code):
            guard let receipt = validReceipt(run.receipt, handoff: handoff) else {
                writeStderr(
                    "The request process finished without a valid receipt from LogicProMCP, so no permission request "
                        + "is confirmed. Run \(flag) with the path of the LogicProMCP executable your client launches.\n"
                )
                return 1
            }
            func state(_ granted: Bool) -> String { granted ? "granted" : "not granted" }
            writeStderr(
                """
                Receipt from LogicProMCP: Accessibility \(state(receipt.before.accessibility)) -> \(state(receipt.after.accessibility)), \
                PostEvent \(state(receipt.before.postEvent)) -> \(state(receipt.after.postEvent)).

                """
            )
            // Success needs the child's exit status AND the receipt's own report of both grants.
            return code == 0 && receipt.after.accessibility && receipt.after.postEvent ? 0 : 1
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

    /// Well-formed means: it decodes, has the current version, echoes this run's handoff, and says
    /// the child ran the request path as its own responsible process.
    static func validReceipt(_ data: Data, handoff: String) -> Receipt? {
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == Receipt.currentVersion,
              receipt.handoff == handoff,
              receipt.requested,
              receipt.selfResponsible else { return nil }
        return receipt
    }

    /// The child proves it was started by `--request-permissions`: it reads the parent's value from
    /// the inherited pipe (the value names the parent's pid, which must be its actual parent).
    private static func handoffIsValid(_ handoff: String?, runtime: Runtime) -> Bool {
        guard let handoff else { return false }
        let parts = handoff.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let parent = pid_t(parts[0]), !parts[1].isEmpty else { return false }
        return parent == runtime.parentPID()
    }

    private static func requestAsDisclaimedChild(runtime: Runtime, writeStderr: (String) -> Void) -> Int32 {
        let handoff = runtime.readHandoff()
        guard handoffIsValid(handoff, runtime: runtime), let handoff else {
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
        let before = Receipt.Probe(accessibility: runtime.probeAccessibility(), postEvent: runtime.probePostEvent())
        let accessibility = runtime.requestAccessibility()
        let postEvent = runtime.requestPostEvent()
        let after = Receipt.Probe(accessibility: runtime.probeAccessibility(), postEvent: runtime.probePostEvent())
        let receipt = Receipt(
            version: Receipt.currentVersion, handoff: handoff, requested: true,
            selfResponsible: true, before: before, after: after
        )
        guard let encoded = try? JSONEncoder().encode(receipt), runtime.writeReceipt(encoded) else {
            writeStderr("The request ran but its receipt could not be delivered to \(flag).\n")
            return 1
        }
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
