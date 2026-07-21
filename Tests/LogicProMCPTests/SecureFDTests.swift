import Darwin
import Foundation
import Testing
@testable import LogicProMCP

/// Isolated mutation matrix for the `SecureFD` primitive: each negative test
/// fails if its guard is removed. The DEBUG seams exercised here are `#if DEBUG`
/// and absent from a release binary.
@Suite("SecureFD primitive", .serialized)
struct SecureFDTests {
    // MARK: fixtures

    private func tempBase(_ label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpmcp-securefd-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Run `body` with `_testBaseOverride` set to `base` (DEBUG-only seam), restored after.
    private func withBase<R>(_ base: URL, _ body: () throws -> R) rethrows -> R {
        SecureFD._testBaseOverride = base
        defer { SecureFD._testBaseOverride = nil }
        return try body()
    }

    /// A verified fd for `base` itself via the real API. `openTrustedBase` requires
    /// the target to be strictly under the base, so we probe with a child name (the
    /// child is never opened — only the base fd + relative arithmetic are used).
    /// Caller owns the returned fd.
    private func openBaseFD(_ base: URL) throws -> Int32 {
        try SecureFD.openTrustedBase(for: base.appendingPathComponent("__probe__")).baseFD
    }

    private func fdIsOpen(_ fd: Int32) -> Bool {
        var st = stat(); return fstat(fd, &st) == 0
    }

    /// Number of open descriptors in this process (F_GETFD sweep). Parallel
    /// suites can hold transient fds, so callers take the minimum of a few
    /// samples: a real leak persists across samples, noise fluctuates away.
    private func openFDCount() -> Int {
        var count = 0
        for fd in 0..<Int32(getdtablesize()) where fcntl(fd, F_GETFD) != -1 { count += 1 }
        return count
    }

    private func minOpenFDCount(samples: Int = 5) -> Int {
        var best = Int.max
        for _ in 0..<samples { best = min(best, openFDCount()) }
        return best
    }

    // MARK: component validation

    @Test("validateComponent rejects empty, dot, dotdot, slash, NUL")
    func componentValidation() throws {
        for bad in ["", ".", "..", "a/b", "x\u{0}y"] {
            #expect(throws: (any Error).self) { try SecureFD.validateComponent(bad) }
        }
        try SecureFD.validateComponent("Library")   // a good one does not throw
    }

    // MARK: walk + verify + fd-lifecycle

    @Test("walkVerified opens a real chain and does NOT close the caller's base fd")
    func walkSucceedsAndOwnsFds() throws {
        let base = try tempBase("walk-ok")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("a/b", isDirectory: true), withIntermediateDirectories: true)
        try withBase(base) {
            let (baseFD, rel) = try SecureFD.openTrustedBase(for: base.appendingPathComponent("a/b"))
            defer { close(baseFD) }
            #expect(rel == ["a", "b"])
            let (leaf, ids) = try SecureFD.walkVerified(baseFD: baseFD, rel)
            #expect(ids.count == rel.count)
            #expect(fdIsOpen(leaf))          // returned fd is open (caller owns it)
            #expect(fdIsOpen(baseFD))        // fd-lifecycle: base NOT closed by the walk
            close(leaf)
            #expect(!fdIsOpen(leaf))         // single-owned: after our close it is gone
        }
    }

