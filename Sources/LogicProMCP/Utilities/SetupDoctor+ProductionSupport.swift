import Darwin
import Foundation

extension SetupDoctor {
    static func resolveProductionExecutablePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        if raw.contains("/") {
            let url: URL
            if raw.hasPrefix("/") {
                url = URL(fileURLWithPath: raw)
            } else {
                url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(raw)
            }
            return url.standardizedFileURL.path
        }

        guard let output = runProductionCommand(
            executable: "/usr/bin/which",
            arguments: [raw],
            timeout: 1.0
        )?.output, output.exitCode == 0 else {
            return nil
        }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    enum ProductionCommandResult: Equatable, Sendable {
        case completed(CommandOutput)
        case timedOut
        case spawnFailed(String)

        var output: CommandOutput? {
            if case let .completed(value) = self { return value }
            return nil
        }
    }

    static func runProductionCommand(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        enforceAllowlist: Bool = true
    ) -> ProductionCommandResult? {
        if enforceAllowlist, DoctorTool.resolve(executable) == nil {
            return .spawnFailed("doctor_tool_not_allowlisted")
        }
        switch BoundedProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout) {
        case let .completed(output):
            return .completed(
                CommandOutput(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
            )
        case .timedOut:
            return .timedOut
        case let .spawnFailed(message):
            return .spawnFailed(message)
        }
    }

    static func runProductionCommandForTesting(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProductionCommandResult? {
        runProductionCommand(executable: executable, arguments: arguments, timeout: timeout, enforceAllowlist: false)
    }

}
