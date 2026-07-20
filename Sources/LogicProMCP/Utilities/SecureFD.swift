import Darwin
import Foundation

/// Secure filesystem primitive for confined, symlink-safe file publication on macOS.
///
/// Opens/creates/publishes strictly through single-component `*at` calls from an
/// explicitly trusted base descriptor, so no component — intermediate or final —
/// can be a symlink or a rebound/renamed-in inode that escapes the base. macOS
/// has no `openat2(RESOLVE_BENEATH)`, so a ~1-syscall + post-verify residual is
/// irreducible; this primitive defeats the realistic attacks (symlink, inode
/// rebind, ancestor/leaf rename-out, hardlink, mkdir→open swap-in) and never
/// claims zero-race confinement.
///
/// The primitive is intentionally independent of its callers: audit-receipt and
/// support-bundle publication wire onto it separately.
enum SecureFD {
    enum FDError: Error, Equatable {
        case badComponent(String)             // empty / "." / ".." / contains "/" or NUL
        case baseNotUnderHome(String)         // production base-path injection guard
        case componentOpenFailed(component: String, errno: Int32)
        case verificationMismatch(component: String)   // pass A != pass B (mid-walk rebind)
        case notDirectory(String)
        case notRegularFile(String)
        case notExclusive(String)             // st_nlink != 1 (hardlink) or already exists
        case stagingNotEmpty(String)
        case fullfsyncFailed(errno: Int32)
        case teardownFailed(errno: Int32)
    }

    /// Publish/append durability outcome — a value, never inferred. `durableSuccess`
    /// means ONLY that the matched object + directory metadata completed the
    /// ordered stable-storage chain at the post-rename verification point. It is
    /// NOT a zero-race, continuous-ancestry, or TOCTOU-closed claim.
    enum Outcome: Equatable {
        case durableSuccess
        case rolledBackClean
        case committedNotDurable
        case rollbackVerifyFailed
        case rollbackIncomplete
    }

    typealias Identity = (dev: dev_t, ino: ino_t)

    static func sameIdentity(_ a: Identity, _ b: Identity) -> Bool {
        a.dev == b.dev && a.ino == b.ino
    }

    // MARK: - Component validation

    /// A single, non-ambiguous path component. Rejects empty, `.`, `..`, and any
    /// component containing `/` or NUL, so no multi-component lookup can slip in.
    static func validateComponent(_ c: String) throws {
        guard !c.isEmpty, c != ".", c != "..",
              !c.contains("/"), !c.utf8.contains(0) else {
            throw FDError.badComponent(c)
        }
    }

    private static func identity(ofFD fd: Int32) -> Identity {
        var st = stat()
        _ = fstat(fd, &st)
        return (st.st_dev, st.st_ino)
    }

    // MARK: - Trusted base (base-path-injection guarded)

