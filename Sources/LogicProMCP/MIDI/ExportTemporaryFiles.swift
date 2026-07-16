import Darwin
import Foundation

enum ExportTemporaryFiles {
    struct TemporaryExportFile {
        let fileURL: URL
        let directoryURL: URL
    }

    private final class ManagedExportFileRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func register(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            paths.insert(ExportTemporaryFiles.canonicalPath(url))
        }

        func unregisterDirectory(_ url: URL) {
            let prefix = ExportTemporaryFiles.canonicalPath(url) + "/"
            lock.lock()
            defer { lock.unlock() }
            paths = paths.filter { !$0.hasPrefix(prefix) }
        }

        func contains(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.contains(ExportTemporaryFiles.canonicalPath(URL(fileURLWithPath: path)))
        }
    }

    private static let managedExportFiles = ManagedExportFileRegistry()

    static func temporaryExportFile(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> TemporaryExportFile {
        let directoryURL = try makePrivateTemporaryDirectory(baseDirectory: baseDirectory)
        let file = TemporaryExportFile(
            fileURL: directoryURL.appendingPathComponent("\(UUID().uuidString).mid"),
            directoryURL: directoryURL
        )
        managedExportFiles.register(file.fileURL)
        return file
    }

    static func cleanupTemporaryExportFile(_ file: TemporaryExportFile) {
        managedExportFiles.unregisterDirectory(file.directoryURL)
        try? FileManager.default.removeItem(at: file.directoryURL)
    }

    static func isManagedTemporaryExportFile(_ path: String) -> Bool {
        managedExportFiles.contains(path)
    }

    static func temporaryDirectoryPrefix(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String {
        let basePath = baseDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let normalizedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return "\(normalizedBasePath)/LogicProMCPExport-\(getuid())-"
    }

    static func cleanupOrphanFiles(
        in dir: String = FileManager.default.temporaryDirectory.path,
        olderThan: TimeInterval = 300
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dir) else { return }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: dir)) == nil else { return }

        let cutoff = Date().addingTimeInterval(-olderThan)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return }
        for name in entries {
            guard name.hasPrefix("LogicProMCPExport-\(getuid())-") else { continue }
            let fullPath = "\(dir)/\(name)"
            guard (try? fileManager.destinationOfSymbolicLink(atPath: fullPath)) == nil else { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  modifiedAt < cutoff,
                  (attributes[.type] as? FileAttributeType) == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uintValue == UInt(getuid()) else { continue }
            managedExportFiles.unregisterDirectory(URL(fileURLWithPath: fullPath, isDirectory: true))
            try? fileManager.removeItem(atPath: fullPath)
        }
    }

    static func cleanupStartupOrphanFiles(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        olderThan: TimeInterval = 300
    ) {
        cleanupOrphanFiles(in: baseDirectory.path, olderThan: olderThan)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func makePrivateTemporaryDirectory(baseDirectory: URL) throws -> URL {
        let template = temporaryDirectoryPrefix(baseDirectory: baseDirectory) + "XXXXXX"
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: template.utf8.count + 1)
        defer { buffer.deallocate() }
        _ = template.withCString { source in
            strcpy(buffer, source)
        }
        guard let created = mkdtemp(buffer) else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        return URL(fileURLWithPath: String(cString: created), isDirectory: true)
    }
}
