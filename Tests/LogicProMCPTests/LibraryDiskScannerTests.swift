import Foundation
import Testing
@testable import LogicProMCP

/// v3.0.5 — filesystem-backed library scan tests. Uses a real temp dir
/// populated with fixture `.patch` bundles (empty directories suffixed with
/// `.patch`) so the production code path under `FileManager.default` is
/// exercised end-to-end. No AX, no Logic Pro process, no network.
@Suite("v3.0.5 LibraryDiskScanner — filesystem-backed scan")
struct LibraryDiskScannerTests {

    /// Build a throwaway "Patches/Instrument" fixture mirroring Logic's
    /// bundle layout. Returns the `Patches/Instrument` URL that the scanner
    /// is expected to walk. Caller is responsible for `try? FileManager.default.removeItem(at:)`
    /// on the enclosing temp dir when done.
    private func makeFixture(
        tree: [String],
        fileManager: FileManager = .default
    ) throws -> (bundleURL: URL, cleanupRoot: URL) {
        let tmp = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("LibraryDiskScannerTests-\(UUID().uuidString)", isDirectory: true)
        let bundle = tmp.appendingPathComponent("Patches/Instrument", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        for rel in tree {
            // Every fixture path ends in .patch (a leaf) or is a plain
            // subfolder; both are represented as empty directories on disk.
            let full = bundle.appendingPathComponent(rel)
            try fileManager.createDirectory(at: full, withIntermediateDirectories: true)
        }
        return (bundle, tmp)
    }

    @Test("scan returns a LibraryRoot with the three fixture leaves and correct depth")
    func scanSmallFixtureProducesExpectedTree() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Synthesizer/Bass/Acid Etched Bass.patch",
            "Synthesizer/Bass/Dark Drone Bass.patch",
            "Drums & Percussion/Electronic Drums/Roland TR-909.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)

        #expect(root.leafCount == 3)
        // Categories are sorted: "Drums & Percussion" before "Synthesizer".
        #expect(root.categories == ["Drums & Percussion", "Synthesizer"])
        // Folder count: (library-root) + 2 top categories + 2 subfolders = 5.
        #expect(root.folderCount == 5)
        // Node count = folders + leaves.
        #expect(root.nodeCount == root.folderCount + root.leafCount)
        #expect(root.selectionRestored == false)
        #expect(root.truncatedBranches == 0)
        #expect(root.probeTimeouts == 0)
        #expect(root.cycleCount == 0)
    }

    @Test("leaf names strip the .patch suffix but preserve segment hierarchy")
    func leafStripsPatchSuffix() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Synthesizer/Bass/Acid Etched Bass.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        let synth = try #require(root.root.children.first { $0.name == "Synthesizer" })
        let bassFolder = try #require(synth.children.first { $0.name == "Bass" })
        #expect(bassFolder.kind == .folder)
        let leaf = try #require(bassFolder.children.first)
        #expect(leaf.kind == .leaf)
        // Display name has NO `.patch` suffix — matches Library Panel display
        // and also matches what `LibraryAccessor.selectPath(segments:)` needs
        // to click in column 2.
        #expect(leaf.name == "Acid Etched Bass")
        // The stored `path` segments stay hierarchically correct.
        #expect(leaf.path == "Synthesizer/Bass/Acid Etched Bass")
    }

    @Test("presetsByCategory flattens leaves under their top-level category")
    func presetsByCategoryFlattensCorrectly() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Synthesizer/Bass/Acid Etched Bass.patch",
            "Synthesizer/Bass/Dark Drone Bass.patch",
            "Synthesizer/Pad/Cinematic Pad.patch",
            "Bass/Sub Bass.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        let synthPresets = try #require(root.presetsByCategory["Synthesizer"])
        #expect(synthPresets.count == 3)
        #expect(synthPresets.contains("Acid Etched Bass"))
        #expect(synthPresets.contains("Dark Drone Bass"))
        #expect(synthPresets.contains("Cinematic Pad"))
        let bassPresets = try #require(root.presetsByCategory["Bass"])
        #expect(bassPresets == ["Sub Bass"])
    }

    @Test("hidden dotfiles (.DS_Store) do not appear as folders or leaves")
    func ignoresHiddenFiles() throws {
        let fm = FileManager.default
        let (bundle, tmp) = try makeFixture(tree: [
            "Synthesizer/Bass/Acid Etched Bass.patch",
        ])
        defer { try? fm.removeItem(at: tmp) }

        // Simulate a .DS_Store file and a hidden dir at both category and
        // patch levels — neither should surface in the tree.
        try Data().write(to: bundle.appendingPathComponent(".DS_Store"))
        try Data().write(to: bundle.appendingPathComponent("Synthesizer/.DS_Store"))
        try fm.createDirectory(
            at: bundle.appendingPathComponent(".hidden"),
            withIntermediateDirectories: true
        )

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        #expect(root.categories == ["Synthesizer"])
        #expect(root.leafCount == 1)
    }

    @Test("missing bundle path throws bundleNotFound")
    func missingBundleThrows() throws {
        let bogus = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        #expect(throws: LibraryDiskScanner.ScanError.self) {
            try LibraryDiskScanner.scan(bundleURL: bogus)
        }
    }

    @Test("empty bundle yields zero leaves but a well-formed LibraryRoot")
    func emptyBundleYieldsEmptyRoot() throws {
        let fm = FileManager.default
        let tmp = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("LibraryDiskScannerTests-\(UUID().uuidString)", isDirectory: true)
        let bundle = tmp.appendingPathComponent("Patches/Instrument", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        #expect(root.leafCount == 0)
        #expect(root.categories.isEmpty)
        // Root node is always present, so folderCount is at least 1.
        #expect(root.folderCount >= 1)
    }

    @Test("non-.patch subfolders under a category still recurse as folders, not leaves")
    func deepFolderHierarchyPreservesKind() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Drums & Percussion/Electronic Drums/Analog/TR-808.patch",
            "Drums & Percussion/Electronic Drums/Analog/TR-909.patch",
            "Drums & Percussion/Electronic Drums/Digital/LinnDrum.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        #expect(root.leafCount == 3)
        // Electronic Drums and its two children (Analog/Digital) are all
        // folders, not leaves, because they lack the `.patch` suffix.
        let drums = try #require(root.root.children.first { $0.name == "Drums & Percussion" })
        let electronic = try #require(drums.children.first { $0.name == "Electronic Drums" })
        let analog = try #require(electronic.children.first { $0.name == "Analog" })
        #expect(analog.kind == .folder)
        #expect(analog.children.count == 2)
        #expect(analog.children.allSatisfy { $0.kind == .leaf })
    }

    /// Integration smoke test: only runs if the live Logic bundle is present
    /// on the machine. Verifies that a full scan returns a clinically
    /// implausible-low count (e.g. under 1000 leaves) does NOT ship — the
    /// whole point of v3.0.5 is to fix the 345-leaf undercount.
    @Test("local-machine integration: factory Library reports at least 1000 leaves when present")
    func scanLocalFactoryLibraryReportsFullCoverage() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let bundleURL = home.appendingPathComponent(LibraryDiskScanner.defaultBundleRelativePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            // Expected in CI; skip silently.
            return
        }
        let root = try LibraryDiskScanner.scan()
        #expect(
            root.leafCount >= 1000,
            "Local factory library scanned \(root.leafCount) leaves — still stuck in the AX-undercount regime"
        )
    }
}
