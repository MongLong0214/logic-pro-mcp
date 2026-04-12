import Dispatch
import Foundation

protocol ServerStarting {
    func start() async throws
}

extension LogicProServer: ServerStarting {}

enum MainEntrypoint {
    static func run(
        arguments: [String],
        permissionCheck: () -> PermissionChecker.PermissionStatus = PermissionChecker.check,
        serverFactory: () -> any ServerStarting = { LogicProServer() },
        approvalStoreFactory: () -> any ManualValidationStoring = { ManualValidationStore() },
        writeStderr: (String) -> Void = { message in
            FileHandle.standardError.write(Data(message.utf8))
        }
    ) async -> Int {
        let approvalStore = approvalStoreFactory()

        if arguments.contains("--list-approvals") {
            let approvals = await approvalStore.list()
            writeStderr(ManualValidationStore.summary(for: approvals) + "\n")
            return 0
        }

        if let rawChannel = optionValue("--approve-channel", in: arguments) {
            guard let channel = ManualValidationChannel.parse(rawChannel) else {
                writeStderr("Unknown approval channel: \(rawChannel)\n")
                return 1
            }
            do {
                try await approvalStore.approve(channel, note: optionValue("--approval-note", in: arguments))
                writeStderr("Approved \(channel.rawValue) for runtime use.\n")
                return 0
            } catch {
                writeStderr("Failed to persist approval for \(channel.rawValue): \(error)\n")
                return 1
            }
        }

        if let rawChannel = optionValue("--revoke-channel", in: arguments) {
            guard let channel = ManualValidationChannel.parse(rawChannel) else {
                writeStderr("Unknown approval channel: \(rawChannel)\n")
                return 1
            }
            do {
                try await approvalStore.revoke(channel)
                writeStderr("Revoked approval for \(channel.rawValue).\n")
                return 0
            } catch {
                writeStderr("Failed to revoke approval for \(channel.rawValue): \(error)\n")
                return 1
            }
        }

        if arguments.contains("--check-permissions") {
            let status = permissionCheck()
            writeStderr(status.summary + "\n")
            return status.allGranted ? 0 : 1
        }

        // Install SIGTERM/SIGINT handlers for graceful shutdown
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler { exit(0) }
        intSource.setEventHandler { exit(0) }
        signalSource.resume()
        intSource.resume()

        do {
            try await serverFactory().start()
            return 0
        } catch {
            Log.error("Server failed: \(error)", subsystem: "main")
            return 1
        }
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
