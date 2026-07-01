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
