import Foundation

extension SetupDoctor {
    static let expectedShareDirFiles: [String] = [
        "SETUP.md",
        "install-keycmds.sh",
        "uninstall-keycmds.sh",
        "keycmd-preset.plist",
        "LogicProMCP-Scripter.js",
        "logic_bounce.py",
        "logic_bounce_ui.py",
        "logic_ui_jxa.py",
        "logic_input_source.py",
    ]


    static func productionShareDirProbe() -> ShareDirProbe {
        if case let .registered(_, environment) = readProductionClaudeRegistration(),
           let shareDir = environment["LOGIC_PRO_MCP_SHARE_DIR"],
           !shareDir.isEmpty,
           let result = probeShareDir(path: shareDir, source: "registered_env") {
            return result
        }
        for path in ["/opt/homebrew/share/logic-pro-mcp", "/usr/local/share/logic-pro-mcp"] {
            if let result = probeShareDir(path: path, source: "brew_pkgshare") {
                return result
            }
        }
        return .unresolved
    }


    private static func probeShareDir(path: String, source: String) -> ShareDirProbe? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return .invalid(path: path, source: source) }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let missing = expectedShareDirFiles.filter { !contents.contains($0) }
        return missing.isEmpty
            ? .complete(path: path, source: source)
            : .missing(path: path, source: source, files: missing)
    }


}
