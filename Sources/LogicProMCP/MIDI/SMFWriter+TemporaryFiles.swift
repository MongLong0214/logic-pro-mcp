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

    /// Where a staged MIDI file goes: a root THIS PROCESS OWNS, never the shared user temporary
    /// directory.
    ///
    /// The reason is not tidiness. `record_sequence` hands the staged path to Logic's
    /// File ▸ Import ▸ MIDI File open panel, and that panel is a COLUMN VIEW: to show the file it
    /// must enumerate the file's parent directory. Under `$TMPDIR` the parent is shared with every
    /// other process on the machine — measured 2026-09-13 at 114,000 entries, most of them other
    /// projects' fixtures — and the panel simply never finishes.
    ///
    /// Measured in one panel, seconds apart, by reading the panel's own state: a path under
    /// `$TMPDIR` left `Import=false`, an `AXBusyIndicator` present and a `Loading…` label in the
    /// browser, still there after thirty seconds; a path whose ancestors are all small came back
    /// `Import=true`, no busy indicator, no label, at once. That is the whole of the "the first
    /// imports after a Logic relaunch fail and then it works forever" behaviour: once the
    /// directory listing is warm in the filesystem cache the panel can finish, which is why a
    /// second attempt usually lands and why the failure looked like flakiness for a day.
    ///
    /// The fallback to `$TMPDIR` keeps the operation working if the Caches root cannot be made;
    /// the import is slow there, not broken.
    static func importStagingRoot() -> URL {
        let manager = FileManager.default
        guard let caches = try? manager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else {
            return manager.temporaryDirectory
        }
        let root = caches
            .appendingPathComponent("LogicProMCP", isDirectory: true)
            .appendingPathComponent("smf", isDirectory: true)
        guard (try? manager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil, isPrivateOwnedDirectory(root) else {
            return manager.temporaryDirectory
        }
        return root
    }

    /// Whether a path is a REAL directory this uid owns and only this uid can write.
    ///
    /// `createDirectory(withIntermediateDirectories: true)` SUCCEEDS on a path that already
    /// exists — including a symlink pointing somewhere else entirely — and it applies the
    /// requested permissions only to what it creates. So the old code could have accepted a root
    /// somebody else prepared, and the staged file would have been written through it.
    ///
    /// `$TMPDIR` never needed this: macOS hands each user a per-boot 0700 directory, so the root
    /// was trustworthy by construction. Moving out of it (the open panel could not enumerate a
    /// directory shared with the whole machine) gave up that guarantee, and this is the part of it
    /// that has to be re-established rather than assumed.
    ///
    /// `lstat`, not `stat`: the question is what the NAME is, and `stat` would follow the symlink
    /// and answer about its target. A path that fails any clause falls back to `$TMPDIR`, which is
    /// slow for the import panel and safe.
    static func isPrivateOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard info.st_uid == getuid() else { return false }
        return (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    }

    static func temporaryMIDIFile(
        baseDirectory: URL = SMFWriter.importStagingRoot()
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
        baseDirectory: URL = SMFWriter.importStagingRoot()
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
        baseDirectory: URL = SMFWriter.importStagingRoot(),
        olderThan: TimeInterval = 300,
        legacyManagedDirectories: Set<String>? = nil
    ) {
        cleanupOrphanFiles(in: baseDirectory.path, olderThan: olderThan)
        // Sweep the OLD home too, or every staging directory written before this moved is left
        // behind forever. It is skipped when the staging root already IS the temporary directory,
        // which is the fallback path — sweeping it twice would be harmless but says something
        // untrue about what this call is for.
        let systemTemporary = FileManager.default.temporaryDirectory
        if canonicalPath(systemTemporary) != canonicalPath(baseDirectory) {
            cleanupOrphanFiles(in: systemTemporary.path, olderThan: olderThan)
        }
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
