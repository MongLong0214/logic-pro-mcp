import AppKit

/// AppleScript injection prevention utilities (PRD §6.3).
enum AppleScriptSafety {
    /// Allowed transport actions — whitelist only.
    private static let allowedTransportActions: Set<String> = [
        "play", "stop", "record", "pause"
    ]

    /// Check if a transport action is in the whitelist.
    static func isAllowedTransportAction(_ action: String) -> Bool {
        allowedTransportActions.contains(action)
    }

    /// For project.open, use NSWorkspace instead of AppleScript string interpolation.
    static let shouldUseNSWorkspaceForOpen = true

    /// Validate a file path is non-empty and usable.
    static func isValidFilePath(_ path: String) -> Bool {
        !path.isEmpty
    }

    /// Open a file safely using NSWorkspace — no AppleScript injection possible.
    static func openFile(at path: String) -> Bool {
        guard isValidFilePath(path) else { return false }
        let url = URL(fileURLWithPath: path)
        return NSWorkspace.shared.open(url)
    }
}
