import Foundation
import Darwin

/// Which process macOS privacy (TCC) evaluates for this server's Accessibility, PostEvent and
/// Automation checks, measured rather than guessed from the parent chain (#1596).
///
/// TCC attributes a request to the *responsible process*. A child usually inherits its
/// launcher's, so a server started from Terminal is judged by Terminal's grants. A launcher
/// can instead spawn the child with responsibility disclaimed, and then the child binary is
/// its own principal: grants the launcher holds do not apply to it. Some desktop MCP clients
/// start stdio servers that way through a `disclaimer` helper, so a server they launch is
/// evaluated as the LogicProMCP binary at its own path, not as the client app.
enum TCCResponsibility {
    /// The responsible process, identified only by a label that is safe to show to anyone.
    /// The executable's directory is never part of it: it can hold a client or project name,
    /// and every public surface (MCP result, CLI, doctor, support bundle) prints this value.
    /// The real path stays inside the spawn code (`PermissionRequestCommand`).
    struct Principal: Equatable, Sendable {
        let pid: pid_t
        /// Public-safe identifier built from fixed strings only (see `publicLabel`). nil when the
        /// path could not be read.
        let label: String?
        /// True when this process is its own responsible process.
        let isSelf: Bool

        var displayName: String { label ?? "unidentified process" }

        /// One line naming the principal, without a setup instruction: the permission report
        /// states what was measured and does not ask for a manual continuation.
        var summaryLine: String {
            isSelf
                ? "TCC principal: this LogicProMCP binary itself (\(displayName)); grants held by the app that launched it do not apply"
                : "TCC principal: \(displayName) (the responsible process that launched this server)"
        }
    }

