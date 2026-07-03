import Foundation

/// v3.0.6 — Filesystem-backed library enumeration with Panel-taxonomy mapping.
///
/// Logic Pro stores every factory instrument patch as a `.patch` bundle
/// (which is itself a directory) under:
///     ~/Music/Logic Pro Library.bundle/Patches/Instrument/
///
/// v3.0.5 assumed the disk hierarchy WAS the Library Panel path. That was
/// wrong: Logic's Panel "flattens" some level-2 folders to top-level (e.g.
/// `Drums & Percussion/Electronic Drums/...` on disk is `Electronic Drums/...`
/// in the Panel), promotes newer grouped content (`Brass & Woodwind/Studio Horns`
/// → `Studio Horns`, `Strings/Studio Strings` → `Studio Strings`), and also
/// renames some intermediate folders (`z01 Kit Pieces` → `Kit Pieces`). Emitting
/// raw disk paths meant `selectPath` failed at segment 0 on the majority of
/// patches.
///
/// v3.0.6 introduces `mapDiskPathToPanel`: a longest-prefix mapper that
/// rewrites disk segments into Panel segments before they're baked into a
/// `LibraryNode.path`. Paths whose top-level category does not exist in the
/// v3.0.4 AX-scanned Panel inventory are dropped (the scanner refuses to
/// emit categories `selectPath` cannot navigate to), with the exception of
/// 1:1-matching categories (Bass, Guitar, Mallet, Synthesizer) which pass
/// through untouched.
///
/// The returned `LibraryRoot` is schema-identical to the AX-scan output so
/// existing callers (resolve_path, clients consuming the JSON output of
/// `library.scan_all`) do not need to change.
enum LibraryDiskScanner {

    /// The canonical factory-content location. Third-party / Jam Pack content
    /// is not enumerated — Logic exposes only this bundle through the Library
    /// Panel's instrument category list, so matching its scope here keeps the
    /// returned `LibraryRoot` aligned with what `selectPath` can actually
    /// navigate to.
    static let defaultBundleRelativePath =
        "Music/Logic Pro Library.bundle/Patches/Instrument"

    static let defaultAppBundlePath =
        "/Applications/Logic Pro.app/Contents/Resources/Library.bundle/Patches/Instrument"

    /// The `.patch` suffix marks a leaf patch bundle. Stripped from the
    /// display name so clients see "Acid Etched Bass", not "Acid Etched
    /// Bass.patch" (matching the Library Panel display).
    static let patchSuffix = ".patch"

    /// Depth cap mirrors `LibraryAccessor.enumerateTree` (12). Prevents
    /// runaway recursion on pathological symlink loops that slipped past
    /// the resolved-path visited set.
    static let maxDepth = 12

    /// Keep diagnostics bounded even on damaged installations with many
    /// unreadable directories.
    static let maxScanWarnings = 64

    enum ScanError: Error {
        case bundleNotFound(String)
        case notADirectory(String)
        case enumerationFailed(String)
    }

    // MARK: - Disk → Panel taxonomy mapping (v3.0.6)

    /// Disk-prefix → Panel-prefix lookup table. Keys are `/`-joined disk
    /// segments. The mapper tries the LONGEST prefix first, so a 2-segment
    /// disk path like `Drums & Percussion/Acoustic Drums/...` collapses to a
    /// 1-segment Panel path `Acoustic Drums/...` before the fallback
    /// `Drums & Percussion` → (no-match) check runs.
    ///
    /// Verified against `Resources/library-inventory.json` (AX panel snapshot).
    /// Panel categories: Bass, Acoustic Drums, Electronic Drums, Percussion,
    /// Guitar, Acoustic Piano, Clavinet, Electric Piano, Mellotron, Organ,
    /// Mallet, Studio Horns, Studio Strings, Synthesizer, Orchestral, World.
    static let diskToPanel: [String: String] = [
        "Brass & Woodwind/Studio Horns": "Studio Horns",
        "Drums & Percussion/Acoustic Drums": "Acoustic Drums",
        "Drums & Percussion/Electronic Drums": "Electronic Drums",
        "Drums & Percussion/Percussion": "Percussion",
        "Keyboard/Acoustic Piano": "Acoustic Piano",
        "Keyboard/Clavinet": "Clavinet",
        "Keyboard/Electric Piano": "Electric Piano",
        "Keyboard/Mellotron": "Mellotron",
        "Keyboard/Organ": "Organ",
        "z_Legacy/Orchestral": "Orchestral",
        "z_Legacy/World": "World",
        "Strings/Studio Strings": "Studio Strings",
        "Strings": "Orchestral",
    ]