    /// The production trusted base is the current user's home directory, opened
    /// once (its own path is the single trusted boundary). Release builds accept
    /// no other base — no arbitrary base-path injection.
    static func openHomeBase() throws -> Int32 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fd = home.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard fd >= 0 else { throw FDError.componentOpenFailed(component: home.path, errno: errno) }
        return fd
    }

    #if DEBUG
    /// TEST-ONLY (compiled out of release): supplies a trusted base directory for
    /// tests operating under a temp root, and a one-shot post-walk-passA hook so an
    /// intermediate/final rebind can be injected deterministically between the two
    /// verification walks. Neither symbol exists in a release binary.
    nonisolated(unsafe) static var _testBaseOverride: URL?
    nonisolated(unsafe) static var _testAfterPassAHook: (() -> Void)?
    #endif

    /// Open the trusted base for `target`: production = home (target MUST be under
    /// home); DEBUG = an explicit test override. Returns the base fd + the
    /// base-relative components down to `target`.
    static func openTrustedBase(for target: URL) throws -> (baseFD: Int32, relative: [String]) {
        let targetComps = target.standardizedFileURL.pathComponents   // ["/", ...]
        #if DEBUG
        if let override = _testBaseOverride {
            let baseComps = override.standardizedFileURL.pathComponents
            guard targetComps.count > baseComps.count,
                  Array(targetComps.prefix(baseComps.count)) == baseComps else {
                throw FDError.baseNotUnderHome(target.path)
            }
            let fd = override.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            guard fd >= 0 else { throw FDError.componentOpenFailed(component: override.path, errno: errno) }
            return (fd, Array(targetComps.dropFirst(baseComps.count)))
        }
        #endif
        let homeComps = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        guard targetComps.count > homeComps.count,
              Array(targetComps.prefix(homeComps.count)) == homeComps else {
            throw FDError.baseNotUnderHome(target.path)
        }
        let baseFD = try openHomeBase()
        return (baseFD, Array(targetComps.dropFirst(homeComps.count)))
    }

    // MARK: - Verified walk (mid-walk rebind caught via A==B)

    /// Walk `relative` from `baseFD` twice with single-component
    /// `openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` and require the per-component
    /// `(dev,ino)` vectors to match (pass A == pass B), so a rebind between the two
    /// passes is caught. Returns the verified leaf dir fd (caller owns it) and the
    /// id vector. If `expected` is provided, each id must also equal it.
    static func walkVerified(baseFD: Int32, _ relative: [String],
                             expected: [Identity]? = nil) throws -> (fd: Int32, ids: [Identity]) {
        for c in relative { try validateComponent(c) }
        let (fdA, idsA) = try walkOnce(baseFD: baseFD, relative)
        // Pass A exists only to produce its identity vector; its fd is closed
        // immediately so no failure in the verification pass can leak it. The
        // verification pass is authoritative and supplies the returned fd.
        close(fdA)
        #if DEBUG
        if let hook = _testAfterPassAHook { _testAfterPassAHook = nil; hook() }
        #endif
        let (fdB, idsB) = try walkOnce(baseFD: baseFD, relative)
        guard idsA.count == idsB.count else {
            close(fdB); throw FDError.verificationMismatch(component: relative.last ?? "")
        }
        for i in idsA.indices where !sameIdentity(idsA[i], idsB[i]) {
            close(fdB); throw FDError.verificationMismatch(component: relative[i])
        }
        if let expected {
            guard expected.count == idsB.count else {
                close(fdB); throw FDError.verificationMismatch(component: relative.last ?? "")
            }
            for i in idsB.indices where !sameIdentity(expected[i], idsB[i]) {
                close(fdB); throw FDError.verificationMismatch(component: relative[i])
            }
        }
        return (fdB, idsB)
    }

    private static func walkOnce(baseFD: Int32, _ relative: [String]) throws -> (fd: Int32, ids: [Identity]) {
        // Start from a dup of the base so ownership of the returned chain is ours
        // and the caller's base fd is never closed by us.
        var dirFD = dup(baseFD)
        guard dirFD >= 0 else { throw FDError.componentOpenFailed(component: "<base-dup>", errno: errno) }
        var ids: [Identity] = []
        for comp in relative {
            let next = comp.withCString { openat(dirFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(dirFD)
            guard next >= 0 else { throw FDError.componentOpenFailed(component: comp, errno: errno) }
            dirFD = next
            ids.append(identity(ofFD: dirFD))
        }
        return (dirFD, ids)
    }

    // MARK: - File opens — O_NOFOLLOW + regular-file + exclusivity

    /// Exclusive create relative to a verified parent fd. Fails closed if the name
    /// exists (defeats pre-planted file) and if `st_nlink != 1` (defeats hardlink).
    static func createFile(parentFD: Int32, name: String, mode: mode_t) throws -> Int32 {
        try validateComponent(name)
        let fd = name.withCString {
            openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        }
        guard fd >= 0 else { throw FDError.componentOpenFailed(component: name, errno: errno) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw FDError.notRegularFile(name)
        }
        guard st.st_nlink == 1 else { close(fd); throw FDError.notExclusive(name) }
        return fd
    }

    /// Open an existing regular file for append relative to a verified parent fd:
    /// no-follow, non-blocking (a fifo fails fast), regular-file, `st_nlink == 1`.
    static func openAppend(parentFD: Int32, name: String) throws -> Int32 {
        try validateComponent(name)
        let fd = name.withCString {
            openat(parentFD, $0, O_WRONLY | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw FDError.componentOpenFailed(component: name, errno: errno) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw FDError.notRegularFile(name)
        }
        guard st.st_nlink == 1 else { close(fd); throw FDError.notExclusive(name) }
        return fd
    }

    /// Open an existing regular file for read relative to a verified parent fd.
    static func openRead(parentFD: Int32, name: String) throws -> Int32 {
        try validateComponent(name)
        let fd = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw FDError.componentOpenFailed(component: name, errno: errno) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw FDError.notRegularFile(name)
        }
        return fd
    }

    // MARK: - Directory create — mkdirat + no-follow open + empty check

    /// Create + open a directory relative to a verified parent fd, then require it
    /// is empty (defeats mkdir→open swap-in of a populated dir). Returns the dir fd
    /// + its identity.
    static func makeEmptyDir(parentFD: Int32, name: String, mode: mode_t) throws -> (fd: Int32, id: Identity) {
        try validateComponent(name)
        guard name.withCString({ mkdirat(parentFD, $0, mode) }) == 0 else {
            throw FDError.componentOpenFailed(component: name, errno: errno)
        }
        let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw FDError.componentOpenFailed(component: name, errno: errno) }
        do {
            try assertEmpty(dirFD: fd, label: name)
        } catch {
            close(fd); throw error
        }
        return (fd, identity(ofFD: fd))
    }

    /// True/throw: the directory fd contains only `.`/`..`. Enumerates through a
    /// DUP (fdopendir consumes the fd it is given on Darwin).
    static func assertEmpty(dirFD: Int32, label: String) throws {
        let dupFD = dup(dirFD)
        guard dupFD >= 0 else { throw FDError.componentOpenFailed(component: label, errno: errno) }
        guard let dir = fdopendir(dupFD) else {
            close(dupFD); throw FDError.componentOpenFailed(component: label, errno: errno)
        }
        defer { closedir(dir) }   // closes the underlying dup fd
        while let ent = readdir(dir) {
            let n = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if n != "." && n != ".." { throw FDError.stagingNotEmpty(label) }
        }
    }

    // MARK: - Durability — F_FULLFSYNC, fail-closed

    static func fullfsync(_ fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC) != -1 else { throw FDError.fullfsyncFailed(errno: errno) }
    }

    // MARK: - Rollback teardown — fd-relative, no path rebuild

    /// Recursively remove a directory relative to its verified parent fd, entirely
    /// through descriptors: `fdopendir` on a DUP, classify children with
    /// `fstatat(AT_SYMLINK_NOFOLLOW)`, recurse into subdirs via
    /// `openat(O_DIRECTORY|O_NOFOLLOW)`, `unlinkat` files (symlink children unlinked
    /// as links, never followed), then `unlinkat(AT_REMOVEDIR)` the now-empty dir.
    static func teardownTree(parentFD: Int32, name: String) throws {
        try validateComponent(name)
        let dirFD = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dirFD >= 0 else { throw FDError.teardownFailed(errno: errno) }
        try removeChildrenThenSelf(dirFD: dirFD, parentFD: parentFD, name: name)
    }

    private static func removeChildrenThenSelf(dirFD: Int32, parentFD: Int32, name: String) throws {
        // This function owns dirFD; the defer is its single close, so every
        // error path — including a throw out of the recursive call — releases it.
        defer { close(dirFD) }
        let dupFD = dup(dirFD)
        guard dupFD >= 0 else { throw FDError.teardownFailed(errno: errno) }
        guard let dir = fdopendir(dupFD) else {
            close(dupFD); throw FDError.teardownFailed(errno: errno)
        }
        var children: [(name: String, isDir: Bool)] = []
        while let ent = readdir(dir) {
            let n = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if n == "." || n == ".." { continue }
            var st = stat()
            let rc = n.withCString { fstatat(dirFD, $0, &st, AT_SYMLINK_NOFOLLOW) }
            guard rc == 0 else { closedir(dir); throw FDError.teardownFailed(errno: errno) }
            children.append((n, (st.st_mode & S_IFMT) == S_IFDIR))   // symlinks classified as non-dir → unlinked as links
        }
        closedir(dir)   // closes dupFD
        for child in children {
            if child.isDir {
                let sub = child.name.withCString { openat(dirFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard sub >= 0 else { throw FDError.teardownFailed(errno: errno) }
                try removeChildrenThenSelf(dirFD: sub, parentFD: dirFD, name: child.name)
            } else {
                guard child.name.withCString({ unlinkat(dirFD, $0, 0) }) == 0 else {
                    throw FDError.teardownFailed(errno: errno)
                }
            }
        }
        // An open descriptor does not pin a directory in the namespace, so the
        // remove can precede the deferred close.
        guard name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) == 0 else {
            throw FDError.teardownFailed(errno: errno)
        }
    }
}
