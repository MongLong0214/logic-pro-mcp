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
        case identityReadFailed(component: String, errno: Int32)
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

    /// The (device, inode) identity of an open descriptor, fail-closed: a
    /// failed read REFUSES the operation instead of returning the zeroed
    /// `stat` fields — a fabricated (0,0) identity from two failed reads
    /// would otherwise compare equal and pass verification.
    private static func identity(ofFD fd: Int32, label: String) throws -> Identity {
        var st = stat()
        var rc = fstat(fd, &st)
        #if DEBUG
        if _testForceIdentityFailureCount > 0 { _testForceIdentityFailureCount -= 1; rc = -1 }
        #endif
        guard rc == 0 else { throw FDError.identityReadFailed(component: label, errno: errno) }
        return (st.st_dev, st.st_ino)
    }

    /// Atomic close-on-exec duplication. Plain `dup()` CLEARS `FD_CLOEXEC` on
    /// the duplicate, which would make trusted directory descriptors heritable
    /// across a concurrent `exec` — every internal duplication flows through
    /// this single primitive instead.
    private static func dupCloexec(_ fd: Int32) -> Int32 {
        fcntl(fd, F_DUPFD_CLOEXEC, 0)
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
    /// TEST-ONLY (compiled out of release): narrow observation/injection seams
    /// so the lifecycle contract is provable deterministically. `_testBaseOverride`
    /// supplies a trusted base under a temp root; `_testAfterPassAHook` runs once
    /// between the two verification walks; `_testPassAClosedFDObserver` reports the
    /// exact descriptor number pass A released; `_testEnumerationFDObserver` sees
    /// every enumeration duplicate before `fdopendir` consumes it;
    /// `_testAfterClassificationHook` runs once after teardown classifies children;
    /// `_testForceIdentityFailureCount` fails that many identity reads. None of
    /// these symbols exists in a release binary.
    nonisolated(unsafe) static var _testBaseOverride: URL?
    nonisolated(unsafe) static var _testAfterPassAHook: (() -> Void)?
    nonisolated(unsafe) static var _testPassAClosedFDObserver: ((Int32) -> Void)?
    nonisolated(unsafe) static var _testEnumerationFDObserver: ((Int32) -> Void)?
    nonisolated(unsafe) static var _testAfterClassificationHook: (() -> Void)?
    nonisolated(unsafe) static var _testForceIdentityFailureCount = 0
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
        _testPassAClosedFDObserver?(fdA)
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
        var dirFD = dupCloexec(baseFD)
        guard dirFD >= 0 else { throw FDError.componentOpenFailed(component: "<base-dup>", errno: errno) }
        var ids: [Identity] = []
        for comp in relative {
            let next = comp.withCString { openat(dirFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            let openErrno = errno   // capture before close(2) can overwrite errno
            close(dirFD)
            guard next >= 0 else { throw FDError.componentOpenFailed(component: comp, errno: openErrno) }
            dirFD = next
            do { ids.append(try identity(ofFD: dirFD, label: comp)) }
            catch { close(dirFD); throw error }
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

    /// Open an existing regular file for read relative to a verified parent fd:
    /// no-follow, non-blocking, regular-file, `st_nlink == 1` — the same
    /// existing-file identity policy as `openAppend`, so a hardlink alias of a
    /// foreign inode cannot serve readback.
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
        guard st.st_nlink == 1 else { close(fd); throw FDError.notExclusive(name) }
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
            let id = try identity(ofFD: fd, label: name)
            return (fd, id)
        } catch {
            close(fd); throw error
        }
    }

    /// True/throw: the directory fd contains only `.`/`..`. Enumerates through a
    /// DUP (fdopendir consumes the fd it is given on Darwin).
    static func assertEmpty(dirFD: Int32, label: String) throws {
        let dupFD = dupCloexec(dirFD)
        guard dupFD >= 0 else { throw FDError.componentOpenFailed(component: label, errno: errno) }
        #if DEBUG
        _testEnumerationFDObserver?(dupFD)
        #endif
        guard let dir = fdopendir(dupFD) else {
            let e = errno; close(dupFD); throw FDError.componentOpenFailed(component: label, errno: e)
        }
        defer { closedir(dir) }   // closes the underlying dup fd
        // readdir returns NULL on BOTH end-of-directory and error; distinguish
        // them via errno so a readdir failure is never mistaken for an empty
        // directory (which would defeat the mkdir→open populated-swap defense).
        errno = 0
        while let ent = readdir(dir) {
            let n = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if n != "." && n != ".." { throw FDError.stagingNotEmpty(label) }
            errno = 0
        }
        guard errno == 0 else { throw FDError.componentOpenFailed(component: label, errno: errno) }
    }

    // MARK: - Durability — F_FULLFSYNC, fail-closed

    static func fullfsync(_ fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC) != -1 else { throw FDError.fullfsyncFailed(errno: errno) }
    }

    // MARK: - Rollback teardown — fd-relative, no path rebuild

    /// Recursively remove a directory relative to its verified parent fd, entirely
    /// through descriptors: classify with `fstatat(AT_SYMLINK_NOFOLLOW)`, open each
    /// directory `O_NOFOLLOW` and REQUIRE the opened object to match its classified
    /// `(dev,ino)` — a rename-swapped REAL directory (which `O_NOFOLLOW` cannot
    /// catch) is refused before anything inside it is touched. Files are likewise
    /// re-bound to their classified `(dev,ino)` immediately before `unlinkat`
    /// (symlink children unlinked as links, never followed), so a regular file
    /// renamed onto the name after classification is refused with zero deletion.
    /// The final `unlinkat(AT_REMOVEDIR)` re-binds the name to the directory that
    /// was actually emptied. Each identity-bind→syscall pair carries the same
    /// irreducible 1-syscall residual (macOS has no `openat2(RESOLVE_BENEATH)`).
    static func teardownTree(parentFD: Int32, name: String) throws {
        try validateComponent(name)
        var st = stat()
        guard name.withCString({ fstatat(parentFD, $0, &st, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw FDError.teardownFailed(errno: errno)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw FDError.notDirectory(name) }
        let expected: Identity = (st.st_dev, st.st_ino)
        let dirFD = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dirFD >= 0 else { throw FDError.teardownFailed(errno: errno) }
        do {
            let got = try identity(ofFD: dirFD, label: name)
            guard sameIdentity(got, expected) else { throw FDError.verificationMismatch(component: name) }
        } catch { close(dirFD); throw error }
        try removeChildrenThenSelf(dirFD: dirFD, parentFD: parentFD, name: name, expected: expected)
    }

    private static func removeChildrenThenSelf(dirFD: Int32, parentFD: Int32, name: String,
                                               expected: Identity) throws {
        // This function owns dirFD; the defer is its single close, so every
        // error path — including a throw out of the recursive call — releases it.
        defer { close(dirFD) }
        let dupFD = dupCloexec(dirFD)
        guard dupFD >= 0 else { throw FDError.teardownFailed(errno: errno) }
        #if DEBUG
        _testEnumerationFDObserver?(dupFD)
        #endif
        guard let dir = fdopendir(dupFD) else {
            let e = errno; close(dupFD); throw FDError.teardownFailed(errno: e)
        }
        var children: [(name: String, isDir: Bool, id: Identity)] = []
        // readdir returns NULL on end-of-directory AND on error; reset errno
        // around each call so a mid-enumeration failure is not mistaken for a
        // complete listing (which could leave children behind).
        errno = 0
        while let ent = readdir(dir) {
            let n = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if n != "." && n != ".." {
                var st = stat()
                let rc = n.withCString { fstatat(dirFD, $0, &st, AT_SYMLINK_NOFOLLOW) }
                guard rc == 0 else { let e = errno; closedir(dir); throw FDError.teardownFailed(errno: e) }
                // symlinks classified as non-dir → unlinked as links
                children.append((n, (st.st_mode & S_IFMT) == S_IFDIR, (st.st_dev, st.st_ino)))
            }
            errno = 0
        }
        let enumErrno = errno
        closedir(dir)   // closes dupFD
        guard enumErrno == 0 else { throw FDError.teardownFailed(errno: enumErrno) }
        #if DEBUG
        if let hook = _testAfterClassificationHook { _testAfterClassificationHook = nil; hook() }
        #endif
        for child in children {
            if child.isDir {
                let sub = child.name.withCString { openat(dirFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard sub >= 0 else { throw FDError.teardownFailed(errno: errno) }
                // The opened object must BE the directory that was classified;
                // a swapped-in real directory is refused with zero deletion.
                do {
                    let got = try identity(ofFD: sub, label: child.name)
                    guard sameIdentity(got, child.id) else { throw FDError.verificationMismatch(component: child.name) }
                } catch { close(sub); throw error }
                try removeChildrenThenSelf(dirFD: sub, parentFD: dirFD, name: child.name, expected: child.id)
            } else {
                // Re-bind the name to the classified inode immediately before the
                // unlink: a regular file renamed onto this name after classification
                // (a victim file moved in) has a different (dev,ino) and is refused
                // with ZERO deletion — the symmetric defense to the subdirectory
                // identity bind above. The fstatat→unlinkat window is the same
                // irreducible 1-syscall residual documented for the final rmdir.
                var st = stat()
                guard child.name.withCString({ fstatat(dirFD, $0, &st, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    throw FDError.teardownFailed(errno: errno)
                }
                guard sameIdentity((st.st_dev, st.st_ino), child.id) else {
                    throw FDError.verificationMismatch(component: child.name)
                }
                guard child.name.withCString({ unlinkat(dirFD, $0, 0) }) == 0 else {
                    throw FDError.teardownFailed(errno: errno)
                }
            }
        }
        // Final removal re-binds the NAME to the directory that was actually
        // emptied. The fstatat→unlinkat window is the irreducible final-syscall
        // residual documented in the type comment; it is not claimed away. An
        // open descriptor does not pin a directory in the namespace, so the
        // remove can precede the deferred close.
        var fin = stat()
        guard name.withCString({ fstatat(parentFD, $0, &fin, AT_SYMLINK_NOFOLLOW) }) == 0,
              sameIdentity((fin.st_dev, fin.st_ino), expected) else {
            throw FDError.verificationMismatch(component: name)
        }
        guard name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) == 0 else {
            throw FDError.teardownFailed(errno: errno)
        }
    }
}