    /// Identity-passthrough set: top-level disk categories that already
    /// match a Panel category 1:1 and should emit unchanged.
    static let identityCategories: Set<String> = [
        "Bass", "Guitar", "Mallet", "Synthesizer",
    ]

    /// Intermediate-folder renames (applied to non-top segments). Logic's
    /// Panel drops the `z01 ` sort prefix from intra-category folders.
    static let intermediateRenames: [String: String] = [
        "z01 Kit Pieces": "Kit Pieces",
        "z02 Multi-Channel Kits": "Multi-Channel Kits",
    ]

    private static let nonApplicableDiskPathKeys: Set<String> = [
        "Drums & Percussion/Electronic Drums/z01 Kit Pieces/Template/Empty Pad",
        "Drums & Percussion/Electronic Drums/z01 Kit Pieces/Template/Empty Quick Sampler",
    ]

    /// Rewrite a disk-segment sequence into Panel-segment form.
    ///
    /// Algorithm (longest-prefix match on `diskToPanel`):
    ///   1. For k = min(2, segs.count) down to 1:
    ///        joined = segs[0..<k].joined("/")
    ///        if diskToPanel[joined] exists → return [mapped] + segs[k...] (renamed)
    ///   2. If segs[0] is in `identityCategories` → return segs as-is (renamed)
    ///   3. Otherwise return nil → caller drops the path (no valid Panel route).
    ///
    /// "renamed" = passing intermediate segments through `intermediateRenames`
    /// so disk `z01 Kit Pieces` surfaces as Panel `Kit Pieces`.
    static func mapDiskPathToPanel(_ diskSegments: [String]) -> [String]? {
        guard !diskSegments.isEmpty else { return [] }

        // 1. Longest-prefix match. Current table only has 1-and-2-segment
        //    keys; we upper-bound at 2 to keep this O(1) per call.
        let maxPrefix = min(2, diskSegments.count)
        for k in stride(from: maxPrefix, through: 1, by: -1) {
            let joined = diskSegments[0..<k].joined(separator: "/")
            if let mapped = diskToPanel[joined] {
                let tail = Array(diskSegments[k...])
                return [mapped] + tail.map { renameIntermediate($0) }
            }
        }
        // 2. Identity passthrough for 1:1 categories.
        if identityCategories.contains(diskSegments[0]) {
            let tail = Array(diskSegments.dropFirst())
            return [diskSegments[0]] + tail.map { renameIntermediate($0) }
        }
        return nil
    }

    private static func renameIntermediate(_ segment: String) -> String {
        return intermediateRenames[segment] ?? segment
    }

    // MARK: - Public entry points