    @Test("walkVerified refuses a symlinked intermediate component (O_NOFOLLOW)")
    func walkRefusesSymlinkComponent() throws {
        let base = try tempBase("walk-symlink")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("leaf", isDirectory: true),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link"), withDestinationURL: real)
        try withBase(base) {
            let baseFD = try openBaseFD(base)
            defer { close(baseFD) }
            #expect(throws: (any Error).self) {
                close(try SecureFD.walkVerified(baseFD: baseFD, ["link", "leaf"]).fd)
            }
        }
    }

    @Test("walkVerified refuses a mid-walk rebind (pass A != pass B)")
    func walkRefusesMidWalkRebind() throws {
        let base = try tempBase("walk-midwalk")
        defer { try? FileManager.default.removeItem(at: base) }
        let mid = base.appendingPathComponent("mid", isDirectory: true)
        try FileManager.default.createDirectory(at: mid.appendingPathComponent("leaf", isDirectory: true),
                                                withIntermediateDirectories: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("leaf", isDirectory: true),
                                                withIntermediateDirectories: true)
        try withBase(base) {
            let baseFD = try openBaseFD(base)
            defer { close(baseFD) }
            // Between pass A and pass B, swap `mid` for a DIFFERENT real dir that
            // still carries `leaf` — the open would succeed without the A==B check.
            SecureFD._testAfterPassAHook = {
                try? FileManager.default.removeItem(at: mid)
                try? FileManager.default.moveItem(at: other, to: mid)
            }
            defer { SecureFD._testAfterPassAHook = nil }
            #expect(throws: (any Error).self) {
                close(try SecureFD.walkVerified(baseFD: baseFD, ["mid", "leaf"]).fd)
            }
        }
    }

    // MARK: file opens

    @Test("createFile is exclusive: refuses a pre-existing file and a symlink at the name")
    func createFileExclusive() throws {
        let base = try tempBase("create")
        defer { try? FileManager.default.removeItem(at: base) }
        try withBase(base) {
            let parent = try openBaseFD(base)
            defer { close(parent) }
            // fresh exclusive create succeeds
            let fd = try SecureFD.createFile(parentFD: parent, name: "fresh.json", mode: 0o600)
            #expect(fdIsOpen(fd)); close(fd)
            // pre-existing regular file → EEXIST refuse
            #expect(throws: (any Error).self) {
                close(try SecureFD.createFile(parentFD: parent, name: "fresh.json", mode: 0o600))
            }
            // symlink at a NEW name → O_NOFOLLOW/O_EXCL refuse
            try FileManager.default.createSymbolicLink(
                at: base.appendingPathComponent("sym.json"),
                withDestinationURL: base.appendingPathComponent("fresh.json"))
            #expect(throws: (any Error).self) {
                close(try SecureFD.createFile(parentFD: parent, name: "sym.json", mode: 0o600))
            }
        }
    }

    @Test("openAppend refuses a symlink, a fifo, and a hardlink (st_nlink>1); accepts a plain file")
    func openAppendGuards() throws {
        let base = try tempBase("append")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("line\n".utf8).write(to: base.appendingPathComponent("real.log"))
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("sym.log"),
            withDestinationURL: base.appendingPathComponent("real.log"))
        _ = base.appendingPathComponent("fifo.log").path.withCString { mkfifo($0, 0o600) }
        // A hardlink at `hard.log` pointing at a SEPARATE target inode → st_nlink==2.
        // `real.log` stays nlink==1 so its append still succeeds.
        try Data("t".utf8).write(to: base.appendingPathComponent("hltarget"))
        let linkRC = base.appendingPathComponent("hltarget").path.withCString { t in
            base.appendingPathComponent("hard.log").path.withCString { l in link(t, l) }
        }
        #expect(linkRC == 0)
        try withBase(base) {
            let parent = try openBaseFD(base)
            defer { close(parent) }
            let ok = try SecureFD.openAppend(parentFD: parent, name: "real.log")
            #expect(fdIsOpen(ok)); close(ok)
            #expect(throws: (any Error).self) { close(try SecureFD.openAppend(parentFD: parent, name: "sym.log")) }
            #expect(throws: (any Error).self) { close(try SecureFD.openAppend(parentFD: parent, name: "fifo.log")) }
            #expect(throws: (any Error).self) { close(try SecureFD.openAppend(parentFD: parent, name: "hard.log")) }
        }
    }

    // MARK: makeEmptyDir + assertEmpty

    @Test("makeEmptyDir creates an empty dir; assertEmpty rejects a populated one")
    func emptyDirGuards() throws {
        let base = try tempBase("emptydir")
        defer { try? FileManager.default.removeItem(at: base) }
        // A populated sibling dir the empty-check must reject.
        let populated = base.appendingPathComponent("pop", isDirectory: true)
        try FileManager.default.createDirectory(at: populated, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: populated.appendingPathComponent("child"))
        try withBase(base) {
            let parent = try openBaseFD(base)
            defer { close(parent) }
            let (dirFD, _) = try SecureFD.makeEmptyDir(parentFD: parent, name: "stage", mode: 0o700)
            #expect(fdIsOpen(dirFD)); close(dirFD)
            let popBase = try openBaseFD(base)
            defer { close(popBase) }
            let popFD = try SecureFD.walkVerified(baseFD: popBase, ["pop"]).fd
            defer { close(popFD) }
            #expect(throws: (any Error).self) { try SecureFD.assertEmpty(dirFD: popFD, label: "pop") }
        }
    }

    // MARK: teardown

    @Test("teardownTree removes a nested tree and unlinks a symlink child as a link (target survives)")
    func teardownNestedAndSymlinkChild() throws {
        let base = try tempBase("teardown")
        defer { try? FileManager.default.removeItem(at: base) }
        let tree = base.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: tree.appendingPathComponent("f1"))
        try Data("b".utf8).write(to: tree.appendingPathComponent("sub/f2"))
        let precious = base.appendingPathComponent("precious.txt")
        try Data("KEEP".utf8).write(to: precious)
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("linkchild"), withDestinationURL: precious)
        try withBase(base) {
            let parent = try openBaseFD(base)
            defer { close(parent) }
            try SecureFD.teardownTree(parentFD: parent, name: "tree")
            #expect(!FileManager.default.fileExists(atPath: tree.path))          // tree gone
            #expect(FileManager.default.fileExists(atPath: precious.path))       // symlink target NOT followed/deleted
            #expect(try String(contentsOf: precious, encoding: .utf8) == "KEEP")
        }
    }

    // MARK: fd-lifecycle under repeated failure

    @Test("repeated error paths do not leak file descriptors")
    func errorPathsAreFDBounded() throws {
        let base = try tempBase("fdbound")
        defer { try? FileManager.default.removeItem(at: base) }
        try withBase(base) {
            let baseFD = try openBaseFD(base)
            defer { close(baseFD) }

            // (a) verification-pass failure: the walk target vanishes between
            // pass A and pass B, so pass B throws after pass A opened its fd.
            // Independently bounded: a one-fd-per-failure leak adds 64.
            let beforeWalk = minOpenFDCount()
            let mid = base.appendingPathComponent("mid", isDirectory: true)
            for _ in 0..<64 {
                try FileManager.default.createDirectory(at: mid, withIntermediateDirectories: true)
                SecureFD._testAfterPassAHook = { try? FileManager.default.removeItem(at: mid) }
                #expect(throws: (any Error).self) {
                    close(try SecureFD.walkVerified(baseFD: baseFD, ["mid"]).fd)
                }
            }
            SecureFD._testAfterPassAHook = nil
            let afterWalk = minOpenFDCount()
            #expect(afterWalk - beforeWalk < 8)

            // (b) mid-recursion teardown failure: a read-only subdirectory makes
            // the child unlink fail AFTER the recursion has opened directory fds
            // at two levels, so the propagating throw must release both.
            // Independently bounded: a per-level leak adds 128.
            let beforeTeardown = minOpenFDCount()
            let tree = base.appendingPathComponent("tree", isDirectory: true)
            let sub = tree.appendingPathComponent("sub", isDirectory: true)
            for _ in 0..<64 {
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: sub.appendingPathComponent("f"))
                _ = sub.path.withCString { chmod($0, 0o500) }
                #expect(throws: (any Error).self) {
                    try SecureFD.teardownTree(parentFD: baseFD, name: "tree")
                }
                _ = sub.path.withCString { chmod($0, 0o700) }
                try FileManager.default.removeItem(at: tree)
            }
            let afterTeardown = minOpenFDCount()
            #expect(afterTeardown - beforeTeardown < 8)
        }
    }

    // MARK: descriptor flags + ownership

    @Test("openRead refuses a symlink and a hardlink; accepts a plain file")
    func openReadGuards() throws {
        let base = try tempBase("read")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("data".utf8).write(to: base.appendingPathComponent("plain.json"))
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("sym.json"),
            withDestinationURL: base.appendingPathComponent("plain.json"))
        try Data("t".utf8).write(to: base.appendingPathComponent("hltarget"))
        let linkRC = base.appendingPathComponent("hltarget").path.withCString { t in
            base.appendingPathComponent("hard.json").path.withCString { l in link(t, l) }
        }
        #expect(linkRC == 0)
        try withBase(base) {
            let parent = try openBaseFD(base)
            defer { close(parent) }
            let ok = try SecureFD.openRead(parentFD: parent, name: "plain.json")
            #expect(fdIsOpen(ok)); close(ok)
            #expect(throws: (any Error).self) { close(try SecureFD.openRead(parentFD: parent, name: "sym.json")) }
            #expect(throws: (any Error).self) { close(try SecureFD.openRead(parentFD: parent, name: "hard.json")) }
        }
    }

    @Test("every returned descriptor carries close-on-exec")
    func returnedDescriptorsAreCloexec() throws {
        let base = try tempBase("cloexec")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("a", isDirectory: true), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: base.appendingPathComponent("f.json"))
        func isCloexec(_ fd: Int32) -> Bool { fcntl(fd, F_GETFD) & FD_CLOEXEC != 0 }
        try withBase(base) {
            let parent = try openBaseFD(base)
            defer { close(parent) }
            // Empty-relative walk returns the internal DUPLICATE of the base —
            // the one descriptor a non-CLOEXEC dup would expose directly.
            let dupLeaf = try SecureFD.walkVerified(baseFD: parent, []).fd
            #expect(isCloexec(dupLeaf)); close(dupLeaf)
            let walkLeaf = try SecureFD.walkVerified(baseFD: parent, ["a"]).fd
            #expect(isCloexec(walkLeaf)); close(walkLeaf)
            let created = try SecureFD.createFile(parentFD: parent, name: "new.json", mode: 0o600)
            #expect(isCloexec(created)); close(created)
            let appended = try SecureFD.openAppend(parentFD: parent, name: "f.json")
            #expect(isCloexec(appended)); close(appended)
            let read = try SecureFD.openRead(parentFD: parent, name: "f.json")
            #expect(isCloexec(read)); close(read)
            let (dirFD, _) = try SecureFD.makeEmptyDir(parentFD: parent, name: "stage", mode: 0o700)
            #expect(isCloexec(dirFD)); close(dirFD)
        }
    }

    @Test("failing calls never close or replace descriptors they do not own")
    func errorPathsDoNotDisturbForeignDescriptors() throws {
        let base = try tempBase("canary")
        defer { try? FileManager.default.removeItem(at: base) }
        let mid = base.appendingPathComponent("mid", isDirectory: true)
        try FileManager.default.createDirectory(at: mid, withIntermediateDirectories: true)
        func fdIdentity(_ fd: Int32) -> (dev: dev_t, ino: ino_t)? {
            var st = stat(); return fstat(fd, &st) == 0 ? (st.st_dev, st.st_ino) : nil
        }
        try withBase(base) {
            let baseFD = try openBaseFD(base)
            defer { close(baseFD) }
            let baseIdentity = try #require(fdIdentity(baseFD))

            // Deterministic double-close probe: the moment pass A's fd is
            // released, the hook claims the lowest free descriptor numbers with
            // canaries. A residual close of pass A's number on the error path
            // would kill a canary; POSIX guarantees open() reuses lowest-free.
            var canaries: [Int32] = []
            SecureFD._testAfterPassAHook = {
                for _ in 0..<4 { canaries.append(open("/dev/null", O_RDONLY | O_CLOEXEC)) }
                try? FileManager.default.removeItem(at: mid)
            }
            #expect(throws: (any Error).self) {
                close(try SecureFD.walkVerified(baseFD: baseFD, ["mid"]).fd)
            }
            SecureFD._testAfterPassAHook = nil
            #expect(canaries.count == 4)
            for canary in canaries {
                #expect(canary >= 0)
                #expect(fdIsOpen(canary))   // a double-close would have killed it
                close(canary)
            }

            // Stale-fd probe: after success and failure paths, the caller's
            // base descriptor is still open AND still the same object — a
            // close-and-reuse inside SecureFD would change its identity. The
            // failure trigger is a nonexistent component, so this probe does
            // not depend on any single guard.
            try FileManager.default.createDirectory(at: mid, withIntermediateDirectories: true)
            close(try SecureFD.walkVerified(baseFD: baseFD, ["mid"]).fd)          // success path
            #expect(throws: (any Error).self) {
                close(try SecureFD.walkVerified(baseFD: baseFD, ["missing"]).fd)  // failure path
            }
            let after = try #require(fdIdentity(baseFD))
            #expect(SecureFD.sameIdentity(baseIdentity, after))
        }
    }

    // MARK: base policy

    @Test("openTrustedBase refuses a target that is not under the trusted base")
    func baseRefusesTargetOutsideBase() throws {
        let base = try tempBase("basepolicy")
        defer { try? FileManager.default.removeItem(at: base) }
        try withBase(base) {
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpmcp-outside-\(UUID().uuidString)")
            #expect(throws: (any Error).self) { _ = try SecureFD.openTrustedBase(for: outside) }
        }
    }
}
