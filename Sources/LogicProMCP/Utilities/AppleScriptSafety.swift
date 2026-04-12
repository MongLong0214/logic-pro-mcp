import AppKit

/// AppleScript injection prevention utilities (PRD §6.3).
enum AppleScriptSafety {
    struct Runtime: Sendable {
        let openFileURL: @Sendable (URL) -> Bool

        static let production = Runtime(
            openFileURL: { url in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "Logic Pro", url.path]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch {
                    Log.error("Failed to launch project via open(1): \(error)", subsystem: "appleScript")
                    return false
                }
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

    /// Validate a file path is non-empty and usable.
    static func isValidFilePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return false
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return false
        }
        guard !trimmed.hasPrefix("/dev/") else {
            return false
        }
        return true
    }

    /// Validate a Logic project path. Existing projects must point to a .logicx package.
    static func isValidProjectPath(_ path: String, requireExisting: Bool) -> Bool {
        guard let url = projectURL(from: path, requireExisting: requireExisting) else {
            return false
        }
        return url.pathExtension.lowercased() == "logicx"
    }

    static func projectURL(from path: String, requireExisting: Bool) -> URL? {
        guard isValidFilePath(path) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
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
