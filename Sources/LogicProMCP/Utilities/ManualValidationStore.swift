import Darwin
import Foundation

enum ManualValidationChannel: String, Sendable, CaseIterable, Codable {
    case midiKeyCommands = "MIDIKeyCommands"
    case scripter = "Scripter"

    static func parse(_ value: String) -> ManualValidationChannel? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "midikeycommands", "keycommands", "keycmd":
            return .midiKeyCommands
        case "scripter":
            return .scripter
        default:
            return nil
        }
    }
}

struct ManualValidationApproval: Sendable, Codable, Equatable {
    enum Kind: String, Sendable, Codable {
        case approved
        case intentionallySkipped = "intentionally_skipped"
    }

    let approvedAt: Date
    let note: String?
    let kind: Kind

    enum CodingKeys: String, CodingKey {
        case approvedAt = "approved_at"
        case note
        case kind
    }

    init(
        approvedAt: Date,
        note: String?,
        kind: Kind = .approved
    ) {
        self.approvedAt = approvedAt
        self.note = note
        self.kind = kind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvedAt = try container.decode(Date.self, forKey: .approvedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .approved
    }
}

protocol ManualValidationStoring: Actor {
    func isApproved(_ channel: ManualValidationChannel) async -> Bool
    func approval(for channel: ManualValidationChannel) async -> ManualValidationApproval?
    func approve(_ channel: ManualValidationChannel, note: String?) async throws
    func revoke(_ channel: ManualValidationChannel) async throws
    func list() async -> [ManualValidationChannel: ManualValidationApproval]
}

enum ManualValidationStoreHealth: Equatable, Sendable {
    case ok
    case corrupt(String)
}

extension ManualValidationStoring {
    func skip(_ channel: ManualValidationChannel, note: String?) async throws {
        throw POSIXError(.ENOTSUP)
    }

    func health() async -> ManualValidationStoreHealth {
        .ok
    }
}

private struct ManualValidationFile: Codable {
    var approvals: [String: ManualValidationApproval] = [:]
}

actor ManualValidationStore: ManualValidationStoring {
    struct Runtime: Sendable {
        let beforeSaveWhileLocked: (@Sendable () async -> Void)?

        static let production = Runtime(beforeSaveWhileLocked: nil)
    }

    private let fileURL: URL
    private let runtime: Runtime
    private static let directoryPermissions: NSNumber = 0o700
    private static let filePermissions: NSNumber = 0o600

    init(
        fileURL: URL = ManualValidationStore.defaultFileURL(),
        runtime: Runtime = .production
    ) {
        self.fileURL = fileURL
        self.runtime = runtime
    }

    static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LogicProMCP/operator-approvals.json")
    }

    static func summary(for approvals: [ManualValidationChannel: ManualValidationApproval]) -> String {
        guard !approvals.isEmpty else {
            return "No legacy manual-channel compatibility records."
        }

        let formatter = ISO8601DateFormatter()
        let lines = approvals
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { channel, approval -> String in
                let noteSuffix: String
                if let note = approval.note, !note.isEmpty {
                    noteSuffix = " — \(note)"
                } else {
                    noteSuffix = ""
                }
                let label = approval.kind == .approved
                    ? "legacy assertion recorded"
                    : "legacy skip recorded"
                return "\(channel.rawValue): \(label) at \(formatter.string(from: approval.approvedAt))\(noteSuffix)"
            }
        return lines.joined(separator: "\n")
    }

    func isApproved(_ channel: ManualValidationChannel) async -> Bool {
        await approval(for: channel)?.kind == .approved
    }

    func approval(for channel: ManualValidationChannel) async -> ManualValidationApproval? {
        let file = loadFile()
        guard let decision = file.approvals[channel.rawValue], decision.kind == .approved else {
            return nil
        }
        return decision
    }

    func approve(_ channel: ManualValidationChannel, note: String?) async throws {
        try await mutateLockedFile { file in
            file.approvals[channel.rawValue] = ManualValidationApproval(
                approvedAt: Date(),
                note: normalized(note),
                kind: .approved
            )
        }
    }

