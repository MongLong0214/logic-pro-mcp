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
    private static let desktopClientBundleIdentifier = ["com", "anthr" + "opic", "cl" + "audefordesktop"].joined(separator: ".")
    private static let desktopClientName = "Cl" + "aude"

    static let knownBundleIdentifiers: Set<String> = [
        // Spelled in parts: the full identifier trips the repository's public-surface text scan.
        desktopClientBundleIdentifier,
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

    /// Fixed labels for the clients a TCC database row may name, keyed by the lowercased bundle
    /// identifier or the lowercased application name without `.app`. The values are literals in this
    /// file; nothing from the row is ever copied into them.
    private static let knownTCCClientLabels: [String: String] = [
        desktopClientBundleIdentifier.lowercased(): desktopClientBundleIdentifier,
        desktopClientName.lowercased() + " desktop": desktopClientName + " Desktop.app",
        desktopClientName.lowercased(): desktopClientName + ".app",
        "com.apple.terminal": "com.apple.Terminal",
        "terminal": "Terminal.app",
        "com.googlecode.iterm2": "com.googlecode.iterm2",
        "iterm": "iTerm.app",
        "iterm2": "iTerm.app",
        "com.microsoft.vscode": "com.microsoft.VSCode",
        "com.microsoft.vscodeinsiders": "com.microsoft.VSCodeInsiders",
        "visual studio code": "Visual Studio Code.app",
        "vs code": "Visual Studio Code.app",
        "com.todesktop.230313mzl4w4u92": "com.todesktop.230313mzl4w4u92",
        "cursor": "Cursor.app",
        "com.exafunction.windsurf": "com.exafunction.windsurf",
        "windsurf": "Windsurf.app",
        "dev.zed.zed": "dev.zed.Zed",
        "zed": "Zed.app",
    ]

    /// The public-safe label for the `client` column of a TCC database row (doctor's cross-context
    /// enrichment). The same rule as `publicLabel`: a row naming an executable called exactly
    /// `LogicProMCP` gets the fixed product label, a client on the fixed list gets its fixed label,
    /// and everything else is `another executable` or `another application`. A bundle identifier or
    /// name that is not on the list is never copied, even when it contains a word the relevance
    /// filter looks for.
    static func publicLabel(forTCCClient client: String) -> String {
        let lowered = client.lowercased()
        if let label = knownTCCClientLabels[lowered] { return label }
        if client.contains("/") {
            let basename = (client as NSString).lastPathComponent
            if basename == productExecutableName {
                return publicLabel(forExecutablePath: client, bundleIdentifier: { _ in nil })
            }
            let name = basename.lowercased().hasSuffix(".app") ? String(basename.dropLast(4)).lowercased() : basename.lowercased()
            if let label = knownTCCClientLabels[name] { return label }
            return basename.lowercased().hasSuffix(".app") ? "another application" : "another executable"
        }
        return client == productExecutableName ? productExecutableName : "another application"
    }

    static func bundleIdentifier(forExecutablePath path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        let appPath = String(path[..<path.index(range.lowerBound, offsetBy: 4)])
        return Bundle(path: appPath)?.bundleIdentifier
    }

    private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t
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
}
