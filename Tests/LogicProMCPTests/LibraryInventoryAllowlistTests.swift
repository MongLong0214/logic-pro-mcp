import Foundation
import Testing
@testable import LogicProMCP

// v3.1.4 backlog #5 — `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override path
// allowlist. Prior to this change, `validateLibraryInventoryPath` only
// enforced a `.json` suffix, so any user-readable JSON file (Keychain
// export, third-party config, token caches) was reachable through a
// hostile env var. These tests pin the allowlist semantics:
// - default-location files accepted
// - <CWD>/Resources/ files accepted
// - arbitrary user-home paths rejected
// - symlink chains escaping the allowlist rejected
// - non-`.json` rejected
// - directories rejected
//
// The validator is exercised directly with synthesised allowlists rather
// than via the readResource path so the tests don't need to mutate
// process-level env vars (which leak across the swift-testing parallel
// runner).

private struct InventoryFixture {
    let dir: URL
    let allowlist: [String]

    static func make(named name: String = "library-inventory-allowlist-tests") -> InventoryFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Normalise the prefix the same way the validator does so symlinks
        // in the temp-dir hierarchy (macOS resolves /var → /private/var)
        // don't cause spurious mismatches.
        var resolved = dir.resolvingSymlinksInPath().path
        if !resolved.hasSuffix("/") { resolved += "/" }
        return InventoryFixture(dir: dir, allowlist: [resolved])
    }

    func writeJSON(_ name: String, contents: String = #"{"ok":true}"#) -> String {
        let url = dir.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Allowlist enforcement

@Test func testValidPathInsideAllowlistAccepted() {
    let fx = InventoryFixture.make()
    defer { fx.cleanup() }
    let path = fx.writeJSON("inventory.json")

    let resolved = ResourceHandlers.validateLibraryInventoryPath(path, allowedPrefixes: fx.allowlist)
    #expect(resolved != nil, "file inside an allowlisted dir must validate")
}

@Test func testPathOutsideAllowlistRejected() {
    // /tmp file with nothing-allowlisted should be rejected even though it
    // ends in .json. Prevents an attacker-controlled env var from pointing
    // the server at arbitrary user-readable JSON.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("secret.json")
    try? #"{"ok":true}"#.write(to: url, atomically: true, encoding: .utf8)

    // Allowlist a *different* tmpdir; the secret path is outside it.
    let other = FileManager.default.temporaryDirectory
        .appendingPathComponent("allowlisted-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: other) }
    var allow = other.resolvingSymlinksInPath().path
    if !allow.hasSuffix("/") { allow += "/" }

    let resolved = ResourceHandlers.validateLibraryInventoryPath(url.path, allowedPrefixes: [allow])
    #expect(resolved == nil, "file outside allowlist must be rejected")
}

@Test func testSiblingPrefixPathRejected() {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("allowlist-prefix-\(UUID().uuidString)", isDirectory: true)
    let allowed = parent.appendingPathComponent("Logic", isDirectory: true)
    let sibling = parent.appendingPathComponent("Logic-evil", isDirectory: true)
    try? FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let url = sibling.appendingPathComponent("inventory.json")
    try? #"{"ok":true}"#.write(to: url, atomically: true, encoding: .utf8)

    var allow = allowed.resolvingSymlinksInPath().path
    if !allow.hasSuffix("/") { allow += "/" }

    let resolved = ResourceHandlers.validateLibraryInventoryPath(url.path, allowedPrefixes: [allow])
    #expect(resolved == nil, "sibling prefix path must not match a trailing-slash allowlist prefix")
}

@Test func testEmptyAllowlistRejectsEverything() {
    // Defence-in-depth: if a misconfigured operator passes an empty
    // allowlist, every candidate must be rejected — no implicit fallback
    // to "any .json".
    let fx = InventoryFixture.make()
    defer { fx.cleanup() }
    let path = fx.writeJSON("inventory.json")

    let resolved = ResourceHandlers.validateLibraryInventoryPath(path, allowedPrefixes: [])
    #expect(resolved == nil, "empty allowlist must reject every path")
}

// MARK: - Symlink escape

@Test func testSymlinkEscapeRejected() throws {
    // Setup:
    //   allowed-dir/escape.json -> outside-dir/secret.json
    // The validator resolves symlinks BEFORE the allowlist check, so the
    // path post-resolution is `outside-dir/secret.json` — outside the
    // allowed prefix. This is the core threat model: an attacker drops a
    // symlink under a writeable allowlisted dir to escape.
    let allowed = FileManager.default.temporaryDirectory
        .appendingPathComponent("allowed-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: allowed)
        try? FileManager.default.removeItem(at: outside)
    }

    let secret = outside.appendingPathComponent("secret.json")
    try #"{"secret":true}"#.write(to: secret, atomically: true, encoding: .utf8)

    let symlink = allowed.appendingPathComponent("escape.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secret)

    var allow = allowed.resolvingSymlinksInPath().path
    if !allow.hasSuffix("/") { allow += "/" }

    let resolved = ResourceHandlers.validateLibraryInventoryPath(symlink.path, allowedPrefixes: [allow])
    #expect(resolved == nil, "symlink that escapes the allowlist must be rejected")
}

@Test func testSymlinkInsideAllowlistAccepted() throws {
    // Symlinks that stay inside the allowlist are still legitimate
    // (e.g. dev workflows where Resources/library-inventory.json is a
    // checked-out symlink). Pin that this case still works.
    let allowed = FileManager.default.temporaryDirectory
        .appendingPathComponent("allowed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: allowed) }

    let real = allowed.appendingPathComponent("real.json")
    try #"{"ok":true}"#.write(to: real, atomically: true, encoding: .utf8)
    let link = allowed.appendingPathComponent("inventory.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    var allow = allowed.resolvingSymlinksInPath().path
    if !allow.hasSuffix("/") { allow += "/" }

    let resolved = ResourceHandlers.validateLibraryInventoryPath(link.path, allowedPrefixes: [allow])
    #expect(resolved != nil, "symlink that stays inside allowlist must validate")
}

// MARK: - Existing guards (regression: still enforced after allowlist add)

@Test func testNonJsonRejectedEvenWhenAllowlisted() {
    let fx = InventoryFixture.make()
    defer { fx.cleanup() }
    let url = fx.dir.appendingPathComponent("inventory.txt")
    try? #"{"ok":true}"#.write(to: url, atomically: true, encoding: .utf8)

    let resolved = ResourceHandlers.validateLibraryInventoryPath(url.path, allowedPrefixes: fx.allowlist)
    #expect(resolved == nil, "non-.json file must still be rejected even inside allowlist")
}

@Test func testDirectoryRejectedEvenWhenAllowlisted() {
    let fx = InventoryFixture.make()
    defer { fx.cleanup() }
    // A directory whose name ends in `.json` (yes, this is a real attack
    // shape — bypasses naïve suffix checks). The validator must still
    // reject because `isDirectory` is true.
    let dir = fx.dir.appendingPathComponent("fake.json", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let resolved = ResourceHandlers.validateLibraryInventoryPath(dir.path, allowedPrefixes: fx.allowlist)
    #expect(resolved == nil, "directory with .json suffix must still be rejected")
}

@Test func testNonexistentPathRejected() {
    let fx = InventoryFixture.make()
    defer { fx.cleanup() }
    let path = fx.dir.appendingPathComponent("nonexistent.json").path
    let resolved = ResourceHandlers.validateLibraryInventoryPath(path, allowedPrefixes: fx.allowlist)
    #expect(resolved == nil, "nonexistent path must be rejected")
}

// MARK: - Default allowlist composition

@Test func testDefaultAllowlistContainsExpectedRoots() {
    let prefixes = ResourceHandlers.defaultLibraryInventoryAllowedPrefixes()

    // Every prefix must end in `/` so prefix comparison is safe.
    for p in prefixes {
        #expect(p.hasSuffix("/"), "allowlist prefix must end in `/` to prevent sibling-path bypass: \(p)")
    }

    // Must include ~/Library/Application Support/LogicProMCP/.
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("LogicProMCP", isDirectory: true)
    var asPath = appSupport.resolvingSymlinksInPath().path
    if !asPath.hasSuffix("/") { asPath += "/" }
    #expect(prefixes.contains(asPath), "default allowlist must include ~/Library/Application Support/LogicProMCP/")

    // Must include <CWD>/Resources/.
    let cwd = FileManager.default.currentDirectoryPath
    var resources = URL(fileURLWithPath: cwd)
        .appendingPathComponent("Resources", isDirectory: true)
        .resolvingSymlinksInPath().path
    if !resources.hasSuffix("/") { resources += "/" }
    #expect(prefixes.contains(resources), "default allowlist must include <CWD>/Resources/")

    // Must include ~/Music/Logic/.
    var music = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Music/Logic", isDirectory: true)
        .resolvingSymlinksInPath().path
    if !music.hasSuffix("/") { music += "/" }
    #expect(prefixes.contains(music), "default allowlist must include ~/Music/Logic/")
}

// MARK: - #923: the reader has to know both filenames the writer uses

/// `writeInventoryJSON` sends a disk scan to `library-inventory-disk.json` and an AX scan to
/// `library-inventory.json`. `parseScanMode` answers `.disk` for an absent mode, so the DEFAULT
/// `scan_library` writes the first name — and this reader knew only the second, so the resource
/// stayed empty however many times you scanned. The list is asserted rather than the resource
/// because an absent candidate is invisible from outside: the resource answers empty, which is
/// also what it answers when nobody has scanned yet.
@Test func testCandidatePathsCarryBothInventoryFilenames() {
    let paths = ResourceHandlers.libraryInventoryCandidatePaths()

    let canonical = paths.filter { $0.hasSuffix("/library-inventory.json") }
    let disk = paths.filter { $0.hasSuffix("/library-inventory-disk.json") }
    #expect(!canonical.isEmpty, "the AX filename must be a candidate: \(paths)")
    #expect(!disk.isEmpty, "the DISK filename is what the default scan writes: \(paths)")
    #expect(canonical.count == disk.count,
            "every directory that can hold one can hold the other: \(paths)")
}

/// The half of the original intent that must survive the fix: "an AX snapshot survives a disk
/// scan". Where both files exist in one directory the AX one is served, so its candidate has to
/// come first — in EVERY directory, not just the one somebody checked.
@Test func testTheAXSnapshotIsPreferredOverTheDiskScanInEveryDirectory() {
    let paths = ResourceHandlers.libraryInventoryCandidatePaths()
    var directoriesSeen = 0
    for (index, path) in paths.enumerated() where path.hasSuffix("/library-inventory.json") {
        let directory = (path as NSString).deletingLastPathComponent
        let sibling = directory + "/library-inventory-disk.json"
        guard let siblingIndex = paths.firstIndex(of: sibling) else {
            Issue.record("no disk sibling for \(path) in \(paths)")
            continue
        }
        directoriesSeen += 1
        #expect(index < siblingIndex,
                "\(directory): the AX snapshot must be tried before the disk scan")
    }
    #expect(directoriesSeen >= 2,
            "both <CWD>/Resources and Application Support must be covered: \(paths)")
}
