import Darwin
import Foundation

struct ProjectExportBounceHelperResult: Sendable, Equatable {
    let artifactPath: String?
    let error: String?
    let bounceFired: Bool

    static func success(_ path: String, bounceFired: Bool = true) -> ProjectExportBounceHelperResult {
        ProjectExportBounceHelperResult(artifactPath: path, error: nil, bounceFired: bounceFired)
    }

    static func failure(_ error: String, bounceFired: Bool = false) -> ProjectExportBounceHelperResult {
        ProjectExportBounceHelperResult(artifactPath: nil, error: error, bounceFired: bounceFired)
    }
}

extension ProjectExportExecutor {
    private static func lexicalPath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty, components.last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
                continue
            }
            components.append(component)
        }
        let joined = components.joined(separator: "/")
        if isAbsolute {
            return joined.isEmpty ? "/" : "/\(joined)"
        }
        return joined.isEmpty ? "." : joined
    }

    private static func parentPath(of path: String) -> String {
        let normalized = lexicalPath(path)
        guard normalized != "/" else { return "/" }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true)
        let parentParts = parts.dropLast()
        if normalized.hasPrefix("/") {
            return parentParts.isEmpty ? "/" : "/" + parentParts.joined(separator: "/")
        }
        return parentParts.isEmpty ? "." : parentParts.joined(separator: "/")
    }

    private static func joinPath(_ base: String, _ component: String) -> String {
        lexicalPath(base.hasSuffix("/") ? base + component : base + "/" + component)
    }

    private static func absoluteLexicalPath(_ path: String) -> String {
        let normalized = lexicalPath(path)
        return normalized.hasPrefix("/") ? normalized : joinPath(FileManager.default.currentDirectoryPath, normalized)
    }

    static func commandExists(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") {
            return isExecutable(trimmed)
        }

        let pathSeparator = ":"
        let searchPath = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for entry in searchPath.split(separator: Character(pathSeparator)) {
            guard !entry.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent(trimmed, isDirectory: false)
                .path
            if isExecutable(candidate) {
                return true
            }
        }
        return false
    }


    /// Resolve the `python3` interpreter via PATH (audit P2 #19). A hardcoded
    /// `/usr/bin/python3` is absent on machines where Python ships only through
    /// Homebrew / pyenv (`/opt/homebrew/bin`, `~/.pyenv/shims`), so the bounce
    /// helper spawn used to fail with a misleading error. Falls back to
    /// `/usr/bin/python3` when PATH resolution finds nothing so behavior is
    /// unchanged on stock macOS.
    ///
    /// The resolved interpreter is EXECUTED, so — exactly like the
    /// `LOGIC_PRO_MCP_BOUNCE_HELPER` script it runs — a PATH-resolved candidate
    /// must also pass the ownership guard (regular file, owned by you or root,
    /// not group/other-writable). Otherwise an operator whose `PATH` is
    /// influenced by another local user (a world-writable dir on `PATH`, or a
    /// planted `python3`) could substitute the interpreter and bypass every
    /// check we apply to the script, since the malicious code would BE the
    /// interpreter. An untrusted candidate is skipped; resolution continues down
    /// PATH and ultimately falls back to the stock `/usr/bin/python3`.
    static func resolvePython3Path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        resolveSymlinks: @Sendable (String) -> String = { ($0 as NSString).resolvingSymlinksInPath },
        ownershipTrusted: @Sendable (String) -> Bool = { bounceHelperOwnershipTrusted($0) }
    ) -> String {
        let searchPath = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for entry in searchPath.split(separator: ":") {
            guard !entry.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent("python3", isDirectory: false)
                .path
            // Ownership must be checked on the symlink-RESOLVED target.
            // `bounceHelperOwnershipTrusted` uses `attributesOfItem` (does NOT
            // follow symlinks) and requires a regular file, but the common
            // Homebrew `python3` is itself a symlink into the Cellar — validating
            // the raw candidate would reject trusted Homebrew Python and defeat
            // this PATH-resolution path. Resolve first, then validate the real
            // target; a symlink pointing at an untrusted file still fails.
            if isExecutable(candidate) && ownershipTrusted(resolveSymlinks(candidate)) {
                return candidate
            }
        }
        return "/usr/bin/python3"
    }

    /// True when `path` is a regular file owned by the current user (or root)
    /// and not writable by group or other — the ownership half of the
    /// `LOGIC_PRO_MCP_BOUNCE_HELPER` L1 guard (audit, security L1). A helper we
    /// EXECUTE must not be swappable by another local user.
    static func bounceHelperOwnershipTrusted(_ path: String) -> Bool {
        // `attributesOfItem` does not follow symlinks; callers pass the already
        // symlink-resolved path, so it reflects the real target file.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { return false }
        guard let ownerID = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value,
              ownerID == getuid() || ownerID == 0 else { return false }
        guard let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        let groupWritable: UInt16 = 0o020
        let otherWritable: UInt16 = 0o002
        guard (perms & groupWritable) == 0, (perms & otherWritable) == 0 else { return false }
        return true
    }

    /// Directory prefixes a `LOGIC_PRO_MCP_BOUNCE_HELPER` override may live under
    /// — the location half of the L1 guard, mirroring
    /// `defaultLibraryInventoryAllowedPrefixes`. The natural install/dev homes
    /// plus an additive operator env (`LOGIC_PRO_MCP_BOUNCE_HELPER_ALLOWLIST`,
    /// colon-separated). Every entry is symlink-resolved and forced to a trailing
    /// "/" so a sibling like `/x/Scripts-evil/` can't match prefix `/x/Scripts/`.
    static func defaultBounceHelperAllowedPrefixes(
        environment: [String: String],
        currentDirectoryPath: String,
        executableDir: String?,
        resolveSymlinks: @Sendable (String) -> String
    ) -> [String] {
        var prefixes: [String] = []
        if let executableDir {
            prefixes.append(executableDir)
            prefixes.append(joinPath(executableDir, "Scripts"))
            prefixes.append(joinPath(executableDir, "share/logic-pro-mcp"))
            let installRoot = parentPath(of: executableDir)
            prefixes.append(joinPath(installRoot, "share/logic-pro-mcp"))
        }
        prefixes.append(joinPath(NSHomeDirectory(), "Library/Application Support/LogicProMCP"))
        prefixes.append(joinPath(absoluteLexicalPath(currentDirectoryPath), "Scripts"))
        if let extra = environment["LOGIC_PRO_MCP_BOUNCE_HELPER_ALLOWLIST"], !extra.isEmpty {
            for raw in extra.split(separator: ":") where !raw.isEmpty {
                prefixes.append(String(raw))
            }
        }
        var seen = Set<String>()
        var out: [String] = []
        for p in prefixes {
            let expanded = (p as NSString).expandingTildeInPath
            var resolved = resolveSymlinks(expanded)
            if !resolved.hasSuffix("/") { resolved += "/" }
            if seen.insert(resolved).inserted { out.append(resolved) }
        }
        return out
    }

    /// Validate an operator-supplied `LOGIC_PRO_MCP_BOUNCE_HELPER` path before we
    /// hand it to python3 (audit, security L1 — this path is EXECUTED, so an
    /// attacker with env access could otherwise gain RCE). validate-if-exists: a
    /// MISSING path is harmless (it fails the downstream missing-helper check)
    /// and flows through unchanged for a truthful error; an EXISTING path must be
    /// a regular `.py` owned by us/root, not group/other-writable, and under an
    /// allowlisted directory. Returns the path to use, or nil (rejected + logged).
    static func validateBounceHelperEnvPath(
        _ rawPath: String,
        environment: [String: String],
        currentDirectoryPath: String,
        executablePath: String?,
        fileExists: @Sendable (String) -> Bool,
        resolveSymlinks: @Sendable (String) -> String,
        ownershipTrusted: @Sendable (String) -> Bool = { bounceHelperOwnershipTrusted($0) }
    ) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = absoluteLexicalPath(trimmed)
        guard fileExists(normalized) else { return normalized }
        let resolved = resolveSymlinks(normalized)
        guard resolved.hasSuffix(".py") else {
            Log.warn("LOGIC_PRO_MCP_BOUNCE_HELPER rejected (must be a .py file): raw=\(rawPath), resolved=\(resolved)", subsystem: "export")
            return nil
        }
        guard ownershipTrusted(resolved) else {
            Log.warn("LOGIC_PRO_MCP_BOUNCE_HELPER rejected (not a regular file owned by you/root and non-group/other-writable): raw=\(rawPath), resolved=\(resolved)", subsystem: "export")
            return nil
        }
        let executableDir = executablePath.map { parentPath(of: resolveSymlinks($0)) }
        let prefixes = defaultBounceHelperAllowedPrefixes(
            environment: environment,
            currentDirectoryPath: currentDirectoryPath,
            executableDir: executableDir,
            resolveSymlinks: resolveSymlinks
        )
        guard prefixes.contains(where: { resolved.hasPrefix($0) }) else {
            Log.warn("LOGIC_PRO_MCP_BOUNCE_HELPER rejected (outside allowlist): raw=\(rawPath), resolved=\(resolved), allowlist=\(prefixes.joined(separator: ", "))", subsystem: "export")
            return nil
        }
        return resolved
    }

    static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func effectiveExecutablePath(
        overrideExecutablePath: String?,
        commandLineExecutablePath: String?,
        processExecutablePath: String?
    ) -> String? {
        for candidate in [overrideExecutablePath, processExecutablePath] {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else { continue }
            return URL(fileURLWithPath: candidate, isDirectory: false).standardized.path
        }
        guard let commandLineExecutablePath = commandLineExecutablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commandLineExecutablePath.isEmpty,
              commandLineExecutablePath.hasPrefix("/") || commandLineExecutablePath.contains("/")
        else {
            return nil
        }
        return absoluteLexicalPath(commandLineExecutablePath)
    }

    static func bounceHelperCandidatePaths(
        environment: [String: String],
        currentDirectoryPath: String,
        executablePath: String?,
        fileExists: @Sendable (String) -> Bool,
        resolveSymlinks: @Sendable (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    ) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ candidate: String?) {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else { return }
            let normalized = absoluteLexicalPath(candidate)
            if !candidates.contains(normalized) {
                candidates.append(normalized)
            }
        }

        // Security L1 (audit): the operator-supplied helper is EXECUTED via
        // python3, so validate it before trusting it (regular .py, owned by
        // you/root, non-group/other-writable, under an allowlisted dir). A
        // missing path flows through for a truthful bounce_helper_missing error.
        if let bounceHelperEnv = environment["LOGIC_PRO_MCP_BOUNCE_HELPER"],
           let validated = validateBounceHelperEnvPath(
               bounceHelperEnv,
               environment: environment,
               currentDirectoryPath: currentDirectoryPath,
               executablePath: executablePath,
               fileExists: fileExists,
               resolveSymlinks: resolveSymlinks
           ) {
            appendCandidate(validated)
        }
        if let shareDir = environment["LOGIC_PRO_MCP_SHARE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shareDir.isEmpty {
            let sharePath = absoluteLexicalPath(shareDir)
            if URL(fileURLWithPath: sharePath, isDirectory: false).pathExtension == "py" {
                appendCandidate(sharePath)
            } else {
                appendCandidate(joinPath(sharePath, "logic_bounce.py"))
                appendCandidate(joinPath(sharePath, "Scripts/logic_bounce.py"))
            }
        }

        if let executablePath {
            let executableDir = parentPath(of: resolveSymlinks(executablePath))
            appendCandidate(joinPath(executableDir, "Scripts/logic_bounce.py"))
            appendCandidate(joinPath(executableDir, "share/logic-pro-mcp/logic_bounce.py"))
            appendCandidate(joinPath(executableDir, "share/logic-pro-mcp/Scripts/logic_bounce.py"))
            let installRoot = parentPath(of: executableDir)
            appendCandidate(joinPath(installRoot, "share/logic-pro-mcp/logic_bounce.py"))
            appendCandidate(joinPath(installRoot, "share/logic-pro-mcp/Scripts/logic_bounce.py"))
            for repoCandidate in repositoryBounceHelperCandidatePaths(
                executablePath: executablePath,
                fileExists: fileExists,
                resolveSymlinks: resolveSymlinks
            ) {
                appendCandidate(repoCandidate)
            }
        } else {
            let repoRoot = absoluteLexicalPath(currentDirectoryPath)
            let packageSwift = joinPath(repoRoot, "Package.swift")
            let helper = joinPath(repoRoot, "Scripts/logic_bounce.py")
            if fileExists(packageSwift), fileExists(helper) {
                appendCandidate(helper)
            }
        }

        return candidates
    }

    static func repositoryBounceHelperCandidatePaths(
        executablePath: String,
        fileExists: @Sendable (String) -> Bool,
        resolveSymlinks: @Sendable (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    ) -> [String] {
        var candidates: [String] = []
        var current = parentPath(of: resolveSymlinks(executablePath))

        while true {
            let packageSwift = joinPath(current, "Package.swift")
            let helper = joinPath(current, "Scripts/logic_bounce.py")
            if fileExists(packageSwift), fileExists(helper) {
                candidates.append(helper)
            }
            let parent = parentPath(of: current)
            if parent == current {
                break
            }
            current = parent
        }

        return candidates
    }

    static func resolveBounceHelperPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        executablePath: String? = nil,
        commandLineExecutablePath: String? = CommandLine.arguments.first,
        processExecutablePath: String? = currentExecutablePath(),
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        // Injectable so unit tests stay fully hermetic: the real
        // `resolvingSymlinksInPath()` performs filesystem I/O (realpath/lstat) on
        // the caller-supplied executable path, which on some CI runners stalls for
        // minutes on certain prefixes (e.g. a real `/opt/homebrew`). Tests inject
        // an identity closure so resolution never touches the disk.
        resolveSymlinks: @Sendable (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    ) -> String? {
        let effectiveExecutablePath = effectiveExecutablePath(
            overrideExecutablePath: executablePath,
            commandLineExecutablePath: commandLineExecutablePath,
            processExecutablePath: processExecutablePath
        )
        let candidates = bounceHelperCandidatePaths(
            environment: environment,
            currentDirectoryPath: currentDirectoryPath,
            executablePath: effectiveExecutablePath,
            fileExists: fileExists,
            resolveSymlinks: resolveSymlinks
        )
        for candidate in candidates where fileExists(candidate) {
            return candidate
        }
        return candidates.first
    }
}