    func skip(_ channel: ManualValidationChannel, note: String?) async throws {
        try await mutateLockedFile { file in
            file.approvals[channel.rawValue] = ManualValidationApproval(
                approvedAt: Date(),
                note: normalized(note),
                kind: .intentionallySkipped
            )
        }
    }

    func revoke(_ channel: ManualValidationChannel) async throws {
        try await mutateLockedFile { file in
            file.approvals.removeValue(forKey: channel.rawValue)
        }
    }

    func list() async -> [ManualValidationChannel: ManualValidationApproval] {
        let file = loadFile()
        var result: [ManualValidationChannel: ManualValidationApproval] = [:]
        for channel in ManualValidationChannel.allCases {
            if let approval = file.approvals[channel.rawValue] {
                result[channel] = approval
            }
        }
        return result
    }

    func health() async -> ManualValidationStoreHealth {
        loadFileResult().health
    }

    /// Lenient read for the read-only `list()`/`status()` paths: an unreadable or
    /// corrupt store degrades to "no approvals" rather than failing the query.
    private func loadFile() -> ManualValidationFile {
        loadFileResult().file
    }

    private func loadFileResult() -> (file: ManualValidationFile, health: ManualValidationStoreHealth) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (.init(), .ok)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return (try JSONDecoder().decode(ManualValidationFile.self, from: data), .ok)
        } catch {
            Log.warn("Failed to read manual validation store: \(error)", subsystem: "validation")
            return (.init(), .corrupt("json_decode_failed"))
        }
    }

    /// Strict read for the read-modify-write mutate path. A missing file
    /// legitimately starts empty, but an existing-but-undecodable file MUST abort
    /// the mutation: `mutateLockedFile` rewrites the WHOLE struct atomically, so
    /// silently starting from an empty store on a transient read/decode failure
    /// would persist only the one channel being changed and destroy every other
    /// operator approval. Fail closed instead.
    private func loadFileForMutation() throws -> ManualValidationFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .init()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ManualValidationFile.self, from: data)
    }

    private func mutateLockedFile(
        _ mutation: (inout ManualValidationFile) throws -> Void
    ) async throws {
        let lockFD = try lockFileDescriptor()
        defer {
            _ = flock(lockFD, LOCK_UN)
            _ = close(lockFD)
        }

        var file = try loadFileForMutation()
        try mutation(&file)
        if let beforeSaveWhileLocked = runtime.beforeSaveWhileLocked {
            await beforeSaveWhileLocked()
        }
        try save(file)
    }

    private func save(_ file: ManualValidationFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let directoryAlreadyExists = fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        if !directoryAlreadyExists || Self.shouldHardenExistingDirectory(directory) {
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: Self.directoryPermissions],
                    ofItemAtPath: directory.path
                )
            } catch {
                if !directoryAlreadyExists {
                    throw error
                }
                Log.warn(
                    "Failed to harden existing manual validation directory permissions: \(error)",
                    subsystem: "validation"
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: fileURL.path
        )
    }

    private static func shouldHardenExistingDirectory(_ directory: URL) -> Bool {
        directory.lastPathComponent == "LogicProMCP"
    }

    private func normalized(_ note: String?) -> String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func lockFileDescriptor() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )

        let lockPath = fileURL.appendingPathExtension("lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        // Acquire the advisory lock WITHOUT parking the actor's cooperative
        // executor indefinitely: a blocking flock(LOCK_EX) would stall the actor
        // for as long as a live peer holds the lock. Use non-blocking attempts
        // with a bounded retry budget and surface a typed timeout instead.
        let deadline = Date().addingTimeInterval(Self.lockAcquireTimeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            if err != EWOULDBLOCK {
                let code = POSIXErrorCode(rawValue: err) ?? .EIO
                _ = close(descriptor)
                throw POSIXError(code)
            }
            if Date() >= deadline {
                _ = close(descriptor)
                throw POSIXError(.ETIMEDOUT)
            }
            usleep(Self.lockRetryIntervalMicroseconds)
        }
        return descriptor
    }

    /// Bounded wait for the cross-process approval lock (rare operator admin
    /// op, latency-insensitive) so a stalled peer can never park the actor.
    private static let lockAcquireTimeout: TimeInterval = 5
    private static let lockRetryIntervalMicroseconds: UInt32 = 25_000
}
