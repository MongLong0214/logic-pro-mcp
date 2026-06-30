import CryptoKit
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
    private static let trustedCliclickPaths = [
        "/opt/homebrew/bin/cliclick",
        "/usr/local/bin/cliclick",
        "/usr/bin/cliclick",
    ]

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

    // MARK: - cliclick trust resolution (issue #210)
    //
    // Trust model (NORMATIVE — mirrored byte-for-byte in Scripts/logic_bounce_ui.py and
    // Scripts/live-e2e-test.py): only execute a cliclick a non-root local attacker cannot swap.
    //   • canonical: one of the 3 system bin dirs, immediate parent non-group/world-writable
    //     (shipped behavior, NO symlink resolution — preserved exactly).
    //   • operator override (LOGIC_PRO_MCP_CLICLICK): an arbitrary absolute path, trusted only when
    //     the symlink-RESOLVED real file is an executable regular file, not group/world-writable,
    //     owned by root or the current uid, with every real ancestor non-group/world-writable AND
    //     owned by root/self, and — if LOGIC_PRO_MCP_CLICLICK_SHA256 is set — a matching content pin.
    // Fail-closed everywhere: any stat/owner/realpath/hash uncertainty → reject.

    enum CliclickRejection: String, Codable, Sendable, Equatable {
        case resolved
        case notAbsolute = "not_absolute"
        case notFound = "not_found"
        case notExecutable = "not_executable"
        case parentWritable = "parent_writable"   // canonical: immediate parent group/world-writable
        case fileWritable = "file_writable"
        case ownerUntrusted = "owner_untrusted"
        case ancestorWritable = "ancestor_writable"
        case sha256Mismatch = "sha256_mismatch"
    }

    enum CliclickSource: String, Codable, Sendable, Equatable {
        case override
        case canonical
    }

    struct CliclickCandidate: Codable, Sendable, Equatable {
        let path: String
        let source: CliclickSource
        let reason: CliclickRejection
    }

    struct CliclickResolution: Sendable, Equatable {
        let resolvedPath: String?
        let candidates: [CliclickCandidate]

        /// Compact, operator-facing diagnosis for error strings / doctor evidence / health.
        var diagnosticSummary: String {
            let tried = candidates.isEmpty
                ? "no candidates"
                : candidates.map { "\($0.path)=\($0.reason.rawValue)" }.joined(separator: ", ")
            return "tried: \(tried); fix: run `chmod g-w /opt/homebrew/bin` so the canonical cliclick "
                + "resolves (note: its symlink target under /opt/homebrew/Cellar stays group-writable, so it "
                + "remains swappable by admin-group users — for full isolation copy cliclick to a non-writable "
                + "dir and set LOGIC_PRO_MCP_CLICLICK to it, optionally with LOGIC_PRO_MCP_CLICLICK_SHA256). "
                + "See docs/SETUP.md#doctor-dependenciescliclick."
        }
    }

    /// Injectable filesystem/crypto seams so the resolver is fully hermetic in tests.
    struct CliclickResolverDeps: Sendable {
        var isExecutable: @Sendable (String) -> Bool
        var attributesOfItem: @Sendable (String) throws -> [FileAttributeKey: Any]
        /// Regular-file check that FOLLOWS symlinks (parity with Python `os.path.isfile`): true only
        /// for an existing regular file (or a symlink to one), false for a directory/missing path.
        var isRegularFile: @Sendable (String) -> Bool
        /// C realpath(3): nil on ENOENT/EACCES/missing component → caller maps to .notFound.
        var realpath: @Sendable (String) -> String?
        /// SHA-256 hex of the file's bytes, or nil if unreadable.
        var sha256OfFile: @Sendable (String) -> String?
        var currentUid: @Sendable () -> UInt32

        static let production = CliclickResolverDeps(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            attributesOfItem: { try FileManager.default.attributesOfItem(atPath: $0) },
            isRegularFile: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            },
            realpath: { path in
                path.withCString { cString -> String? in
                    guard let resolved = Darwin.realpath(cString, nil) else { return nil }
                    defer { free(resolved) }
                    return String(cString: resolved)
                }
            },
            sha256OfFile: { path in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            },
            currentUid: { getuid() }
        )
    }

    /// Full resolution with per-candidate reasons (issue #210 diagnosability).
    static func resolveCliclickDetailed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        deps: CliclickResolverDeps = .production
    ) -> CliclickResolution {
        var candidates: [CliclickCandidate] = []

        // 1) Operator override — ALWAYS evaluated as approved-arbitrary (strict). A rejected
        //    override does NOT suppress canonical fallthrough.
        if let raw = environment["LOGIC_PRO_MCP_CLICLICK"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let outcome = validateArbitraryCliclick(raw, environment: environment, deps: deps)
            candidates.append(
                CliclickCandidate(path: absoluteLexicalPath(raw), source: .override, reason: outcome.reason)
            )
            if outcome.reason == .resolved, let real = outcome.resolvedPath {
                return CliclickResolution(resolvedPath: real, candidates: candidates)
            }
        }

        // 2) Canonical candidates — shipped rule, no symlink resolution.
        for canonical in trustedCliclickPaths {
            let reason = validateCanonicalCliclick(canonical, deps: deps)
            candidates.append(CliclickCandidate(path: canonical, source: .canonical, reason: reason))
            if reason == .resolved {
                return CliclickResolution(resolvedPath: canonical, candidates: candidates)
            }
        }

        return CliclickResolution(resolvedPath: nil, candidates: candidates)
    }

    /// Back-compat thin wrapper: resolved path or nil. Existing callers keep working.
    static func resolveTrustedCliclick(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        attributesOfItem: @escaping @Sendable (String) throws -> [FileAttributeKey: Any] = {
            try FileManager.default.attributesOfItem(atPath: $0)
        }
    ) -> String? {
        var deps = CliclickResolverDeps.production
        deps.isExecutable = isExecutable
        deps.attributesOfItem = attributesOfItem
        return resolveCliclickDetailed(environment: environment, deps: deps).resolvedPath
    }

    /// Canonical rule (shipped, NG1): immediate-parent non-writable, no symlink follow.
    private static func validateCanonicalCliclick(
        _ path: String,
        deps: CliclickResolverDeps
    ) -> CliclickRejection {
        let normalized = absoluteLexicalPath(path)
        let parent = parentPath(of: normalized)
        guard let attrs = try? deps.attributesOfItem(parent),
              let permissions = attrs[.posixPermissions] as? NSNumber else {
            return .notFound
        }
        if permissions.intValue & 0o022 != 0 {
            return .parentWritable
        }
        // Regular-file (follows symlinks) BEFORE executable — exact parity with Python's
        // `os.path.isfile(p) and os.access(p, X_OK)`. Rejects a directory at a canonical path
        // (FileManager.isExecutableFile returns true for directories, which would otherwise
        // false-green vs the Python bounce gate).
        guard deps.isRegularFile(normalized) else {
            return .notFound
        }
        return deps.isExecutable(normalized) ? .resolved : .notExecutable
    }

    /// Approved-arbitrary rule (strict, symlink-resolved, fail-closed). Returns the resolved
    /// REAL path on success so the caller execs the validated inode.
    private static func validateArbitraryCliclick(
        _ raw: String,
        environment: [String: String],
        deps: CliclickResolverDeps
    ) -> (reason: CliclickRejection, resolvedPath: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("\0") {
            return (.notFound, nil)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return (.notAbsolute, nil)
        }
        guard let real = deps.realpath(expanded) else {
            return (.notFound, nil)
        }
        // Must be an executable REGULAR file (not a dir/other).
        let realAttrs = try? deps.attributesOfItem(real)
        guard let fileType = realAttrs?[.type] as? FileAttributeType, fileType == .typeRegular else {
            return (.notFound, nil)
        }
        guard deps.isExecutable(real) else {
            return (.notExecutable, nil)
        }
        // File must not be group/world-writable.
        guard let filePerms = realAttrs?[.posixPermissions] as? NSNumber else {
            return (.fileWritable, nil)   // unverifiable perms → fail closed
        }
        if filePerms.intValue & 0o022 != 0 {
            return (.fileWritable, nil)
        }
        // File owner must be root or the current uid.
        guard let fileOwner = realAttrs?[.ownerAccountID] as? NSNumber,
              isTrustedOwner(fileOwner.uint32Value, deps: deps) else {
            return (.ownerUntrusted, nil)
        }
        // Every real ancestor (immediate parent … "/") must be non-writable AND owned by root/self.
        if let ancestorReason = validateAncestryNonWritable(of: real, deps: deps) {
            return (ancestorReason, nil)
        }
        // Optional content pin. Key PRESENT (even blank) ⇒ must match a 64-hex digest.
        if let rawPin = environment["LOGIC_PRO_MCP_CLICLICK_SHA256"] {
            let pin = rawPin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard pin.count == 64,
                  pin.allSatisfy({ $0.isHexDigit }),
                  let actual = deps.sha256OfFile(real),
                  actual.lowercased() == pin else {
                return (.sha256Mismatch, nil)
            }
        }
        return (.resolved, real)
    }

    private static func isTrustedOwner(_ uid: UInt32, deps: CliclickResolverDeps) -> Bool {
        uid == 0 || uid == deps.currentUid()
    }

    /// Walk parent…"/" inclusive; any group/world-writable or non-{root,self}-owned ancestor, or any
    /// unreadable ancestor, is untrusted. Returns the rejection reason, or nil if all ancestors pass.
    private static func validateAncestryNonWritable(
        of real: String,
        deps: CliclickResolverDeps
    ) -> CliclickRejection? {
        var current = parentPath(of: real)
        while true {
            guard let attrs = try? deps.attributesOfItem(current),
                  let perms = attrs[.posixPermissions] as? NSNumber else {
                return .ancestorWritable   // unreadable ancestor → fail closed
            }
            if perms.intValue & 0o022 != 0 {
                return .ancestorWritable
            }
            guard let owner = attrs[.ownerAccountID] as? NSNumber,
                  isTrustedOwner(owner.uint32Value, deps: deps) else {
                return .ancestorWritable
            }
            let parent = parentPath(of: current)
            if parent == current {   // reached "/"
                break
            }
            current = parent
        }
        return nil
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

        appendCandidate(environment["LOGIC_PRO_MCP_BOUNCE_HELPER"])
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
