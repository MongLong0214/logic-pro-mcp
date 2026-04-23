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

    @Test("scan returns a LibraryRoot with Panel-mapped top-levels (v3.0.6)")
    func scanSmallFixtureProducesExpectedTree() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Synthesizer/Bass/Acid Etched Bass.patch",
            "Synthesizer/Bass/Dark Drone Bass.patch",
            "Drums & Percussion/Electronic Drums/Roland TR-909.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)

        #expect(root.leafCount == 3)
        // v3.0.6: disk `Drums & Percussion/Electronic Drums/...` collapses
        // to Panel top-level `Electronic Drums`. Alphabetical sort →
        // Electronic Drums, Synthesizer.
        #expect(root.categories == ["Electronic Drums", "Synthesizer"])
        // Folder count: (library-root) + 2 top categories (Electronic Drums,
        // Synthesizer) + 1 nested subfolder (Synthesizer/Bass) = 4.
        // (Drums & Percussion/Electronic Drums is flattened — no nested
        // subfolder under Electronic Drums.)
        #expect(root.folderCount == 4)
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

    @Test("non-.patch subfolders under a Panel category still recurse as folders, not leaves")
    func deepFolderHierarchyPreservesKind() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Drums & Percussion/Electronic Drums/Analog/TR-808.patch",
            "Drums & Percussion/Electronic Drums/Analog/TR-909.patch",
            "Drums & Percussion/Electronic Drums/Digital/LinnDrum.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        #expect(root.leafCount == 3)
        // v3.0.6: disk `Drums & Percussion/Electronic Drums` collapses to
        // Panel `Electronic Drums`. Its disk-children Analog/Digital remain
        // folders (no .patch suffix) and retain their kind + sub-leaves.
        let electronic = try #require(root.root.children.first { $0.name == "Electronic Drums" })
        let analog = try #require(electronic.children.first { $0.name == "Analog" })
        #expect(analog.kind == .folder)
        #expect(analog.children.count == 2)
        #expect(analog.children.allSatisfy { $0.kind == .leaf })
        // Leaf path is Panel-rooted, not disk-rooted.
        let tr808 = try #require(analog.children.first { $0.name == "TR-808" })
        #expect(tr808.path == "Electronic Drums/Analog/TR-808")
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

    // MARK: - v3.0.6 Panel-taxonomy mapping tests

    @Test("mapDiskPathToPanel: Drums & Percussion/Acoustic Drums → Acoustic Drums")
    func mapperFlattensDrumsAcoustic() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Drums & Percussion", "Acoustic Drums", "SoCal"]
        )
        #expect(mapped == ["Acoustic Drums", "SoCal"])
    }

    @Test("mapDiskPathToPanel: Drums & Percussion/Electronic Drums → Electronic Drums")
    func mapperFlattensDrumsElectronic() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Drums & Percussion", "Electronic Drums", "Roland TR-909"]
        )
        #expect(mapped == ["Electronic Drums", "Roland TR-909"])
    }

    @Test("mapDiskPathToPanel: Drums & Percussion/Percussion → Percussion")
    func mapperFlattensPercussion() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Drums & Percussion", "Percussion", "Conga Ensemble"]
        )
        #expect(mapped == ["Percussion", "Conga Ensemble"])
    }

    @Test("mapDiskPathToPanel: Keyboard/Acoustic Piano → Acoustic Piano")
    func mapperFlattensAcousticPiano() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Keyboard", "Acoustic Piano", "Concert Grand"]
        )
        #expect(mapped == ["Acoustic Piano", "Concert Grand"])
    }

    @Test("mapDiskPathToPanel: Keyboard/Clavinet → Clavinet")
    func mapperFlattensClavinet() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Keyboard", "Clavinet", "Bright Clav"]
        )
        #expect(mapped == ["Clavinet", "Bright Clav"])
    }

    @Test("mapDiskPathToPanel: Keyboard/Electric Piano → Electric Piano")
    func mapperFlattensElectricPiano() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Keyboard", "Electric Piano", "Rhodes"]
        )
        #expect(mapped == ["Electric Piano", "Rhodes"])
    }

    @Test("mapDiskPathToPanel: Keyboard/Mellotron → Mellotron")
    func mapperFlattensMellotron() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Keyboard", "Mellotron", "Strings"]
        )
        #expect(mapped == ["Mellotron", "Strings"])
    }

    @Test("mapDiskPathToPanel: Keyboard/Organ → Organ")
    func mapperFlattensOrgan() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Keyboard", "Organ", "B3 Gospel"]
        )
        #expect(mapped == ["Organ", "B3 Gospel"])
    }

    @Test("mapDiskPathToPanel: z_Legacy/Orchestral → Orchestral")
    func mapperFlattensOrchestral() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["z_Legacy", "Orchestral", "Film Strings"]
        )
        #expect(mapped == ["Orchestral", "Film Strings"])
    }

    @Test("mapDiskPathToPanel: Strings → Orchestral")
    func mapperRoutesStringsToOrchestral() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Strings", "Solo Cello"]
        )
        #expect(mapped == ["Orchestral", "Solo Cello"])
    }

    @Test("mapDiskPathToPanel: Bass identity passthrough")
    func mapperIdentityBass() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Bass", "Upright", "Sub Bass"]
        )
        #expect(mapped == ["Bass", "Upright", "Sub Bass"])
    }

    @Test("mapDiskPathToPanel: Guitar identity passthrough")
    func mapperIdentityGuitar() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Guitar", "Clean", "Jazz"]
        )
        #expect(mapped == ["Guitar", "Clean", "Jazz"])
    }

    @Test("mapDiskPathToPanel: Mallet identity passthrough")
    func mapperIdentityMallet() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(["Mallet", "Vibraphone"])
        #expect(mapped == ["Mallet", "Vibraphone"])
    }

    @Test("mapDiskPathToPanel: Synthesizer identity passthrough")
    func mapperIdentitySynthesizer() {
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Synthesizer", "Bass", "Acid Etched Bass"]
        )
        #expect(mapped == ["Synthesizer", "Bass", "Acid Etched Bass"])
    }

    @Test("mapDiskPathToPanel: unmapped top-level returns nil (dropped)")
    func mapperRejectsUnmapped() {
        // z_Legacy without /Orchestral has no Panel route.
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["z_Legacy", "World", "Gamelan"]
        )
        #expect(mapped == nil)
    }

    @Test("mapDiskPathToPanel: z01 Kit Pieces → Kit Pieces (intermediate rename)")
    func mapperRenamesZ01KitPieces() {
        // Raw disk `Drums & Percussion/Acoustic Drums/z01 Kit Pieces/Kick.patch`
        // stripped of .patch → segments ["Drums & Percussion", "Acoustic Drums",
        // "z01 Kit Pieces", "Kick"]. Mapper flattens first two → Acoustic Drums,
        // then renames "z01 Kit Pieces" → "Kit Pieces" in the tail.
        let mapped = LibraryDiskScanner.mapDiskPathToPanel(
            ["Drums & Percussion", "Acoustic Drums", "z01 Kit Pieces", "Kick"]
        )
        #expect(mapped == ["Acoustic Drums", "Kit Pieces", "Kick"])
    }

    @Test("mapDiskPathToPanel: empty input returns empty array")
    func mapperHandlesEmpty() {
        #expect(LibraryDiskScanner.mapDiskPathToPanel([]) == [])
    }

    @Test("scan drops unmapped top-levels (e.g. z_Legacy/World)")
    func scanDropsUnmappedCategories() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Bass/Sub Bass.patch",
            "z_Legacy/World/Gamelan.patch",    // should be dropped
            "z_Legacy/Orchestral/Film Strings.patch",  // should land under Orchestral
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        #expect(root.categories.sorted() == ["Bass", "Orchestral"])
        #expect(root.leafCount == 2)
        let orchestral = try #require(root.root.children.first { $0.name == "Orchestral" })
        #expect(orchestral.children.map(\.name) == ["Film Strings"])
    }

    @Test("scan flattens Drums & Percussion + Keyboard into Panel-visible top-levels")
    func scanRedistributesDrumsAndKeyboard() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Drums & Percussion/Acoustic Drums/SoCal.patch",
            "Drums & Percussion/Electronic Drums/Roland TR-909.patch",
            "Drums & Percussion/Percussion/Conga.patch",
            "Keyboard/Acoustic Piano/Concert Grand.patch",
            "Keyboard/Organ/B3.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        #expect(root.categories.sorted() == [
            "Acoustic Drums", "Acoustic Piano", "Electronic Drums", "Organ", "Percussion",
        ])
        #expect(root.leafCount == 5)
    }

    @Test("scan renames z01 intermediate folders to their Panel equivalents")
    func scanRenamesZ01Folders() throws {
        let (bundle, tmp) = try makeFixture(tree: [
            "Drums & Percussion/Acoustic Drums/z01 Kit Pieces/Kick.patch",
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        let acoustic = try #require(root.root.children.first { $0.name == "Acoustic Drums" })
        let kitPieces = try #require(acoustic.children.first { $0.name == "Kit Pieces" })
        #expect(kitPieces.kind == .folder)
        #expect(kitPieces.path == "Acoustic Drums/Kit Pieces")
        let kick = try #require(kitPieces.children.first)
        #expect(kick.name == "Kick")
        #expect(kick.path == "Acoustic Drums/Kit Pieces/Kick")
    }

    /// v3.0.6 contract assertion: every emitted top-level category must exist
    /// in the v3.0.4 AX Panel snapshot's `categories` array. This is the
    /// "mapping bug detector" — if a new disk taxonomy slips through without
    /// a `diskToPanel` entry, this test starts failing.
    @Test("scan result: every emitted category exists in Resources/library-inventory.json Panel snapshot")
    func everyEmittedCategoryExistsInPanelInventory() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let bundleURL = home.appendingPathComponent(LibraryDiskScanner.defaultBundleRelativePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            // Expected in CI; skip silently.
            return
        }

        // Load Panel snapshot from committed resource. Scan-result
        // categories must be a subset.
        let panelCategories = try loadPanelCategoriesFromResource()
        guard !panelCategories.isEmpty else {
            // Fixture missing — skip rather than misreport.
            return
        }

        let root = try LibraryDiskScanner.scan()
        for cat in root.categories {
            #expect(
                panelCategories.contains(cat),
                "Disk scan emitted `\(cat)` which is not in the v3.0.4 AX Panel snapshot (\(panelCategories.sorted()))"
            )
        }
    }

    private func loadPanelCategoriesFromResource() throws -> Set<String> {
        // Tests run from the package root by default; try a couple of
        // candidate paths so either a raw `swift test` invocation or one
        // launched from a subdirectory still resolves the resource.
        let fm = FileManager.default
        let candidates = [
            fm.currentDirectoryPath + "/Resources/library-inventory.json",
            fm.currentDirectoryPath + "/../Resources/library-inventory.json",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cats = obj["categories"] as? [String] {
                return Set(cats)
            }
        }
        return []
    }

    @Test("scan handles symlink cycles via visited-set guard (no runaway recursion)")
    func scanHandlesSymlinkCycle() throws {
        let fm = FileManager.default
        let (bundle, tmp) = try makeFixture(tree: [
            "Bass/Sub Bass.patch",
        ])
        defer { try? fm.removeItem(at: tmp) }

        // Symlink Bass → itself via a child link. Pre-visited guard must
        // bail on the second entry rather than looping until stack blows.
        let loopLink = bundle.appendingPathComponent("Bass/loop")
        try fm.createSymbolicLink(
            at: loopLink,
            withDestinationURL: bundle.appendingPathComponent("Bass")
        )

        // Must return a LibraryRoot without throwing or hanging.
        let root = try LibraryDiskScanner.scan(bundleURL: bundle)
        #expect(root.leafCount == 1)
        #expect(root.categories == ["Bass"])
    }
}