    /// Enumerate the Logic Pro factory Library on disk into a `LibraryRoot`.
    ///
    /// - Parameters:
    ///   - homeDirectory: defaults to the real user home; tests inject a
    ///     temp dir to simulate a Library bundle.
    ///   - fileManager: injectable for tests.
    /// - Returns: a populated `LibraryRoot` whose `root.children` mirror the
    ///   top-level Panel categories with every `.patch` bundle surfaced as a
    ///   leaf at the correct Panel-relative depth.
    static func scan(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> LibraryRoot {
        let start = Date()
        let home = homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
        let userBundleURL = home.appendingPathComponent(defaultBundleRelativePath)
        let appBundleURL = URL(fileURLWithPath: defaultAppBundlePath)
        return try scan(
            bundleURLs: [userBundleURL, appBundleURL],
            fileManager: fileManager,
            start: start
        )
    }

    /// Scan a specific Patches/Instrument directory. Tests use this entry
    /// point to point at a fixture directory without going through HOME.
    static func scan(
        bundleURL: URL,
        fileManager: FileManager = .default,
        start: Date = Date()
    ) throws -> LibraryRoot {
        try scan(
            bundleURLs: [bundleURL],
            fileManager: fileManager,
            start: start,
            requireAllBundles: true
        )
    }

    static func scan(
        bundleURLs: [URL],
        fileManager: FileManager = .default,
        start: Date = Date()
    ) throws -> LibraryRoot {
        try scan(
            bundleURLs: bundleURLs,
            fileManager: fileManager,
            start: start,
            requireAllBundles: false
        )
    }

    private static func scan(
        bundleURLs: [URL],
        fileManager: FileManager,
        start: Date,
        requireAllBundles: Bool
    ) throws -> LibraryRoot {
        guard let firstBundleURL = bundleURLs.first else {
            throw ScanError.bundleNotFound("")
        }

        var visited = Set<String>()
        var rawLeaves: [[String]] = []
        var skippedDirectoryCount = 0
        var scanWarnings: [String] = []
        var scannedBundleCount = 0
        for bundleURL in bundleURLs {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDir)
            guard exists else {
                if requireAllBundles {
                    throw ScanError.bundleNotFound(bundleURL.path)
                }
                recordBundleWarning(
                    "missing_bundle",
                    path: bundleURL.path,
                    scanWarnings: &scanWarnings
                )
                continue
            }
            guard isDir.boolValue else {
                if requireAllBundles {
                    throw ScanError.notADirectory(bundleURL.path)
                }
                recordBundleWarning(
                    "not_directory",
                    path: bundleURL.path,
                    scanWarnings: &scanWarnings
                )
                continue
            }

            let topNames: [String]
            do {
                topNames = try fileManager.contentsOfDirectory(atPath: bundleURL.path)
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
            } catch {
                if requireAllBundles {
                    throw ScanError.enumerationFailed(bundleURL.path)
                }
                recordBundleWarning(
                    "enumeration_failed",
                    path: bundleURL.path,
                    scanWarnings: &scanWarnings
                )
                continue
            }

            scannedBundleCount += 1
            for name in topNames {
                let childURL = bundleURL.appendingPathComponent(name)
                guard isDirectory(childURL, fileManager: fileManager) else { continue }
                collectDiskLeaves(
                    url: childURL,
                    pathSegments: [name],
                    depth: 1,
                    visited: &visited,
                    rawLeaves: &rawLeaves,
                    skippedDirectoryCount: &skippedDirectoryCount,
                    scanWarnings: &scanWarnings,
                    fileManager: fileManager
                )
            }
        }

        guard scannedBundleCount > 0 else {
            throw ScanError.bundleNotFound(firstBundleURL.path)
        }

        let uniqueRawLeaves = deduplicateRawLeaves(rawLeaves)

        var panelLeavesByCategory: [String: [[String]]] = [:]
        var panelCategoryOrder: [String] = []
        var nonApplicablePatchCount = 0
        for diskSegs in uniqueRawLeaves {
            if nonApplicableDiskPathKeys.contains(diskSegs.joined(separator: "/")) {
                recordNonApplicablePatch(
                    diskSegs,
                    reason: "non_applicable:no_panel_template_route",
                    nonApplicablePatchCount: &nonApplicablePatchCount,
                    scanWarnings: &scanWarnings
                )
                continue
            }
            guard let panelSegs = mapDiskPathToPanel(diskSegs), !panelSegs.isEmpty else {
                recordNonApplicablePatch(
                    diskSegs,
                    reason: "non_applicable:no_panel_taxonomy_route",
                    nonApplicablePatchCount: &nonApplicablePatchCount,
                    scanWarnings: &scanWarnings
                )
                continue
            }
            let category = panelSegs[0]
            if panelLeavesByCategory[category] == nil {
                panelLeavesByCategory[category] = []
                panelCategoryOrder.append(category)
            }
            panelLeavesByCategory[category]!.append(panelSegs)
        }

        panelCategoryOrder.sort()
        var topChildren: [LibraryNode] = []
        for category in panelCategoryOrder {
            let leafPaths = panelLeavesByCategory[category] ?? []
            let node = buildPanelSubtree(
                category: category,
                leafPaths: leafPaths
            )
            topChildren.append(node)
        }

        let rootNode = LibraryNode(
            name: "(library-root)",
            path: "",
            kind: .folder,
            children: topChildren
        )

        let counts = countNodes(rootNode)
        let categories = topChildren.map(\.name)
        let presetsByCategory = flattenPresetsByCategory(rootNode)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        return LibraryRoot(
            generatedAt: ISO8601DateFormatter().string(from: start),
            scanDurationMs: durationMs,
            measuredSettleDelayMs: 0,         // no settle needed for a disk scan
            selectionRestored: false,         // disk scan never touches the panel
            truncatedBranches: 0,
            probeTimeouts: 0,
            cycleCount: 0,
            nodeCount: counts.total,
            leafCount: counts.leaves,
            folderCount: counts.folders,
            candidatePatchCount: uniqueRawLeaves.count,
            nonApplicablePatchCount: nonApplicablePatchCount,
            root: rootNode,
            categories: categories,
            presetsByCategory: presetsByCategory,
            skippedDirectoryCount: skippedDirectoryCount,
            scanWarnings: scanWarnings
        )
    }