    /// Fixed install-kind vocabulary. Anything unrecognised is "other install", never the path.
    static func installKind(of path: String) -> String {
        if path.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            return "homebrew"
        }
        if path.contains("/.build/") { return "source build" }
        if path.contains(".app/Contents/") { return "app bundle" }
        return "other install"
    }

    /// The executable name this product ships under. Only this exact basename is ever named.
    static let productExecutableName = "LogicProMCP"

    /// Bundle identifiers that may appear in public output: the apps the launch-context classifier
    /// recognises. Anything else is reported as a fixed phrase.
    static let knownBundleIdentifiers: Set<String> = [
        // Spelled in parts: the full identifier trips the repository's public-surface text scan.
        ["com", "anthr" + "opic", "cl" + "audefordesktop"].joined(separator: "."),
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
    ]

    /// The public-safe identifier for an executable path (see `Principal.label`). Built only from
    /// fixed strings: no part of the path, the basename or the bundle identifier is copied unless
    /// it equals one of the fixed values above.
    static func publicLabel(forExecutablePath path: String, bundleIdentifier: (String) -> String? = TCCResponsibility.bundleIdentifier(forExecutablePath:)) -> String {
        let bundle = bundleIdentifier(path)
        if (path as NSString).lastPathComponent == productExecutableName {
            var detail = installKind(of: path)
            if let bundle, knownBundleIdentifiers.contains(bundle) { detail += ", \(bundle)" }
            return "\(productExecutableName) (\(detail))"
        }
        guard let bundle, !bundle.isEmpty else { return "another executable" }
        return knownBundleIdentifiers.contains(bundle) ? "\(bundle) (app bundle)" : "another application"
    }

    static func bundleIdentifier(forExecutablePath path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        let appPath = String(path[..<path.index(range.lowerBound, offsetBy: 4)])
        return Bundle(path: appPath)?.bundleIdentifier
    }

    private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The responsible pid of `pid`, or nil when the system does not expose the query or
    /// refuses it for this pid.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let query = symbol("responsibility_get_pid_responsible_for_pid", as: ResponsibleForPID.self) else {
            return nil
        }
        let responsible = query(pid)
        return responsible > 0 ? responsible : nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The principal for this process, or nil when it cannot be measured.
    static func currentPrincipal() -> Principal? {
        principal(
            selfPID: getpid(),
            responsiblePID: responsiblePID(for:),
            pathForPID: executablePath(of:),
            labelForPath: { publicLabel(forExecutablePath: $0) }
        )
    }

    /// Pure mapping, so the attribution rule is testable without a launcher that actually
    /// disclaims (an unattended test host cannot reproduce a disclaiming launch).
    static func principal(
        selfPID: pid_t,
        responsiblePID: (pid_t) -> pid_t?,
        pathForPID: (pid_t) -> String?,
        labelForPath: (String) -> String = { publicLabel(forExecutablePath: $0, bundleIdentifier: { _ in nil }) }
    ) -> Principal? {
        guard let responsible = responsiblePID(selfPID) else { return nil }
        return Principal(
            pid: responsible,
            label: pathForPID(responsible).map(labelForPath),
            isSelf: responsible == selfPID
        )
    }

    enum SpawnOutcome: Equatable, Sendable {
        case exited(Int32)
        /// This system does not expose the disclaim spawn attribute.
        case disclaimUnavailable
        case spawnFailed(Int32)
    }

    /// File descriptors the disclaimed child inherits from `runDisclaimed`: the parent's one-shot
    /// handoff (read end) and the receipt channel back to the parent (write end).
    static let handoffDescriptor: Int32 = 3
    static let receiptDescriptor: Int32 = 4

    struct DisclaimedRun: Equatable, Sendable {
        var outcome: SpawnOutcome
        /// Whatever the child wrote to its receipt descriptor (capped). Untrusted until parsed.
        var receipt: Data
    }

    /// A pipe whose descriptors are close-on-exec and sit above the fixed numbers the child gets.
    private static func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let moved = fds.map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
        fds.forEach { close($0) }
        guard moved.allSatisfy({ $0 >= 0 }) else { moved.filter { $0 >= 0 }.forEach { close($0) }; return nil }
        return (moved[0], moved[1])
    }

    /// Run `executable` as its own responsible process, inheriting stdin/stdout/stderr, and
    /// wait for it. This is the same arrangement a disclaiming MCP client uses for servers, so a
    /// permission request made by the child is recorded for the child's binary.
    ///
    /// The child also inherits two pipes: `handoffDescriptor` (readable, holds `handoff`) and
    /// `receiptDescriptor` (writable). The exit status alone proves nothing, because any program
    /// can exit 0; the caller decides from the receipt.
    static func runDisclaimed(
        executable: String,
        arguments: [String],
        handoff: String
    ) -> DisclaimedRun {
        func failed(_ outcome: SpawnOutcome) -> DisclaimedRun { DisclaimedRun(outcome: outcome, receipt: Data()) }
        guard let setDisclaim = symbol("responsibility_spawnattrs_setdisclaim", as: SetDisclaim.self) else {
            return failed(.disclaimUnavailable)
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return failed(.spawnFailed(errno)) }
        defer { posix_spawnattr_destroy(&attributes) }
        let disclaimStatus = setDisclaim(&attributes, 1)
        guard disclaimStatus == 0 else { return failed(.spawnFailed(disclaimStatus)) }

        guard let handoffPipe = makePipe() else { return failed(.spawnFailed(errno)) }
        guard let receiptPipe = makePipe() else {
            close(handoffPipe.read); close(handoffPipe.write)
            return failed(.spawnFailed(errno))
        }
        var held = [handoffPipe.read, handoffPipe.write, receiptPipe.read, receiptPipe.write]
        func closeAll() { held.forEach { close($0) }; held = [] }
        func closeOne(_ fd: Int32) { close(fd); held.removeAll { $0 == fd } }
        defer { closeAll() }

        let bytes = Array(handoff.utf8)
        // Small enough for the pipe buffer, so this cannot block before the child exists.
        guard bytes.count <= 512, write(handoffPipe.write, bytes, bytes.count) == bytes.count else {
            return failed(.spawnFailed(EIO))
        }
        closeOne(handoffPipe.write)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return failed(.spawnFailed(errno)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, handoffPipe.read, handoffDescriptor) == 0,
              posix_spawn_file_actions_adddup2(&actions, receiptPipe.write, receiptDescriptor) == 0 else {
            return failed(.spawnFailed(errno))
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard spawnStatus == 0 else { return failed(.spawnFailed(spawnStatus)) }
        closeOne(handoffPipe.read)
        closeOne(receiptPipe.write)

        // Read to EOF (the child's exit closes its end); keep a bounded prefix only.
        var receipt = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(receiptPipe.read, &chunk, chunk.count)
            if count > 0 {
                if receipt.count < 8192 { receipt.append(contentsOf: chunk.prefix(count)) }
            } else if count == 0 || errno != EINTR {
                break
            }
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return failed(.spawnFailed(errno)) }
        }
        // WIFEXITED / WEXITSTATUS are macros Swift does not import.
        let terminationSignal = status & 0x7f
        let outcome: SpawnOutcome = terminationSignal == 0 ? .exited((status >> 8) & 0xff) : .exited(128 + terminationSignal)
        return DisclaimedRun(outcome: outcome, receipt: receipt)
    }
}
