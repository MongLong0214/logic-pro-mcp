import Foundation

extension SetupDoctor {
    static func productionKeyCommandsPresetStaged() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Audio Music Apps/Key Commands/LogicProMCP-KeyCommands.plist")
            .path
        return FileManager.default.fileExists(atPath: path)
    }


    static func productionMCUPortReferenceFound() -> Bool? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.logic.pro.cs")
            .path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let output = runProductionCommand(
            executable: "/usr/bin/strings",
            arguments: [path],
            timeout: 1.5
        )?.output?.stdout ?? ""
        return output.contains("LogicProMCP-MCU-Internal")
    }


}