    // MARK: - Private helpers

    private static func deduplicateRawLeaves(_ rawLeaves: [[String]]) -> [[String]] {
        var seen = Set<String>()
        var unique: [[String]] = []
        for leaf in rawLeaves {
            let key = leaf.joined(separator: "\u{0000}")
            guard seen.insert(key).inserted else { continue }
            unique.append(leaf)
        }
        return unique
    }

    private static func recordBundleWarning(
        _ code: String,
        path: String,
        scanWarnings: inout [String]
    ) {
        guard scanWarnings.count < maxScanWarnings else { return }
        scanWarnings.append("\(code) path=\"\(path)\"")
    }

    private static func recordNonApplicablePatch(
        _ diskSegments: [String],
        reason: String,
        nonApplicablePatchCount: inout Int,
        scanWarnings: inout [String]
    ) {
        nonApplicablePatchCount += 1
        guard scanWarnings.count < maxScanWarnings else { return }
        let path = diskSegments.joined(separator: "/")
        scanWarnings.append(
            "unmapped_patch path=\"\(path)\" reason=\"\(reason)\""
        )
    }

    /// First-pass walk: produces a flat list of `diskSegments` for every
    /// reachable `.patch` leaf. Uses `visited` (keyed by resolved absolute
    /// path via `URL.resolvingSymlinksInPath()`) so symlink cycles cannot
    /// drive the recursion past the depth cap.
    private static func collectDiskLeaves(
        url: URL,
        pathSegments: [String],
        depth: Int,
        visited: inout Set<String>,
        rawLeaves: inout [[String]],
        skippedDirectoryCount: inout Int,
        scanWarnings: inout [String],
        fileManager: FileManager
    ) {
        // Depth cap — mirrors AX scan's 12-level bound.
        if depth > maxDepth { return }

        let resolved = url.resolvingSymlinksInPath().path
        if visited.contains(resolved) { return }
        visited.insert(resolved)

        let rawName = url.lastPathComponent
        let isPatchBundle = rawName.hasSuffix(patchSuffix)

        if isPatchBundle {
            // Strip `.patch` from the LAST segment so Panel-display names
            // match Logic's own ("Acid Etched Bass", not "…bass.patch").
            var segs = pathSegments
            if let last = segs.last, last.hasSuffix(patchSuffix) {
                segs[segs.count - 1] = String(last.dropLast(patchSuffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            rawLeaves.append(segs)
            return
        }

        // Folder: recurse sorted children. `.patch` bundles and subfolders
        // only — skip files (shouldn't exist in a healthy install, but a
        // stray .DS_Store must not surface as a "leaf").
        let childNames: [String]
        do {
            childNames = try fileManager.contentsOfDirectory(atPath: url.path)
                .filter { !$0.hasPrefix(".") }
                .sorted()
        } catch {
            // One unreadable folder should not abort a full Library scan, but
            // it must be visible to callers because it can explain undercounts.
            recordSkippedDirectory(
                url,
                error: error,
                skippedDirectoryCount: &skippedDirectoryCount,
                scanWarnings: &scanWarnings
            )
            return
        }

        for childName in childNames {
            let childURL = url.appendingPathComponent(childName)
            guard isDirectory(childURL, fileManager: fileManager) else { continue }
            collectDiskLeaves(
                url: childURL,
                pathSegments: pathSegments + [childName],
                depth: depth + 1,
                visited: &visited,
                rawLeaves: &rawLeaves,
                skippedDirectoryCount: &skippedDirectoryCount,
                scanWarnings: &scanWarnings,
                fileManager: fileManager
            )
        }
    }

    private static func recordSkippedDirectory(
        _ url: URL,
        error: Error,
        skippedDirectoryCount: inout Int,
        scanWarnings: inout [String]
    ) {
        skippedDirectoryCount += 1

        guard scanWarnings.count < maxScanWarnings else { return }
        scanWarnings.append(
            "skipped_directory path=\"\(url.path)\" reason=\"\(error.localizedDescription)\""
        )
    }

    /// Given a Panel category name and a list of Panel-relative leaf paths
    /// (each starting with the category as segs[0]), rebuild a folder-tree
    /// node whose `.path` fields are joinable `/`-segments that `selectPath`
    /// can navigate column-by-column.
    ///
    /// De-duplicates on leaf name within a folder — if two disk paths map
    /// to the same Panel path (theoretical, shouldn't happen in a clean
    /// install) we keep the first and silently drop the rest.
    private static func buildPanelSubtree(
        category: String,
        leafPaths: [[String]]
    ) -> LibraryNode {
        let children = buildSubtreeChildren(
            prefix: [category],
            // All leafPaths start with `category` as segs[0]; strip it so
            // the recursion sees "the remainder below this prefix".
            remainders: leafPaths.compactMap { segs in
                segs.count >= 2 ? Array(segs.dropFirst()) : nil
            }
        )
        return LibraryNode(
            name: category,
            path: category,
            kind: .folder,
            children: children
        )
    }

    /// Recursive children builder. `prefix` is the Panel path leading to
    /// this point (so a leaf's full path is `prefix + [leafName]`); each
    /// element of `remainders` is the tail-segments below `prefix`.
    ///
    /// Groups remainders by their first segment:
    ///   - remainder.count == 1  → direct leaf here
    ///   - remainder.count >  1  → nested subfolder, recurse
    private static func buildSubtreeChildren(
        prefix: [String],
        remainders: [[String]]
    ) -> [LibraryNode] {
        var directLeaves: [String] = []           // leaf names directly under prefix
        var seenLeafNames = Set<String>()
        var nestedByFolder: [String: [[String]]] = [:]
        var folderOrder: [String] = []

        for rem in remainders {
            guard !rem.isEmpty else { continue }
            if rem.count == 1 {
                let name = rem[0]
                if !seenLeafNames.contains(name) {
                    seenLeafNames.insert(name)
                    directLeaves.append(name)
                }
            } else {
                let folderName = rem[0]
                if nestedByFolder[folderName] == nil {
                    nestedByFolder[folderName] = []
                    folderOrder.append(folderName)
                }
                nestedByFolder[folderName]!.append(Array(rem.dropFirst()))
            }
        }

        var children: [LibraryNode] = []

        // Build leaf nodes. Full path = prefix + leafName.
        for leafName in directLeaves {
            let segs = prefix + [leafName]
            children.append(LibraryNode(
                name: leafName,
                path: segs.joined(separator: "/"),
                kind: .leaf,
                children: []
            ))
        }

        // Build nested folder nodes recursively.
        for folderName in folderOrder {
            let subPrefix = prefix + [folderName]
            let subChildren = buildSubtreeChildren(
                prefix: subPrefix,
                remainders: nestedByFolder[folderName] ?? []
            )
            children.append(LibraryNode(
                name: folderName,
                path: subPrefix.joined(separator: "/"),
                kind: .folder,
                children: subChildren
            ))
        }

        // Interleave folders + leaves alphabetically (matches AX Panel display).
        children.sort { $0.name < $1.name }
        return children
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    /// Tally total / leaves / folders across the tree, matching the
    /// semantics of `LibraryAccessor.countNodes` used by the AX scan.
    private static func countNodes(
        _ node: LibraryNode
    ) -> (total: Int, leaves: Int, folders: Int) {
        var t = 1
        var l = node.kind == .leaf ? 1 : 0
        var f = node.kind == .folder ? 1 : 0
        for c in node.children {
            let r = countNodes(c)
            t += r.total
            l += r.leaves
            f += r.folders
        }
        return (t, l, f)
    }

    /// Flatten every leaf descendant under each top-level category into
    /// `presetsByCategory`. Mirrors `LibraryAccessor.flattenPresetsByCategory`
    /// so the disk-scan output slots into the same schema contract.
    private static func flattenPresetsByCategory(
        _ root: LibraryNode
    ) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for topCat in root.children {
            guard topCat.kind != .leaf else {
                out[topCat.name] = []
                continue
            }
            var leaves: [String] = []
            collectLeaves(topCat, into: &leaves)
            out[topCat.name] = leaves
        }
        return out
    }

    private static func collectLeaves(_ node: LibraryNode, into acc: inout [String]) {
        if node.kind == .leaf {
            acc.append(node.name)
            return
        }
        for child in node.children {
            collectLeaves(child, into: &acc)
        }
    }
}
