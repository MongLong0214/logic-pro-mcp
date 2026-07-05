import AppKit

/// AppleScript injection prevention utilities (PRD §6.3).
enum AppleScriptSafety {
    struct Runtime: Sendable {
        let openFileURL: @Sendable (URL) -> Bool

        static let production = Runtime(
            openFileURL: { url in
                let result = BoundedProcessRunner.run(
                    executable: "/usr/bin/open",
                    arguments: ["-a", "Logic Pro", url.path],
                    timeout: ServerConfig.appleScriptTimeout,
                    outputLimitBytes: 4 * 1024
                )
                guard case let .completed(output) = result else {
                    Log.error("Failed to launch project via open(1): \(result)", subsystem: "appleScript")
                    return false
                }
                return output.exitCode == 0
            }
        )
    }

    /// Allowed transport actions — whitelist only.
    private static let allowedTransportActions: Set<String> = [
        "play", "stop", "record", "pause"
    ]

    /// Check if a transport action is in the whitelist.
    static func isAllowedTransportAction(_ action: String) -> Bool {
        allowedTransportActions.contains(action)
    }

    /// Escape a string for safe interpolation inside an AppleScript
    /// double-quoted literal. Backslash MUST be escaped first (otherwise the
    /// backslashes we introduce for the quote escape would themselves be
    /// doubled), then the double-quote. Shared by the osascript probe/command
    /// builders (`PermissionChecker`, `ProcessUtils`) so the escaping lives in
    /// one place. WS2's AppleScriptChannel call-sites defer to this in a later
    /// sweep; this sweep only wires the Utilities-owned builders.
    static func escapeForScript(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Validate a file path is non-empty and usable.
    static func isValidFilePath(_ path: String) -> Bool {
        validatedFilePath(path) != nil
    }

    private static func validatedFilePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == path else {
            return nil
        }
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return nil
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        guard !trimmed.hasPrefix("/dev/") else {
            return nil
        }
        guard !containsParentDirectoryTraversal(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func containsParentDirectoryTraversal(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains("..")
    }

    /// Validate a Logic project path. Existing projects must point to a .logicx package.
    static func isValidProjectPath(_ path: String, requireExisting: Bool) -> Bool {
        guard let url = projectURL(from: path, requireExisting: requireExisting) else {
            return false
        }
        return url.pathExtension.lowercased() == "logicx"
    }

    static func projectURL(from path: String, requireExisting: Bool) -> URL? {
        guard let safePath = validatedFilePath(path) else { return nil }
        let url = URL(fileURLWithPath: safePath).standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix("/") else {
            return nil
        }
        if requireExisting {
            guard isValidExistingProjectPackage(at: url) else {
                return nil
            }
        }
        return url
    }

    static func isValidExistingProjectPackage(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "logicx" else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let projectInfo = url
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ProjectInformation.plist", isDirectory: false)
        guard FileManager.default.fileExists(atPath: projectInfo.path) else {
            return false
        }

        let alternativesURL = url.appendingPathComponent("Alternatives", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: alternativesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let candidate as URL in enumerator {
            if candidate.lastPathComponent == "ProjectData" {
                return true
            }
        }

        return false
    }

    /// Open a file safely using NSWorkspace — no AppleScript injection possible.
    static func openFile(at path: String) -> Bool {
        openFile(at: path, runtime: .production)
    }

    static func openFile(at path: String, runtime: Runtime) -> Bool {
        guard let url = projectURL(from: path, requireExisting: true),
              url.pathExtension.lowercased() == "logicx" else {
            return false
        }
        return runtime.openFileURL(url)
    }
}
