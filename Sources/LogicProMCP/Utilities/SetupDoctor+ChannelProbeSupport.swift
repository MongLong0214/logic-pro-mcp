import Foundation

extension SetupDoctor {
    static func productionKeyCommandsPresetStaged() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Audio Music Apps/Key Commands/LogicProMCP-KeyCommands.plist")
            .path
        return FileManager.default.fileExists(atPath: path)
    }


    static func productionMCUPortReferenceProbe(
        fileExistsAtPath: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        runCommand: (String, [String], TimeInterval) -> CommandResult = { executable, arguments, timeout in
            SetupDoctor.runProductionCommand(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) -> MCUPortReferenceProbe {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.logic.pro.cs")
            .path
        guard fileExistsAtPath(path) else { return .sourceMissing }
        let result = runCommand("/usr/bin/strings", [path], 1.5)
        guard case let .completed(output) = result, output.exitCode == 0 else {
            return .indeterminate(reason: result.failureReason ?? "unknown_failure")
        }
        return output.stdout.contains("LogicProMCP-MCU-Internal") ? .found : .confirmedAbsent
    }


}
