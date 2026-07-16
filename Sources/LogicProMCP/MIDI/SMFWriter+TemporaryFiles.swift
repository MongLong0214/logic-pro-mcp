import Darwin
import Foundation

extension SMFWriter {
    struct TemporaryMIDIFile {
        let fileURL: URL
        let directoryURL: URL
    }

    private final class ManagedMIDIFileRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func register(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            paths.insert(SMFWriter.canonicalPath(url))
        }

        func unregisterDirectory(_ url: URL) {
            let prefix = SMFWriter.canonicalPath(url) + "/"
            lock.lock()
            defer { lock.unlock() }
            paths = paths.filter { !$0.hasPrefix(prefix) }
        }

        func contains(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.contains(SMFWriter.canonicalPath(URL(fileURLWithPath: path)))
        }
    }

    private static let managedMIDIFiles = ManagedMIDIFileRegistry()

    static func temporaryMIDIFile(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> TemporaryMIDIFile {
        let directoryURL = try makePrivateTemporaryDirectory(baseDirectory: baseDirectory)
        let file = TemporaryMIDIFile(
            fileURL: directoryURL.appendingPathComponent("\(UUID().uuidString).mid"),
            directoryURL: directoryURL
        )
        managedMIDIFiles.register(file.fileURL)
        return file
    }

    static func cleanupTemporaryMIDIFile(_ file: TemporaryMIDIFile) {
        managedMIDIFiles.unregisterDirectory(file.directoryURL)
        try? FileManager.default.removeItem(at: file.directoryURL)
    }

    static func isManagedTemporaryMIDIFile(_ path: String) -> Bool {
        managedMIDIFiles.contains(path)
    }

    static func temporaryDirectoryPrefix(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String {
        let basePath = baseDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let normalizedBasePath = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return "\(normalizedBasePath)/LogicProMCP-\(getuid())-"
    }

    static func cleanupOrphanFiles(
        in dir: String = FileManager.default.temporaryDirectory.path,
        olderThan: TimeInterval = 300,
        legacyManagedDirectories: Set<String>? = nil
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dir) else { return }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: dir)) == nil else { return }

        let scopedDirectory = canonicalPath(URL(fileURLWithPath: dir, isDirectory: true))
        let isLegacyDirectory = (legacyManagedDirectories ?? legacyManagedImportDirectories())
            .contains(scopedDirectory)
        let cutoff = Date().addingTimeInterval(-olderThan)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return }

        for name in entries {
            let isCandidate: Bool
            if isLegacyDirectory {
                isCandidate = name.hasSuffix(".mid")
            } else {
                isCandidate = name.hasPrefix("LogicProMCP-\(getuid())-")
            }
            guard isCandidate else { continue }

            let fullPath = "\(dir)/\(name)"
            guard (try? fileManager.destinationOfSymbolicLink(atPath: fullPath)) == nil else { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  modifiedAt < cutoff else { continue }

            if isLegacyDirectory, name.hasSuffix(".mid") {
                // The legacy /tmp roots are world-writable, so only reclaim .mid
                // files THIS uid owns — otherwise another local user could plant
                // *.mid here and have this process delete them. Matches the
                // uid-scoping the new-style directory branch already enforces.
                guard (attributes[.ownerAccountID] as? NSNumber)?.uintValue == UInt(getuid()) else { continue }
                try? fileManager.removeItem(atPath: fullPath)
            } else if name.hasPrefix("LogicProMCP-\(getuid())-"),
                      (attributes[.type] as? FileAttributeType) == .typeDirectory,
                      (attributes[.ownerAccountID] as? NSNumber)?.uintValue == UInt(getuid()) {
                // Match on the uid in the directory NAME and on-disk ownership —
                // the name alone is attacker-controllable, so verify the real
                // owner before deleting (the uid-scoping the legacy branch refers
                // to). Harmless in $TMPDIR (0700); defense-in-depth otherwise.
                // Keep the in-memory registry consistent with disk so a future
                // mid-session sweep can never delete a directory while its .mid
                // path is still registered as live.
                managedMIDIFiles.unregisterDirectory(URL(fileURLWithPath: fullPath, isDirectory: true))
                try? fileManager.removeItem(atPath: fullPath)
            }
        }
    }

    static func cleanupLegacyOrphanFiles(
        olderThan: TimeInterval = 300,
        legacyManagedDirectories: Set<String>? = nil
    ) {
        let directories = legacyManagedDirectories ?? legacyManagedImportDirectories()
        for directory in directories {
            cleanupOrphanFiles(
                in: directory,
                olderThan: olderThan,
                legacyManagedDirectories: directories
            )
        }
    }

    static func cleanupStartupOrphanFiles(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        olderThan: TimeInterval = 300,
        legacyManagedDirectories: Set<String>? = nil
    ) {
        cleanupOrphanFiles(in: baseDirectory.path, olderThan: olderThan)
        cleanupLegacyOrphanFiles(
            olderThan: olderThan,
            legacyManagedDirectories: legacyManagedDirectories
        )
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func legacyManagedImportDirectories() -> Set<String> {
        Set(
            [
                "/tmp/LogicProMCP",
                "/private/tmp/LogicProMCP",
            ].map { canonicalPath(URL(fileURLWithPath: $0, isDirectory: true)) }
        )
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
        // mkdtemp() creates the directory with 0700 per POSIX, so no extra chmod
        // is needed. The previous explicit setAttributes was redundant AND a leak
        // hazard: if it threw, the just-created directory was orphaned on disk
        // (unregistered, so only the periodic sweep could ever reclaim it).
        return URL(fileURLWithPath: String(cString: created), isDirectory: true)
    }
}
