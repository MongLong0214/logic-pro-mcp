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
        /// Public-safe identifier: executable basename, a fixed install-kind label, and the
        /// bundle identifier when the executable is inside an app bundle. nil when the path
        /// could not be read.
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

    /// The public-safe identifier for an executable path (see `Principal.label`).
    static func publicLabel(forExecutablePath path: String, bundleIdentifier: (String) -> String? = TCCResponsibility.bundleIdentifier(forExecutablePath:)) -> String {
        let raw = (path as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
        let name = raw.isEmpty || raw.count > 64 || raw.unicodeScalars.contains(where: { !allowed.contains($0) })
            ? "unnamed executable"
            : raw
        var detail = installKind(of: path)
        if let bundle = bundleIdentifier(path), !bundle.isEmpty, bundle.count <= 128,
           bundle.unicodeScalars.allSatisfy({ allowed.contains($0) && $0 != " " }) {
            detail += ", \(bundle)"
        }
        return "\(name) (\(detail))"
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

    /// Run `executable` as its own responsible process, inheriting stdin/stdout/stderr, and
    /// wait for it. This is the same arrangement a disclaiming MCP client uses for servers, so a
    /// permission request made by the child is recorded for the child's binary.
    static func runDisclaimed(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) -> SpawnOutcome {
        guard let setDisclaim = symbol("responsibility_spawnattrs_setdisclaim", as: SetDisclaim.self) else {
            return .disclaimUnavailable
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .spawnFailed(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        let disclaimStatus = setDisclaim(&attributes, 1)
        guard disclaimStatus == 0 else { return .spawnFailed(disclaimStatus) }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var environment = ProcessInfo.processInfo.environment
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, nil, &attributes, argv, envp)
        guard spawnStatus == 0 else { return .spawnFailed(spawnStatus) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return .spawnFailed(errno) }
        }
        // WIFEXITED / WEXITSTATUS are macros Swift does not import.
        let terminationSignal = status & 0x7f
        return terminationSignal == 0 ? .exited((status >> 8) & 0xff) : .exited(128 + terminationSignal)
    }
}
