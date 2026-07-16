import Foundation

package enum LogicProMCPMain {
    static func defaultRunner(
        arguments: [String],
        permissionCheck: () -> PermissionChecker.PermissionStatus = PermissionChecker.check,
        serverFactory: () -> any ServerStarting = { LogicProServer() },
        approvalStoreFactory: () -> any ManualValidationStoring = { ManualValidationStore() },
        doctorRuntime: SetupDoctor.Runtime = .production,
        lifecycleRuntime: SetupLifecycle.Runtime = .production,
        writeStdout: (String) -> Void = { message in
            FileHandle.standardOutput.write(Data(message.utf8))
        },
        writeStderr: (String) -> Void = { message in
            FileHandle.standardError.write(Data(message.utf8))
        }
    ) async -> Int {
        await MainEntrypoint.run(
            arguments: arguments,
            permissionCheck: permissionCheck,
            serverFactory: serverFactory,
            approvalStoreFactory: approvalStoreFactory,
            doctorRuntime: doctorRuntime,
            lifecycleRuntime: lifecycleRuntime,
            writeStdout: writeStdout,
            writeStderr: writeStderr
        )
    }

    package static func exitCode(
        arguments: [String],
        runner: ([String]) async -> Int = { arguments in
            await LogicProMCPMain.defaultRunner(arguments: arguments)
        }
    ) async -> Int32 {
        Int32(await runner(arguments))
    }
}
