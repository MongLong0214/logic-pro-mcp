import Foundation

/// v3.0.5 — Filesystem-backed library enumeration.
///
/// Logic Pro stores every factory instrument patch as a `.patch` bundle
/// (which is itself a directory) under:
///     ~/Music/Logic Pro Library.bundle/Patches/Instrument/
///
/// The on-disk hierarchy *IS* the Library Panel navigation path expected by
/// `LibraryAccessor.selectPath(segments:)`, so a pure filesystem enumeration
/// yields a ground-truth LibraryRoot without ever touching the live Library
/// Panel (no clicks, no mutation of the user's focused track).
///
/// Compare with `LibraryAccessor.enumerateTree` (AX probe): the AX path can
/// only safely enumerate the first two columns of Logic's "finder column"
/// browser because any click on a leaf-looking item in a deeper column may
/// actually load that preset onto the focused track — i.e. it mutates user
/// state. The disk scan has no such constraint.
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

    /// The `.patch` suffix marks a leaf patch bundle. Stripped from the
    /// display name so clients see "Acid Etched Bass", not "Acid Etched
    /// Bass.patch" (matching the Library Panel display).
    static let patchSuffix = ".patch"

    enum ScanError: Error {
        case bundleNotFound(String)
        case notADirectory(String)
        case enumerationFailed(String)
    }

    /// Enumerate the Logic Pro factory Library on disk into a `LibraryRoot`.
    ///
    /// - Parameters:
    ///   - homeDirectory: defaults to the real user home; tests inject a
    ///     temp dir to simulate a Library bundle.
    ///   - fileManager: injectable for tests.
    /// - Returns: a populated `LibraryRoot` whose `root.children` mirror the
    ///   top-level category folders in the bundle, with every `.patch` bundle
    ///   surfaced as a leaf node.
    static func scan(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> LibraryRoot {
        let start = Date()
        let home = homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
        let bundleURL = home.appendingPathComponent(defaultBundleRelativePath)
        return try scan(bundleURL: bundleURL, fileManager: fileManager, start: start)
    }

    /// Scan a specific Patches/Instrument directory. Tests use this entry
    /// point to point at a fixture directory without going through HOME.
    static func scan(
        bundleURL: URL,
        fileManager: FileManager = .default,
        start: Date = Date()
    ) throws -> LibraryRoot {
        // 1. Validate the bundle path exists and is a directory.
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDir)
        guard exists else {
            throw ScanError.bundleNotFound(bundleURL.path)
        }
        guard isDir.boolValue else {
            throw ScanError.notADirectory(bundleURL.path)
        }

        // 2. Enumerate top-level category directories. Each one becomes a
        //    top-level child of the synthetic "(library-root)" node so the
        //    resulting tree matches what the AX scan produces.
        let topNames: [String]
        do {
            topNames = try fileManager.contentsOfDirectory(atPath: bundleURL.path)
                .filter { !$0.hasPrefix(".") }   // skip .DS_Store etc.
                .sorted()
        } catch {
            throw ScanError.enumerationFailed(bundleURL.path)
        }

        var topChildren: [LibraryNode] = []
        for name in topNames {
            let childURL = bundleURL.appendingPathComponent(name)
            // Top-level entries are always directories in a healthy bundle,
            // but we defensively skip anything else (no stray files should
            // appear, but if they do we don't crash).
            guard isDirectory(childURL, fileManager: fileManager) else {
                continue
            }
            let node = buildNode(
                url: childURL,
                pathSegments: [name],
                fileManager: fileManager
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
            root: rootNode,
            categories: categories,
            presetsByCategory: presetsByCategory
        )
    }

    // MARK: - Private helpers

    /// Recursive tree builder. A directory whose name ends in `.patch` is a
    /// leaf (the patch bundle itself); any other directory is a folder that
    /// recurses. Non-directory entries are ignored entirely — only folders
    /// and `.patch` bundles carry semantic meaning in Logic's library.
    private static func buildNode(
        url: URL,
        pathSegments: [String],
        fileManager: FileManager
    ) -> LibraryNode {
        let rawName = url.lastPathComponent
        let isPatchBundle = rawName.hasSuffix(patchSuffix)

        if isPatchBundle {
            // Strip `.patch` for display + for the path segment that
            // `selectPath` will use to click the Library Panel leaf.
            let displayName = String(rawName.dropLast(patchSuffix.count))
            var segments = pathSegments
            if let last = segments.last {
                segments[segments.count - 1] = last.hasSuffix(patchSuffix)
                    ? String(last.dropLast(patchSuffix.count))
                    : last
            }
            return LibraryNode(
                name: displayName,
                path: segments.joined(separator: "/"),
                kind: .leaf,
                children: []
            )
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
            // Unreadable folder: emit an empty folder rather than crashing
            // the whole scan. Matches the AX scan's "graceful-empty" shape.
            return LibraryNode(
                name: rawName, path: pathSegments.joined(separator: "/"),
                kind: .folder, children: []
            )
        }

        var children: [LibraryNode] = []
        for childName in childNames {
            let childURL = url.appendingPathComponent(childName)
            guard isDirectory(childURL, fileManager: fileManager) else { continue }
            let child = buildNode(
                url: childURL,
                pathSegments: pathSegments + [childName],
                fileManager: fileManager
            )
            children.append(child)
        }

        return LibraryNode(
            name: rawName,
            path: pathSegments.joined(separator: "/"),
            kind: .folder,
            children: children
        )
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
