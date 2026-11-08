import Darwin
import Foundation

enum MIDIKeyCommandBindingRecordStoreError: Error, Equatable {
    case invalidPortName
    case nonCatalogEntry(String)
    case duplicateOperation(String)
    case unsupportedSchema(Int)
}

/// A persisted observation of one functionally verified MIDI Key Command binding.
///
/// Records are not approvals and never become readiness by themselves. Callers must
/// still prove that the current process owns the named port before promoting any row.
struct MIDIKeyCommandBindingRecord: Codable, Equatable, Sendable {
    let operation: String
    let portName: String
    let channel: UInt8
    let cc: UInt8
    let value: UInt8
    let observedAt: Date

    enum CodingKeys: String, CodingKey {
        case operation
        case portName = "port_name"
        case channel
        case cc
        case value
        case observedAt = "observed_at"
    }
}

private struct MIDIKeyCommandBindingRecordFile: Codable {
    let schema: Int
    let records: [MIDIKeyCommandBindingRecord]
}

/// Atomic storage for the complete set observed by one successful setup run.
///
/// Reads fail closed to no observations. Replacements validate every row against
/// the current catalog and refuse to overwrite an existing unreadable file.
actor MIDIKeyCommandBindingRecordStore {
    private let fileURL: URL

    private static let schema = 1
    private static let directoryPermissions: NSNumber = 0o700
    private static let filePermissions: NSNumber = 0o600
    private static let lockAcquireTimeout: TimeInterval = 5
    private static let lockRetryIntervalMicroseconds: UInt32 = 25_000

    init(fileURL: URL = MIDIKeyCommandBindingRecordStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/LogicProMCP/midi-key-commands.json"
            )
    }

    func replaceVerified(
        entries: [MIDIKeyCommandBindingCatalog.Entry],
        portName: String,
        observedAt: Date = Date(),
        catalog: [MIDIKeyCommandBindingCatalog.Entry] = MIDIKeyCommandBindingCatalog.entries
    ) throws {
        guard !portName.isEmpty, !portName.contains("\0") else {
            throw MIDIKeyCommandBindingRecordStoreError.invalidPortName
        }

        var operations: Set<String> = []
        for entry in entries {
            guard operations.insert(entry.operation).inserted else {
                throw MIDIKeyCommandBindingRecordStoreError.duplicateOperation(entry.operation)
            }
            guard catalog.contains(entry) else {
                throw MIDIKeyCommandBindingRecordStoreError.nonCatalogEntry(entry.operation)
            }
        }

        let records = entries
            .map { entry in
                MIDIKeyCommandBindingRecord(
                    operation: entry.operation,
                    portName: portName,
                    channel: entry.channel,
                    cc: entry.cc,
                    value: entry.value,
                    observedAt: observedAt
                )
            }
            .sorted { $0.operation < $1.operation }
        try replaceLocked(.init(schema: Self.schema, records: records))
    }

    func matchingRecords(
        portName: String,
        channel: UInt8,
        catalog: [MIDIKeyCommandBindingCatalog.Entry] = MIDIKeyCommandBindingCatalog.entries
    ) -> [MIDIKeyCommandBindingRecord] {
        guard !portName.isEmpty,
              let file = loadLenient(),
              file.schema == Self.schema else {
            return []
        }

        return catalog.compactMap { entry in
            guard entry.channel == channel else { return nil }
            let candidates = file.records.filter {
                $0.operation == entry.operation
                    && $0.portName == portName
                    && $0.channel == channel
            }
            guard candidates.count == 1, let record = candidates.first,
                  record.cc == entry.cc,
                  record.value == entry.value else {
                return nil
            }
            return record
        }.sorted { $0.operation < $1.operation }
    }

    private func loadLenient() -> MIDIKeyCommandBindingRecordFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .init(schema: Self.schema, records: [])
        }
        do {
            return try decodeFile()
        } catch {
            Log.warn(
                "Failed to read MIDI Key Command binding records: \(error)",
                subsystem: "keycmd"
            )
            return nil
        }
    }

    private func decodeFile() throws -> MIDIKeyCommandBindingRecordFile {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(MIDIKeyCommandBindingRecordFile.self, from: data)
    }

    private func validateExistingFileForReplacement() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let existing = try decodeFile()
        guard existing.schema == Self.schema else {
            throw MIDIKeyCommandBindingRecordStoreError.unsupportedSchema(existing.schema)
        }
    }

    private func replaceLocked(_ file: MIDIKeyCommandBindingRecordFile) throws {
        let lockFD = try lockFileDescriptor()
        defer {
            _ = flock(lockFD, LOCK_UN)
            _ = close(lockFD)
        }
        try validateExistingFileForReplacement()
        try save(file)
    }

    private func save(_ file: MIDIKeyCommandBindingRecordFile) throws {
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
        if !directoryAlreadyExists || directory.lastPathComponent == "LogicProMCP" {
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: Self.directoryPermissions],
                    ofItemAtPath: directory.path
                )
            } catch {
                if !directoryAlreadyExists { throw error }
                Log.warn(
                    "Failed to harden MIDI Key Command record directory permissions: \(error)",
                    subsystem: "keycmd"
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

    private func lockFileDescriptor() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )

        let descriptor = open(
            fileURL.appendingPathExtension("lock").path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let deadline = Date().addingTimeInterval(Self.lockAcquireTimeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let errorNumber = errno
            if errorNumber != EWOULDBLOCK {
                _ = close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
            }
            if Date() >= deadline {
                _ = close(descriptor)
                throw POSIXError(.ETIMEDOUT)
            }
            usleep(Self.lockRetryIntervalMicroseconds)
        }
        return descriptor
    }
}
